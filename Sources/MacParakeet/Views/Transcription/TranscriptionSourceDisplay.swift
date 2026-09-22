import SwiftUI
import MacParakeetCore

enum TranscriptionSourceDisplay: Equatable {
    case meeting
    case localFile
    case youtube
    case x
    case vimeo
    case facebook
    case tiktok
    case instagram
    case podcast
    case audioURL
    case mediaURL

    static func resolve(for transcription: Transcription) -> TranscriptionSourceDisplay {
        switch transcription.sourceType {
        case .meeting:
            return .meeting
        case .file:
            return .localFile
        case .podcast:
            return .podcast
        case .youtube:
            // `.youtube` is the shared "downloaded from a URL" source type. Use
            // host recognition to label it with the actual platform when known,
            // falling back to a generic video badge for anything else.
            guard let sourceURL = transcription.sourceURL else { return .youtube }
            switch MediaPlatform.recognize(sourceURL) {
            case .youtube: return .youtube
            case .x: return .x
            case .vimeo: return .vimeo
            case .facebook: return .facebook
            case .tiktok: return .tiktok
            case .instagram: return .instagram
            case .applePodcasts: return .podcast
            // SoundCloud is audio-first — give it an audio affordance, not the
            // generic video badge. Twitch / unknown hosts stay video.
            case .soundcloud: return .audioURL
            case .twitch, .none: return .mediaURL
            }
        }
    }

    /// The platform whose bundled brand mark identifies this source on sight.
    ///
    /// Only the six whose display maps to exactly one platform. `.podcast`
    /// covers any feed, not just Apple Podcasts, and `.mediaURL` covers Twitch
    /// *and* unrecognized hosts, so neither can claim a mark. `.audioURL` is
    /// reached only from SoundCloud today, but the case is named for audio in
    /// general and would mislabel a future generic audio source, so it is left
    /// out too. Anything absent here keeps its SF Symbol and its text.
    var brandedPlatform: MediaPlatform? {
        switch self {
        case .youtube: return .youtube
        case .x: return .x
        case .vimeo: return .vimeo
        case .facebook: return .facebook
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .meeting, .localFile, .podcast, .audioURL, .mediaURL: return nil
        }
    }

    var collapsedText: String {
        switch self {
        case .meeting: return "Meeting"
        case .localFile: return "Local"
        case .youtube: return "YouTube"
        case .x: return "X"
        case .vimeo: return "Vimeo"
        case .facebook: return "Facebook"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .podcast: return "Podcast"
        case .audioURL: return "Audio"
        case .mediaURL: return "Video"
        }
    }

    var expandedText: String {
        switch self {
        case .meeting: return "Meeting recording"
        case .localFile: return "Local file"
        case .youtube: return "YouTube source"
        case .x: return "X source"
        case .vimeo: return "Vimeo source"
        case .facebook: return "Facebook source"
        case .tiktok: return "TikTok source"
        case .instagram: return "Instagram source"
        case .podcast: return "Podcast episode"
        case .audioURL: return "Audio source"
        case .mediaURL: return "Video source"
        }
    }

    var systemImage: String {
        switch self {
        case .meeting: return "record.circle.fill"
        case .localFile: return "waveform"
        case .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .mediaURL:
            return "play.rectangle.fill"
        case .podcast: return "mic.fill"
        case .audioURL: return "waveform"
        }
    }

    var symbolText: String? {
        switch self {
        case .x: return "𝕏"
        case .meeting, .localFile, .youtube, .vimeo, .facebook, .tiktok, .instagram, .podcast, .audioURL, .mediaURL:
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
        case .vimeo:
            return DesignSystem.Colors.vimeoBlue
        case .facebook:
            return DesignSystem.Colors.facebookBlue
        case .tiktok:
            return DesignSystem.Colors.tiktokTeal
        case .instagram:
            return DesignSystem.Colors.instagramPink
        case .podcast:
            return DesignSystem.Colors.podcastPurple
        case .audioURL, .mediaURL:
            return DesignSystem.Colors.textSecondary
        }
    }
}
