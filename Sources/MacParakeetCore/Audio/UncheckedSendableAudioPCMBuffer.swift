import AVFAudio

/// AVAudioConverter invokes its input block synchronously, but Swift 6 still
/// treats the escaping block as `@Sendable`. This wrapper keeps that local
/// handoff explicit at the converter boundary.
final class UncheckedSendableAudioPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Values captured by the serialized AVAudioEngine tap callback. These wrappers
/// keep the unchecked boundary explicit without muting diagnostics around the
/// rest of the recording actor.
final class UncheckedSendableAudioFormat: @unchecked Sendable {
    let format: AVAudioFormat

    init(_ format: AVAudioFormat) {
        self.format = format
    }
}

final class UncheckedSendableAudioFile: @unchecked Sendable {
    let file: AVAudioFile

    init(_ file: AVAudioFile) {
        self.file = file
    }
}

/// Captures the notification's concrete engine instance across the dispatch
/// queue hop in `AVAudioEngineMicrophonePlatform`. Access still happens on the
/// platform queue; this wrapper only makes that audited boundary explicit for
/// Swift 6 strict concurrency.
final class UncheckedSendableAudioEngine: @unchecked Sendable {
    private let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }

    func inputFormat() -> AVAudioFormat? {
        try? catchingObjCException {
            engine.inputNode.outputFormat(forBus: 0)
        }
    }

    /// ObjC-exception-safe read of the engine's running state.
    func isEngineRunning() -> Bool {
        (try? catchingObjCException { engine.isRunning }) ?? false
    }

    /// Returns true if this box wraps the given engine instance (identity check).
    func wraps(_ other: AVAudioEngine) -> Bool {
        engine === other
    }
}
