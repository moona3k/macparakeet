@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor FakeCaptionCapture: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private(set) var startedModes: [MeetingAudioSourceMode] = []
    private(set) var stopCount = 0
    private let beforeStartReturns: @Sendable () async -> Void

    init(beforeStartReturns: @escaping @Sendable () async -> Void = {}) {
        self.beforeStartReturns = beforeStartReturns
    }

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        AsyncStream { continuation = $0 }
    }

    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        startedModes.append(sourceMode ?? .microphoneAndSystem)
        await beforeStartReturns()
        return MeetingAudioCaptureStartReport(sourceMode: sourceMode ?? .microphoneAndSystem)
    }

    func stop() async { stopCount += 1 }

    func emit(_ event: MeetingAudioCaptureEvent) { continuation?.yield(event) }
}

/// Deliberately ignores task cancellation to model a late external completion.
private actor CaptionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private final class CaptionSocket: RealtimeSTTSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private var incoming: AsyncStream<String>.Continuation!
    private var iterator: AsyncStream<String>.Iterator
    private let beforeSendReturns: @Sendable (String) async -> Void

    init(beforeSendReturns: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.beforeSendReturns = beforeSendReturns
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
        await beforeSendReturns(text)
    }
    func receive() async throws -> String {
        guard let message = await iterator.next() else { throw CancellationError() }
        return message
    }
    func close() {
        lock.withLock { _closed = true }
        incoming.finish()
    }
}

private final class SocketPool: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [CaptionSocket] = []
    var sockets: [CaptionSocket] { lock.withLock { _sockets } }
    func make(beforeSendReturns: @escaping @Sendable (String) async -> Void = { _ in }) -> CaptionSocket {
        let socket = CaptionSocket(beforeSendReturns: beforeSendReturns)
        lock.withLock { _sockets.append(socket) }
        return socket
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [LiveCaptionLine] = []
    var lines: [LiveCaptionLine] { lock.withLock { _lines } }
    func set(_ lines: [LiveCaptionLine]) { lock.withLock { _lines = lines } }
}

private final class CaptionMemoryKeys: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}

private final class ScriptedCaptionConverter: LiveCaptionAudioConverting, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<[Float], LiveCaptionResampler.ConversionError>]
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ outcomes: [Result<[Float], LiveCaptionResampler.ConversionError>]) { self.outcomes = outcomes }
    func matches(_ format: AVAudioFormat) -> Bool { true }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        try lock.withLock {
            _calls += 1
            return try outcomes.removeFirst().get()
        }
    }
}

final class LiveCaptionSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CloudSTTConfigStore!

    override func setUp() {
        suiteName = "test.live-captions.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = CloudSTTConfigStore(defaults: defaults, keychain: CaptionMemoryKeys())
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

    /// 100 ms of 48 kHz stereo audio, as system capture delivers it.
    private func buffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for frame in 0..<4_800 { buffer.floatChannelData![channel][frame] = 0.2 }
        }
        return buffer
    }

    func testRefusesToStartWithoutARealtimeModel() async throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k"))
        let capture = FakeCaptionCapture()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            XCTFail("Must not connect")
            return CaptionSocket()
        }

        do {
            try await session.start(sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in })
            XCTFail("Expected realtimeModelMissing")
        } catch {
            XCTAssertEqual(error as? LiveCaptionSessionError, .realtimeModelMissing)
        }
        let modes = await capture.startedModes
        XCTAssertTrue(modes.isEmpty, "No audio is captured when the service is not set up")
    }

    func testStreamsCapturedAudioAndMergesLinesFromBothSources() async throws {
        try store.save(
            CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "k", realtimeModel: "rt"))
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in pool.make() }
        let box = LineBox()

        try await session.start(sourceMode: .microphoneAndSystem, onUpdate: { box.set($0) }, onFailure: { _ in })

        XCTAssertEqual(pool.sockets.count, 2, "One realtime session per source keeps speakers apart")
        let modes = await capture.startedModes
        XCTAssertEqual(modes, [.microphoneAndSystem])
        let microphone = pool.sockets[0]
        let system = pool.sockets[1]

        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { system.sent.contains { $0.contains("input_audio_buffer.append") } }
        XCTAssertFalse(microphone.sent.contains { $0.contains("input_audio_buffer.append") })

        system.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hallo"}"#)
        await waitUntil { box.lines.count == 1 }
        microphone.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hi."}"#)
        await waitUntil { box.lines.count == 2 }

        XCTAssertEqual(box.lines.map(\.id), ["sys:a", "mic:a"], "Ordered by when each phrase was first heard")
        XCTAssertEqual(box.lines.map(\.source), [.system, .microphone])
        XCTAssertEqual(box.lines.map(\.isFinal), [false, true])

        await session.stop()
        XCTAssertTrue(microphone.isClosed && system.isClosed)
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testResamplerConvertsStereo48kToMono24k() throws {
        let input = buffer()
        let resampler = LiveCaptionResampler(inputFormat: input.format)
        // The converter holds back a few samples at the start of a stream, so
        // the rate is checked over several buffers rather than the first one.
        var samples: [Float] = []
        for _ in 0..<10 { samples += try resampler?.convert(input) ?? [] }

        XCTAssertEqual(Double(samples.count), 24_000, accuracy: 600, "Half the frames: 48 kHz to 24 kHz")
        XCTAssertTrue(samples.dropFirst(600).allSatisfy { abs($0 - 0.2) < 0.05 }, "Stereo is mixed to mono, not summed")
    }

    func testValidEmptyConversionKeepsSessionAliveForTheNextBuffer() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let socket = CaptionSocket()
        let converter = ScriptedCaptionConverter([.success([]), .success(Array(repeating: 0.2, count: 2_400))])
        let session = LiveCaptionSession(
            capture: capture, configStore: store, makeConverter: { _ in converter }, connect: { _, _ in socket })
        try await session.start(
            sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in XCTFail("Priming is not a failure") })
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { converter.calls == 1 }
        XCTAssertFalse(socket.isClosed)
        XCTAssertFalse(socket.sent.contains { $0.contains("input_audio_buffer.append") })
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { socket.sent.contains { $0.contains("input_audio_buffer.append") } }
        await session.stop()
        XCTAssertEqual(converter.calls, 2)
    }

    func testConversionFailureOrUnavailableConverterStopsVisibly() async throws {
        try configureRealtime()
        for unavailable in [false, true] {
            let capture = FakeCaptionCapture()
            let socket = CaptionSocket()
            let failed = expectation(description: "Conversion failure is visible")
            let converter = ScriptedCaptionConverter([.failure(.conversionFailed)])
            let session = LiveCaptionSession(
                capture: capture, configStore: store,
                makeConverter: { _ in unavailable ? nil : converter }, connect: { _, _ in socket })
            try await session.start(
                sourceMode: .systemOnly, onUpdate: { _ in },
                onFailure: { message in
                    XCTAssertTrue(message.contains("conversion failed"))
                    failed.fulfill()
                })
            await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
            await fulfillment(of: [failed], timeout: 2)
            await session.stop()
            XCTAssertTrue(socket.isClosed)
            XCTAssertFalse(socket.sent.contains { $0.contains("input_audio_buffer.append") })
            let stops = await capture.stopCount
            XCTAssertEqual(stops, 1)
        }
    }

    func testNativeResamplerDistinguishesEmptyAudioFromWrongFormat() throws {
        let input = buffer()
        let converter = try XCTUnwrap(LiveCaptionResampler(inputFormat: input.format))
        input.frameLength = 0
        XCTAssertTrue(try converter.convert(input).isEmpty)
        let different = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let other = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: different, frameCapacity: 10))
        other.frameLength = 10
        XCTAssertThrowsError(try converter.convert(other)) {
            guard case LiveCaptionResampler.ConversionError.invalidFormat = $0 else {
                return XCTFail("Wrong format must be an explicit conversion failure")
            }
        }
    }

    func testCommittedSourceOrderReusesCrossSourceArrivalSlots() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let box = LineBox()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in pool.make() }
        try await session.start(sourceMode: .microphoneAndSystem, onUpdate: box.set, onFailure: { _ in })
        let mic = try XCTUnwrap(pool.sockets.first)
        let system = try XCTUnwrap(pool.sockets.last)
        system.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"Second"}"#)
        await waitUntil { box.lines.map(\.id) == ["sys:b"] }
        mic.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"x","transcript":"Microphone"}"#
        )
        await waitUntil { box.lines.map(\.id) == ["sys:b", "mic:x"] }
        system.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"First"}"#)
        await waitUntil { box.lines.map(\.id) == ["sys:b", "mic:x", "sys:a"] }
        system.push(#"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}"#)
        system.push(#"{"type":"input_audio_buffer.committed","item_id":"a","previous_item_id":null}"#)
        await waitUntil { box.lines.map(\.id) == ["sys:a", "mic:x", "sys:b"] }
        XCTAssertEqual(box.lines.map(\.text), ["First", "Microphone", "Second"])
        XCTAssertEqual(box.lines.map(\.source), [.system, .microphone, .system])
        _ = await session.clearHistory()
        let replacement = try XCTUnwrap(pool.sockets.last)
        XCTAssertTrue(mic.isClosed && system.isClosed)
        replacement.push(#"{"type":"input_audio_buffer.committed","item_id":"c","previous_item_id":null}"#)
        system.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"Old"}"#)
        replacement.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"c","transcript":"New"}"#)
        await waitUntil { box.lines.map(\.id) == ["sys:c"] }
        XCTAssertEqual(box.lines.map(\.text), ["New"])
        await session.stop()
    }

    private func configureRealtime() throws {
        try store.save(CloudSTTConfig(baseURL: "https://example.com/v1", model: "m", realtimeModel: "rt"))
    }

    func testStopRevokesPendingConnectionBeforeItCanStartCapture() async throws {
        try configureRealtime()
        let connected = expectation(description: "Connection pending")
        let gate = CaptionGate()
        let capture = FakeCaptionCapture()
        let socket = CaptionSocket()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            connected.fulfill()
            await gate.wait()
            return socket
        }
        let starting = Task {
            try await session.start(sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in })
        }
        await fulfillment(of: [connected], timeout: 3)
        await session.stop()
        await gate.open()
        do {
            try await starting.value
            XCTFail("A stopped startup must not become active")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(socket.isClosed)
        XCTAssertTrue(socket.sent.isEmpty)
        let modes = await capture.startedModes
        XCTAssertTrue(modes.isEmpty)
    }

    func testStopRevokesPendingCaptureStartAndClosesItsSocket() async throws {
        try configureRealtime()
        let captureStarted = expectation(description: "Capture start pending")
        let gate = CaptionGate()
        let capture = FakeCaptionCapture {
            captureStarted.fulfill()
            await gate.wait()
        }
        let socket = CaptionSocket()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in socket }
        let starting = Task {
            try await session.start(sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in })
        }
        await fulfillment(of: [captureStarted], timeout: 3)
        await session.stop()
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1, "Capture receives stop even before its start returns")
        XCTAssertTrue(socket.isClosed)
        await gate.open()
        do {
            try await starting.value
            XCTFail("The late capture result must not reactivate the session")
        } catch { XCTAssertTrue(error is CancellationError) }
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        XCTAssertFalse(socket.sent.contains { $0.contains("input_audio_buffer.append") })
    }

    func testLateConnectionCannotStopOrUpdateARestartedSession() async throws {
        try configureRealtime()
        let firstConnection = expectation(description: "First connection pending")
        let gate = CaptionGate()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let box = LineBox()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            let socket = pool.make()
            if pool.sockets.count == 1 {
                firstConnection.fulfill()
                await gate.wait()
            }
            return socket
        }
        let firstStart = Task {
            try await session.start(
                sourceMode: .systemOnly, onUpdate: { _ in XCTFail("Stale update") },
                onFailure: { _ in XCTFail("Stale failure") })
        }
        await fulfillment(of: [firstConnection], timeout: 3)
        await session.stop()
        try await session.start(sourceMode: .systemOnly, onUpdate: { box.set($0) }, onFailure: { _ in })
        let active = try XCTUnwrap(pool.sockets.last)
        await gate.open()
        do {
            try await firstStart.value
            XCTFail("The superseded start must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(pool.sockets[0].isClosed)
        XCTAssertFalse(active.isClosed)
        let stopsBeforeFinalStop = await capture.stopCount
        XCTAssertEqual(stopsBeforeFinalStop, 0, "The old startup never owned the new capture")
        active.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"new","delta":"New"}"#)
        await waitUntil { box.lines.map(\.text) == ["New"] }
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { active.sent.contains { $0.contains("input_audio_buffer.append") } }
        await session.stop()
    }

    func testStopRevokesPendingSessionUpdate() async throws {
        try configureRealtime()
        let updating = expectation(description: "Session update pending")
        let gate = CaptionGate()
        let capture = FakeCaptionCapture()
        let socket = CaptionSocket { text in
            if text.contains("session.update") {
                updating.fulfill()
                await gate.wait()
            }
        }
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in socket }
        let starting = Task {
            try await session.start(sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in })
        }
        await fulfillment(of: [updating], timeout: 3)
        await session.stop()
        XCTAssertTrue(socket.isClosed)
        await gate.open()
        do {
            try await starting.value
            XCTFail("The late session update must not start capture")
        } catch { XCTAssertTrue(error is CancellationError) }
        let modes = await capture.startedModes
        XCTAssertTrue(modes.isEmpty)
    }

    func testSlowUploadStopsAtBufferLimitAndDiscardsQueuedAudio() async throws {
        try configureRealtime()
        let uploading = expectation(description: "Upload pending")
        let failed = expectation(description: "Overflow reported")
        let gate = CaptionGate()
        let capture = FakeCaptionCapture()
        let socket = CaptionSocket { text in
            if text.contains("input_audio_buffer.append") {
                uploading.fulfill()
                await gate.wait()
            }
        }
        let session = LiveCaptionSession(capture: capture, configStore: store, uploadBufferSampleLimit: 6_000) {
            _, _ in socket
        }
        try await session.start(
            sourceMode: .systemOnly, onUpdate: { _ in },
            onFailure: { message in
                XCTAssertTrue(message.contains("too slow"))
                failed.fulfill()
            })
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await fulfillment(of: [uploading], timeout: 3)
        for _ in 0..<5 { await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0))) }
        await fulfillment(of: [failed], timeout: 3)
        await session.stop()
        XCTAssertTrue(socket.isClosed)
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
        await gate.open()
        XCTAssertEqual(socket.sent.filter { $0.contains("input_audio_buffer.append") }.count, 1)
    }

    func testClearedSessionHistoryDoesNotReturnWithLaterProviderUpdates() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let box = LineBox()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in pool.make() }
        try await session.start(sourceMode: .systemOnly, onUpdate: { box.set($0) }, onFailure: { _ in })
        let socket = try XCTUnwrap(pool.sockets.first)
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"old","delta":"Old"}"#)
        await waitUntil { box.lines.map(\.text) == ["Old"] }
        let cleared = await session.clearHistory()
        XCTAssertTrue(cleared.isEmpty)
        socket.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"Old final"}"#
        )
        let replacement = try XCTUnwrap(pool.sockets.last)
        replacement.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"new","delta":"New"}"#)
        await waitUntil { box.lines.map(\.text) == ["New"] }
        XCTAssertEqual(box.lines.map(\.id), ["sys:new"])
        await session.stop()
    }

    func testClearDropsOldQueueAndPreservesAudioAdmittedDuringReconnect() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let oldSend = CaptionGate()
        let reconnect = CaptionGate()
        let pool = SocketPool()
        let appendStarted = expectation(description: "Old append suspended")
        let reconnectStarted = expectation(description: "Replacement connection suspended")
        let converter = ScriptedCaptionConverter([
            .success([Float](repeating: 0.1, count: 240)),
            .success([Float](repeating: 0.2, count: 240)),
            .success([Float](repeating: 0.3, count: 240)),
        ])
        let box = LineBox()
        let session = LiveCaptionSession(
            capture: capture, configStore: store, makeConverter: { _ in converter },
            connect: { _, _ in
                let index = pool.sockets.count
                let socket = pool.make(beforeSendReturns: { text in
                    if index == 0, text.contains("input_audio_buffer.append") {
                        appendStarted.fulfill()
                        await oldSend.wait()
                    }
                })
                if index == 1 { reconnectStarted.fulfill(); await reconnect.wait() }
                return socket
            })
        defer {
            Task {
                await oldSend.open(); await reconnect.open(); await session.stop()
            }
        }
        try await session.start(sourceMode: .systemOnly, onUpdate: box.set, onFailure: { XCTFail($0) })
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await fulfillment(of: [appendStarted], timeout: 2)
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { converter.calls == 2 }
        let clearing = Task { await session.clearHistory() }
        await fulfillment(of: [reconnectStarted], timeout: 2)
        await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0)))
        await waitUntil { converter.calls == 3 }
        XCTAssertTrue(pool.sockets[0].isClosed)
        XCTAssertTrue(pool.sockets[1].sent.isEmpty, "New audio must wait for session setup")
        await oldSend.open()
        await reconnect.open()
        _ = await clearing.value
        await waitUntil { pool.sockets[1].sent.contains { $0.contains("input_audio_buffer.append") } }
        let appends = pool.sockets[1].sent.filter { $0.contains("input_audio_buffer.append") }
        XCTAssertEqual(appends.count, 1, "The old queued buffer must be discarded")
        XCTAssertEqual(
            appends.first, RealtimeTranscribeEngine.appendEvent(samples: [Float](repeating: 0.3, count: 240)))
        pool.sockets[0].push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"Old"}"#)
        pool.sockets[1].push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"New"}"#)
        await waitUntil { box.lines.map(\.text) == ["New"] }
        let starts = await capture.startedModes
        XCTAssertEqual(starts, [.systemOnly], "Clear keeps capture running")
        await session.stop()
    }

    func testRepeatedClearAndStopRevokeOlderReconnectFailure() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let firstReconnect = CaptionGate()
        let secondReconnect = CaptionGate()
        let firstStarted = expectation(description: "First reconnect pending")
        let secondStarted = expectation(description: "Second reconnect pending")
        let pool = SocketPool()
        let box = LineBox()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            let socket = pool.make()
            switch pool.sockets.count {
            case 2: firstStarted.fulfill(); await firstReconnect.wait(); throw URLError(.cannotConnectToHost)
            case 3: secondStarted.fulfill(); await secondReconnect.wait()
            default: break
            }
            return socket
        }
        defer {
            Task {
                await firstReconnect.open(); await secondReconnect.open(); await session.stop()
            }
        }
        try await session.start(sourceMode: .systemOnly, onUpdate: box.set, onFailure: { XCTFail($0) })
        let first = Task { await session.clearHistory() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await session.clearHistory() }
        await fulfillment(of: [secondStarted], timeout: 2)
        await session.stop()
        try await session.start(sourceMode: .systemOnly, onUpdate: box.set, onFailure: { XCTFail($0) })
        let active = try XCTUnwrap(pool.sockets.last)
        await firstReconnect.open()
        await secondReconnect.open()
        _ = await first.value
        _ = await second.value
        XCTAssertFalse(active.isClosed)
        XCTAssertTrue(pool.sockets[2].isClosed)
        active.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"New"}"#)
        await waitUntil { box.lines.map(\.text) == ["New"] }
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1, "Obsolete Clear cannot stop the restarted capture")
        await session.stop()
    }

    func testRepeatedClearRetainsFailureObserverWithoutMoreAudio() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let gate = CaptionGate()
        let pending = expectation(description: "First reconnect pending")
        let failed = expectation(description: "Replacement still reports server failures")
        let pool = SocketPool()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            let socket = pool.make()
            if pool.sockets.count == 2 { pending.fulfill(); await gate.wait() }
            return socket
        }
        defer {
            Task {
                await gate.open(); await session.stop()
            }
        }
        try await session.start(sourceMode: .systemOnly, onUpdate: { _ in }, onFailure: { _ in failed.fulfill() })
        let first = Task { await session.clearHistory() }
        await fulfillment(of: [pending], timeout: 2)
        _ = await session.clearHistory()
        await gate.open()
        _ = await first.value
        let active = try XCTUnwrap(pool.sockets.last)
        XCTAssertFalse(active.isClosed)
        active.push(#"{"type":"error","error":{"code":"invalid_model"}}"#)
        await fulfillment(of: [failed], timeout: 2)
        await session.stop()
        XCTAssertTrue(active.isClosed)
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testAudioWaitingForReconnectStillUsesTheBufferBound() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let gate = CaptionGate()
        let pool = SocketPool()
        let reconnecting = expectation(description: "Reconnect pending")
        let failed = expectation(description: "Bound exceeded during reconnect")
        let converter = ScriptedCaptionConverter([
            .success([Float](repeating: 0.2, count: 240)),
            .success([Float](repeating: 0.2, count: 240)),
        ])
        let session = LiveCaptionSession(
            capture: capture, configStore: store, uploadBufferSampleLimit: 300,
            makeConverter: { _ in converter },
            connect: { _, _ in
                let socket = pool.make()
                if pool.sockets.count == 2 { reconnecting.fulfill(); await gate.wait() }
                return socket
            })
        defer {
            Task {
                await gate.open(); await session.stop()
            }
        }
        try await session.start(
            sourceMode: .systemOnly, onUpdate: { _ in },
            onFailure: { message in
                XCTAssertTrue(message.contains("too slow"))
                failed.fulfill()
            })
        let clearing = Task { await session.clearHistory() }
        await fulfillment(of: [reconnecting], timeout: 2)
        for _ in 0..<2 { await capture.emit(.systemBuffer(buffer(), AVAudioTime(hostTime: 0))) }
        await fulfillment(of: [failed], timeout: 2)
        await session.stop()
        await gate.open()
        _ = await clearing.value
        XCTAssertTrue(pool.sockets[1].isClosed)
        XCTAssertTrue(pool.sockets[1].sent.isEmpty)
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testReconnectFailureStopsCaptureVisibly() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let failed = expectation(description: "Reconnect failure surfaced")
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in
            if !pool.sockets.isEmpty { throw URLError(.cannotConnectToHost) }
            return pool.make()
        }
        try await session.start(
            sourceMode: .systemOnly, onUpdate: { _ in },
            onFailure: { message in
                XCTAssertTrue(message.contains("after Clear"))
                failed.fulfill()
            })
        _ = await session.clearHistory()
        await fulfillment(of: [failed], timeout: 2)
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(pool.sockets[0].isClosed)
    }

    @MainActor
    func testViewModelClearsSessionHistoryAndStopsOnServerFailure() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in pool.make() }
        let viewModel = LiveCaptionsViewModel(
            sessionFactory: { session },
            liveTranslation: LiveTranslationViewModel(defaults: defaults), defaults: defaults)
        viewModel.start()
        await waitUntil { viewModel.state == .running }
        let socket = try XCTUnwrap(pool.sockets.first)
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"old","delta":"Old"}"#)
        await waitUntil { viewModel.lines.map(\.text) == ["Old"] }
        viewModel.clear()
        XCTAssertTrue(viewModel.lines.isEmpty)
        // A visible new line proves the clear operation has resumed updates.
        await waitUntil {
            if viewModel.lines.map(\.text) == ["New"] { return true }
            if pool.sockets.count > 1 {
                pool.sockets.last?.push(
                    #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"New"}"#
                )
            }
            return false
        }
        socket.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"Old final"}"#
        )
        let replacement = try XCTUnwrap(pool.sockets.last)
        replacement.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"after","transcript":"After"}"#)
        await waitUntil { viewModel.lines.contains { $0.text == "After" } }
        XCTAssertFalse(viewModel.lines.contains { $0.text.contains("Old") })
        replacement.push(#"{"type":"error","error":{"code":"invalid_model","message":"provider detail"}}"#)
        await waitUntil { if case .failed = viewModel.state { return true } else { return false } }
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertTrue(replacement.isClosed)
        XCTAssertFalse(viewModel.notice?.contains("provider detail") ?? true)
        await session.stop()
        let stops = await capture.stopCount
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testCopiedCaptionsPreserveSourceAttributionInBothMode() async throws {
        try configureRealtime()
        let capture = FakeCaptionCapture()
        let pool = SocketPool()
        let session = LiveCaptionSession(capture: capture, configStore: store) { _, _ in pool.make() }
        let viewModel = LiveCaptionsViewModel(
            sessionFactory: { session },
            liveTranslation: LiveTranslationViewModel(defaults: defaults), defaults: defaults)
        viewModel.sourceMode = .microphoneAndSystem
        viewModel.start()
        await waitUntil { viewModel.state == .running }
        XCTAssertEqual(pool.sockets.count, 2)
        pool.sockets[0].push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Question"}"#)
        await waitUntil { viewModel.lines.count == 1 }
        pool.sockets[1].push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Answer"}"#)
        await waitUntil { viewModel.lines.count == 2 }
        XCTAssertEqual(viewModel.transcriptText, "Microphone: Question\n\nComputer audio: Answer")
        viewModel.stop()
        await session.stop()
    }

    @MainActor
    func testViewModelReportsSetupErrorAndRemembersSource() async {
        let capture = FakeCaptionCapture()
        let store = self.store!
        let viewModel = LiveCaptionsViewModel(
            sessionFactory: { LiveCaptionSession(capture: capture, configStore: store) { _, _ in CaptionSocket() } },
            liveTranslation: LiveTranslationViewModel(defaults: defaults),
            defaults: defaults
        )
        XCTAssertEqual(viewModel.sourceMode, .systemOnly)
        viewModel.sourceMode = .microphoneOnly

        viewModel.start()
        await waitUntil { if case .failed = viewModel.state { return true } else { return false } }
        guard case .failed(let message) = viewModel.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(message.contains("realtime model"))

        let reloaded = LiveCaptionsViewModel(
            sessionFactory: { nil }, liveTranslation: LiveTranslationViewModel(defaults: defaults), defaults: defaults)
        XCTAssertEqual(reloaded.sourceMode, .microphoneOnly)
    }
}
