import XCTest

@testable import MacParakeetCore

private final class FakeRealtimeSocket: RealtimeSTTSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private var incoming: AsyncStream<String>.Continuation!
    private var iterator: AsyncStream<String>.Iterator
    private let beforeSendReturns: @Sendable (String) async throws -> Void
    private let beforeReceiveReturns: @Sendable (String) async -> Void

    init(
        beforeReceiveReturns: @escaping @Sendable (String) async -> Void = { _ in },
        beforeSendReturns: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.beforeSendReturns = beforeSendReturns
        self.beforeReceiveReturns = beforeReceiveReturns
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { continuation = $0 }
        iterator = stream.makeAsyncIterator()
        incoming = continuation
    }

    var sent: [String] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { _closed } }

    func push(_ message: String) { incoming.yield(message) }

    func send(_ text: String) async throws {
        lock.withLock { _sent.append(text) }
        try await beforeSendReturns(text)
    }

    func receive() async throws -> String {
        guard let message = await iterator.next() else { throw CancellationError() }
        await beforeReceiveReturns(message)
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
    var failReads = false
    func getString(_ key: String) throws -> String? {
        try lock.withLock {
            if failReads { throw URLError(.cannotOpenFile) }
            return values[key]
        }
    }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}

private final class RealtimeUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UUID: UsageEvent] = [:]
    private var _writes: [UsageEvent] = []
    var rows: [UsageEvent] { lock.withLock { Array(events.values) } }
    var writes: [UsageEvent] { lock.withLock { _writes } }
    func record(_ event: UsageEvent) {
        lock.withLock {
            events[event.id] = event; _writes.append(event)
        }
    }
}

/// Deliberately permits a socket send to complete after close/cancel.
private actor RealtimeAppendGate {
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let started: @Sendable () -> Void
    private let fails: Bool

    init(fails: Bool, started: @escaping @Sendable () -> Void) {
        self.fails = fails
        self.started = started
    }

    func intercept(_ text: String) async throws {
        guard text.contains("input_audio_buffer.append") else { return }
        count += 1
        guard count == 2 else { return }
        started()
        if !opened { await withCheckedContinuation { continuation = $0 } }
        if fails { throw URLError(.networkConnectionLost) }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RealtimeClearGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private final class RealtimeClearSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeRealtimeSocket]
    init(_ sockets: [FakeRealtimeSocket]) { self.sockets = sockets }
    func take() -> FakeRealtimeSocket { lock.withLock { sockets.removeFirst() } }
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

    func testReadinessRequiresReadableMatchingCredentialsButAllowsAnonymousServers() async throws {
        let keys = RealtimeMemoryKeys()
        let configStore = CloudSTTConfigStore(defaults: defaults, keychain: keys)
        let engine = RealtimeTranscribeEngine(configStore: configStore) { _, _ in
            XCTFail("Readiness must not contact the server")
            return FakeRealtimeSocket()
        }
        var config = CloudSTTConfig(
            baseURL: "https://first.example/v1", model: "whisper-1", apiKey: "key",
            realtimeModel: "realtime-model")
        try configStore.save(config)
        let savedReady = await engine.isReady()
        XCTAssertTrue(savedReady)

        defaults.set("https://second.example/v1", forKey: CloudSTTConfigStore.baseURLKey)
        let mismatchedReady = await engine.isReady()
        XCTAssertFalse(mismatchedReady)
        defaults.set(config.baseURL, forKey: CloudSTTConfigStore.baseURLKey)
        keys.failReads = true
        let unreadableReady = await engine.isReady()
        XCTAssertFalse(unreadableReady)
        keys.failReads = false

        config.apiKey = nil
        try configStore.save(config)
        let anonymousReady = await engine.isReady()
        XCTAssertTrue(anonymousReady)
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

    func testFailedAppendsDoNotCountUsageOrCommitUnsentSpeech() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "m", realtimeModel: "rt"))
        for direct24k in [false, true] {
            let usage = RealtimeUsageRecorder()
            let socket = FakeRealtimeSocket(beforeSendReturns: { text in
                if text.contains("input_audio_buffer.append") { throw URLError(.networkConnectionLost) }
            })
            let engine = RealtimeTranscribeEngine(configStore: store, recordUsage: usage.record) { _, _ in socket }
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            do {
                if direct24k {
                    try await engine.processSamples24k(Array(repeating: 0.2, count: 2_400))
                } else {
                    try await engine.processLiveDictationSamples(speech)
                }
                XCTFail("Expected failed append")
            } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            _ = try await engine.finishLiveDictation()
            XCTAssertTrue(usage.rows.isEmpty)
            XCTAssertFalse(socket.sent.contains { $0.contains("input_audio_buffer.commit") })
        }
    }

    func testSuccessfulPCMCountsAccumulateBeforeMillisecondsAreRounded() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "m", realtimeModel: "rt"))
        for direct24k in [false, true] {
            let usage = RealtimeUsageRecorder()
            let socket = FakeRealtimeSocket()
            let engine = RealtimeTranscribeEngine(configStore: store, recordUsage: usage.record) { _, _ in socket }
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            for _ in 0..<25 {
                if direct24k {
                    try await engine.processSamples24k([0])
                } else {
                    try await engine.processLiveDictationSamples([0])
                }
            }
            await engine.cancelLiveDictation()
            let samplesSent = try socket.sent.reduce(0) { count, text in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                guard let encoded = object["audio"] as? String else { return count }
                let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
                XCTAssertFalse(bytes.isEmpty, "Resampler priming must not send an empty append")
                return count + bytes.count / 2
            }
            XCTAssertEqual(usage.rows.count, 1)
            XCTAssertEqual(usage.rows.first?.audioMs, samplesSent / 24)
            XCTAssertGreaterThan(usage.rows.first?.audioMs ?? 0, 0)
        }
    }

    func testLateAppendSuccessOrFailureStaysWithOriginalSessionAfterRestart() async throws {
        for fails in [false, true] {
            try store.save(CloudSTTConfig(baseURL: "https://old.example/v1", model: "m", realtimeModel: "old-rt"))
            let usage = RealtimeUsageRecorder()
            let pending = expectation(description: "Old append is suspended")
            let completed = expectation(description: "Old append settled")
            let gate = RealtimeAppendGate(fails: fails) { pending.fulfill() }
            let oldSocket = FakeRealtimeSocket(beforeSendReturns: { try await gate.intercept($0) })
            let newSocket = FakeRealtimeSocket()
            let engine = RealtimeTranscribeEngine(configStore: store, recordUsage: usage.record) { url, _ in
                url.host == "old.example" ? oldSocket : newSocket
            }
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            try await engine.processSamples24k(Array(repeating: 0, count: 2_400))
            let appending = Task {
                defer { completed.fulfill() }
                try await engine.processSamples24k(Array(repeating: 0, count: 2_400))
            }
            defer { appending.cancel() }
            addTeardownBlock {
                await gate.open(); await engine.cancelLiveDictation()
            }
            guard await XCTWaiter.fulfillment(of: [pending], timeout: 2) == .completed else {
                return XCTFail("Append did not suspend")
            }
            await engine.cancelLiveDictation()
            XCTAssertEqual(usage.rows.first?.audioMs, 100, "Unacknowledged audio is not counted at teardown")
            let originalID = usage.rows.first?.id
            let originalDate = usage.rows.first?.createdAt
            try store.save(CloudSTTConfig(baseURL: "https://new.example/v1", model: "m", realtimeModel: "new-rt"))
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            try await engine.processSamples24k(Array(repeating: 0, count: 2_400))
            await engine.cancelLiveDictation()
            await gate.open()
            guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
                return XCTFail("Late append did not settle")
            }
            do {
                try await appending.value
                XCTFail("Retired session cannot resume phrase state")
            } catch {
                if fails {
                    XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
                } else {
                    XCTAssertTrue(error is CancellationError)
                }
            }
            XCTAssertEqual(usage.rows.count, 2, "Late acknowledgement updates the same session row")
            let old = try XCTUnwrap(usage.rows.first { $0.provider == "old.example" })
            let new = try XCTUnwrap(usage.rows.first { $0.provider == "new.example" })
            XCTAssertEqual(old.id, originalID)
            XCTAssertEqual(old.createdAt, originalDate)
            XCTAssertEqual(old.model, "old-rt")
            XCTAssertEqual(old.audioMs, fails ? 100 : 200)
            XCTAssertEqual(new.model, "new-rt")
            XCTAssertEqual(new.audioMs, 100)
        }
    }

    func testCommittedPredecessorsOrderReverseCompletionsAndRejectCycles() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "m", realtimeModel: "rt"))
        let socket = FakeRealtimeSocket()
        let engine = RealtimeTranscribeEngine(configStore: store) { _, _ in socket }
        let partials = PartialRecorder()
        try await engine.beginLiveDictation(language: nil, onPartial: partials.add)
        for item in ["c", "b", "a"] {
            socket.push(
                "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"\(item)\",\"transcript\":\"\(item)\"}"
            )
        }
        await waitUntil { partials.values.last == "c b a" }
        socket.push(#"{"type":"input_audio_buffer.committed","item_id":"c","previous_item_id":"b"}"#)
        socket.push(#"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}"#)
        socket.push(#"{"type":"input_audio_buffer.committed","item_id":"a","previous_item_id":null}"#)
        await waitUntil { partials.values.last == "a b c" }
        socket.push(#"{"type":"input_audio_buffer.committed","item_id":"a","previous_item_id":"c"}"#)
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"d","delta":"d"}"#)
        await waitUntil { partials.values.last == "a b c d" }
        let result = try await engine.finishLiveDictation()
        XCTAssertEqual(result.text, "a b c d")
    }

    // MARK: - Helpers

    func testClearRejectsDelayedCommitAndKeepsOriginalConnectionSettings() async throws {
        try store.save(
            CloudSTTConfig(
                baseURL: "https://original.example/v1", model: "file", apiKey: "original-key",
                realtimeModel: "original-rt"))
        let received = expectation(description: "Old committed event is waiting to return")
        let returned = expectation(description: "Old committed event returned after Clear")
        let gate = RealtimeClearGate()
        let old = FakeRealtimeSocket(beforeReceiveReturns: { _ in
            received.fulfill()
            await gate.wait()
            returned.fulfill()
        })
        let new = FakeRealtimeSocket()
        let sockets = RealtimeClearSockets([old, new])
        let connections = PartialRecorder()
        let partials = PartialRecorder()
        let engine = RealtimeTranscribeEngine(configStore: store) { url, key in
            connections.add("\(url.host ?? "")|\(key ?? "")")
            return sockets.take()
        }
        defer {
            Task {
                await gate.open(); await engine.cancelLiveDictation()
            }
        }
        try await engine.beginLiveDictation(language: nil, onPartial: partials.add)
        try await engine.processSamples24k([Float](repeating: 0.2, count: 2_400))
        try await engine.processSamples24k([Float](repeating: 0, count: 14_400))
        XCTAssertTrue(old.sent.contains { $0.contains("input_audio_buffer.commit") })
        old.push(#"{"type":"input_audio_buffer.committed","item_id":"unknown-old","previous_item_id":null}"#)
        await fulfillment(of: [received], timeout: 2)
        try store.save(
            CloudSTTConfig(
                baseURL: "https://different.example/v1", model: "other", apiKey: "different-key",
                realtimeModel: "different-rt"))
        try await engine.clearCaptionHistory()
        XCTAssertTrue(old.isClosed)
        XCTAssertEqual(connections.values, ["original.example|original-key", "original.example|original-key"])
        XCTAssertTrue(new.sent.first?.contains("original-rt") == true)
        new.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"New"}"#)
        await waitUntil { partials.values.last == "New" }
        await gate.open()
        await fulfillment(of: [returned], timeout: 2)
        old.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"unknown-old","delta":"Old"}"#)
        old.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"unknown-old","transcript":"Old final"}"#
        )
        new.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"after","transcript":"After"}"#)
        await waitUntil { partials.values.last == "New After" }
        XCTAssertFalse(partials.values.contains { $0.contains("Old") })
        await engine.cancelLiveDictation()
    }

    func testClearRevokesSuspendedAppendAndCommitState() async throws {
        for suspendCommit in [false, true] {
            try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "file", realtimeModel: "rt"))
            let started = expectation(description: "Old send suspended")
            let gate = RealtimeClearGate()
            let old = FakeRealtimeSocket(beforeSendReturns: { text in
                let event = suspendCommit ? "input_audio_buffer.commit" : "input_audio_buffer.append"
                if text.contains(event) { started.fulfill(); await gate.wait() }
            })
            let new = FakeRealtimeSocket()
            let sockets = RealtimeClearSockets([old, new])
            let engine = RealtimeTranscribeEngine(configStore: store) { _, _ in sockets.take() }
            try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
            let sending = Task {
                try await engine.processSamples24k([Float](repeating: 0.2, count: 2_400))
                if suspendCommit { try await engine.processSamples24k([Float](repeating: 0, count: 14_400)) }
            }
            defer {
                Task {
                    await gate.open(); await engine.cancelLiveDictation()
                }
            }
            await fulfillment(of: [started], timeout: 2)
            try await engine.clearCaptionHistory()
            await gate.open()
            do { try await sending.value; XCTFail("The old send must be revoked") } catch {
                XCTAssertTrue(error is CancellationError)
            }
            // Old speech/commit state must not turn new silence into a phrase.
            try await engine.processSamples24k([Float](repeating: 0, count: 14_400))
            XCTAssertFalse(new.sent.contains { $0.contains("input_audio_buffer.commit") })
            await engine.cancelLiveDictation()
        }
    }

    func testParseEventIgnoresUnknownTypesAndReadsErrors() {
        XCTAssertNil(RealtimeTranscribeEngine.parseEvent(#"{"type":"session.updated"}"#))
        XCTAssertNil(RealtimeTranscribeEngine.parseEvent("not json"))
        XCTAssertEqual(
            RealtimeTranscribeEngine.parseEvent(#"{"type":"error","error":{"code":"invalid_model","message":"x"}}"#),
            .error(code: "invalid_model", message: "x")
        )
        XCTAssertEqual(
            RealtimeTranscribeEngine.parseEvent(
                #"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}"#),
            .committed(itemID: "b", previousItemID: "a"))
        XCTAssertNil(
            RealtimeTranscribeEngine.parseEvent(
                #"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":7}"#))
    }

    func testResamplerProducesThreeSamplesForEveryTwoAcrossChunks() {
        var carry: [Float] = []
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

    func testOddSizedResamplingChunksPreserveTheSameSamplesAndPhase() {
        let input = (0..<321).map { Float($0) / 321 }
        var wholeCarry: [Float] = []
        let whole = RealtimeTranscribeEngine.resample16kTo24k(input, carry: &wholeCarry)
        for chunkSize in [1, 3, 7, 17, 159] {
            var carry: [Float] = []
            var output: [Float] = []
            for start in stride(from: 0, to: input.count, by: chunkSize) {
                output += RealtimeTranscribeEngine.resample16kTo24k(
                    Array(input[start..<min(start + chunkSize, input.count)]), carry: &carry)
            }
            XCTAssertEqual(output, whole, "Chunk size \(chunkSize) must preserve interpolation phase")
            XCTAssertEqual(carry, wholeCarry)
        }
    }

    func testServerRejectionClosesSocketAndFailsFurtherAudio() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "m", realtimeModel: "rt"))
        let socket = FakeRealtimeSocket()
        let engine = RealtimeTranscribeEngine(configStore: store) { _, _ in socket }
        let failures = PartialRecorder()
        try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
        try await engine.setFailureObserver { failures.add($0) }
        socket.push(#"{"type":"error","error":{"code":"bad_request","message":"private provider detail"}}"#)
        await waitUntil { !failures.values.isEmpty }
        XCTAssertTrue(socket.isClosed)
        XCTAssertFalse(failures.values[0].contains("private provider detail"))
        do {
            try await engine.processLiveDictationSamples(speech)
            XCTFail("Rejected sessions must fail instead of silently consuming audio")
        } catch {
            XCTAssertEqual(error as? RealtimeSTTFailure, .requestRejected)
        }
    }

    func testNonfinitePCMValuesEncodeAsSilence() throws {
        let event = RealtimeTranscribeEngine.appendEvent(samples: [.nan, .infinity, -.infinity])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: object["audio"] as? String ?? ""))
        XCTAssertEqual([UInt8](data), [UInt8](repeating: 0, count: 6))
    }
}
