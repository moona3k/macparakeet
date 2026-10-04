import XCTest

@testable import MacParakeetCore

private final class FakeRealtimeSocket: RealtimeSTTSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private var incoming: AsyncStream<String>.Continuation!
    private var iterator: AsyncStream<String>.Iterator

    init() {
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { continuation = $0 }
        iterator = stream.makeAsyncIterator()
        incoming = continuation
    }

    var sent: [String] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { _closed } }

    func push(_ message: String) { incoming.yield(message) }

    func send(_ text: String) async throws { lock.withLock { _sent.append(text) } }

    func receive() async throws -> String {
        guard let message = await iterator.next() else { throw CancellationError() }
        return message
    }

    func close() {
        lock.withLock { _closed = true }
        incoming.finish()
    }
}

private final class PartialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func add(_ value: String) { lock.withLock { _values.append(value) } }
}

private final class RealtimeMemoryKeys: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}

final class RealtimeTranscribeEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CloudSTTConfigStore!

    override func setUp() {
        suiteName = "test.realtime-stt.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = CloudSTTConfigStore(defaults: defaults, keychain: RealtimeMemoryKeys())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async
    {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("Timed out", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private let speech = [Float](repeating: 0.2, count: 1_600)  // 100 ms
    private let silence = [Float](repeating: 0, count: 1_600)

    // MARK: - Config

    func testRealtimeURLDerivesFromServerAddress() {
        XCTAssertEqual(
            CloudSTTConfig(baseURL: "https://api.openai.com/v1").realtimeURL?.absoluteString,
            "wss://api.openai.com/v1/realtime?intent=transcription"
        )
        XCTAssertEqual(
            CloudSTTConfig(baseURL: "http://localhost:8080/v1/").realtimeURL?.absoluteString,
            "ws://localhost:8080/v1/realtime?intent=transcription"
        )
        XCTAssertNil(CloudSTTConfig(baseURL: "ftp://x").realtimeURL)
    }

    func testNotOfferedWithoutARealtimeModel() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let engine = RealtimeTranscribeEngine(configStore: store) { _, _ in
            XCTFail("Must not connect without a realtime model")
            return FakeRealtimeSocket()
        }

        let ready = await engine.isReady()
        XCTAssertFalse(ready)
        do {
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            XCTFail("Expected unsupportedEngine")
        } catch {
            XCTAssertEqual(error as? STTLiveDictationTranscriptionError, .unsupportedEngine(.cloud))
        }
    }

    // MARK: - Session

    func testStreamsAudioCommitsPhrasesAndReportsPartials() async throws {
        try store.save(
            CloudSTTConfig(
                baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "sk-test",
                realtimeModel: "gpt-realtime-whisper"))
        let socket = FakeRealtimeSocket()
        let connected = PartialRecorder()
        let engine = RealtimeTranscribeEngine(configStore: store) { url, apiKey in
            connected.add("\(url.absoluteString)|\(apiKey ?? "")")
            return socket
        }
        let partials = PartialRecorder()

        try await engine.beginLiveDictation(language: nil, onPartial: { partials.add($0) })

        XCTAssertEqual(connected.values, ["wss://example.com/v1/realtime?intent=transcription|sk-test"])
        let update = try XCTUnwrap(socket.sent.first)
        XCTAssertTrue(update.contains(#""type":"session.update""#))
        XCTAssertTrue(update.contains(#""model":"gpt-realtime-whisper""#))
        XCTAssertTrue(update.contains(#""type":"transcription""#))
        XCTAssertTrue(update.contains(#""rate":24000"#))
        XCTAssertTrue(update.contains(#""turn_detection":null"#))

        // Speech, then a pause long enough to end the phrase.
        for _ in 0..<3 { try await engine.processLiveDictationSamples(speech) }
        XCTAssertFalse(socket.sent.contains { $0.contains("input_audio_buffer.commit") })
        for _ in 0..<6 { try await engine.processLiveDictationSamples(silence) }
        XCTAssertEqual(socket.sent.filter { $0.contains("input_audio_buffer.commit") }.count, 1)
        XCTAssertEqual(socket.sent.filter { $0.contains("input_audio_buffer.append") }.count, 9)

        // More silence must not commit an empty buffer.
        for _ in 0..<10 { try await engine.processLiveDictationSamples(silence) }
        XCTAssertEqual(socket.sent.filter { $0.contains("input_audio_buffer.commit") }.count, 1)

        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hello"}"#)
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":" wor"}"#)
        await waitUntil { partials.values.last == "Hello wor" }
        socket.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hello world."}"#
        )
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"Next"}"#)
        await waitUntil { partials.values.last == "Hello world. Next" }

        let result = try await engine.finishLiveDictation()
        XCTAssertEqual(result.text, "Hello world. Next")
        XCTAssertEqual(result.engine, .cloud)
        XCTAssertEqual(result.engineVariant, "gpt-realtime-whisper")
        XCTAssertTrue(socket.isClosed)
    }

    func testCancelClosesTheConnection() async throws {
        try store.save(
            CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k", realtimeModel: "m"))
        let socket = FakeRealtimeSocket()
        let engine = RealtimeTranscribeEngine(configStore: store) { _, _ in socket }

        try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
        try await engine.processLiveDictationSamples(speech)
        await engine.cancelLiveDictation()

        XCTAssertTrue(socket.isClosed)
        let countAfterCancel = socket.sent.count
        try await engine.processLiveDictationSamples(speech)
        XCTAssertEqual(socket.sent.count, countAfterCancel, "No audio is sent after cancel")
    }

    // MARK: - Helpers

    func testParseEventIgnoresUnknownTypesAndReadsErrors() {
        XCTAssertNil(RealtimeTranscribeEngine.parseEvent(#"{"type":"session.updated"}"#))
        XCTAssertNil(RealtimeTranscribeEngine.parseEvent("not json"))
        XCTAssertEqual(
            RealtimeTranscribeEngine.parseEvent(#"{"type":"error","error":{"code":"invalid_model","message":"x"}}"#),
            .error(code: "invalid_model")
        )
    }

    func testResamplerProducesThreeSamplesForEveryTwoAcrossChunks() {
        var carry: Float?
        let ramp = (0..<1_600).map { Float($0) / 1_600 }
        var output: [Float] = []
        for start in stride(from: 0, to: ramp.count, by: 160) {
            output += RealtimeTranscribeEngine.resample16kTo24k(Array(ramp[start..<start + 160]), carry: &carry)
        }

        XCTAssertEqual(Double(output.count), 2_400, accuracy: 3, "1.5x as many samples")
        XCTAssertTrue(zip(output, output.dropFirst()).allSatisfy { $1 >= $0 - 0.0001 }, "No clicks at chunk joins")
    }

    func testAppendEventEncodesLittleEndianPCM16() throws {
        let event = RealtimeTranscribeEngine.appendEvent(samples: [0, 1, -1])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        let data = try XCTUnwrap(Data(base64Encoded: object["audio"] as? String ?? ""))
        XCTAssertEqual([UInt8](data), [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80])
    }
}
