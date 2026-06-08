import SwiftUI
import MacParakeetCore

enum TranscriptionSourceDisplay: Equatable {
    case meeting
    case localFile
    case youtube
    case x
    case mediaURL

    static func resolve(for transcription: Transcription) -> TranscriptionSourceDisplay {
        switch transcription.sourceType {
        case .meeting:
            return .meeting
        case .file:
            return .localFile
        case .youtube:
            guard let sourceURL = transcription.sourceURL else { return .youtube }
            if XURLValidator.isXURL(sourceURL) { return .x }
            if YouTubeURLValidator.isYouTubeURL(sourceURL) { return .youtube }
            return .mediaURL
        }
    }

    var collapsedText: String {
        switch self {
        case .meeting:
            return "Meeting"
        case .localFile:
            return "Local"
        case .youtube:
            return "YouTube"
        case .x:
            return "X"
        case .mediaURL:
            return "Video"
        }
    }

    var expandedText: String {
        switch self {
        case .meeting:
            return "Meeting recording"
        case .localFile:
            return "Local file"
        case .youtube:
            return "YouTube source"
        case .x:
            return "X source"
        case .mediaURL:
            return "Video source"
        }
    }

    var systemImage: String {
        switch self {
        case .meeting:
            return "record.circle.fill"
        case .localFile:
            return "waveform"
        case .youtube, .x, .mediaURL:
            return "play.rectangle.fill"
        }
    }

    var symbolText: String? {
        switch self {
        case .x:
            return "𝕏"
        case .meeting, .localFile, .youtube, .mediaURL:
            return nil
        }
    }

    var tint: Color {
        switch self {
        case .meeting, .localFile:
            return DesignSystem.Colors.accent
        case .youtube:
            return DesignSystem.Colors.youtubeRed
        case .x:
            return DesignSystem.Colors.xMark
        case .mediaURL:
            return DesignSystem.Colors.textSecondary
        }
    }
}
