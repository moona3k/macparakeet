import Foundation

public struct MeetingImportRequest: Sendable, Equatable {
    public let sourceURL: URL
    public let titleOverride: String?
    public let startedAt: Date?

    public init(sourceURL: URL, titleOverride: String? = nil, startedAt: Date? = nil) {
        self.sourceURL = sourceURL
        self.titleOverride = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
    }

    /// Shared, read-only defaults for app and CLI. A blank explicit title is
    /// invalid; an absent override leaves normal title generation enabled.
    public func resolveDefaults(now: Date = Date()) throws -> MeetingImportDefaults {
        guard sourceURL.isFileURL else { throw MeetingImportError.invalidSource }
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey, .creationDateKey, .contentModificationDateKey,
            ])
        } catch {
            throw MeetingImportError.invalidSource
        }
        guard values.isRegularFile == true else { throw MeetingImportError.invalidSource }
        guard AudioFileConverter.isSupported(extension: sourceURL.pathExtension) else {
            throw MeetingImportError.unsupportedFormat
        }
        if titleOverride?.isEmpty == true { throw MeetingImportError.blankTitle }
        return MeetingImportDefaults(
            title: titleOverride ?? sourceURL.deletingPathExtension().lastPathComponent,
            startedAt: startedAt ?? values.creationDate ?? values.contentModificationDate ?? now,
            titleOverride: titleOverride
        )
    }
}

public struct MeetingImportDefaults: Sendable, Equatable {
    public let title: String
    public let startedAt: Date
    public let titleOverride: String?
}

public enum MeetingImportError: Error, LocalizedError, Sendable {
    case invalidSource
    case unsupportedFormat
    case blankTitle
    case invalidAudio

    public var errorDescription: String? {
        switch self {
        case .invalidSource: "Choose a local audio or video file."
        case .unsupportedFormat: "This audio or video format is not supported."
        case .blankTitle: "Enter a meeting title or use the filename default."
        case .invalidAudio: "The file does not contain playable audio."
        }
    }
}

public enum MeetingImportProgress: Sendable {
    case preparingMedia
    case published(Transcription)
    case transcription(TranscriptionProgress)
    case automation(SavedAudioAutoPromptCompletionProgress)
}

public enum MeetingImportWarning: Sendable, Equatable {
    case transcriptionFailed(message: String)
    case transcriptionCancelled
    case persistenceFailed(message: String)
    case settlementFailed(message: String)
    case ownershipReleaseFailed(message: String)
    case audioRetentionFailed(message: String)
    case automationFailed(message: String)
    case automationCancelled
    case promptFailed(promptID: UUID?, promptName: String, message: String)
    case knowledgeCardFailed(message: String)
    case artifactRefreshFailed(message: String)

    public func userFacingMessage(
        for transcriptionStatus: Transcription.TranscriptionStatus
    ) -> String {
        switch self {
        case .transcriptionFailed:
            "Transcription needs another try. The saved meeting is available in Meetings."
        case .transcriptionCancelled:
            "Transcription was stopped. The saved meeting can be retried."
        case .persistenceFailed, .settlementFailed, .ownershipReleaseFailed:
            if transcriptionStatus == .completed {
                "Some saved-meeting details need attention. The transcript is ready."
            } else {
                "Transcription needs another try. The saved meeting is available in Meetings."
            }
        case .audioRetentionFailed:
            "The managed audio could not be removed for the configured retention setting. The transcript is ready."
        case .automationFailed:
            "Some meeting notes could not finish. The transcript is ready."
        case .automationCancelled:
            "Meeting notes stopped before they finished. The transcript is ready."
        case .promptFailed:
            "An enabled meeting note could not finish. The transcript is ready."
        case .knowledgeCardFailed:
            "The knowledge card could not finish. The transcript is ready."
        case .artifactRefreshFailed:
            "Some meeting details could not finish. The transcript is ready."
        }
    }
}

public struct MeetingImportResult: Sendable {
    public enum Completion: String, Sendable, Equatable {
        case completed
        case partial
        case needsRetry
    }

    public let transcription: Transcription
    public let warnings: [MeetingImportWarning]

    public var completion: Completion {
        guard transcription.status == .completed else { return .needsRetry }
        return warnings.isEmpty ? .completed : .partial
    }

    public init(transcription: Transcription, warnings: [MeetingImportWarning] = []) {
        self.transcription = transcription
        self.warnings = warnings
    }
}
