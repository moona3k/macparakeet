import Foundation

/// Cheap, filesystem-light UI gating for whether "Split and transcribe"
/// should be offered for a row at all. Mirrors the read-only preconditions
/// `MeetingSplitService.validateSource` enforces authoritatively — this is
/// never a substitute for that check, which still runs (and can still
/// reject) at `preview`/`createAndProcess` time.
public enum MeetingSplitEligibility {
    public static func isEligible(
        _ transcription: Transcription,
        fileManager: FileManager = .default
    ) -> Bool {
        guard transcription.sourceType == .meeting else { return false }
        guard transcription.status == .completed || transcription.status == .error else { return false }
        guard MeetingArtifactStore.sessionFolderURL(for: transcription) != nil else { return false }
        guard !MeetingAudioFile.isFinalizationInProgress(for: transcription, fileManager: fileManager) else {
            return false
        }
        return true
    }
}
