import Foundation
import OSLog

/// Connection settings for the online speech engine. Any server that speaks
/// the OpenAI `audio/transcriptions` API works (OpenAI, Groq, self-hosted).
public struct CloudSTTConfig: Equatable, Sendable {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "whisper-1"

    public var baseURL: String
    public var model: String
    public var apiKey: String?
    /// Optional streaming model (for example `gpt-realtime-whisper`). When
    /// set, dictation shows text while you speak over a realtime connection;
    /// empty turns that off. Files and finished recordings always use `model`.
    public var realtimeModel: String

    public init(
        baseURL: String = defaultBaseURL,
        model: String = defaultModel,
        apiKey: String? = nil,
        realtimeModel: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.realtimeModel = realtimeModel
    }

    /// WebSocket address for a realtime transcription session, derived from
    /// the same server address (`https` → `wss`).
    public var realtimeURL: URL? {
        guard let normalizedEndpoint, var components = URLComponents(string: normalizedEndpoint),
            let scheme = components.scheme
        else { return nil }
        switch scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path =
            (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/realtime"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url
    }

    public var hasRealtimeModel: Bool {
        !realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The endpoint requests are posted to, or `nil` when the base URL is not
    /// a usable http(s) URL.
    public var transcriptionsURL: URL? {
        guard let normalizedEndpoint, let url = URL(string: normalizedEndpoint) else { return nil }
        return url.appendingPathComponent("audio").appendingPathComponent("transcriptions")
    }

    /// Credentials belong to the whole API base, including its path. A different
    /// path on the same host can be a different tenant or reverse-proxy service.
    public var normalizedEndpoint: String? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    public var isUsable: Bool {
        transcriptionsURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Persists the online speech engine settings. The server address and model
/// live in preferences; the API key lives in the Keychain.
public final class CloudSTTConfigStore: @unchecked Sendable {
    public static let baseURLKey = "cloudSTTBaseURL"
    public static let modelKey = "cloudSTTModel"
    public static let realtimeModelKey = "cloudSTTRealtimeModel"
    static let apiKeyKeychainKey = "cloud_stt_api_key"

    private let defaults: UserDefaults
    private let keychain: KeyValueStore
    private static let configurationLock = NSRecursiveLock()
    private static let credentialPrefix = "endpoint-v1:"
    private struct StoredCredential: Codable {
        let endpoint: String?
        let apiKey: String
    }

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.cloud-stt")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Server address and model only; never touches the Keychain.
    public func loadMetadata() -> CloudSTTConfig {
        Self.configurationLock.withLock {
            CloudSTTConfig(
                baseURL: defaults.string(forKey: Self.baseURLKey) ?? CloudSTTConfig.defaultBaseURL,
                model: defaults.string(forKey: Self.modelKey) ?? CloudSTTConfig.defaultModel,
                realtimeModel: defaults.string(forKey: Self.realtimeModelKey) ?? ""
            )
        }
    }

    public func load() throws -> CloudSTTConfig {
        Self.configurationLock.lock()
        defer { Self.configurationLock.unlock() }
        var config = loadMetadata()
        if let stored = try keychain.getString(Self.apiKeyKeychainKey) {
            if stored.hasPrefix(Self.credentialPrefix) {
                let data = Data(stored.dropFirst(Self.credentialPrefix.count).utf8)
                guard let credential = try? JSONDecoder().decode(StoredCredential.self, from: data),
                    credential.endpoint == config.normalizedEndpoint
                else { throw CloudSTTError.endpointCredentialMismatch }
                config.apiKey = credential.apiKey
            } else {
                // Existing installations stored a raw key for the saved endpoint.
                // The next save upgrades it to an endpoint-bound value.
                config.apiKey = stored
            }
        }
        return config
    }

    public func save(_ config: CloudSTTConfig) throws {
        Self.configurationLock.lock()
        defer { Self.configurationLock.unlock() }
        let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            try keychain.delete(Self.apiKeyKeychainKey)
        } else {
            let credential = StoredCredential(endpoint: config.normalizedEndpoint, apiKey: key)
            let encoded = try JSONEncoder().encode(credential)
            try keychain.setString(
                Self.credentialPrefix + String(decoding: encoded, as: UTF8.self), forKey: Self.apiKeyKeychainKey)
        }
        // A failed Keychain write must leave the old endpoint and key paired.
        // The endpoint inside the Keychain value also prevents a mismatched pair
        // from being used after a crash between these two persistent writes.
        defaults.set(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(config.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        defaults.set(
            config.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.realtimeModelKey)
    }

    /// A blank Settings field means keep the saved credential only for its
    /// original endpoint. Callers can explicitly clear it for anonymous servers.
    public func resolvingSavedAPIKey(for draft: CloudSTTConfig) throws -> CloudSTTConfig {
        Self.configurationLock.lock()
        defer { Self.configurationLock.unlock() }
        var resolved = draft
        guard draft.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return draft }
        let saved = try load()
        guard let key = saved.apiKey, !key.isEmpty else { resolved.apiKey = nil; return resolved }
        guard let endpoint = draft.normalizedEndpoint, endpoint == saved.normalizedEndpoint else {
            throw CloudSTTError.endpointCredentialMismatch
        }
        resolved.apiKey = key
        return resolved
    }

    public func clearAPIKey() throws {
        try Self.configurationLock.withLock { try keychain.delete(Self.apiKeyKeychainKey) }
    }

    /// True only after the user has saved a usable server address and model.
    /// The placeholder defaults shown in Settings do not count, so the online
    /// engine is never offered or used before it is deliberately set up.
    public var isConfigured: Bool {
        guard defaults.string(forKey: Self.baseURLKey) != nil,
            defaults.string(forKey: Self.modelKey) != nil
        else { return false }
        return loadMetadata().isUsable
    }

    /// Local readiness includes reading the saved credential. A missing key is
    /// valid for anonymous endpoints; unreadable or mismatched keys are not.
    /// This does not contact the service or validate the credential remotely.
    public var isReady: Bool {
        Self.configurationLock.withLock {
            guard isConfigured, let config = try? load() else { return false }
            return config.isUsable
        }
    }

    public var hasAPIKey: Bool {
        ((try? keychain.getString(Self.apiKeyKeychainKey)) ?? nil)?.isEmpty == false
    }
}

public enum CloudSTTError: Error, LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case server(status: Int, message: String?)
    case network(String)
    case invalidResponse
    case endpointCredentialMismatch

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The online speech engine is not set up. Add its server address and model in Settings → Speech."
        case .unauthorized:
            return "The online speech service rejected the API key. Check it in Settings → Speech."
        case .server(let status, let message) where status == 404:
            // Services answer 404 both for a wrong address and for a model
            // that is not served on the transcription endpoint (for example a
            // realtime-only model), so name both.
            let detail = message.map { ": \($0)" } ?? ""
            return
                "The online speech service returned an error (404)\(detail). Check the server address, and that the model is one for file transcription such as whisper-1 or gpt-4o-transcribe. Realtime-only models do not work here."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                return "The online speech service returned an error (\(status)): \(message)"
            }
            return "The online speech service returned an error (\(status))."
        case .network(let detail):
            return "Could not reach the online speech service: \(detail)"
        case .invalidResponse:
            return "The online speech service returned a response that could not be read."
        case .endpointCredentialMismatch:
            return
                "The server address changed. Enter its API key, or clear the saved key to use a server without authentication."
        }
    }
}

/// Sends one prepared request. Injected so tests never touch the network.
public protocol CloudSTTTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudSTTTransport: CloudSTTTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw CloudSTTError.invalidResponse }
        return (data, http)
    }
}

/// Online speech engine: uploads audio to an OpenAI-compatible
/// `audio/transcriptions` endpoint.
///
/// This batch engine sends speech audio off the device.
/// It is opt-in, never a default, and departs from ADR-026's local-only ASR
/// rule (see the amendment there). Batch-only: dictation records first and
/// transcribes after stop. The shared cloud capability does not enable
/// meeting preview because arbitrary models do not guarantee word timings.
public actor CloudTranscribeEngine: STTTranscribing {
    static let sampleRate = 16_000
    /// 16 kHz mono 16-bit PCM is ~1.9 MB per minute, so ten minutes stays
    /// under the 25 MB upload limit common to these services.
    static let maxChunkSamples = 10 * 60 * sampleRate
    /// How far back from a chunk limit to look for a quiet point to cut at.
    static let splitSearchSamples = 15 * sampleRate

    private let configStore: CloudSTTConfigStore
    private let transport: CloudSTTTransport
    private let makeSampleReader: @Sendable (URL) async throws -> any CloudAudioSampleReading
    private let chunkSampleLimit: Int
    private let splitSearchLimit: Int
    private let retryDelay: Duration
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CloudTranscribeEngine")

    public init(
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        transport: CloudSTTTransport = URLSessionCloudSTTTransport(),
        loadSamples: (@Sendable (URL) throws -> [Float])? = nil,
        retryDelay: Duration = .seconds(1)
    ) {
        self.configStore = configStore
        self.transport = transport
        // Explicit injection is retained for fixtures and Settings' one-second
        // synthetic connection probe. Real recording callers use the file reader.
        if let loadSamples {
            makeSampleReader = { url in CloudArraySampleReader(samples: try loadSamples(url)) }
        } else {
            makeSampleReader = { try CloudAudioFileReader(url: $0) }
        }
        chunkSampleLimit = Self.maxChunkSamples
        splitSearchLimit = Self.splitSearchSamples
        self.retryDelay = retryDelay
    }

    init(
        configStore: CloudSTTConfigStore,
        transport: CloudSTTTransport,
        makeSampleReader: @escaping @Sendable (URL) async throws -> any CloudAudioSampleReading,
        maxChunkSamples: Int,
        splitSearchSamples: Int
    ) {
        precondition(maxChunkSamples > 1 && splitSearchSamples > 0)
        self.configStore = configStore
        self.transport = transport
        self.makeSampleReader = makeSampleReader
        chunkSampleLimit = maxChunkSamples
        splitSearchLimit = splitSearchSamples
        retryDelay = .seconds(1)
    }

    /// Ready means the saved configuration and credential can be loaded.
    public func isReady() -> Bool {
        configStore.isReady
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try await transcribe(
            audioURL: URL(fileURLWithPath: audioPath), job: job, language: nil, onProgress: onProgress)
    }

    public func transcribe(
        audioURL: URL,
        job: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let config = try configStore.load()
        guard configStore.isConfigured, let endpoint = config.transcriptionsURL else {
            throw CloudSTTError.notConfigured
        }

        onProgress?(0, 100)
        try Task.checkCancellation()
        let reader = try await makeSampleReader(audioURL)
        let estimatedSamples = await reader.estimatedSampleCount
        var pending: [Float] = []
        var reachedEnd = false
        var offset = 0
        var texts: [String] = []
        var words: [TimestampedWord] = []
        var detectedLanguage: String?

        while true {
            try Task.checkCancellation()
            // One extra sample distinguishes an exact final window from a
            // longer recording that needs a quiet-point cut. No read occurs
            // during the upload; only the short cut tail survives it.
            while pending.count < chunkSampleLimit + 1, !reachedEnd {
                try Task.checkCancellation()
                let requested = min(CloudAudioFileReader.maxReadSamples, chunkSampleLimit + 1 - pending.count)
                let batch = try await reader.read(maxSamples: requested)
                try Task.checkCancellation()
                guard batch.count <= requested else { throw CloudAudioFileReader.ReadError.invalidBatch }
                if batch.isEmpty { reachedEnd = true } else { pending.append(contentsOf: batch) }
            }
            guard !pending.isEmpty else { break }
            let count = Self.chunkRanges(
                for: pending, maxChunkSamples: chunkSampleLimit, splitSearchSamples: splitSearchLimit
            )[0].count
            let wav = Self.wavData(from: pending[..<count])
            pending = Array(pending.dropFirst(count))
            let response = try await requestTranscription(
                wav: wav, endpoint: endpoint, config: config, language: language)
            try Task.checkCancellation()
            UsageLedger.shared.record(
                UsageEvent(
                    kind: .cloudSpeech,
                    provider: endpoint.host ?? "online",
                    model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
                    audioMs: count * 1000 / Self.sampleRate
                ))
            let offsetMs = offset * 1000 / Self.sampleRate
            let chunkMs = count * 1000 / Self.sampleRate
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            words.append(
                contentsOf: response.words.filter { $0.startMs < chunkMs }.map {
                    TimestampedWord(
                        word: $0.word,
                        startMs: $0.startMs + offsetMs,
                        endMs: min($0.endMs, chunkMs) + offsetMs,
                        confidence: $0.confidence
                    )
                })
            detectedLanguage = detectedLanguage ?? response.language
            offset += count
            let progress = estimatedSamples > 0 ? Int(min(99, Double(offset) / Double(estimatedSamples) * 100)) : 0
            onProgress?(progress, 100)
        }
        guard offset > 0 else { throw AudioProcessorError.insufficientSamples }
        try Task.checkCancellation()
        onProgress?(100, 100)

        return STTResult(
            text: texts.joined(separator: " "),
            words: words,
            language: language ?? detectedLanguage,
            engine: .cloud,
            engineVariant: config.model
        )
    }

    // MARK: - Request

    struct ParsedResponse: Equatable {
        var text: String
        var words: [ParsedWord]
        var language: String?
    }

    struct ParsedWord: Equatable {
        var word: String
        var startMs: Int
        var endMs: Int
        var confidence: Double
    }

    private func requestTranscription(
        wav: Data,
        endpoint: URL,
        config: CloudSTTConfig,
        language: String?
    ) async throws -> ParsedResponse {
        // Word timings need `verbose_json`, which not every model accepts
        // (OpenAI's gpt-4o-transcribe family is `json` only). Fall back to
        // plain text for those rather than failing the transcription.
        do {
            return try await send(wav: wav, endpoint: endpoint, config: config, language: language, wordTimings: true)
        } catch CloudSTTError.server(let status, _) where status == 400 || status == 422 {
            logger.notice("cloud_stt_retry_without_word_timings status=\(status, privacy: .public)")
            return try await send(wav: wav, endpoint: endpoint, config: config, language: language, wordTimings: false)
        }
    }

    private func send(
        wav: Data,
        endpoint: URL,
        config: CloudSTTConfig,
        language: String?,
        wordTimings: Bool
    ) async throws -> ParsedResponse {
        let boundary = "macparakeet-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var fields: [(String, String)] = [("model", config.model.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let language = Self.primaryLanguageSubtag(language) {
            fields.append(("language", language))
        }
        if wordTimings {
            fields.append(("response_format", "verbose_json"))
            fields.append(("timestamp_granularities[]", "word"))
        } else {
            fields.append(("response_format", "json"))
        }
        let body = Self.multipartBody(boundary: boundary, fields: fields, wav: wav)

        let (data, response) = try await sendWithRetry(request, body: body)

        switch response.statusCode {
        case 200..<300:
            guard let parsed = Self.parseResponse(data) else { throw CloudSTTError.invalidResponse }
            return parsed
        case 401, 403:
            throw CloudSTTError.unauthorized
        default:
            throw CloudSTTError.server(status: response.statusCode, message: Self.errorMessage(from: data))
        }
    }

    /// Sends the request, retrying connection-level failures. A brief drop
    /// must not fail a whole meeting; server answers (including errors) are
    /// returned as-is and never retried here.
    private func sendWithRetry(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            do {
                let response = try await transport.send(request, body: body)
                try Task.checkCancellation()
                return response
            } catch let error as CloudSTTError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                let code = (error as? URLError)?.code
                // Only the error code is logged; it carries no user content.
                logger.error(
                    "cloud_stt_network_error attempt=\(attempt, privacy: .public) code=\(code?.rawValue ?? 0, privacy: .public)"
                )
                let canRetry = code.map(Self.transientNetworkCodes.contains) ?? false
                guard canRetry, attempt < Self.maxNetworkAttempts else {
                    let detail =
                        code.map { "\(error.localizedDescription) (code \($0.rawValue))" }
                        ?? error.localizedDescription
                    throw CloudSTTError.network(detail)
                }
                try await Task.sleep(for: retryDelay * attempt)
            }
        }
    }

    static let maxNetworkAttempts = 3
    static let transientNetworkCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .secureConnectionFailed, .notConnectedToInternet,
    ]

    // MARK: - Pure helpers

    static func primaryLanguageSubtag(_ language: String?) -> String? {
        guard
            let primary = language?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(),
            (2...3).contains(primary.count), primary != "auto"
        else { return nil }
        return String(primary)
    }

    static func multipartBody(boundary: String, fields: [(String, String)], wav: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                    .utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func parseResponse(_ data: Data) -> ParsedResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String
        else { return nil }

        let rawWords = object["words"] as? [[String: Any]] ?? []
        let words = rawWords.compactMap { raw -> ParsedWord? in
            guard let word = (raw["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !word.isEmpty,
                let start = (raw["start"] as? NSNumber)?.doubleValue,
                let end = (raw["end"] as? NSNumber)?.doubleValue,
                start.isFinite, end.isFinite, start >= 0, end >= start,
                let startMs = Int(exactly: (start * 1000).rounded()),
                let endMs = Int(exactly: (end * 1000).rounded()),
                endMs <= maxChunkSamples * 1000 / sampleRate
            else { return nil }
            let probability = (raw["probability"] as? NSNumber)?.doubleValue ?? 1
            return ParsedWord(
                word: word,
                startMs: startMs,
                endMs: endMs,
                confidence: probability.isFinite ? min(1, max(0, probability)) : 1
            )
        }
        return ParsedResponse(text: text, words: words, language: object["language"] as? String)
    }

    /// Reads `{"error": {"message": ...}}` or `{"error": "..."}`, bounded so a
    /// provider cannot push an arbitrarily long string into the UI.
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message =
            ((object["error"] as? [String: Any])?["message"] as? String)
            ?? (object["error"] as? String)
            ?? (object["message"] as? String)
        return message.map { String($0.prefix(300)) }
    }

    /// Splits long audio into uploads no longer than `maxChunkSamples`,
    /// cutting at the quietest point shortly before each limit so words are
    /// not split across requests.
    static func chunkRanges(
        for samples: [Float],
        maxChunkSamples: Int = maxChunkSamples,
        splitSearchSamples: Int = splitSearchSamples
    ) -> [Range<Int>] {
        guard samples.count > maxChunkSamples else { return [0..<samples.count] }

        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxChunkSamples {
            let limit = start + maxChunkSamples
            let searchStart = max(start + maxChunkSamples / 2, limit - splitSearchSamples)
            let cut = quietestPoint(in: samples, from: searchStart, to: limit)
            ranges.append(start..<cut)
            start = cut
        }
        if start < samples.count {
            ranges.append(start..<samples.count)
        }
        return ranges
    }

    private static func quietestPoint(in samples: [Float], from: Int, to: Int) -> Int {
        let window = max(1, min(sampleRate / 5, (to - from) / 2))
        guard to - from > window else { return to }

        var best = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = from
        while position + window <= to {
            var energy: Float = 0
            for index in position..<(position + window) {
                energy += samples[index] * samples[index]
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = position + window / 2
            }
            position += window
        }
        return best
    }

    /// 16 kHz mono 16-bit PCM WAV.
    static func wavData(from samples: ArraySlice<Float>) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(Data("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            let finiteSample = sample.isFinite ? sample : 0
            append(Int16((max(-1, min(1, finiteSample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}

/// Compatibility adapter for explicit synthetic/test input. It is never the
/// default decoder for a recording and does not claim bounded source storage.
private actor CloudArraySampleReader: CloudAudioSampleReading {
    let estimatedSampleCount: Int
    private let samples: [Float]
    private var position = 0

    init(samples: [Float]) {
        self.samples = samples
        estimatedSampleCount = samples.count
    }

    func read(maxSamples: Int) throws -> [Float] {
        try Task.checkCancellation()
        let end = min(samples.count, position + maxSamples)
        defer { position = end }
        return Array(samples[position..<end])
    }
}
