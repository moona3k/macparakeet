import Foundation

struct MeetingFinalizationBenchmarkObserver: Sendable {
    enum Stage: String, Sendable {
        case microphoneSTT = "mic_stt"
        case systemSTT = "system_stt"
        case diarization
        case finalizeMerge = "finalize_merge"
    }

    private let onStageStart: @Sendable (Stage) -> Void
    private let onStageEnd: @Sendable (Stage) -> Void

    init(
        onStageStart: @escaping @Sendable (Stage) -> Void,
        onStageEnd: @escaping @Sendable (Stage) -> Void
    ) {
        self.onStageStart = onStageStart
        self.onStageEnd = onStageEnd
    }

    func stageDidStart(_ stage: Stage) {
        onStageStart(stage)
    }

    func stageDidEnd(_ stage: Stage) {
        onStageEnd(stage)
    }
}
