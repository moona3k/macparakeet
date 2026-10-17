import XCTest

@testable import MacParakeetCore

private final class RecordingCloudTransport: CloudSTTTransport, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let body: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [(status: Int, json: String)]

    init(responses: [(status: Int, json: String)]) {
        self.responses = responses
    }

    var calls: [Call] { lock.withLock { _calls } }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let response = lock.withLock { () -> (status: Int, json: String) in
            // The WAV payload is binary; keep only the readable multipart text.
            _calls.append(Call(request: request, body: String(decoding: body, as: UTF8.self)))
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (Data(response.json.utf8), http)
    }
}

private final class FlakyCloudTransport: CloudSTTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var _attempts = 0
    private let code: URLError.Code

    init(failures: Int, code: URLError.Code) {
        remainingFailures = failures
        self.code = code
    }

    var attempts: Int { lock.withLock { _attempts } }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let shouldFail = lock.withLock { () -> Bool in
            _attempts += 1
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if shouldFail { throw URLError(code) }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"text":"ok"}"#.utf8), http)
    }
}

private final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}

final class CloudTranscribeEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CloudSTTConfigStore!

    override func setUp() {
        suiteName = "test.cloud-stt.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = CloudSTTConfigStore(defaults: defaults, keychain: MemoryKeyValueStore())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeEngine(
        transport: RecordingCloudTransport,
        samples: [Float] = Array(repeating: 0.1, count: 16_000)
    ) -> CloudTranscribeEngine {
        CloudTranscribeEngine(configStore: store, transport: transport, loadSamples: { _ in samples })
    }

    private let audioURL = URL(fileURLWithPath: "/tmp/audio.wav")

    // MARK: - Config

    func testConfigBuildsEndpointAndRejectsUnusableAddresses() {
        XCTAssertEqual(
            CloudSTTConfig(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3")
                .transcriptionsURL?.absoluteString,
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
        XCTAssertFalse(CloudSTTConfig(baseURL: "not a url", model: "m").isUsable)
        XCTAssertFalse(CloudSTTConfig(baseURL: "ftp://example.com", model: "m").isUsable)
        XCTAssertFalse(CloudSTTConfig(baseURL: "https://example.com/v1", model: "  ").isUsable)
    }

    func testStoreKeepsKeyOutOfPreferences() throws {
        try store.save(CloudSTTConfig(baseURL: " https://example.com/v1 ", model: " whisper-1 ", apiKey: "sk-secret"))

        XCTAssertEqual(defaults.string(forKey: CloudSTTConfigStore.baseURLKey), "https://example.com/v1")
        XCTAssertNil(store.loadMetadata().apiKey)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("sk-secret") })
        XCTAssertEqual(try store.load().apiKey, "sk-secret")
        XCTAssertTrue(store.hasAPIKey)

        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: ""))
        XCTAssertFalse(store.hasAPIKey)
    }

    func testFreshInstallIsNotConfiguredEvenThoughDefaultsLookUsable() async {
        XCTAssertTrue(store.loadMetadata().isUsable, "Placeholders shown in Settings are a valid address and model")
        XCTAssertFalse(store.isConfigured, "Nothing was saved, so the engine must not be offered or used")

        let transport = RecordingCloudTransport(responses: [(200, #"{"text":"x"}"#)])
        do {
            _ = try await makeEngine(transport: transport)
                .transcribe(audioURL: audioURL, job: .fileTranscription, language: nil)
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .notConfigured)
        }
        XCTAssertTrue(transport.calls.isEmpty, "No audio may be uploaded before setup")
    }

    // MARK: - Transcribing

    func testTranscribeSendsModelKeyAndParsesWordTimings() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "sk-test"))
        let transport = RecordingCloudTransport(responses: [
            (
                200,
                #"{"text":" Hello world ","language":"english","words":[{"word":"Hello","start":0.0,"end":0.4},{"word":"world","start":0.5,"end":0.9}]}"#
            )
        ])

        let result = try await makeEngine(transport: transport)
            .transcribe(audioURL: audioURL, job: .fileTranscription, language: "de-DE")

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.words.map(\.word), ["Hello", "world"])
        XCTAssertEqual(result.words.map(\.startMs), [0, 500])
        XCTAssertEqual(result.words.last?.endMs, 900)
        XCTAssertEqual(result.engine, .cloud)
        XCTAssertEqual(result.engineVariant, "whisper-1")
        XCTAssertEqual(result.language, "de-DE")

        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.request.url?.absoluteString, "https://example.com/v1/audio/transcriptions")
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertTrue(call.body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(call.body.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(call.body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        XCTAssertTrue(call.body.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
    }

    func testModelsWithoutWordTimingsFallBackToPlainText() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "gpt-4o-transcribe", apiKey: "k"))
        let transport = RecordingCloudTransport(responses: [
            (400, #"{"error":{"message":"response_format verbose_json is not supported"}}"#),
            (200, #"{"text":"Plain text only"}"#),
        ])

        let result = try await makeEngine(transport: transport)
            .transcribe(audioURL: audioURL, job: .fileTranscription, language: nil)

        XCTAssertEqual(result.text, "Plain text only")
        XCTAssertTrue(result.words.isEmpty)
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertTrue(transport.calls[1].body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertFalse(transport.calls[1].body.contains("name=\"language\""))
    }

    func testLongAudioIsUploadedInChunksWithOffsetWordTimes() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let transport = RecordingCloudTransport(responses: [
            (200, #"{"text":"part","words":[{"word":"part","start":1.0,"end":1.5}]}"#)
        ])
        // Just over one chunk, so the audio must be split into two uploads.
        let samples = [Float](repeating: 0.2, count: CloudTranscribeEngine.maxChunkSamples + 16_000 * 30)

        let result = try await makeEngine(transport: transport, samples: samples)
            .transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)

        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(result.text, "part part")
        XCTAssertEqual(result.words.first?.startMs, 1_000)
        let secondStart = try XCTUnwrap(result.words.last?.startMs)
        XCTAssertGreaterThan(secondStart, 9 * 60 * 1000, "Second chunk's words are offset by the first chunk's length")
        XCTAssertLessThanOrEqual(secondStart, 10 * 60 * 1000 + 1_000)
    }

    func testChunkRangesCoverAllSamplesAndCutAtQuietPoint() {
        var samples = [Float](repeating: 0.5, count: 2_500)
        for index in 900..<950 { samples[index] = 0 }

        let ranges = CloudTranscribeEngine.chunkRanges(for: samples, maxChunkSamples: 1_000, splitSearchSamples: 400)

        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        XCTAssertEqual(zip(ranges, ranges.dropFirst()).filter { $0.upperBound != $1.lowerBound }.count, 0)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 1_000 && !$0.isEmpty })
        XCTAssertTrue((900..<950).contains(ranges[0].upperBound), "First cut lands in the silent stretch")
    }

    // MARK: - Failures

    func testRejectedKeyAndServerErrorsAreReportedWithoutLeakingTheKey() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "sk-secret"))

        do {
            _ = try await makeEngine(transport: RecordingCloudTransport(responses: [(401, "{}")]))
                .transcribe(audioURL: audioURL, job: .fileTranscription, language: nil)
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .unauthorized)
            XCTAssertFalse(error.localizedDescription.contains("sk-secret"))
        }

        do {
            _ = try await makeEngine(
                transport: RecordingCloudTransport(responses: [(500, #"{"error":{"message":"overloaded"}}"#)])
            ).transcribe(audioURL: audioURL, job: .fileTranscription, language: nil)
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .server(status: 500, message: "overloaded"))
        }
    }

    func testTransientNetworkFailureIsRetriedAndThenSucceeds() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let transport = FlakyCloudTransport(failures: 2, code: .networkConnectionLost)
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) }, retryDelay: .milliseconds(1))

        let result = try await engine.transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)

        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(transport.attempts, 3)
    }

    func testPersistentNetworkFailureReportsTheErrorCode() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let transport = FlakyCloudTransport(failures: 99, code: .timedOut)
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) }, retryDelay: .milliseconds(1))

        do {
            _ = try await engine.transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)
            XCTFail("Expected network error")
        } catch let CloudSTTError.network(detail) {
            XCTAssertTrue(detail.contains("-1001"), "The URL error code helps diagnose it: \(detail)")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(transport.attempts, CloudTranscribeEngine.maxNetworkAttempts)
    }

    func testNonTransientNetworkFailureIsNotRetried() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let transport = FlakyCloudTransport(failures: 99, code: .badServerResponse)
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) }, retryDelay: .milliseconds(1))

        _ = try? await engine.transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)
        XCTAssertEqual(transport.attempts, 1)
    }

    func testUnconfiguredEngineDoesNotSendAudio() async throws {
        try store.save(CloudSTTConfig(baseURL: "", model: "whisper-1", apiKey: "k"))
        let transport = RecordingCloudTransport(responses: [(200, #"{"text":"x"}"#)])
        let engine = makeEngine(transport: transport)

        let ready = await engine.isReady()
        XCTAssertFalse(ready)
        do {
            _ = try await engine.transcribe(audioURL: audioURL, job: .dictation, language: nil)
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .notConfigured)
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testWavEncodingIsSixteenBitMonoSixteenKilohertz() {
        let wav = CloudTranscribeEngine.wavData(from: [0, 1, -1, 2][...])

        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 16_000)
        let samples = wav.subdata(in: 44..<52).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [0, Int16.max, -Int16.max, Int16.max], "Out-of-range samples are clamped")
    }

    func testCapabilitiesDescribeABatchEngineWithWordTimings() {
        let capabilities = SpeechEngineCapabilityRegistry.capabilities(for: .cloud)
        XCTAssertTrue(
            capabilities.supportsNativeLiveDictation, "Offered; declined at start unless a realtime model is saved")
        XCTAssertTrue(capabilities.supportsMeetingLivePreview)
        XCTAssertNil(capabilities.modelLifecycle.minimumMemoryBytes)
        XCTAssertFalse(capabilities.modelLifecycle.isUserDeletable)
        XCTAssertEqual(SpeechEnginePreference.cloud.displayName, "Online")
    }
}
