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
