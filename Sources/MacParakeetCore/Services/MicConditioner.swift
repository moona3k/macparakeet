import Foundation

protocol MicConditioning: AnyObject, Sendable {
    var mode: MeetingMicProcessingEffectiveMode { get }
    func condition(microphone: [Float], speaker: [Float]) -> [Float]
    func reset()
}

final class VPIOConditioner: MicConditioning {
    var mode: MeetingMicProcessingEffectiveMode { .vpio }

    func condition(microphone: [Float], speaker: [Float]) -> [Float] {
        microphone
    }

    func reset() {}
}

final class SoftwareAECConditioner: MicConditioning {
    var mode: MeetingMicProcessingEffectiveMode { .raw }

    private let aec: MeetingSoftwareAEC

    init(aec: MeetingSoftwareAEC = MeetingSoftwareAEC()) {
        self.aec = aec
    }

    func condition(microphone: [Float], speaker: [Float]) -> [Float] {
        aec.process(microphone: microphone, speaker: speaker)
    }

    func reset() {
        aec.reset()
    }
}
