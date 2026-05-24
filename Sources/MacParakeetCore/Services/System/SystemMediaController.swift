import Darwin
import Foundation
import OSLog

public struct MediaPauseToken: Sendable, Equatable {
    public let id: UUID
    public let processIdentifier: Int32?

    public init(id: UUID = UUID(), processIdentifier: Int32?) {
        self.id = id
        self.processIdentifier = processIdentifier
    }
}

public protocol SystemMediaControlling: Sendable {
    func pauseIfPlaying() async -> MediaPauseToken?
    func resume(_ token: MediaPauseToken) async
}

public final class SystemMediaController: SystemMediaControlling, @unchecked Sendable {
    private typealias IsPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void
    private typealias PIDFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Int32) -> Void
    ) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> UInt8

    private enum Command {
        static let play: Int32 = 0
        static let pause: Int32 = 1
    }

    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemMediaController")
    private static let mediaRemotePath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private let symbolsLock = NSLock()
    private var cachedSymbols: MediaRemoteSymbols?
    private var didLoadSymbols = false
    private let callbackQueue = DispatchQueue(label: "com.macparakeet.media-remote")
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 0.75) {
        self.timeout = timeout
    }

    public func pauseIfPlaying() async -> MediaPauseToken? {
        guard let symbols = loadSymbolsIfNeeded() else {
            Self.logger.notice("media_pause_skipped reason=unavailable")
            return nil
        }

        guard await isPlaying(symbols: symbols) else {
            Self.logger.notice("media_pause_skipped reason=no_playing_session")
            return nil
        }

        guard let pid = await nowPlayingPID(symbols: symbols) else {
            Self.logger.notice("media_pause_skipped reason=session_identity_unavailable")
            return nil
        }

        guard send(Command.pause, symbols: symbols) else {
            Self.logger.error("media_pause_failed bucket=send_command_failed")
            return nil
        }

        Self.logger.notice("media_pause_sent source=now_playing")
        return MediaPauseToken(processIdentifier: pid)
    }

    public func resume(_ token: MediaPauseToken) async {
        guard let symbols = loadSymbolsIfNeeded() else {
            Self.logger.notice("media_resume_skipped reason=unavailable")
            return
        }

        if await isPlaying(symbols: symbols) {
            Self.logger.notice("media_resume_skipped reason=already_playing")
            return
        }

        if let expectedPID = token.processIdentifier {
            let currentPID = await nowPlayingPID(symbols: symbols)
            guard currentPID == expectedPID else {
                Self.logger.notice("media_resume_skipped reason=now_playing_changed")
                return
            }
        }

        guard send(Command.play, symbols: symbols) else {
            Self.logger.error("media_resume_failed bucket=send_command_failed")
            return
        }

        Self.logger.notice("media_resume_sent source=now_playing")
    }

    private func isPlaying(symbols: MediaRemoteSymbols) async -> Bool {
        await callbackValue(defaultValue: false) { [callbackQueue] callback in
            symbols.isPlaying(callbackQueue, callback)
        }
    }

    private func nowPlayingPID(symbols: MediaRemoteSymbols) async -> Int32? {
        await callbackValue(defaultValue: nil) { [callbackQueue] callback in
            symbols.nowPlayingPID(callbackQueue) { pid in
                callback(pid > 0 ? pid : nil)
            }
        }
    }

    private func send(_ command: Int32, symbols: MediaRemoteSymbols) -> Bool {
        symbols.sendCommand(command, nil) != 0
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

    private func callbackValue<T: Sendable>(
        defaultValue: T,
        operation: (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let oneShot = OneShotContinuation(continuation)
            callbackQueue.asyncAfter(deadline: .now() + timeout) {
                oneShot.resume(defaultValue)
            }
            operation { value in
                oneShot.resume(value)
            }
        }
    }

    private struct MediaRemoteSymbols: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let isPlaying: IsPlayingFunction
        let nowPlayingPID: PIDFunction
        let sendCommand: SendCommandFunction

        static func load() -> MediaRemoteSymbols? {
            guard let handle = dlopen(SystemMediaController.mediaRemotePath, RTLD_LAZY) else {
                SystemMediaController.logger.notice("media_remote_load_failed")
                return nil
            }

            guard let isPlayingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
                  let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID"),
                  let sendCommandSymbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
                SystemMediaController.logger.notice("media_remote_symbol_missing")
                dlclose(handle)
                return nil
            }

            return MediaRemoteSymbols(
                handle: handle,
                isPlaying: unsafeBitCast(isPlayingSymbol, to: IsPlayingFunction.self),
                nowPlayingPID: unsafeBitCast(pidSymbol, to: PIDFunction.self),
                sendCommand: unsafeBitCast(sendCommandSymbol, to: SendCommandFunction.self)
            )
        }
    }
}

private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
