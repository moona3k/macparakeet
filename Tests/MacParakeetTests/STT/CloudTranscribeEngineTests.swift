import AVFAudio
import AudioToolbox
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

private actor CancelledFallbackCloudTransport: CloudSTTTransport {
    private(set) var attempts = 0

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return (
            Data(#"{"error":"verbose_json unsupported"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        )
    }
}

private final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectsWrites = false
    func rejectWrites() { lock.withLock { rejectsWrites = true } }

    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws {
        try lock.withLock {
            if rejectsWrites { throw CloudSTTError.unauthorized }
            values[key] = value
        }
    }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}

private actor PullCloudReader: CloudAudioSampleReading {
    let estimatedSampleCount: Int
    private let samples: [Float]
    private let failAt: Int?
    private(set) var position = 0
    private(set) var requests: [Int] = []

    init(samples: [Float], failAt: Int? = nil) {
        self.samples = samples
        self.failAt = failAt
        estimatedSampleCount = samples.count
    }

    func read(maxSamples: Int) throws -> [Float] {
        try Task.checkCancellation()
        requests.append(maxSamples)
        if let failAt, position >= failAt { throw CloudAudioFileReader.ReadError.conversionFailed }
        let end = min(samples.count, position + min(maxSamples, 137))
        defer { position = end }
        return Array(samples[position..<end])
    }
}

private actor PullCloudTransport: CloudSTTTransport {
    private let reader: PullCloudReader
    private let onFirstUpload: @Sendable () async throws -> Void
    private(set) var readPositions: [Int] = []
    private(set) var uploads: [[Int16]] = []

    init(reader: PullCloudReader, onFirstUpload: @escaping @Sendable () async throws -> Void = {}) {
        self.reader = reader
        self.onFirstUpload = onFirstUpload
    }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        readPositions.append(await reader.position)
        let start = try XCTUnwrap(body.range(of: Data("RIFF".utf8))?.lowerBound)
        let count = body.subdata(in: start + 40..<start + 44).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        let samples = body.subdata(in: start + 44..<start + 44 + count).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
        uploads.append(samples)
        if uploads.count == 1 { try await onFirstUpload() }
        let json = #"{"text":"part","words":[{"word":"part","start":0.001,"end":0.002}]}"#
        return (
            Data(json.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
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

    func testSavedCredentialIsReusedOnlyForTheSameNormalizedEndpoint() throws {
        try store.save(CloudSTTConfig(baseURL: "https://provider-a.example/v1", model: "m", apiKey: "secret-a"))
        let same = try store.resolvingSavedAPIKey(
            for: CloudSTTConfig(baseURL: " HTTPS://PROVIDER-A.EXAMPLE:443/v1/ ", model: "new", apiKey: " "))
        XCTAssertEqual(same.apiKey, "secret-a")
        for endpoint in [
            "https://provider-b.example/v1", "http://provider-a.example/v1",
            "https://provider-a.example/other", "https://provider-a.example:444/v1",
        ] {
            XCTAssertThrowsError(try store.resolvingSavedAPIKey(for: CloudSTTConfig(baseURL: endpoint, model: "m"))) {
                XCTAssertEqual($0 as? CloudSTTError, .endpointCredentialMismatch)
            }
        }
        XCTAssertEqual(try store.load().apiKey, "secret-a")
    }

    func testChangedEndpointUsesOnlyExplicitNewKeyForLookupAndTranscription() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://provider-a.example/v1", model: "m", apiKey: "secret-a"))
        let config = try store.resolvingSavedAPIKey(
            for: CloudSTTConfig(baseURL: "https://provider-b.example/v1", model: "m", apiKey: "secret-b"))
        _ = try await CloudSTTModelCatalog.load(config: config) { request in
            XCTAssertEqual(request.url?.host, "provider-b.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-b")
            return (
                Data(#"{"data":[]}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }
        try store.save(config)
        let transport = RecordingCloudTransport(responses: [(200, #"{"text":"ok"}"#)])
        _ = try await makeEngine(transport: transport).transcribe(
            audioURL: audioURL, job: .fileTranscription, language: nil)
        XCTAssertEqual(transport.calls.first?.request.url?.host, "provider-b.example")
        XCTAssertEqual(transport.calls.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-b")

        try store.clearAPIKey()
        let anonymous = try store.resolvingSavedAPIKey(
            for: CloudSTTConfig(baseURL: "https://anonymous.example/v1", model: "m"))
        XCTAssertNil(anonymous.apiKey)
    }

    func testFailedKeychainSaveCannotAttachOldKeyToNewEndpoint() throws {
        let keys = MemoryKeyValueStore()
        let store = CloudSTTConfigStore(defaults: defaults, keychain: keys)
        let original = CloudSTTConfig(baseURL: "https://provider-a.example/v1", model: "m", apiKey: "secret-a")
        try store.save(original)
        keys.rejectWrites()

        XCTAssertThrowsError(
            try store.save(
                CloudSTTConfig(baseURL: "https://provider-b.example/v1", model: "new", apiKey: "secret-b")))

        XCTAssertEqual(try store.load(), original)
    }

    func testEndpointBoundKeyFailsClosedWhenPreferencesAndKeychainDisagree() throws {
        try store.save(CloudSTTConfig(baseURL: "https://provider-b.example/v1", model: "m", apiKey: "secret-b"))
        // Model a restart after the Keychain write but before preferences update.
        defaults.set("https://provider-a.example/v1", forKey: CloudSTTConfigStore.baseURLKey)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? CloudSTTError, .endpointCredentialMismatch)
        }
    }

    func testLegacyRawKeyIsReadAndBoundToEndpointOnNextSave() throws {
        let keys = MemoryKeyValueStore()
        defaults.set("https://provider-a.example/v1", forKey: CloudSTTConfigStore.baseURLKey)
        defaults.set("m", forKey: CloudSTTConfigStore.modelKey)
        try keys.setString("legacy-secret", forKey: CloudSTTConfigStore.apiKeyKeychainKey)
        let store = CloudSTTConfigStore(defaults: defaults, keychain: keys)
        let saved = try store.load()
        XCTAssertEqual(saved.apiKey, "legacy-secret")
        try store.save(saved)
        XCTAssertEqual(try store.load().apiKey, "legacy-secret")
        XCTAssertNotEqual(try keys.getString(CloudSTTConfigStore.apiKeyKeychainKey), "legacy-secret")
        defaults.set("https://provider-b.example/v1", forKey: CloudSTTConfigStore.baseURLKey)
        XCTAssertThrowsError(try store.load())
    }

    func testMalformedProviderTimesAreDiscardedWithoutTrapping() throws {
        let response = try XCTUnwrap(
            CloudTranscribeEngine.parseResponse(
                Data(
                    #"""
                    {"text":"kept","words":[
                      {"word":"huge","start":1e300,"end":1e300},
                      {"word":"negative","start":-1,"end":0},
                      {"word":"reversed","start":2,"end":1},
                      {"word":"out-of-chunk","start":700,"end":701},
                      {"word":"valid","start":0.1,"end":0.2,"probability":2}
                    ]}
                    """#.utf8)))
        XCTAssertEqual(response.text, "kept")
        XCTAssertEqual(response.words.map(\.word), ["valid"])
        XCTAssertEqual(response.words.first?.startMs, 100)
        XCTAssertEqual(response.words.first?.endMs, 200)
        XCTAssertEqual(response.words.first?.confidence, 1)
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

    func testPullDecoderWaitsForUploadAndPreservesEverySampleAndOffset() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        var samples = [Float](repeating: 0.5, count: 2_500)
        for index in 900..<950 { samples[index] = 0 }
        let reader = PullCloudReader(samples: samples)
        let started = expectation(description: "First upload owns the decoded window")
        let completed = expectation(description: "Incremental transcription completed")
        let gate = AsyncStream<Void>.makeStream()
        let transport = PullCloudTransport(reader: reader) {
            started.fulfill()
            for await _ in gate.stream {}
        }
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport, makeSampleReader: { _ in reader },
            maxChunkSamples: 1_000, splitSearchSamples: 400)
        let inputURL = audioURL
        let request = Task {
            defer { completed.fulfill() }
            return try await engine.transcribe(audioURL: inputURL, job: .meetingFinalize, language: nil)
        }
        defer { request.cancel(); gate.continuation.finish() }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 2) == .completed else {
            return XCTFail("First upload did not start")
        }
        let positionDuringUpload = await reader.position
        XCTAssertEqual(positionDuringUpload, 1_001, "Decode only one window plus EOF lookahead before uploading")
        gate.continuation.finish()
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            return XCTFail("Incremental transcription did not complete")
        }
        let result = try await request.value
        let ranges = CloudTranscribeEngine.chunkRanges(for: samples, maxChunkSamples: 1_000, splitSearchSamples: 400)
        let uploads = await transport.uploads
        XCTAssertEqual(uploads.map(\.count), ranges.map(\.count))
        XCTAssertEqual(
            uploads.flatMap { $0 }, samples.map { Int16(($0 * Float(Int16.max)).rounded()) },
            "Quiet-point tails are neither dropped nor duplicated")
        XCTAssertEqual(result.words.map(\.startMs), ranges.map { $0.lowerBound * 1_000 / 16_000 + 1 })
        XCTAssertEqual(result.text, Array(repeating: "part", count: ranges.count).joined(separator: " "))
        let readPositions = await transport.readPositions
        XCTAssertEqual(readPositions, [1_001, 1_901, 2_500])
        let requests = await reader.requests
        XCTAssertTrue(requests.allSatisfy { $0 > 0 && $0 <= 1_001 })
    }

    func testCancellationAfterNoncooperativeUploadPreventsFurtherDecode() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        let reader = PullCloudReader(samples: Array(repeating: 0.2, count: 2_500))
        let transport = PullCloudTransport(reader: reader) {
            withUnsafeCurrentTask { $0?.cancel() }
            // Deliberately return success despite cancellation, like a provider
            // that has already buffered its response.
        }
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport, makeSampleReader: { _ in reader },
            maxChunkSamples: 1_000, splitSearchSamples: 400)
        let inputURL = audioURL
        let request = Task {
            try await engine.transcribe(audioURL: inputURL, job: .meetingFinalize, language: nil)
        }
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let position = await reader.position
        let uploads = await transport.uploads
        XCTAssertEqual(position, 1_001)
        XCTAssertEqual(uploads.count, 1)
    }

    func testCancelledUploadCannotTriggerPlainJSONFallbackUpload() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        let transport = CancelledFallbackCloudTransport()
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport, loadSamples: { _ in [0.1, 0.2] })
        let inputURL = audioURL
        let request = Task {
            try await engine.transcribe(audioURL: inputURL, job: .dictation, language: nil)
        }
        do {
            _ = try await request.value
            XCTFail("Cancellation must win over an unsupported response format")
        } catch is CancellationError {}
        let attempts = await transport.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testDecodeFailureAndEmptyFileDoNotUploadPartialAudio() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        for reader in [
            PullCloudReader(samples: []),
            PullCloudReader(samples: Array(repeating: 0.2, count: 2_500), failAt: 137),
        ] {
            let transport = PullCloudTransport(reader: reader)
            let engine = CloudTranscribeEngine(
                configStore: store, transport: transport, makeSampleReader: { _ in reader },
                maxChunkSamples: 1_000, splitSearchSamples: 400)
            do {
                _ = try await engine.transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)
                XCTFail("Empty or failed decoding must not upload")
            } catch {}
            let uploads = await transport.uploads
            XCTAssertTrue(uploads.isEmpty)
        }
    }

    func testFailedUploadStopsBeforeReadingTheNextWindow() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        let reader = PullCloudReader(samples: Array(repeating: 0.2, count: 2_500))
        let transport = PullCloudTransport(reader: reader) { throw CloudSTTError.unauthorized }
        let engine = CloudTranscribeEngine(
            configStore: store, transport: transport, makeSampleReader: { _ in reader },
            maxChunkSamples: 1_000, splitSearchSamples: 400)
        do {
            _ = try await engine.transcribe(audioURL: audioURL, job: .meetingFinalize, language: nil)
            XCTFail("Expected upload failure")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .unauthorized)
        }
        let position = await reader.position
        XCTAssertEqual(position, 1_001)
    }

    func testFileReaderKeepsResamplingStateAcrossSmallReadsAndDrainsEOF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-reader-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (rate, ext) in [(16_000.0, "wav"), (44_100.0, "wav"), (48_000.0, "wav"), (48_000.0, "m4a")] {
            let url = folder.appendingPathComponent("\(Int(rate)).\(ext)")
            let frames = Int(rate / 4) + 113
            try writeReaderFixture(url, rate: rate, frames: frames)
            let small = try await readFixture(url, batch: 257)
            let large = try await readFixture(url, batch: 16_384)
            XCTAssertEqual(small, large, "Chunk size must not reset the resampler or change its phase")
            let expected = Int((Double(frames) * 16_000 / rate).rounded(.up))
            XCTAssertLessThanOrEqual(abs(small.count - expected), 1)
            XCTAssertGreaterThan(small.suffix(100).reduce(Float(0)) { $0 + $1 * $1 }, 0.01)
        }
    }

    func testDefaultEngineReadsARealFileAndLeavesItIntact() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-default-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeReaderFixture(url, rate: 48_000, frames: 4_913)
        let original = try Data(contentsOf: url)
        let transport = RecordingCloudTransport(responses: [(200, #"{"text":"real file"}"#)])
        let engine = CloudTranscribeEngine(configStore: store, transport: transport)
        let result = try await engine.transcribe(audioURL: url, job: .fileTranscription, language: nil)
        XCTAssertEqual(result.text, "real file")
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func writeReaderFixture(_ url: URL, rate: Double, frames: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        if url.pathExtension == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            buffer.floatChannelData![0][index] = 0
            buffer.floatChannelData![1][index] = Float(sin(Double(index) * 2 * .pi * 440 / rate)) * 0.5
        }
        try file.write(from: buffer)
    }

    private func readFixture(_ url: URL, batch: Int) async throws -> [Float] {
        let reader = try CloudAudioFileReader(url: url)
        let expected = await reader.estimatedSampleCount
        var result: [Float] = []
        while true {
            let next = try await reader.read(maxSamples: batch)
            XCTAssertLessThanOrEqual(next.count, batch)
            if next.isEmpty { return result }
            result.append(contentsOf: next)
            guard result.count <= expected + CloudAudioFileReader.maxReadSamples else {
                throw CloudAudioFileReader.ReadError.noProgress
            }
        }
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

    func testWavEncodingTurnsNonfiniteSamplesIntoSilence() {
        let wav = CloudTranscribeEngine.wavData(from: [Float.nan, .infinity, -.infinity][...])
        XCTAssertEqual(wav.suffix(6), Data(repeating: 0, count: 6))
    }

    func testCapabilitiesAllowConditionalDictationWithoutGuaranteedMeetingTimings() {
        let capabilities = SpeechEngineCapabilityRegistry.capabilities(for: .cloud)
        XCTAssertTrue(
            capabilities.supportsNativeLiveDictation, "Offered; declined at start unless a realtime model is saved")
        XCTAssertFalse(capabilities.providesWordTimestamps, "Arbitrary online models do not guarantee word timings")
        XCTAssertFalse(capabilities.supportsMeetingLivePreview)
        XCTAssertNil(capabilities.modelLifecycle.minimumMemoryBytes)
        XCTAssertFalse(capabilities.modelLifecycle.isUserDeletable)
        XCTAssertEqual(SpeechEnginePreference.cloud.displayName, "Online")
    }
}
