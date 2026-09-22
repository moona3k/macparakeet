import Foundation

/// Structured progress updates emitted by TranscriptionService.
/// The UI layer converts these to display strings — the service never emits human-readable text.
public enum TranscriptionProgress: Sendable {
    case converting
    case downloading(percent: Int)
    case preparingSpeechModel
    case transcribing(percent: Int)
    case identifyingSpeakers
    case finalizing

    /// The progress fraction (0.0–1.0) if this phase carries a percentage.
    public var fraction: Double? {
        switch self {
        case .downloading(let percent), .transcribing(let percent):
            return min(Double(percent), 100) / 100
        case .converting, .preparingSpeechModel, .identifyingSpeakers, .finalizing:
            return nil
        }
    }
}
