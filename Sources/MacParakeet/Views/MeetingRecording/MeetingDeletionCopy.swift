import Foundation
import MacParakeetCore

enum MeetingDeletionCopy {
    enum Surface {
        case library
        case meetings

        var name: String {
            switch self {
            case .library:
                return "Library"
            case .meetings:
                return "Meetings"
            }
        }
    }

    static let audioOnlyAlertTitle = "Remove Meeting Audio?"
    static let audioOnlyConfirmTitle = "Remove Audio Only"
    static let audioOnlyMenuTitle = "Remove Audio Only"

    static let fullDeleteAlertTitle = "Delete Meeting?"
    static let fullDeleteConfirmTitle = "Delete Meeting"
    static let fullDeleteMenuTitle = "Delete Meeting"

    static func singleAudioOnlyMessage(surface: Surface) -> String {
        singleAudioOnlyMessage(surface: surface, status: .completed)
    }

    static func singleAudioOnlyMessage(
        surface: Surface,
        status: Transcription.TranscriptionStatus
    ) -> String {
        nonCompletedWarning(status: status)
            + "This permanently deletes the saved audio for this meeting. The meeting stays in \(surface.name) with its transcript. Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available, and MacParakeet will not be able to detect or backfill speakers for this recording."
    }

    static func bulkAudioOnlyMessage(
        count: Int,
        skippedCount: Int,
        surface: Surface,
        hasNonCompletedMeeting: Bool = false
    ) -> String {
        let selectedCount = count + skippedCount
        let selectedWord = selectedCount == 1 ? "meeting" : "meetings"
        let meetingWord = count == 1 ? "meeting" : "meetings"
        let meetingSubject = count == 1 ? "The meeting stays" : "The meetings stay"
        let transcriptObject = count == 1 ? "its transcript" : "their transcripts"
        let recordingObject = count == 1 ? "this recording" : "these recordings"
        let prefix = skippedCount > 0 ? "\(selectedCount) selected \(selectedWord). " : ""
        var message =
            bulkNonCompletedWarning(hasNonCompletedMeeting: hasNonCompletedMeeting)
            + "\(prefix)This permanently deletes saved audio from \(count) \(meetingWord). \(meetingSubject) in \(surface.name) with \(transcriptObject). Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available, and MacParakeet will not be able to detect or backfill speakers for \(recordingObject)."
        if skippedCount > 0 {
            if skippedCount == 1 {
                message += " 1 selected meeting cannot have its audio removed right now, so it will be skipped."
            } else {
                message +=
                    " \(skippedCount) selected meetings cannot have their audio removed right now, so they will be skipped."
            }
        }
        return message
    }

    static func singleFullDeleteMessage(title: String) -> String {
        singleFullDeleteMessage(title: title, status: .completed)
    }

    static func singleFullDeleteMessage(
        title: String,
        status: Transcription.TranscriptionStatus
    ) -> String {
        nonCompletedWarning(status: status)
            + "This permanently deletes \"\(title)\", including its transcript and saved audio. Notes, AI results, and chats for this meeting are also deleted if they exist."
    }

    static func singleFullDeleteMessage(for transcription: Transcription) -> String {
        singleFullDeleteMessage(
            title: transcription.fileName,
            status: transcription.status
        )
    }

    static func bulkFullDeleteMessage(
        count: Int,
        hasNonCompletedMeeting: Bool = false
    ) -> String {
        let meetingWord = count == 1 ? "meeting" : "meetings"
        let transcriptObject = count == 1 ? "its transcript and saved audio" : "transcripts and saved audio"
        let artifactSubject = count == 1 ? "this meeting" : "those meetings"
        return
            bulkNonCompletedWarning(hasNonCompletedMeeting: hasNonCompletedMeeting)
            + "This permanently deletes \(count) \(meetingWord), including \(transcriptObject). Notes, AI results, and chats for \(artifactSubject) are also deleted if they exist."
    }

    static func mixedBulkFullDeleteMessage(
        totalCount: Int,
        meetingCount: Int,
        hasNonCompletedMeeting: Bool = false
    ) -> String {
        let itemWord = totalCount == 1 ? "item" : "items"
        let meetingWord = meetingCount == 1 ? "meeting" : "meetings"
        return
            bulkNonCompletedWarning(hasNonCompletedMeeting: hasNonCompletedMeeting)
            + "This permanently deletes \(totalCount) \(itemWord), including \(meetingCount) \(meetingWord). Meeting transcripts, saved audio, notes, AI results, and chats are removed if they exist. Original local source files are not removed."
    }

    static func audioUnavailableHelp(for state: MeetingAudioFile.State) -> String {
        switch state {
        case .saved:
            assertionFailure(
                "audioUnavailableHelp called for .saved state; callers should show positive help text instead.")
            return "Meeting audio is available"
        case .removed:
            return "Saved meeting audio has been removed"
        case .missing:
            return "Meeting audio file is missing"
        case .notMeeting:
            return "Meeting audio is not available"
        }
    }

    static func audioRemovalUnavailableHelp(
        for transcription: Transcription,
        state: MeetingAudioFile.State
    ) -> String {
        if state == .saved && MeetingAudioFile.isFinalizationInProgress(for: transcription) {
            return TranscriptionAssetCleanup.meetingAudioFinalizationInProgressMessage
        }
        return audioUnavailableHelp(for: state)
    }

    private static func nonCompletedWarning(status: Transcription.TranscriptionStatus) -> String {
        guard status != .completed else { return "" }
        return "This meeting hasn't been transcribed yet — deleting the audio makes that permanent. "
    }

    private static func bulkNonCompletedWarning(hasNonCompletedMeeting: Bool) -> String {
        guard hasNonCompletedMeeting else { return "" }
        return "At least one selected meeting hasn't been transcribed yet — deleting the audio makes that permanent. "
    }
}
