@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor FakeCaptionCapture: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private(set) var startedModes: [MeetingAudioSourceMode] = []
    private(set) var stopCount = 0

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        AsyncStream { continuation = $0 }
    }

    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        startedModes.append(sourceMode ?? .microphoneAndSystem)
        return MeetingAudioCaptureStartReport(sourceMode: sourceMode ?? .microphoneAndSystem)
    }

    func stop() async { stopCount += 1 }

    func emit(_ event: MeetingAudioCaptureEvent) { continuation?.yield(event) }
}

private final class CaptionSocket: RealtimeSTTSocket, @unchecked Sendable {
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

private final class SocketPool: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [CaptionSocket] = []
    var sockets: [CaptionSocket] { lock.withLock { _sockets } }
    func make() -> CaptionSocket {
        let socket = CaptionSocket()
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

    func testResamplerConvertsStereo48kToMono24k() {
        let input = buffer()
        let resampler = LiveCaptionResampler(inputFormat: input.format)
        // The converter holds back a few samples at the start of a stream, so
        // the rate is checked over several buffers rather than the first one.
        var samples: [Float] = []
        for _ in 0..<10 { samples += resampler?.convert(input) ?? [] }

        XCTAssertEqual(Double(samples.count), 24_000, accuracy: 600, "Half the frames: 48 kHz to 24 kHz")
        XCTAssertTrue(samples.dropFirst(600).allSatisfy { abs($0 - 0.2) < 0.05 }, "Stereo is mixed to mono, not summed")
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
