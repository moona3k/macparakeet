import Foundation
import OSLog

/// One realtime connection. Injected so tests never open a socket.
public protocol RealtimeSTTSocket: Sendable {
    func send(_ text: String) async throws
    /// Next text message from the service; throws when the connection ends.
    func receive() async throws -> String
    func close()
    /// Non-content diagnostics (close code and HTTP status), when known.
    var closeDescription: String? { get }
}

extension RealtimeSTTSocket {
    public var closeDescription: String? { nil }
}

/// One phrase of a realtime session, as shown in a live caption view.
public struct RealtimeCaptionLine: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    /// False while the phrase is still being spoken and its text can change.
    public let isFinal: Bool

    public init(id: String, text: String, isFinal: Bool) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
    }
}

public typealias RealtimeSTTConnect = @Sendable (_ url: URL, _ apiKey: String?) async throws -> RealtimeSTTSocket

enum RealtimeSTTFailure: Error, LocalizedError, Equatable, Sendable {
    case connectionLost
    case requestRejected

    var errorDescription: String? {
        switch self {
        case .connectionLost: "The connection to the speech service was lost."
        case .requestRejected:
            "The speech service rejected the realtime session. Check its model and connection settings."
        }
    }
}

public final class URLSessionRealtimeSTTSocket: RealtimeSTTSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, apiKey: String?, session: URLSession = .shared) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        task = session.webSocketTask(with: request)
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    public var closeDescription: String? {
        let status = (task.response as? HTTPURLResponse).map { " http=\($0.statusCode)" } ?? ""
        return "close_code=\(task.closeCode.rawValue)\(status)"
    }
}

/// Streaming half of the online speech engine: sends microphone audio to an
/// OpenAI-compatible Realtime transcription session and reports text while
/// the user is still speaking.
///
/// Like `CloudTranscribeEngine`, this uploads audio and is opt-in (fork
/// amendment to ADR-026). It is only used when the Online engine is selected
/// **and** a realtime model is saved. Dictation still takes its final text
/// from the recorded audio through the file model, so a dropped connection
/// costs the live preview, never the dictation.
actor RealtimeTranscribeEngine: NativeLiveDictating {
    static let inputSampleRate = 16_000
    static let outputSampleRate = 24_000
    /// Samples louder than this count as speech for end-of-phrase detection.
    static let speechRMSThreshold: Float = 0.012
    /// A pause this long after speech ends a phrase and asks for its final text.
    static let phraseEndSilenceMs = 600
    /// Upper bound on one phrase, so a long monologue is still finalized.
    static let maxPhraseMs = 25_000

    private let configStore: CloudSTTConfigStore
    private let connect: RealtimeSTTConnect
    private let recordUsage: @Sendable (UsageEvent) -> Void
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "RealtimeTranscribeEngine")

    private var socket: RealtimeSTTSocket?
    private var generation = 0
    private var failure: RealtimeSTTFailure?
    private var onFailure: (@Sendable (String) -> Void)?
    private var clearedItems: Set<String> = []
    private var receiveTask: Task<Void, Never>?
    private var onPartial: (@Sendable (String) -> Void)?
    private var model = ""
    private var provider = "online"

    /// Arrival is the fallback when a compatible provider supplies no chain.
    private var itemOrder: [String] = []
    private var itemPredecessors: [String: String] = [:]
    private var itemTexts: [String: String] = [:]
    private var finalItems: Set<String> = []
    /// Canonical source order plus a revision so asynchronous delivery cannot
    /// restore an older ordering after a committed predecessor arrives.
    private var onLines: (@Sendable ([RealtimeCaptionLine], Int) -> Void)?
    private var lineRevision = 0
    /// Server event types already written to the diagnostics log this session.
    private var loggedEventTypes: Set<String> = []
    private var hasLoggedFirstText = false
    private var pendingFinals = 0

    private var resampleCarry: [Float] = []
    private var hasSpeechSinceCommit = false
    private var silenceSamples = 0
    private var uncommittedSamples = 0
    private var usage: SessionUsage?

    /// Actor-confined reference retained across an append's await, even when
    /// teardown replaces the current session. A late successful send upserts
    /// the original row, never the replacement session's provider or model.
    private final class SessionUsage {
        var event: UsageEvent
        var sentSamples = 0
        var retired = false

        init(provider: String, model: String) {
            event = UsageEvent(kind: .cloudSpeech, provider: provider, model: model)
        }
    }

    init(
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        connect: @escaping RealtimeSTTConnect = { url, apiKey in
            URLSessionRealtimeSTTSocket(url: url, apiKey: apiKey)
        }
    ) {
        self.init(configStore: configStore, recordUsage: { UsageLedger.shared.record($0) }, connect: connect)
    }

    init(
        configStore: CloudSTTConfigStore,
        recordUsage: @escaping @Sendable (UsageEvent) -> Void,
        connect: @escaping RealtimeSTTConnect
    ) {
        self.configStore = configStore
        self.connect = connect
        self.recordUsage = recordUsage
    }

    func isReady() -> Bool {
        configStore.isReady && configStore.loadMetadata().hasRealtimeModel
    }

    func beginLiveDictation(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        teardown()
        let current = generation
        try Task.checkCancellation()
        let config = try configStore.load()
        guard configStore.isConfigured, config.hasRealtimeModel, let url = config.realtimeURL else {
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.cloud)
        }

        model = config.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider = url.host ?? "online"
        usage = SessionUsage(provider: provider, model: model)
        self.onPartial = onPartial

        let socket = try await connect(url, config.apiKey)
        guard current == generation, !Task.isCancelled else {
            socket.close()
            throw CancellationError()
        }
        self.socket = socket
        do {
            try await socket.send(Self.sessionUpdate(model: model))
            try requireCurrent(current)
        } catch {
            socket.close()
            if current == generation { teardown() }
            throw error
        }

        AudioCaptureDiagnostics.append("realtime_stt_session_started host=\(provider) model=\(model)")
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self?.handle(message, generation: current)
                } catch {
                    if !Task.isCancelled {
                        // No user content: close code, HTTP status, and error type only.
                        let code = (error as? URLError).map { " url_error=\($0.code.rawValue)" } ?? ""
                        AudioCaptureDiagnostics.append(
                            "realtime_stt_socket_closed \(socket.closeDescription ?? "")\(code) error_type=\(type(of: error))"
                        )
                        await self?.fail(.connectionLost, generation: current)
                    }
                    return
                }
            }
        }
    }

    /// Per-phrase updates for caption views. Dictation uses `onPartial`.
    func setLineObserver(_ observer: (@Sendable ([RealtimeCaptionLine], Int) -> Void)?) {
        onLines = observer
        observer?(captionLines(), lineRevision)
    }

    func setFailureObserver(_ observer: (@Sendable (String) -> Void)?) throws {
        onFailure = observer
        if let failure { throw failure }
    }

    func clearCaptionHistory() {
        clearedItems.formUnion(itemOrder)
        itemOrder = []
        itemPredecessors = [:]
        itemTexts = [:]
        finalItems = []
        lineRevision += 1
        onLines?([], lineRevision)
    }

    func processLiveDictationSamples(_ samples: [Float]) async throws {
        let current = generation
        try requireCurrent(current)
        guard let socket, !samples.isEmpty else { return }

        let resampled = Self.resample16kTo24k(samples, carry: &resampleCarry)
        try await send(
            resampled, isSpeech: Self.rms(samples) >= Self.speechRMSThreshold, to: socket, generation: current)
    }

    /// Feeds audio that is already 24 kHz mono (live captions convert capture
    /// buffers straight to the session rate).
    func processSamples24k(_ samples: [Float]) async throws {
        let current = generation
        try requireCurrent(current)
        guard let socket, !samples.isEmpty else { return }

        try await send(
            samples, isSpeech: Self.rms(samples) >= Self.speechRMSThreshold, to: socket, generation: current)
    }

    private func send(_ samples24k: [Float], isSpeech: Bool, to socket: RealtimeSTTSocket, generation: Int) async throws
    {
        try requireCurrent(generation)
        guard !samples24k.isEmpty, let usage else { return }
        try await socket.send(Self.appendEvent(samples: samples24k))
        usage.sentSamples += samples24k.count
        recordRetiredUsage(usage)
        try requireCurrent(generation)

        uncommittedSamples += samples24k.count
        if isSpeech {
            hasSpeechSinceCommit = true
            silenceSamples = 0
        } else {
            silenceSamples += samples24k.count
        }

        // The service does no turn detection for transcription sessions, so
        // the client marks the end of each phrase to receive its final text.
        let phraseEnded = hasSpeechSinceCommit && silenceSamples >= Self.phraseEndSilenceMs * 24
        if phraseEnded || (hasSpeechSinceCommit && uncommittedSamples >= Self.maxPhraseMs * 24) {
            try await commit()
        }
    }

    func finishLiveDictation() async throws -> STTResult {
        let current = generation
        try requireCurrent(current)
        if hasSpeechSinceCommit {
            try? await commit()
        }
        // Give the service a moment to return finals for committed phrases.
        var waitedMs = 0
        while pendingFinals > 0, waitedMs < 3_000 {
            try await Task.sleep(for: .milliseconds(50))
            try requireCurrent(current)
            waitedMs += 50
        }
        try requireCurrent(current)
        let result = STTResult(text: currentText(), words: [], language: nil, engine: .cloud, engineVariant: model)
        teardown()
        return result
    }

    func cancelLiveDictation() async {
        teardown()
    }

    // MARK: - Session

    private func commit() async throws {
        let current = generation
        try requireCurrent(current)
        guard let socket else { return }
        try await socket.send(#"{"type":"input_audio_buffer.commit"}"#)
        try requireCurrent(current)
        pendingFinals += 1
        hasSpeechSinceCommit = false
        silenceSamples = 0
        uncommittedSamples = 0
    }

    private func recordRetiredUsage(_ usage: SessionUsage) {
        guard usage.retired, usage.sentSamples >= 24 else { return }
        usage.event.audioMs = usage.sentSamples / 24
        recordUsage(usage.event)
    }

    private func teardown() {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        if let usage {
            usage.retired = true
            recordRetiredUsage(usage)
        }
        usage = nil
        socket = nil
        onPartial = nil
        onLines = nil
        onFailure = nil
        failure = nil
        clearedItems = []
        finalItems = []
        loggedEventTypes = []
        hasLoggedFirstText = false
        itemOrder = []
        itemPredecessors = [:]
        itemTexts = [:]
        lineRevision = 0
        pendingFinals = 0
        resampleCarry = []
        hasSpeechSinceCommit = false
        silenceSamples = 0
        uncommittedSamples = 0
    }

    private func requireCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
        if let failure { throw failure }
    }

    private func fail(_ error: RealtimeSTTFailure, generation expected: Int) {
        guard generation == expected else { return }
        let notify = onFailure
        teardown()
        failure = error
        notify?(error.localizedDescription)
    }

    private func handle(_ message: String, generation expected: Int) {
        guard generation == expected, !Task.isCancelled else { return }
        logEventTypeOnce(message)
        guard let event = Self.parseEvent(message) else { return }
        switch event {
        case .committed(let itemID, let previousItemID):
            guard !clearedItems.contains(itemID) else { return }
            noteItem(itemID)
            if let previousItemID, !clearedItems.contains(previousItemID) { noteItem(previousItemID) }
            // Ignore malformed cycles instead of hanging or inventing a new
            // order from an invalid predecessor chain.
            var predecessor = previousItemID
            var visited: Set<String> = [itemID]
            while let id = predecessor {
                guard visited.insert(id).inserted else { return }
                predecessor = itemPredecessors[id]
            }
            itemPredecessors[itemID] = previousItemID
            publish()
        case .delta(let itemID, let text):
            guard !clearedItems.contains(itemID) else { return }
            noteItem(itemID)
            itemTexts[itemID, default: ""] += text
            publish()
        case .completed(let itemID, let transcript):
            guard !clearedItems.contains(itemID) else { return }
            noteItem(itemID)
            itemTexts[itemID] = transcript
            finalItems.insert(itemID)
            pendingFinals = max(0, pendingFinals - 1)
            publish()
        case .error:
            logger.error("realtime_stt_request_rejected")
            AudioCaptureDiagnostics.append("realtime_stt_request_rejected")
            fail(.requestRejected, generation: expected)
        }
    }

    private func publish() {
        if !hasLoggedFirstText, !currentText().isEmpty {
            hasLoggedFirstText = true
            AudioCaptureDiagnostics.append("realtime_stt_first_text")
        }
        onPartial?(currentText())
        lineRevision += 1
        onLines?(captionLines(), lineRevision)
    }

    private func captionLines() -> [RealtimeCaptionLine] {
        orderedItems().compactMap { id in
            guard let text = itemTexts[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return RealtimeCaptionLine(id: id, text: text, isFinal: finalItems.contains(id))
        }
    }

    /// Records each server event type once per session (type names only), so
    /// a session that connects but produces no text can be diagnosed.
    private func logEventTypeOnce(_ message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let rawType = object["type"] as? String
        else { return }
        let knownTypes: Set<String> = [
            "session.created", "session.updated", "transcription_session.created", "transcription_session.updated",
            "conversation.item.input_audio_transcription.delta",
            "conversation.item.input_audio_transcription.completed",
            "input_audio_buffer.committed", "error",
        ]
        let type = knownTypes.contains(rawType) ? rawType : "other"
        guard loggedEventTypes.insert(type).inserted else { return }
        AudioCaptureDiagnostics.append("realtime_stt_event type=\(type)")
    }

    private func noteItem(_ itemID: String) {
        if itemTexts[itemID] == nil, !itemOrder.contains(itemID) {
            itemOrder.append(itemID)
        }
    }

    private func currentText() -> String {
        orderedItems()
            .compactMap { itemTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func orderedItems() -> [String] {
        let known = Set(itemOrder)
        var emitted: Set<String> = []
        var ordered: [String] = []
        for item in itemOrder {
            var chain: [String] = []
            var visiting: Set<String> = []
            var next: String? = item
            while let id = next, known.contains(id), !emitted.contains(id), visiting.insert(id).inserted {
                chain.append(id)
                next = itemPredecessors[id]
            }
            for id in chain.reversed() where emitted.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }

    // MARK: - Pure helpers

    enum ServerEvent: Equatable {
        case committed(itemID: String, previousItemID: String?)
        case delta(itemID: String, text: String)
        case completed(itemID: String, transcript: String)
        case error(code: String, message: String)
    }

    static func parseEvent(_ message: String) -> ServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        let itemID = object["item_id"] as? String ?? "item"
        switch type {
        case "input_audio_buffer.committed":
            guard let itemID = object["item_id"] as? String, !itemID.isEmpty,
                object["previous_item_id"] == nil || object["previous_item_id"] is NSNull
                    || object["previous_item_id"] is String
            else { return nil }
            return .committed(itemID: itemID, previousItemID: object["previous_item_id"] as? String)
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = object["delta"] as? String else { return nil }
            return .delta(itemID: itemID, text: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = object["transcript"] as? String else { return nil }
            return .completed(itemID: itemID, transcript: transcript)
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(
                code: (error?["code"] as? String) ?? (error?["type"] as? String) ?? "unknown",
                message: (error?["message"] as? String) ?? "")
        default:
            return nil
        }
    }

    static func sessionUpdate(model: String) -> String {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": outputSampleRate],
                        "transcription": ["model": model],
                        "turn_detection": NSNull(),
                    ]
                ],
            ],
        ]
        return json(payload)
    }

    static func appendEvent(samples: [Float]) -> String {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let value = Int16((max(-1, min(1, finite)) * Float(Int16.max)).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return json(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// 16 kHz → 24 kHz by linear interpolation (three output samples for every
    /// two input samples). Keep one or two unconsumed inputs, including the
    /// interpolation phase, so odd chunk boundaries cannot discard time.
    static func resample16kTo24k(_ samples: [Float], carry: inout [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let input = carry + samples
        let usable = input.count - 1
        guard usable > 0 else {
            carry = input
            return []
        }
        let pairs = usable / 2
        var output: [Float] = []
        output.reserveCapacity(pairs * 3)
        for pair in 0..<pairs {
            let a = input[pair * 2]
            let b = input[pair * 2 + 1]
            let c = input[pair * 2 + 2]
            output.append(a)
            output.append(a + (b - a) * (2.0 / 3.0))
            output.append(b + (c - b) * (1.0 / 3.0))
        }
        carry = Array(input[(pairs * 2)...])
        return output
    }
}
