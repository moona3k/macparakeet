import Darwin
import Foundation
import OSLog

public struct MediaPauseToken: Sendable, Equatable {
    public let id: UUID
    public let processIdentifier: Int32?
    public let bundleIdentifier: String?

    public init(id: UUID = UUID(), processIdentifier: Int32?, bundleIdentifier: String? = nil) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public protocol SystemMediaControlling: Sendable {
    func pauseIfPlaying() async -> MediaPauseToken?
    func resume(_ token: MediaPauseToken) async
}

public final class SystemMediaController: SystemMediaControlling, @unchecked Sendable {
    private enum Command {
        static let play: Int32 = 0
        static let pause: Int32 = 1
    }

    fileprivate static let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemMediaController")

    private let snapshotProvider: @Sendable () async -> SystemMediaSnapshot?
    private let commandSender: @Sendable (Int32) -> Bool

    public convenience init(timeout: TimeInterval = 1.25) {
        let commandSender = MediaRemoteCommandSender()
        self.init(
            snapshotProvider: {
                await OsaScriptNowPlayingSnapshotReader.snapshot(timeout: timeout)
            },
            commandSender: { command in
                commandSender.send(command)
            }
        )
    }

    init(
        snapshotProvider: @escaping @Sendable () async -> SystemMediaSnapshot?,
        commandSender: @escaping @Sendable (Int32) -> Bool
    ) {
        self.snapshotProvider = snapshotProvider
        self.commandSender = commandSender
    }

    public func pauseIfPlaying() async -> MediaPauseToken? {
        // Mirrored into dictation-audio.log (issue #474): the delta between
        // `dictation_capture_start` and `media_pause_sent` line timestamps is
        // the window where playing media bleeds into the capture, and
        // `snapshot_ms` shows how much of it the now-playing helper costs.
        // Identity fields (pid/bundle) stay out — the log is user-shareable.
        let clock = ContinuousClock()
        let snapshotStart = clock.now
        let snapshot = await snapshotProvider()
        let snapshotMs = Int(((clock.now - snapshotStart) / .milliseconds(1)).rounded())

        guard let snapshot else {
            Self.logger.notice("media_pause_skipped reason=snapshot_unavailable")
            AudioCaptureDiagnostics.append(
                "media_pause_skipped reason=snapshot_unavailable snapshot_ms=\(snapshotMs)"
            )
            return nil
        }

        guard snapshot.isPlaying else {
            Self.logger.notice("media_pause_skipped reason=no_playing_session")
            AudioCaptureDiagnostics.append(
                "media_pause_skipped reason=no_playing_session snapshot_ms=\(snapshotMs)"
            )
            return nil
        }

        guard snapshot.hasIdentity else {
            Self.logger.notice("media_pause_skipped reason=session_identity_unavailable")
            AudioCaptureDiagnostics.append(
                "media_pause_skipped reason=session_identity_unavailable snapshot_ms=\(snapshotMs)"
            )
            return nil
        }

        guard commandSender(Command.pause) else {
            Self.logger.error("media_pause_failed bucket=send_command_failed")
            AudioCaptureDiagnostics.append(
                "media_pause_failed bucket=send_command_failed snapshot_ms=\(snapshotMs)"
            )
            return nil
        }

        Self.logger.notice("media_pause_sent source=now_playing_helper")
        AudioCaptureDiagnostics.append(
            "media_pause_sent snapshot_ms=\(snapshotMs)"
        )
        return MediaPauseToken(
            processIdentifier: snapshot.processIdentifier,
            bundleIdentifier: snapshot.bundleIdentifier
        )
    }

    public func resume(_ token: MediaPauseToken) async {
        guard let snapshot = await snapshotProvider() else {
            Self.logger.notice("media_resume_skipped reason=snapshot_unavailable")
            AudioCaptureDiagnostics.append("media_resume_skipped reason=snapshot_unavailable")
            return
        }

        if snapshot.isPlaying {
            Self.logger.notice("media_resume_skipped reason=already_playing")
            AudioCaptureDiagnostics.append("media_resume_skipped reason=already_playing")
            return
        }

        guard snapshot.matches(token) else {
            Self.logger.notice("media_resume_skipped reason=now_playing_changed")
            AudioCaptureDiagnostics.append("media_resume_skipped reason=now_playing_changed")
            return
        }

        guard commandSender(Command.play) else {
            Self.logger.error("media_resume_failed bucket=send_command_failed")
            AudioCaptureDiagnostics.append("media_resume_failed bucket=send_command_failed")
            return
        }

        Self.logger.notice("media_resume_sent source=now_playing_helper")
        AudioCaptureDiagnostics.append("media_resume_sent")
    }
}

struct SystemMediaSnapshot: Sendable, Equatable {
    let isPlaying: Bool
    let processIdentifier: Int32?
    let bundleIdentifier: String?

    var hasIdentity: Bool {
        processIdentifier != nil || bundleIdentifier?.isEmpty == false
    }

    func matches(_ token: MediaPauseToken) -> Bool {
        var matchedIdentity = false

        if let expectedPID = token.processIdentifier {
            matchedIdentity = true
            guard processIdentifier == expectedPID else { return false }
        }

        if let expectedBundle = token.bundleIdentifier, !expectedBundle.isEmpty {
            matchedIdentity = true
            guard bundleIdentifier == expectedBundle else { return false }
        }

        return matchedIdentity
    }
}

enum OsaScriptNowPlayingSnapshotReader {
    private static let osascriptPath = "/usr/bin/osascript"
    private static let script = """
    function run() {
      ObjC.import('Foundation');

      const mediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      if (!mediaRemote) return JSON.stringify({ "available": false });
      mediaRemote.load;

      const request = $.NSClassFromString('MRNowPlayingRequest');
      if (!request) return JSON.stringify({ "available": false });

      const item = request.localNowPlayingItem;
      const playerPath = request.localNowPlayingPlayerPath;
      const info = item ? item.nowPlayingInfo : null;
      const client = playerPath ? playerPath.client : null;

      function unwrap(value) {
        if (value === null || value === undefined) return null;
        try {
          const result = ObjC.unwrap(value);
          return result === undefined ? null : result;
        } catch (e) {
          return null;
        }
      }

      function infoValue(key) {
        if (!info) return null;
        try { return unwrap(info.valueForKey(key)); } catch (e) { return null; }
      }

      function clientValue(key) {
        if (!client) return null;
        try { return unwrap(client.valueForKey(key)); } catch (e) { return null; }
      }

      const playbackRateValue = infoValue('kMRMediaRemoteNowPlayingInfoPlaybackRate');
      const playbackRate = playbackRateValue === null ? 0 : Number(playbackRateValue);
      const processIdentifierValue = clientValue('processIdentifier');
      const processIdentifier = processIdentifierValue === null ? null : Number(processIdentifierValue);
      const bundleIdentifier = clientValue('bundleIdentifier');

      return JSON.stringify({
        "available": true,
        "playing": playbackRate > 0.01,
        "playbackRate": playbackRate,
        "processIdentifier": processIdentifier && processIdentifier > 0 ? processIdentifier : null,
        "bundleIdentifier": bundleIdentifier || null
      });
    }
    """

    static func snapshot(timeout: TimeInterval) async -> SystemMediaSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.standardError = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        do {
            try process.run()
            try await ChildProcessWaiter.waitUntilExit(
                process,
                timeout: timeout,
                timeoutError: SnapshotError.timedOut
            )
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        return decode(data)
    }

    static func decode(_ data: Data) -> SystemMediaSnapshot? {
        guard let payload = try? JSONDecoder().decode(HelperPayload.self, from: data),
              payload.available != false else {
            return nil
        }

        let processIdentifier = payload.processIdentifier.flatMap { $0 > 0 ? $0 : nil }
        let bundleIdentifier = payload.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let isPlaying = payload.playing ?? ((payload.playbackRate ?? 0) > 0.01)

        return SystemMediaSnapshot(
            isPlaying: isPlaying,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    private enum SnapshotError: Error {
        case timedOut
    }

    private struct HelperPayload: Decodable {
        let available: Bool?
        let playing: Bool?
        let playbackRate: Double?
        let processIdentifier: Int32?
        let bundleIdentifier: String?
    }
}

private final class MediaRemoteCommandSender: @unchecked Sendable {
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> UInt8

    private static let mediaRemotePath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private let symbolsLock = NSLock()
    private var cachedSymbols: MediaRemoteSymbols?
    private var didLoadSymbols = false

    func send(_ command: Int32) -> Bool {
        guard let symbols = loadSymbolsIfNeeded() else { return false }
        return symbols.sendCommand(command, nil) != 0
    }

    private func loadSymbolsIfNeeded() -> MediaRemoteSymbols? {
        symbolsLock.lock()
        defer { symbolsLock.unlock() }

        if didLoadSymbols {
            return cachedSymbols
        }

        cachedSymbols = MediaRemoteSymbols.load()
        didLoadSymbols = true
        return cachedSymbols
    }

    private struct MediaRemoteSymbols: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let sendCommand: SendCommandFunction

        static func load() -> MediaRemoteSymbols? {
            guard let handle = dlopen(MediaRemoteCommandSender.mediaRemotePath, RTLD_LAZY) else {
                SystemMediaController.logger.notice("media_remote_load_failed")
                return nil
            }

            guard let sendCommandSymbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
                SystemMediaController.logger.notice("media_remote_symbol_missing")
                dlclose(handle)
                return nil
            }

            return MediaRemoteSymbols(
                handle: handle,
                sendCommand: unsafeBitCast(sendCommandSymbol, to: SendCommandFunction.self)
            )
        }
    }
}
