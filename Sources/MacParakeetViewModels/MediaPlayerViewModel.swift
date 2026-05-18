import AVFoundation
import Foundation
import MacParakeetCore
import os

// MARK: - Playback Mode

public enum PlaybackMode: Equatable, Sendable {
    case video    // YouTube or local video file — split-pane layout
    case audio    // Local audio file — scrubber bar + full-width content
    case none     // No playable media (file deleted or unavailable)
}

public enum PlayerState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case error(String)
    case unavailableOffline
}

public enum PlaybackRate: Sendable {
    public static let defaultValue: Float = 1.0
    public static let minimumValue: Float = 0.5
    public static let maximumValue: Float = 2.0
    public static let options: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public static func normalized(_ rate: Float) -> Float {
        guard rate.isFinite else { return defaultValue }
        return min(max(rate, minimumValue), maximumValue)
    }

    public static func label(for rate: Float) -> String {
        let hundredths = Int((Double(rate) * 100).rounded())
        if hundredths % 100 == 0 {
            return "\(hundredths / 100)x"
        }
        if hundredths % 10 == 0 {
            return String(format: "%.1fx", Double(hundredths) / 100)
        }
        return String(format: "%.2fx", Double(hundredths) / 100)
    }
}

// MARK: - MediaPlayerViewModel

@MainActor @Observable
public final class MediaPlayerViewModel {
    public var player: AVPlayer?
    public var isPlaying: Bool = false
    public var playbackRate: Float
    public var currentTimeMs: Int = 0
    public var durationMs: Int = 0
    public var playerState: PlayerState = .idle
    public var playbackMode: PlaybackMode = .none
    /// Seconds elapsed since loading started (for UX feedback)
    public var loadingElapsed: TimeInterval = 0
    /// Whether subtitle overlay is visible on the video player
    public var showSubtitles: Bool = false
    /// Current subtitle text to display (nil when between cues or subtitles disabled)
    public var currentSubtitleText: String?
    /// Whether YouTube stream extraction is still pending (local audio preloaded via prepare())
    public var needsVideoStreamLoad: Bool = false

    /// Optional callback used by the lazy on-open migration of existing
    /// webm/opus YouTube files to .m4a. Arguments: `(transcriptionID,
    /// newFilePath, sourceFileToDeleteOnSuccess)`. The owner is expected
    /// to persist the new `filePath` to the database in the same flow
    /// and then delete the source file *only if* the DB write succeeded —
    /// otherwise the row would still reference a now-deleted source. When
    /// `nil`, the lazy migration is suppressed entirely (we'd otherwise
    /// produce an orphan .m4a the DB couldn't point at).
    public var onPlaybackFilePathConverted: (@MainActor @Sendable (UUID, String, String) async throws -> Void)?

    private var subtitleCues: [ExportService.SubtitleCue] = []
    private var lastCueIndex: Int = -1
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endOfTrackObserver: NSObjectProtocol?
    private var loadingTask: Task<Void, Never>?
    private var loadingTimerTask: Task<Void, Never>?
    private var playbackConversionTask: Task<Void, Never>?
    private let videoStreamService: VideoStreamService
    private let playbackConverter: YouTubeAudioPlaybackConverting
    private let playbackRateDefaults: UserDefaults?
    private let logger = Logger(subsystem: "com.macparakeet", category: "MediaPlayer")
    private static let playbackRateDefaultsKey = "MediaPlayerViewModel.playbackRate"

    public init(
        videoStreamService: VideoStreamService = VideoStreamService(),
        playbackConverter: YouTubeAudioPlaybackConverting = YouTubeAudioPlaybackConverter(),
        playbackRateDefaults: UserDefaults? = .standard
    ) {
        self.videoStreamService = videoStreamService
        self.playbackConverter = playbackConverter
        self.playbackRateDefaults = playbackRateDefaults
        self.playbackRate = Self.loadPlaybackRate(from: playbackRateDefaults)
    }

    // MARK: - Public API

    /// Prepare media without YouTube stream extraction. Sets playback mode and loads
    /// local audio for the scrubber bar. YouTube stream is deferred until "Show Video".
    /// This avoids unnecessary yt-dlp calls that trigger YouTube rate limiting.
    public func prepare(for transcription: Transcription) async {
        loadingTask?.cancel()
        // Cancel any in-flight transcode from a previous transcription so
        // it doesn't complete after we've switched to a new row and clobber
        // the active player with the old file's audio.
        playbackConversionTask?.cancel()

        let mode = Self.detectPlaybackMode(for: transcription)
        playbackMode = mode

        guard mode != .none else {
            playerState = .idle
            return
        }

        // Local files: load immediately (no rate limiting concern)
        if transcription.sourceURL == nil {
            await load(for: transcription)
            return
        }

        // YouTube: load local audio file for scrubber bar, defer video stream
        needsVideoStreamLoad = true

        // Set duration from transcription metadata so the scrubber shows the correct
        // total time immediately — AVPlayer may fail to read duration from downloaded
        // audio (e.g. webm/opus format) or the async asset load may not complete yet.
        let knownDurationMs = transcription.durationMs.flatMap { $0 > 0 ? $0 : nil }
        if let knownDurationMs {
            durationMs = knownDurationMs
        }

        if let filePath = transcription.filePath,
           FileManager.default.fileExists(atPath: filePath) {
            if YouTubeAudioPlaybackConverter.needsConversion(forPath: filePath) {
                clearLoadedPlayer()
                if let knownDurationMs {
                    durationMs = knownDurationMs
                }
                if let persist = onPlaybackFilePathConverted {
                    // Existing webm-backed transcription (predates issue #237's
                    // playback fix). Transcode to .m4a in the background so
                    // the audio scrubber starts working. Show `.loading` while
                    // the transcode runs so the play button isn't presented as
                    // ready before the player is actually loaded — the swap
                    // back to `.ready` happens inside the conversion task.
                    playerState = .loading
                    schedulePlaybackConversion(
                        inputPath: filePath,
                        transcriptionId: transcription.id,
                        metadata: YouTubeAudioArtifactMetadata(
                            title: transcription.fileName,
                            artist: transcription.channelName,
                            description: transcription.videoDescription,
                            thumbnailURL: transcription.thumbnailURL
                        ),
                        persist: persist
                    )
                    logger.info("Prepared YouTube media: queued lazy m4a conversion for unplayable saved audio")
                } else {
                    playerState = .idle
                    logger.info("Prepared YouTube media: saved audio needs conversion but no persistence callback is wired; using Show Video fallback")
                }
            } else {
                loadLocalFile(filePath)
                playerState = .ready
                logger.info("Prepared YouTube media: loaded local audio, deferring video stream")
            }
        } else {
            playerState = .ready
            logger.info("Prepared YouTube media: no local audio file, using transcription duration for scrubber")
        }
    }

    /// Runs an off-main transcode of an existing webm-backed file to .m4a
    /// and, on success, swaps the AVPlayer to the new file in place so the
    /// audio scrubber starts working without making the user reload. If
    /// the user navigated away (`cleanup()` cancelled this task) or the
    /// transcode failed, we just leave the original file alone — next
    /// open will retry, or the existing Show Video stream-extract path
    /// remains a viable fallback.
    private func schedulePlaybackConversion(
        inputPath: String,
        transcriptionId: UUID,
        metadata: YouTubeAudioArtifactMetadata?,
        persist: @escaping @MainActor @Sendable (UUID, String, String) async throws -> Void
    ) {
        playbackConversionTask?.cancel()
        let converter = playbackConverter
        let logger = self.logger
        playbackConversionTask = Task { @MainActor [weak self] in
            do {
                let newPath = try await converter.convertToPlayableM4AIfNeeded(
                    inputPath: inputPath,
                    metadata: metadata
                )
                guard !Task.isCancelled, let self else { return }
                guard newPath != inputPath else {
                    // No-op conversion (already playable). Keep the player
                    // empty — caller's `else` branch in `prepare(for:)`
                    // would have handled this.
                    return
                }
                // Hand off DB persist + source deletion atomically (in the
                // sense that one cannot happen without the other). The
                // owner deletes the source only after the row is updated;
                // a DB failure leaves the source in place so the next open
                // retries. Until 9a1fda2e the VM scheduled its own
                // `removeItem` here in parallel with `persist`, which was a
                // race with the persist's own internal task.
                try await persist(transcriptionId, newPath, inputPath)
                // Only swap the active player if we're still presenting
                // the audio-scrubber state for this transcription. If the
                // user clicked Show Video in the meantime, `needsVideoStreamLoad`
                // is false and the video stream owns the player — clobbering
                // it with the audio-only m4a would interrupt their playback.
                if self.needsVideoStreamLoad {
                    self.loadLocalFile(newPath)
                }
            } catch {
                logger.error("playback_conversion_failed id=\(transcriptionId, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                // Leave the player empty; Show Video remains a viable
                // fallback. A future open will retry the conversion.
                if !Task.isCancelled, let self, self.playerState == .loading {
                    self.playerState = .error("Audio scrubber unavailable for this file. Use Show Video to play.")
                }
            }
        }
    }

    /// Load media for a transcription. Determines playback mode and sets up AVPlayer.
    /// Cancels any in-flight load to prevent race conditions on rapid navigation.
    public func load(for transcription: Transcription) async {
        loadingTask?.cancel()
        // Cancel any in-flight lazy m4a transcode too — switching modes
        // (e.g., user clicked Show Video) makes its eventual `loadLocalFile`
        // unwanted. The `needsVideoStreamLoad` guard inside the conversion
        // task is a belt-and-suspenders second line of defense.
        playbackConversionTask?.cancel()

        let mode = Self.detectPlaybackMode(for: transcription)
        playbackMode = mode

        guard mode != .none else {
            playerState = .idle
            return
        }

        // Set fallback duration from transcription metadata (STT word timestamps)
        if let transcriptionDurationMs = transcription.durationMs, transcriptionDurationMs > 0 {
            durationMs = transcriptionDurationMs
        }

        playerState = .loading
        loadingElapsed = 0
        startLoadingTimer()
        logger.info("Loading media: mode=\(String(describing: mode), privacy: .public), source=\(transcription.sourceURL ?? transcription.filePath ?? "none", privacy: .private)")

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let sourceURL = transcription.sourceURL {
                await self.loadYouTubeStream(sourceURL)
            } else if let filePath = transcription.filePath {
                self.loadLocalFile(filePath)
            } else {
                self.playbackMode = .none
                self.playerState = .idle
            }
            self.stopLoadingTimer()
        }
        loadingTask = task
        await task.value
    }

    public func seek(toMs ms: Int) {
        let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTimeMs = ms
    }

    public func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.defaultRate = playbackRate
            player.play()
        }
        // isPlaying is updated by the KVO observer on timeControlStatus
    }

    public var playbackRateLabel: String {
        PlaybackRate.label(for: playbackRate)
    }

    public func setPlaybackRate(_ rate: Float) {
        let normalizedRate = PlaybackRate.normalized(rate)
        playbackRate = normalizedRate
        playbackRateDefaults?.set(Double(normalizedRate), forKey: Self.playbackRateDefaultsKey)

        guard let player else { return }
        player.defaultRate = normalizedRate
        if player.timeControlStatus == .playing || isPlaying {
            player.rate = normalizedRate
        }
    }

    /// Load subtitle cues from word timestamps for overlay display.
    public func loadSubtitleCues(from words: [WordTimestamp]) {
        subtitleCues = ExportService().buildSubtitleCues(from: words)
        lastCueIndex = -1
        currentSubtitleText = nil
    }

    public func cleanup() {
        loadingTask?.cancel()
        loadingTask = nil
        playbackConversionTask?.cancel()
        playbackConversionTask = nil
        stopLoadingTimer()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endOfTrackObserver {
            NotificationCenter.default.removeObserver(endOfTrackObserver)
        }
        endOfTrackObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTimeMs = 0
        durationMs = 0
        playerState = .idle
        playbackMode = .none
        needsVideoStreamLoad = false
        subtitleCues = []
        lastCueIndex = -1
        currentSubtitleText = nil
        showSubtitles = false
    }

    // MARK: - Playback Mode Detection

    nonisolated public static func detectPlaybackMode(for transcription: Transcription) -> PlaybackMode {
        if transcription.sourceURL != nil {
            return .video
        }
        guard let filePath = transcription.filePath,
              FileManager.default.fileExists(atPath: filePath) else {
            return .none
        }
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v"]
        return videoExtensions.contains(ext) ? .video : .audio
    }

    // MARK: - Private

    private func loadYouTubeStream(_ sourceURL: String) async {
        // Preserve playback position from local audio preload (if any)
        let savedTimeMs = currentTimeMs
        let wasPlaying = isPlaying

        let start = ContinuousClock.now
        do {
            logger.info("Extracting stream URL via yt-dlp for source=\(sourceURL, privacy: .private)")
            let streamURL = try await videoStreamService.streamURL(for: sourceURL)
            let extractionTime = ContinuousClock.now - start
            logger.info("Stream URL extracted in \(extractionTime)")
            guard !Task.isCancelled else { return }
            let playerItem = AVPlayerItem(url: streamURL)
            setupPlayer(with: playerItem)
            needsVideoStreamLoad = false
            playerState = .ready
            // Restore playback position from local audio
            if savedTimeMs > 0 {
                seek(toMs: savedTimeMs)
            }
            if wasPlaying {
                player?.defaultRate = playbackRate
                player?.play()
            }
            logger.info("YouTube video player ready")
        } catch {
            guard !Task.isCancelled else { return }
            let detail = TelemetryErrorClassifier.errorDetail(error)
            logger.error("YouTube stream load failed after \(String(describing: ContinuousClock.now - start), privacy: .public): \(detail, privacy: .private)")
            playerState = .error(detail)
        }
    }

    private func loadLocalFile(_ filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        let playerItem = AVPlayerItem(url: url)
        setupPlayer(with: playerItem)
        playerState = .ready
    }

    private func clearLoadedPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endOfTrackObserver {
            NotificationCenter.default.removeObserver(endOfTrackObserver)
        }
        endOfTrackObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTimeMs = 0
        durationMs = 0
    }

    private func setupPlayer(with item: AVPlayerItem) {
        // Tear down previous observers
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        statusObserver?.invalidate()
        if let endOfTrackObserver {
            NotificationCenter.default.removeObserver(endOfTrackObserver)
        }

        item.audioTimePitchAlgorithm = .timeDomain
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.defaultRate = playbackRate
        self.player = avPlayer

        // Observe playback time at 10Hz for smooth transcript sync + subtitle updates
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTimeMs = Int(time.seconds * 1000)
                self.updateSubtitleText()
            }
        }

        // Drive isPlaying from AVPlayer's actual timeControlStatus via KVO
        statusObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }

        // Reset isPlaying when track finishes
        endOfTrackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }

        // Observe duration once available
        Task { @MainActor [weak self] in
            guard let self, self.player === avPlayer else { return }
            if let duration = try? await item.asset.load(.duration),
               duration.isNumeric {
                self.durationMs = Int(duration.seconds * 1000)
            }
        }
    }

    private func startLoadingTimer() {
        loadingTimerTask?.cancel()
        let start = Date()
        loadingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.loadingElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopLoadingTimer() {
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
    }

    /// Binary search for the subtitle cue matching the current playback time.
    /// Only updates `currentSubtitleText` when the active cue changes.
    private func updateSubtitleText() {
        guard showSubtitles, !subtitleCues.isEmpty else {
            if currentSubtitleText != nil { currentSubtitleText = nil }
            return
        }
        let ms = currentTimeMs

        // Quick check: is the last known cue still active?
        if lastCueIndex >= 0, lastCueIndex < subtitleCues.count {
            let cue = subtitleCues[lastCueIndex]
            if ms >= cue.startMs && ms <= cue.endMs {
                return // Still on the same cue
            }
        }

        // Binary search for the cue containing currentTimeMs
        var lo = 0, hi = subtitleCues.count - 1
        var found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = subtitleCues[mid]
            if ms < cue.startMs {
                hi = mid - 1
            } else if ms > cue.endMs {
                lo = mid + 1
            } else {
                found = mid
                break
            }
        }

        if found != lastCueIndex {
            lastCueIndex = found
            currentSubtitleText = found >= 0 ? subtitleCues[found].text : nil
        }
    }

    private static func loadPlaybackRate(from defaults: UserDefaults?) -> Float {
        guard let storedRate = defaults?.object(forKey: playbackRateDefaultsKey) as? NSNumber else {
            return PlaybackRate.defaultValue
        }
        return PlaybackRate.normalized(storedRate.floatValue)
    }
}
