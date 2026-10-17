import Foundation
import OSLog

/// One realtime connection. Injected so tests never open a socket.
public protocol RealtimeSTTSocket: Sendable {
    func send(_ text: String) async throws
    /// Next text message from the service; throws when the connection ends.
    func receive() async throws -> String
    func close()
    /// Why the connection ended (close code and reason), when known.
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
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let status = (task.response as? HTTPURLResponse).map { " http=\($0.statusCode)" } ?? ""
        return "close_code=\(task.closeCode.rawValue)\(status) reason=\(reason.prefix(200))"
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
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "RealtimeTranscribeEngine")

    private var socket: RealtimeSTTSocket?
    private var receiveTask: Task<Void, Never>?
    private var onPartial: (@Sendable (String) -> Void)?
    private var model = ""
    private var provider = "online"

    /// Phrase texts in the order the service first mentioned them.
    private var itemOrder: [String] = []
    private var itemTexts: [String: String] = [:]
    private var finalItems: Set<String> = []
    private var onLines: (@Sendable ([RealtimeCaptionLine]) -> Void)?
    /// Server event types already written to the diagnostics log this session.
    private var loggedEventTypes: Set<String> = []
    private var hasLoggedFirstText = false
    private var pendingFinals = 0

    private var resampleCarry: Float?
    private var hasSpeechSinceCommit = false
    private var silenceMs = 0
    private var uncommittedMs = 0
    private var totalAudioMs = 0

    init(
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        connect: @escaping RealtimeSTTConnect = { url, apiKey in
            URLSessionRealtimeSTTSocket(url: url, apiKey: apiKey)
        }
    ) {
        self.configStore = configStore
        self.connect = connect
    }

    func isReady() -> Bool {
        configStore.isConfigured && configStore.loadMetadata().hasRealtimeModel
    }

    func beginLiveDictation(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        await cancelLiveDictation()
        let config = try configStore.load()
        guard configStore.isConfigured, config.hasRealtimeModel, let url = config.realtimeURL else {
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.cloud)
        }

        model = config.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider = url.host ?? "online"
        self.onPartial = onPartial

        let socket = try await connect(url, config.apiKey)
        self.socket = socket
        try await socket.send(Self.sessionUpdate(model: model))

        AudioCaptureDiagnostics.append("realtime_stt_session_started host=\(provider) model=\(model)")
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self?.handle(message)
                } catch {
                    if !Task.isCancelled {
                        // No user content: close code, HTTP status, and error type only.
                        let code = (error as? URLError).map { " url_error=\($0.code.rawValue)" } ?? ""
                        AudioCaptureDiagnostics.append(
                            "realtime_stt_socket_closed \(socket.closeDescription ?? "")\(code) error_type=\(type(of: error))"
                        )
                    }
                    return
                }
            }
        }
    }

    /// Per-phrase updates for caption views. Dictation uses `onPartial`.
    func setLineObserver(_ observer: (@Sendable ([RealtimeCaptionLine]) -> Void)?) {
        onLines = observer
    }

    func processLiveDictationSamples(_ samples: [Float]) async throws {
        guard let socket, !samples.isEmpty else { return }

        let chunkMs = samples.count * 1000 / Self.inputSampleRate
        totalAudioMs += chunkMs
        uncommittedMs += chunkMs
        if Self.rms(samples) >= Self.speechRMSThreshold {
            hasSpeechSinceCommit = true
            silenceMs = 0
        } else {
            silenceMs += chunkMs
        }

        let resampled = Self.resample16kTo24k(samples, carry: &resampleCarry)
        try await send(resampled, to: socket)
    }

    /// Feeds audio that is already 24 kHz mono (live captions convert capture
    /// buffers straight to the session rate).
    func processSamples24k(_ samples: [Float]) async throws {
        guard let socket, !samples.isEmpty else { return }

        let chunkMs = samples.count * 1000 / Self.outputSampleRate
        totalAudioMs += chunkMs
        uncommittedMs += chunkMs
        if Self.rms(samples) >= Self.speechRMSThreshold {
            hasSpeechSinceCommit = true
            silenceMs = 0
        } else {
            silenceMs += chunkMs
        }
        try await send(samples, to: socket)
    }

    private func send(_ samples24k: [Float], to socket: RealtimeSTTSocket) async throws {
        try await socket.send(Self.appendEvent(samples: samples24k))

        // The service does no turn detection for transcription sessions, so
        // the client marks the end of each phrase to receive its final text.
        let phraseEnded = hasSpeechSinceCommit && silenceMs >= Self.phraseEndSilenceMs
        if phraseEnded || (hasSpeechSinceCommit && uncommittedMs >= Self.maxPhraseMs) {
            try await commit()
        }
    }

    func finishLiveDictation() async throws -> STTResult {
        if hasSpeechSinceCommit {
            try? await commit()
        }
        // Give the service a moment to return finals for committed phrases.
        var waitedMs = 0
        while pendingFinals > 0, waitedMs < 3_000 {
            try? await Task.sleep(for: .milliseconds(50))
            waitedMs += 50
        }
        let result = STTResult(text: currentText(), words: [], language: nil, engine: .cloud, engineVariant: model)
        teardown()
        return result
    }

    func cancelLiveDictation() async {
        teardown()
    }

    // MARK: - Session

    private func commit() async throws {
        guard let socket else { return }
        try await socket.send(#"{"type":"input_audio_buffer.commit"}"#)
        pendingFinals += 1
        hasSpeechSinceCommit = false
        silenceMs = 0
        uncommittedMs = 0
    }

    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        if socket != nil, totalAudioMs > 0 {
            UsageLedger.shared.record(
                UsageEvent(kind: .cloudSpeech, provider: provider, model: model, audioMs: totalAudioMs))
        }
        socket = nil
        onPartial = nil
        onLines = nil
        finalItems = []
        loggedEventTypes = []
        hasLoggedFirstText = false
        itemOrder = []
        itemTexts = [:]
        pendingFinals = 0
        resampleCarry = nil
        hasSpeechSinceCommit = false
        silenceMs = 0
        uncommittedMs = 0
        totalAudioMs = 0
    }

    private func handle(_ message: String) {
        logEventTypeOnce(message)
        guard let event = Self.parseEvent(message) else { return }
        switch event {
        case .delta(let itemID, let text):
            noteItem(itemID)
            itemTexts[itemID, default: ""] += text
            publish()
        case .completed(let itemID, let transcript):
            noteItem(itemID)
            itemTexts[itemID] = transcript
            finalItems.insert(itemID)
            pendingFinals = max(0, pendingFinals - 1)
            publish()
        case .error(let code, let message):
            // The service's error text describes the request (for example an
            // unsupported parameter); it does not echo audio or transcripts.
            logger.error("realtime_stt_error code=\(code, privacy: .public)")
            AudioCaptureDiagnostics.append("realtime_stt_error code=\(code) message=\(message.prefix(240))")
        }
    }

    private func publish() {
        if !hasLoggedFirstText {
            hasLoggedFirstText = true
            AudioCaptureDiagnostics.append("realtime_stt_first_text")
        }
        onPartial?(currentText())
        if let onLines {
            onLines(
                itemOrder.compactMap { id in
                    guard let text = itemTexts[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                    else { return nil }
                    return RealtimeCaptionLine(id: id, text: text, isFinal: finalItems.contains(id))
                })
        }
    }

    /// Records each server event type once per session (type names only), so
    /// a session that connects but produces no text can be diagnosed.
    private func logEventTypeOnce(_ message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let type = object["type"] as? String, !loggedEventTypes.contains(type), loggedEventTypes.count < 24
        else { return }
        loggedEventTypes.insert(type)
        AudioCaptureDiagnostics.append("realtime_stt_event type=\(type.prefix(80))")
    }

    private func noteItem(_ itemID: String) {
        if itemTexts[itemID] == nil, !itemOrder.contains(itemID) {
            itemOrder.append(itemID)
        }
    }

    private func currentText() -> String {
        itemOrder
            .compactMap { itemTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Pure helpers

    enum ServerEvent: Equatable {
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
            let value = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
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
    /// two input samples). `carry` holds the last input sample so consecutive
    /// chunks join without a click.
    static func resample16kTo24k(_ samples: [Float], carry: inout Float?) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let input = (carry.map { [$0] } ?? []) + samples
        let usable = input.count - 1
        guard usable > 0 else {
            carry = input.last
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
        // An odd leftover input sample waits for the next chunk.
        carry = input[pairs * 2]
        if usable % 2 == 1 {
            output.append(input[pairs * 2])
            carry = input[pairs * 2 + 1]
        }
        return output
    }
}
