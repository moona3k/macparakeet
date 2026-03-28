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

// MARK: - MediaPlayerViewModel

@MainActor @Observable
public final class MediaPlayerViewModel {
    public var player: AVPlayer?
    public var isPlaying: Bool = false
    public var currentTimeMs: Int = 0
    public var durationMs: Int = 0
    public var playerState: PlayerState = .idle
    public var playbackMode: PlaybackMode = .none
    /// Seconds elapsed since loading started (for UX feedback)
    public var loadingElapsed: TimeInterval = 0

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endOfTrackObserver: NSObjectProtocol?
    private var loadingTask: Task<Void, Never>?
    private var loadingTimerTask: Task<Void, Never>?
    private let videoStreamService: VideoStreamService
    private let logger = Logger(subsystem: "com.macparakeet", category: "MediaPlayer")

    public init(videoStreamService: VideoStreamService = VideoStreamService()) {
        self.videoStreamService = videoStreamService
    }

    // MARK: - Public API

    /// Load media for a transcription. Determines playback mode and sets up AVPlayer.
    /// Cancels any in-flight load to prevent race conditions on rapid navigation.
    public func load(for transcription: Transcription) async {
        loadingTask?.cancel()

        let mode = Self.detectPlaybackMode(for: transcription)
        playbackMode = mode

        guard mode != .none else {
            playerState = .idle
            return
        }

        playerState = .loading
        loadingElapsed = 0
        startLoadingTimer()
        logger.info("Loading media: mode=\(String(describing: mode)), source=\(transcription.sourceURL ?? transcription.filePath ?? "none")")

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
            player.play()
        }
        // isPlaying is updated by the KVO observer on timeControlStatus
    }

    public func cleanup() {
        loadingTask?.cancel()
        loadingTask = nil
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
        let start = ContinuousClock.now
        do {
            logger.info("Extracting stream URL via yt-dlp for \(sourceURL)")
            let streamURL = try await videoStreamService.streamURL(for: sourceURL)
            let extractionTime = ContinuousClock.now - start
            logger.info("Stream URL extracted in \(extractionTime)")
            guard !Task.isCancelled else { return }
            let playerItem = AVPlayerItem(url: streamURL)
            setupPlayer(with: playerItem)
            playerState = .ready
            logger.info("YouTube video player ready")
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("YouTube stream load failed after \(ContinuousClock.now - start): \(error.localizedDescription)")
            playerState = .error(error.localizedDescription)
        }
    }

    private func loadLocalFile(_ filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        let playerItem = AVPlayerItem(url: url)
        setupPlayer(with: playerItem)
        playerState = .ready
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

        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        // Observe playback time at 10Hz for smooth transcript sync
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTimeMs = Int(time.seconds * 1000)
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
}
