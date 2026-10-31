import AVFoundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class MediaPlayerViewModelTests: XCTestCase {

    @MainActor
    func testChangingSubtitleLanguageClearsPreviousCueDuringGap() {
        let model = MediaPlayerViewModel()
        model.showSubtitles = true
        model.currentTimeMs = 500
        model.loadSubtitleCues(from: [WordTimestamp(word: "Original", startMs: 2000, endMs: 3000, confidence: 1)])
        model.showTranslatedSubtitles(
            [TranslatedSegment(startMs: 0, endMs: 1000, text: "Translated")], language: .german)
        XCTAssertEqual(model.currentSubtitleText, "Translated")
        model.showOriginalSubtitles()
        XCTAssertNil(model.currentSubtitleText)
        model.showTranslatedSubtitles(
            [TranslatedSegment(startMs: 0, endMs: 1000, text: "Translated")], language: .german)
        XCTAssertEqual(model.currentSubtitleText, "Translated")
        model.showTranslatedSubtitles(
            [TranslatedSegment(startMs: 2000, endMs: 3000, text: "Later")], language: .english)
        XCTAssertNil(model.currentSubtitleText)
    }

    // MARK: - Playback Mode Detection

    func testDetectPlaybackModeForYouTube() {
        let t = Transcription(
            fileName: "YouTube Video",
            sourceURL: "https://www.youtube.com/watch?v=abc123",
            sourceType: .youtube
        )
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .video)
    }

    func testDetectPlaybackModeForLocalVideo() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mp4")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let t = Transcription(fileName: "video.mp4", filePath: tempFile.path)
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .video)
    }

    func testDetectPlaybackModeForLocalAudio() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mp3")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let t = Transcription(fileName: "audio.mp3", filePath: tempFile.path)
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .audio)
    }

    func testDetectPlaybackModeForPodcastWithSavedAudio() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-\(UUID().uuidString).mp3")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let t = Transcription(
            fileName: "Podcast Episode",
            filePath: tempFile.path,
            sourceURL: "https://podcasts.apple.com/us/podcast/show/id1?i=2",
            sourceType: .podcast
        )
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .audio)
    }

    func testDetectPlaybackModeForPodcastWithoutSavedAudio() {
        let t = Transcription(
            fileName: "Podcast Episode",
            sourceURL: "https://podcasts.apple.com/us/podcast/show/id1?i=2",
            sourceType: .podcast
        )
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .none)
    }

    func testDetectPlaybackModeForMissingFile() {
        let t = Transcription(fileName: "deleted.mp3", filePath: "/nonexistent/path/file.mp3")
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .none)
    }

    func testDetectPlaybackModeForNoPath() {
        let t = Transcription(fileName: "orphan.mp3")
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .none)
    }

    func testDetectPlaybackModeVideoExtensions() throws {
        let videoExts = ["mp4", "mov", "mkv", "avi", "webm", "m4v"]
        for ext in videoExts {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-\(UUID().uuidString).\(ext)")
            try Data([0x00]).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let t = Transcription(fileName: "file.\(ext)", filePath: tempFile.path)
            XCTAssertEqual(
                MediaPlayerViewModel.detectPlaybackMode(for: t), .video,
                "Expected .video for .\(ext)"
            )
        }
    }

    func testDetectPlaybackModeAudioExtensions() throws {
        let audioExts = ["mp3", "wav", "m4a", "flac", "ogg", "aac"]
        for ext in audioExts {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-\(UUID().uuidString).\(ext)")
            try Data([0x00]).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let t = Transcription(fileName: "file.\(ext)", filePath: tempFile.path)
            XCTAssertEqual(
                MediaPlayerViewModel.detectPlaybackMode(for: t), .audio,
                "Expected .audio for .\(ext)"
            )
        }
    }

    // MARK: - Initial State

    @MainActor
    func testInitialState() {
        let vm = MediaPlayerViewModel()
        XCTAssertNil(vm.player)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTimeMs, 0)
        XCTAssertEqual(vm.durationMs, 0)
        XCTAssertEqual(vm.playerState, .idle)
        XCTAssertEqual(vm.playbackMode, .none)
    }

    @MainActor
    func testCleanupResetsState() {
        let vm = MediaPlayerViewModel()
        vm.currentTimeMs = 5000
        vm.durationMs = 60000
        vm.isPlaying = true
        vm.playerState = .ready
        vm.playbackMode = .video

        vm.cleanup()

        XCTAssertNil(vm.player)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTimeMs, 0)
        XCTAssertEqual(vm.durationMs, 0)
        XCTAssertEqual(vm.playerState, .idle)
    }

    @MainActor
    func testLoadNoMediaSetsPlaybackModeNone() async {
        let vm = MediaPlayerViewModel()
        let t = Transcription(fileName: "orphan.mp3")
        await vm.load(for: t)
        XCTAssertEqual(vm.playbackMode, .none)
        XCTAssertEqual(vm.playerState, .idle)
    }

    @MainActor
    func testPreparePodcastSavedAudioDoesNotEnableVideoFallback() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-\(UUID().uuidString).mp3")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let vm = MediaPlayerViewModel()
        let t = Transcription(
            fileName: "Podcast Episode",
            filePath: tempFile.path,
            sourceURL: "https://podcasts.apple.com/us/podcast/show/id1?i=2",
            sourceType: .podcast
        )

        await vm.prepare(for: t)

        XCTAssertEqual(vm.playbackMode, .audio)
        XCTAssertFalse(vm.needsVideoStreamLoad)
    }

    // MARK: - YouTube video preparation

    @MainActor
    func testPreparedVideoLivesUntilPlayerCleanup() async throws {
        let directory = try makeVideoPreparationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = PreparedVideoStub(directory: directory)
        let vm = MediaPlayerViewModel(videoStreamService: service, playbackRateDefaults: nil)
        vm.setPlaybackRate(1.5)

        await vm.load(for: youtubeTranscription())

        XCTAssertNotNil(vm.player)
        XCTAssertEqual(vm.player?.defaultRate, 1.5)
        XCTAssertFalse(vm.needsVideoStreamLoad)
        XCTAssertEqual(vm.videoPreparationStage, .combining)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let previousPlayer = vm.player
        vm.cancelVideoPreparation()
        XCTAssertTrue(vm.player === previousPlayer, "Hiding prepared video must keep its audio available")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        vm.cleanup()

        XCTAssertNil(previousPlayer?.currentItem, "Detach the item before deleting its temporary media")
        XCTAssertNil(vm.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testVideoPreparationFailurePreservesRetainedAudio() async throws {
        let directory = try makeVideoPreparationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("retained.m4a")
        try Data([0]).write(to: audio)
        let transcription = youtubeTranscription(filePath: audio.path)
        let vm = MediaPlayerViewModel(videoStreamService: FailingVideoStub(), playbackRateDefaults: nil)
        defer { vm.cleanup() }
        await vm.prepare(for: transcription)
        let audioPlayer = vm.player

        await vm.load(for: transcription)

        XCTAssertTrue(vm.player === audioPlayer)
        XCTAssertTrue(vm.needsVideoStreamLoad)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        guard case .error = vm.playerState else {
            return XCTFail("A failed preparation should show a retryable error")
        }
    }

    @MainActor
    func testNavigationDiscardsLateVideoAndPreparationUpdates() async throws {
        let directory = try makeVideoPreparationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Video download started")
        let service = SuspendedVideoStub(directory: directory, started: started)
        let vm = MediaPlayerViewModel(videoStreamService: service, playbackRateDefaults: nil)
        defer { vm.cleanup() }
        let oldLoad = Task { await vm.load(for: youtubeTranscription()) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(vm.videoPreparationStage, .downloading)

        await vm.prepare(for: youtubeTranscription())
        await service.finish()
        await oldLoad.value

        XCTAssertNil(vm.player, "The old download must not install its player in the newly selected transcript")
        XCTAssertEqual(vm.videoPreparationStage, .extracting)
        XCTAssertEqual(vm.playerState, .ready)
        XCTAssertTrue(vm.needsVideoStreamLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testVideoSwitchUsesPlaybackStateChangedDuringPreparation() async throws {
        let directory = try makeVideoPreparationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Video download started")
        let service = SuspendedVideoStub(directory: directory, started: started)
        let vm = MediaPlayerViewModel(videoStreamService: service, playbackRateDefaults: nil)
        defer { vm.cleanup() }
        vm.player = AVPlayer()
        vm.currentTimeMs = 5_000
        vm.isPlaying = true
        let load = Task { await vm.load(for: youtubeTranscription()) }
        await fulfillment(of: [started], timeout: 2)

        vm.seek(toMs: 45_000)
        vm.isPlaying = false
        vm.setPlaybackRate(1.5)
        await service.finish()
        await load.value

        XCTAssertEqual(vm.currentTimeMs, 45_000, "The switch must use the latest seek position")
        XCTAssertEqual(vm.player?.rate, 0, "Pausing during preparation must prevent automatic playback")
        XCTAssertEqual(vm.player?.defaultRate, 1.5)
    }

    @MainActor
    func testHidingVideoCancelsPreparationAndPreservesRetainedAudio() async throws {
        let directory = try makeVideoPreparationDirectory()
        let audioDirectory = try makeVideoPreparationDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: audioDirectory)
        }
        let audio = audioDirectory.appendingPathComponent("retained.m4a")
        try Data([0]).write(to: audio)
        let transcription = youtubeTranscription(filePath: audio.path)
        let started = expectation(description: "Video download started")
        let service = SuspendedVideoStub(directory: directory, started: started)
        let vm = MediaPlayerViewModel(videoStreamService: service, playbackRateDefaults: nil)
        defer { vm.cleanup() }
        await vm.prepare(for: transcription)
        let audioPlayer = vm.player
        let load = Task { await vm.load(for: transcription) }
        await fulfillment(of: [started], timeout: 2)

        vm.cancelVideoPreparation()
        await service.finish()
        await load.value

        XCTAssertTrue(vm.player === audioPlayer)
        XCTAssertEqual(vm.playerState, .ready)
        XCTAssertEqual(vm.videoPreparationStage, .extracting)
        XCTAssertTrue(vm.needsVideoStreamLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    @MainActor
    func testPreparingAnotherTranscriptReleasesPreviousVideo() async throws {
        let directory = try makeVideoPreparationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vm = MediaPlayerViewModel(
            videoStreamService: PreparedVideoStub(directory: directory), playbackRateDefaults: nil
        )
        defer { vm.cleanup() }
        await vm.load(for: youtubeTranscription())

        await vm.prepare(for: youtubeTranscription())

        XCTAssertNil(vm.player)
        XCTAssertTrue(vm.needsVideoStreamLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Playback Rate

    @MainActor
    func testPlaybackRateLabelsUseCompactMediaPlayerFormat() {
        XCTAssertEqual(PlaybackRate.label(for: 0.5), "0.5x")
        XCTAssertEqual(PlaybackRate.label(for: 1.0), "1x")
        XCTAssertEqual(PlaybackRate.label(for: 1.25), "1.25x")
        XCTAssertEqual(PlaybackRate.label(for: 1.5), "1.5x")
        XCTAssertEqual(PlaybackRate.label(for: 2.0), "2x")
    }

    @MainActor
    func testPlaybackRateOptionsUseStandardMediaPlayerPresets() {
        XCTAssertEqual(PlaybackRate.options, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
    }

    @MainActor
    func testPlaybackRatePersistsAcrossViewModelInstances() {
        let defaults = isolatedPlaybackDefaults()
        let vm = MediaPlayerViewModel(playbackRateDefaults: defaults)

        vm.setPlaybackRate(1.5)

        let reloaded = MediaPlayerViewModel(playbackRateDefaults: defaults)
        XCTAssertEqual(reloaded.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(reloaded.playbackRateLabel, "1.5x")
    }

    @MainActor
    func testTogglePlayPauseUsesSelectedPlaybackRate() {
        let vm = MediaPlayerViewModel(playbackRateDefaults: isolatedPlaybackDefaults())
        let player = AVPlayer()
        vm.player = player
        vm.setPlaybackRate(1.5)

        vm.togglePlayPause()

        XCTAssertEqual(player.defaultRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.001)
    }

    @MainActor
    func testChangingPlaybackRateUpdatesActivePlayerRate() {
        let vm = MediaPlayerViewModel(playbackRateDefaults: isolatedPlaybackDefaults())
        let player = AVPlayer()
        vm.player = player
        player.rate = 1.0

        vm.setPlaybackRate(1.25)

        XCTAssertEqual(player.defaultRate, 1.25, accuracy: 0.001)
        XCTAssertEqual(player.rate, 1.25, accuracy: 0.001)
    }

    @MainActor
    func testChangingPlaybackRateDoesNotResumePausedPlayerWhenIsPlayingIsStale() {
        let vm = MediaPlayerViewModel(playbackRateDefaults: isolatedPlaybackDefaults())
        let player = AVPlayer()
        vm.player = player
        vm.isPlaying = true
        player.pause()

        vm.setPlaybackRate(1.5)

        XCTAssertEqual(player.defaultRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(player.rate, 0.0, accuracy: 0.001)
    }

    @MainActor
    func testCleanupPreservesPlaybackRatePreference() {
        let vm = MediaPlayerViewModel(playbackRateDefaults: isolatedPlaybackDefaults())
        vm.setPlaybackRate(1.5)
        vm.player = AVPlayer()
        vm.playerState = .ready

        vm.cleanup()

        XCTAssertEqual(vm.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(vm.playbackRateLabel, "1.5x")
    }

    // MARK: - Lazy webm → m4a migration (issue #237 playback fix)

    @MainActor
    func testPrepareSchedulesPlaybackConversionForExistingWebMFile() async throws {
        // Place a (zero-byte) webm next to where a converted m4a would land.
        // We don't need ffmpeg to actually succeed — we only assert that the
        // VM observed the unplayable extension and scheduled a conversion
        // via the injected converter (the persist callback proves it).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        let stubConverter = StubPlaybackConverter(
            transformedPath: dir.appendingPathComponent("video.m4a").path
        )

        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        let persistExpectation = expectation(description: "persistConvertedFilePath called")
        let captured = PersistCapture()
        vm.onPlaybackFilePathConverted = { id, path, source in
            captured.record(id: id, path: path, source: source)
            persistExpectation.fulfill()
        }

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc",
            thumbnailURL: "https://img.example/thumb.jpg",
            channelName: "Talk Channel",
            videoDescription: "Talk description",
            sourceType: .youtube
        )
        await vm.prepare(for: transcription)

        await fulfillment(of: [persistExpectation], timeout: 2.0)
        XCTAssertEqual(captured.id, transcription.id)
        XCTAssertEqual(captured.path, dir.appendingPathComponent("video.m4a").path)
        XCTAssertEqual(captured.source, webm.path,
                       "Persist callback must receive the source path for cleanup-after-DB-write")
        let metadata = await stubConverter.lastMetadataSnapshot()
        XCTAssertEqual(metadata?.title, "Talk")
        XCTAssertEqual(metadata?.artist, "Talk Channel")
        XCTAssertEqual(metadata?.description, "Talk description")
        XCTAssertEqual(metadata?.thumbnailURL, "https://img.example/thumb.jpg")
    }

    @MainActor
    func testPrepareSkipsConversionWhenNoCallbackWired() async throws {
        // Without `onPlaybackFilePathConverted`, the converter must NOT run
        // (we'd orphan the resulting .m4a since the DB still points at the
        // deleted .webm).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        let stubConverter = StubPlaybackConverter(
            transformedPath: dir.appendingPathComponent("video.m4a").path
        )

        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        // No callback wired.

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc",
            sourceType: .youtube
        )
        await vm.prepare(for: transcription)

        // Give the @MainActor task a couple of runloop hops to settle.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let invocationCount = await stubConverter.currentInvocationCount()
        XCTAssertEqual(invocationCount, 0, "Converter must not run when callback is absent")
        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.playerState, .idle)
        XCTAssertTrue(vm.needsVideoStreamLoad, "Show Video fallback should remain available")
    }

    @MainActor
    func testPrepareReportsLoadingStateUntilConversionSwapsThePlayer() async throws {
        // A webm-backed YouTube transcription must not present `.ready`
        // before the m4a player is loaded — that would expose a dead play
        // button with no visible indicator. We surface `.loading` and
        // flip to `.ready` only after `loadLocalFile` runs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-loading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        // A slow stub keeps the conversion task suspended so we can
        // observe the in-flight UI state without flakiness.
        let stubConverter = SuspendingStubPlaybackConverter()
        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        vm.onPlaybackFilePathConverted = { _, _, _ in }
        vm.player = AVPlayer()
        vm.isPlaying = true
        vm.currentTimeMs = 12_345
        vm.durationMs = 67_890
        vm.playerState = .ready

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            durationMs: 45_000,
            sourceURL: "https://www.youtube.com/watch?v=abc",
            sourceType: .youtube
        )
        await vm.prepare(for: transcription)

        XCTAssertEqual(vm.playerState, .loading,
                       "Player should be `.loading` while the lazy m4a transcode is in flight")
        XCTAssertNil(vm.player)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTimeMs, 0)
        XCTAssertEqual(vm.durationMs, 45_000)

        vm.cleanup()
    }

    @MainActor
    func testPrepareCancelsPriorPlaybackConversionTaskOnRapidNavigation() async throws {
        // Switching to a different transcription while the first one's
        // m4a conversion is still in flight must cancel the prior task —
        // otherwise it can complete late and swap the AVPlayer to the old
        // file's audio while the user is viewing a different row.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)
        let plainAudio = dir.appendingPathComponent("audio.mp3")
        try Data([0x00]).write(to: plainAudio)

        let stubConverter = SuspendingStubPlaybackConverter()
        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        let invocationCounter = InvocationCounter()
        vm.onPlaybackFilePathConverted = { _, _, _ in
            invocationCounter.increment()
        }

        let webmTranscription = Transcription(
            fileName: "Webm Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc",
            sourceType: .youtube
        )
        await vm.prepare(for: webmTranscription)
        XCTAssertEqual(vm.playerState, .loading)

        // Navigate to a different (already playable) transcription. The
        // suspending converter would otherwise sit forever; if cancellation
        // didn't propagate, the suspended task would block this test.
        let plainTranscription = Transcription(
            fileName: "Plain Audio",
            filePath: plainAudio.path
        )
        await vm.prepare(for: plainTranscription)

        // Give the cancelled task a runloop hop to settle.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(invocationCounter.value, 0,
                       "Cancelled conversion must not invoke the persist callback")
    }
}

private extension MediaPlayerViewModelTests {
    func youtubeTranscription(filePath: String? = nil) -> Transcription {
        Transcription(
            fileName: "Video", filePath: filePath,
            sourceURL: "https://www.youtube.com/watch?v=P-4nHu9y9gk", sourceType: .youtube
        )
    }

    func makeVideoPreparationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-preparation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: directory.appendingPathComponent("playback.mp4"))
        return directory
    }

    func isolatedPlaybackDefaults() -> UserDefaults {
        let suiteName = makeIsolatedDefaultsSuite("com.macparakeet.tests.playback-rate.")
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }
}

private struct PreparedVideoStub: VideoStreamProviding {
    let directory: URL

    func playbackResource(
        for youtubeURL: String,
        onStageChange: @escaping @Sendable (VideoPreparationStage) async -> Void
    ) async throws -> VideoPlaybackResource {
        await onStageChange(.combining)
        return VideoPlaybackResource(url: directory.appendingPathComponent("playback.mp4"), temporaryDirectory: directory)
    }
}

private struct FailingVideoStub: VideoStreamProviding {
    func playbackResource(
        for youtubeURL: String,
        onStageChange: @escaping @Sendable (VideoPreparationStage) async -> Void
    ) async throws -> VideoPlaybackResource {
        await onStageChange(.downloading)
        throw VideoStreamError.preparationFailed("Fixture download failed")
    }
}

private actor SuspendedVideoStub: VideoStreamProviding {
    let directory: URL
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(directory: URL, started: XCTestExpectation) {
        self.directory = directory
        self.started = started
    }

    func playbackResource(
        for youtubeURL: String,
        onStageChange: @escaping @Sendable (VideoPreparationStage) async -> Void
    ) async throws -> VideoPlaybackResource {
        await onStageChange(.downloading)
        // Deliberately return after cancellation to exercise the caller's stale-result guard.
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        await onStageChange(.combining)
        return VideoPlaybackResource(url: directory.appendingPathComponent("playback.mp4"), temporaryDirectory: directory)
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// Reference-type capture wrapper. Closures that have to mutate state can
/// hold onto an instance of this rather than capturing a `var`, which
/// keeps the closure compatible with `@Sendable` semantics under strict
/// concurrency. Single-threaded access is guaranteed by the VM design
/// (the callback runs on MainActor and is read from the same test method
/// after `fulfillment`).
private final class PersistCapture: @unchecked Sendable {
    private(set) var id: UUID?
    private(set) var path: String?
    private(set) var source: String?

    func record(id: UUID, path: String, source: String) {
        self.id = id
        self.path = path
        self.source = source
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}

private actor StubPlaybackConverter: YouTubeAudioPlaybackConverting {
    private let transformedPath: String
    private(set) var invocationCount: Int = 0
    private var lastMetadata: YouTubeAudioArtifactMetadata?

    init(transformedPath: String) {
        self.transformedPath = transformedPath
    }

    func convertToPlayableM4AIfNeeded(
        inputPath: String,
        metadata: YouTubeAudioArtifactMetadata?
    ) async throws -> String {
        invocationCount += 1
        lastMetadata = metadata
        return transformedPath
    }

    func currentInvocationCount() -> Int {
        invocationCount
    }

    func lastMetadataSnapshot() -> YouTubeAudioArtifactMetadata? {
        lastMetadata
    }
}

/// Test converter that suspends until cancelled. Used to observe
/// in-flight UI state and cancellation propagation without timing-sensitive
/// sleeps. `Task.sleep` throws `CancellationError` when the surrounding
/// task is cancelled, which propagates out as a converter failure.
private final class SuspendingStubPlaybackConverter: YouTubeAudioPlaybackConverting, @unchecked Sendable {
    func convertToPlayableM4AIfNeeded(
        inputPath: String,
        metadata: YouTubeAudioArtifactMetadata?
    ) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64.max)
        return inputPath
    }
}
