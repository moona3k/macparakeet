import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private final class FakeSystemMediaController: SystemMediaControlling, @unchecked Sendable {
    enum PauseBehavior {
        case immediate(MediaPauseToken?)
        case deferred
    }

    struct Snapshot {
        let pauseCallCount: Int
        let resumeTokens: [MediaPauseToken]
    }

    private let lock = NSLock()
    private var pauseBehavior: PauseBehavior
    private var pauseContinuation: CheckedContinuation<MediaPauseToken?, Never>?
    private var pauseStartedHandler: (() -> Void)?
    private var pauseCallCount = 0
    private var resumeTokens: [MediaPauseToken] = []

    init(pauseBehavior: PauseBehavior) {
        self.pauseBehavior = pauseBehavior
    }

    func pauseIfPlaying() async -> MediaPauseToken? {
        await withCheckedContinuation { continuation in
            var shouldResumeImmediately = false
            var immediateToken: MediaPauseToken?
            var startedHandler: (() -> Void)?

            withLock {
                pauseCallCount += 1
                switch pauseBehavior {
                case .immediate(let token):
                    shouldResumeImmediately = true
                    immediateToken = token
                case .deferred:
                    pauseContinuation = continuation
                    startedHandler = pauseStartedHandler
                }
            }

            if shouldResumeImmediately {
                continuation.resume(returning: immediateToken)
            } else {
                startedHandler?()
            }
        }
    }

    func resume(_ token: MediaPauseToken) async {
        withLock {
            resumeTokens.append(token)
        }
    }

    func setPauseStartedHandler(_ handler: @escaping () -> Void) {
        withLock {
            pauseStartedHandler = handler
        }
    }

    func completeDeferredPause(with token: MediaPauseToken?) {
        let continuation = withLock {
            let continuation = pauseContinuation
            pauseContinuation = nil
            return continuation
        }

        continuation?.resume(returning: token)
    }

    func snapshot() -> Snapshot {
        withLock {
            Snapshot(pauseCallCount: pauseCallCount, resumeTokens: resumeTokens)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
final class DictationMediaPauseCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var settings: SettingsViewModel!

    override func setUp() {
        defaultsSuiteName = "dictation-media-pause-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        settings = SettingsViewModel(defaults: defaults)
    }

    override func tearDown() {
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        settings = nil
        defaults = nil
        defaultsSuiteName = nil
    }

    func testDisabledSettingSkipsPauseAndResume() async {
        let token = MediaPauseToken(processIdentifier: 101)
        let media = FakeSystemMediaController(pauseBehavior: .immediate(token))
        let coordinator = makeCoordinator(media: media)

        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        await coordinator.resumeAfterDictationCapture()

        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 0)
        XCTAssertEqual(snapshot.resumeTokens, [])
    }

    func testMeetingRecordingActiveSkipsPause() async {
        settings.pauseMediaDuringDictation = true
        let token = MediaPauseToken(processIdentifier: 101)
        let media = FakeSystemMediaController(pauseBehavior: .immediate(token))
        let coordinator = makeCoordinator(media: media, isMeetingRecordingActive: true)

        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        await coordinator.resumeAfterDictationCapture()

        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 0)
        XCTAssertEqual(snapshot.resumeTokens, [])
    }

    func testPauseTokenIsResumedOnceWhenCaptureEnds() async {
        settings.pauseMediaDuringDictation = true
        let token = MediaPauseToken(processIdentifier: 101)
        let media = FakeSystemMediaController(pauseBehavior: .immediate(token))
        let coordinator = makeCoordinator(media: media)

        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        await coordinator.resumeAfterDictationCapture()
        await coordinator.resumeAfterDictationCapture()

        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 1)
        XCTAssertEqual(snapshot.resumeTokens, [token])
    }

    func testNoTokenDoesNotResume() async {
        settings.pauseMediaDuringDictation = true
        let media = FakeSystemMediaController(pauseBehavior: .immediate(nil))
        let coordinator = makeCoordinator(media: media)

        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        await coordinator.resumeAfterDictationCapture()

        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 1)
        XCTAssertEqual(snapshot.resumeTokens, [])
    }

    /// The fix: `requestPauseBeforeDictationCapture()` must return without
    /// waiting on the (potentially slow) now-playing round-trip, so audio
    /// capture starts immediately and the first words are never clipped.
    func testRequestPauseDoesNotBlockOnMediaRoundTrip() async {
        settings.pauseMediaDuringDictation = true
        let token = MediaPauseToken(processIdentifier: 1)
        let media = FakeSystemMediaController(pauseBehavior: .deferred)
        let coordinator = makeCoordinator(media: media)
        let pauseStarted = expectation(description: "pause request started")
        media.setPauseStartedHandler {
            pauseStarted.fulfill()
        }

        // Synchronous: returns even though the media round-trip is still in
        // flight (it never resolves until completeDeferredPause below).
        coordinator.requestPauseBeforeDictationCapture()
        await fulfillment(of: [pauseStarted], timeout: 1)

        // Clean up the in-flight pause so the task settles deterministically.
        await coordinator.resumeAfterDictationCapture()
        media.completeDeferredPause(with: token)
        await coordinator.pauseTask?.value

        // The round-trip ran once and its late-arriving token was resumed,
        // never left paused.
        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 1)
        XCTAssertEqual(snapshot.resumeTokens, [token])
    }

    func testLatePauseTokenIsReleasedIfCaptureEndsBeforePauseCompletes() async {
        settings.pauseMediaDuringDictation = true
        let token = MediaPauseToken(processIdentifier: 202)
        let media = FakeSystemMediaController(pauseBehavior: .deferred)
        let coordinator = makeCoordinator(media: media)
        let pauseStarted = expectation(description: "pause request started")
        media.setPauseStartedHandler {
            pauseStarted.fulfill()
        }

        coordinator.requestPauseBeforeDictationCapture()
        await fulfillment(of: [pauseStarted], timeout: 1)

        // Capture ends (resume) before the pause round-trip settles.
        await coordinator.resumeAfterDictationCapture()
        media.completeDeferredPause(with: token)
        await coordinator.pauseTask?.value

        // The late-arriving pause token must be resumed, not left stuck paused.
        let snapshot = media.snapshot()
        XCTAssertEqual(snapshot.pauseCallCount, 1)
        XCTAssertEqual(snapshot.resumeTokens, [token])
    }

    func testTerminationResumesActiveToken() async throws {
        settings.pauseMediaDuringDictation = true
        let token = MediaPauseToken(processIdentifier: 303)
        let media = FakeSystemMediaController(pauseBehavior: .immediate(token))
        let coordinator = makeCoordinator(media: media)

        coordinator.requestPauseBeforeDictationCapture()
        await coordinator.pauseTask?.value
        coordinator.resumeForTermination()

        try await waitUntil {
            media.snapshot().resumeTokens == [token]
        }
    }

    private func makeCoordinator(
        media: FakeSystemMediaController,
        isMeetingRecordingActive: Bool = false
    ) -> DictationMediaPauseCoordinator {
        DictationMediaPauseCoordinator(
            settingsViewModel: settings,
            mediaController: media,
            isMeetingRecordingActive: { isMeetingRecordingActive }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
