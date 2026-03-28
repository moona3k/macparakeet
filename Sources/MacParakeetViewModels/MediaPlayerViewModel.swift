import AVFoundation
import Foundation
import MacParakeetCore

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

    private var timeObserver: Any?
    private var loadingTask: Task<Void, Never>?
    private let videoStreamService: VideoStreamService

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
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = !isPlaying
    }

    public func cleanup() {
        loadingTask?.cancel()
        loadingTask = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
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
        do {
            let streamURL = try await videoStreamService.streamURL(for: sourceURL)
            guard !Task.isCancelled else { return }
            let playerItem = AVPlayerItem(url: streamURL)
            setupPlayer(with: playerItem)
            playerState = .ready
        } catch {
            guard !Task.isCancelled else { return }
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
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }

        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        // Observe playback time at 10Hz for smooth transcript sync
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTimeMs = Int(time.seconds * 1000)
        }

        // Observe duration once available
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let duration = try? await item.asset.load(.duration),
               duration.isNumeric {
                self.durationMs = Int(duration.seconds * 1000)
            }
        }
    }
}
