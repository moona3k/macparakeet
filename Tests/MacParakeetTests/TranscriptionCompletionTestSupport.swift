import Foundation
@testable import MacParakeetCore

/// Pure fixture merge; each double owns the synchronization around its storage.
func mergingCompletionForTest(
    _ completion: Transcription, current: Transcription?, originalFileName: String
) throws -> Transcription {
    guard let current else { throw TranscriptionCompletionError.recordingDeleted }
    var merged = completion
    merged.updatedAt = max(completion.updatedAt, current.updatedAt)
    merged.userNotes = current.userNotes
    merged.meetingTypeId = current.meetingTypeId
    merged.isFavorite = current.isFavorite
    merged.titleOverride = current.titleOverride
    merged.chatMessages = current.chatMessages
    merged.meetingArtifactFolderPath = current.meetingArtifactFolderPath
    merged.filePath = current.filePath
    if current.fileName != originalFileName {
        merged.fileName = current.fileName
        if current.sourceType == .meeting { merged.derivedTitle = current.derivedTitle }
    }
    return merged
}
