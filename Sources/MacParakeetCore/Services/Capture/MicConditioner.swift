import Foundation

protocol MicConditioning: AnyObject, Sendable {
    func condition(microphone: [Float], speaker: [Float]) -> [Float]
    func reset()
}

/// No-op pass-through. The mic stream is cleaned upstream by macOS
/// Voice Processing I/O (engaged via `MeetingMicProcessingMode.vpioPreferred`).
/// Used both when VPIO engages (mic is already AEC'd) and as the fallback
/// when VPIO fails to engage (mic is raw — speaker bleed will be present
/// and logged loudly so we know it happened).
final class PassthroughMicConditioner: MicConditioning {
    func condition(microphone: [Float], speaker: [Float]) -> [Float] {
        microphone
    }

    func reset() {}
}
