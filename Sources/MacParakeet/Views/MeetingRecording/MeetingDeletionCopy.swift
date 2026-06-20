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
        "This removes the saved audio for this meeting. The meeting stays in \(surface.name) with its transcript. Notes, AI results, and chats stay too if they exist. Playback and retranscription will no longer be available unless you saved a copy of the audio."
    }

    static func bulkAudioOnlyMessage(
        count: Int,
        skippedCount: Int,
        surface: Surface
    ) -> String {
        let meetingWord = count == 1 ? "meeting" : "meetings"
        let meetingSubject = count == 1 ? "The meeting stays" : "The meetings stay"
        let transcriptObject = count == 1 ? "its transcript" : "their transcripts"
        let savedCopy = count == 1 ? "a copy" : "copies"
        var message =
            "This removes saved audio from \(count) \(meetingWord). \(meetingSubject) in \(surface.name) with \(transcriptObject). Notes, AI results, and chats stay too if they exist. Playback and retranscription will no longer be available unless you saved \(savedCopy) of the audio."
        if skippedCount > 0 {
            let skippedWord = skippedCount == 1 ? "item" : "items"
            message +=
                " \(skippedCount) selected \(skippedWord) will be skipped because no saved meeting audio is available."
        }
        return message
    }

    static func singleFullDeleteMessage(title: String) -> String {
        "This permanently deletes \"\(title)\", including its transcript and saved audio. Notes, AI results, and chats for this meeting are also deleted if they exist."
    }

    static func bulkFullDeleteMessage(count: Int) -> String {
        let meetingWord = count == 1 ? "meeting" : "meetings"
        let transcriptObject = count == 1 ? "its transcript and saved audio" : "transcripts and saved audio"
        let artifactSubject = count == 1 ? "this meeting" : "those meetings"
        return
            "This permanently deletes \(count) \(meetingWord), including \(transcriptObject). Notes, AI results, and chats for \(artifactSubject) are also deleted if they exist."
    }

    static func mixedBulkFullDeleteMessage(
        totalCount: Int,
        meetingCount: Int
    ) -> String {
        let itemWord = totalCount == 1 ? "item" : "items"
        let meetingWord = meetingCount == 1 ? "meeting" : "meetings"
        return
            "This permanently deletes \(totalCount) \(itemWord), including \(meetingCount) \(meetingWord). Meeting transcripts, saved audio, notes, AI results, and chats are removed if they exist. Original local source files are not removed."
    }

    static func audioUnavailableHelp(for state: MeetingAudioFile.State) -> String {
        switch state {
        case .saved:
            assertionFailure("audioUnavailableHelp called for .saved state; callers should show positive help text instead.")
            return "Meeting audio is available"
        case .removed:
            return "Saved meeting audio has been removed"
        case .missing:
            return "Meeting audio file is missing"
        case .notMeeting:
            return "Meeting audio is not available"
        }
    }
}
