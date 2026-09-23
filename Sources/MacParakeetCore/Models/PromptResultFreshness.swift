import Foundation

/// Decides when a saved prompt result no longer matches the transcript the
/// user is reading.
public enum PromptResultFreshness {
    public static func summaryNeedsUpdate(
        sourceCorrectionRevision: Int?,
        currentCorrectionRevision: Int
    ) -> Bool {
        if let sourceCorrectionRevision {
            return sourceCorrectionRevision != currentCorrectionRevision
        }
        return currentCorrectionRevision > 0
    }
}
