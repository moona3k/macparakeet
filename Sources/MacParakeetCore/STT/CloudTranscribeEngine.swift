import FluidAudio
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
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            components.host?.isEmpty == false
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
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return url.appendingPathComponent("audio").appendingPathComponent("transcriptions")
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

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.cloud-stt")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Server address and model only; never touches the Keychain.
    public func loadMetadata() -> CloudSTTConfig {
        CloudSTTConfig(
            baseURL: defaults.string(forKey: Self.baseURLKey) ?? CloudSTTConfig.defaultBaseURL,
            model: defaults.string(forKey: Self.modelKey) ?? CloudSTTConfig.defaultModel,
            realtimeModel: defaults.string(forKey: Self.realtimeModelKey) ?? ""
        )
    }

    public func load() throws -> CloudSTTConfig {
        var config = loadMetadata()
        config.apiKey = try keychain.getString(Self.apiKeyKeychainKey)
        return config
    }

    public func save(_ config: CloudSTTConfig) throws {
        defaults.set(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(config.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        defaults.set(
            config.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.realtimeModelKey)
        let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            try keychain.delete(Self.apiKeyKeychainKey)
        } else {
            try keychain.setString(key, forKey: Self.apiKeyKeychainKey)
        }
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
/// Unlike every other engine, this one sends speech audio off the device.
/// It is opt-in, never a default, and departs from ADR-026's local-only ASR
/// rule (see the amendment there). Batch-only: dictation records first and
/// transcribes after stop; meeting preview chunks and final jobs are uploaded
/// as they are submitted.
public actor CloudTranscribeEngine: STTTranscribing {
    static let sampleRate = 16_000
    /// 16 kHz mono 16-bit PCM is ~1.9 MB per minute, so ten minutes stays
    /// under the 25 MB upload limit common to these services.
    static let maxChunkSamples = 10 * 60 * sampleRate
    /// How far back from a chunk limit to look for a quiet point to cut at.
    static let splitSearchSamples = 15 * sampleRate

    private let configStore: CloudSTTConfigStore
    private let transport: CloudSTTTransport
    private let loadSamples: @Sendable (URL) throws -> [Float]
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CloudTranscribeEngine")

    public init(
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        transport: CloudSTTTransport = URLSessionCloudSTTTransport(),
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = { try AudioConverter().resampleAudioFile($0) }
    ) {
        self.configStore = configStore
        self.transport = transport
        self.loadSamples = loadSamples
    }

    /// Ready means configured; there is no model to load.
    public func isReady() -> Bool {
        configStore.isConfigured
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
        let loadSamples = self.loadSamples
        let samples = try await Task.detached(priority: .userInitiated) {
            try loadSamples(audioURL)
        }.value
        try Task.checkCancellation()

        let ranges = Self.chunkRanges(for: samples)
        var texts: [String] = []
        var words: [TimestampedWord] = []
        var detectedLanguage: String?

        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let wav = Self.wavData(from: samples[range])
            let response = try await requestTranscription(
                wav: wav, endpoint: endpoint, config: config, language: language)
            UsageLedger.shared.record(
                UsageEvent(
                    kind: .cloudSpeech,
                    provider: endpoint.host ?? "online",
                    model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
                    audioMs: range.count * 1000 / Self.sampleRate
                ))
            let offsetMs = range.lowerBound * 1000 / Self.sampleRate
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            words.append(
                contentsOf: response.words.map {
                    TimestampedWord(
                        word: $0.word,
                        startMs: $0.startMs + offsetMs,
                        endMs: $0.endMs + offsetMs,
                        confidence: $0.confidence
                    )
                })
            detectedLanguage = detectedLanguage ?? response.language
            onProgress?((index + 1) * 100 / ranges.count, 100)
        }

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

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, body: body)
        } catch let error as CloudSTTError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CloudSTTError.network(error.localizedDescription)
        }

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
                let end = (raw["end"] as? NSNumber)?.doubleValue
            else { return nil }
            let startMs = max(0, Int((start * 1000).rounded()))
            return ParsedWord(
                word: word,
                startMs: startMs,
                endMs: max(startMs, Int((end * 1000).rounded())),
                confidence: (raw["probability"] as? NSNumber)?.doubleValue ?? 1.0
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
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}
