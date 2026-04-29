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
