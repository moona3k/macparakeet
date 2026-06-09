import Foundation

/// A media platform a transcribable URL can come from.
///
/// Two responsibilities, kept deliberately small:
///
/// 1. **Recognition** (``recognize(_:)``) — best-effort, host-based. Drives
///    *display only*: which brand glyph / label to show for a pasted or saved URL.
///    It is **not** an allowlist and **not** a gate. Unrecognized URLs simply show
///    a generic mark.
///
/// 2. **The single gate** (``isTranscribable(_:)``) — `true` for any plausible
///    media URL. The app accepts anything yt-dlp might handle and lets the bundled
///    download path try it (failures surface in the UI), because yt-dlp supports
///    far more sites than we name here. This replaces the duplicated
///    "YouTube || X || Podcast" OR-chains that used to live in every URL surface.
///
/// Routing still keys off the dedicated validators: Apple Podcasts goes through the
/// iTunes resolver (``PodcastURLValidator``) and YouTube keeps client-side videoID
/// dedup (``YouTubeURLValidator``). Everything else flows through the generic
/// yt-dlp downloader.
public enum MediaPlatform: String, CaseIterable, Sendable, Hashable {
    case youtube
    case x
    case vimeo
    case facebook
    case tiktok
    case instagram
    case applePodcasts
    case soundcloud
    case twitch

    /// Human-facing platform name, e.g. the "TikTok link detected" label.
    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .x: return "X"
        case .vimeo: return "Vimeo"
        case .facebook: return "Facebook"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .applePodcasts: return "Apple Podcasts"
        case .soundcloud: return "SoundCloud"
        case .twitch: return "Twitch"
        }
    }

    /// Whether this platform's content is audio-first (podcasts) rather than video.
    /// Drives copy/labeling only.
    public var isAudioFirst: Bool {
        switch self {
        case .applePodcasts, .soundcloud:
            return true
        case .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .twitch:
            return false
        }
    }

    /// Host suffix → platform. Matched by registrable-suffix so that `www.`,
    /// `m.`, `mobile.`, `player.`, regional, and other subdomains all resolve.
    /// Suffixes are platform-unique, so match order is irrelevant.
    private static let hostSuffixes: [(suffix: String, platform: MediaPlatform)] = [
        ("youtube.com", .youtube),
        ("youtu.be", .youtube),
        ("youtube-nocookie.com", .youtube),
        ("x.com", .x),
        ("twitter.com", .x),
        ("vimeo.com", .vimeo),
        ("vimeopro.com", .vimeo),
        ("facebook.com", .facebook),
        ("fb.watch", .facebook),
        ("fb.com", .facebook),
        ("tiktok.com", .tiktok),
        ("instagram.com", .instagram),
        ("instagr.am", .instagram),
        ("podcasts.apple.com", .applePodcasts),
        ("podcast.apple.com", .applePodcasts),
        ("soundcloud.com", .soundcloud),
        ("twitch.tv", .twitch),
    ]

    /// Best-effort: which known platform does this URL belong to? `nil` when
    /// unrecognized (still transcribable via the generic yt-dlp path).
    public static func recognize(_ string: String) -> MediaPlatform? {
        guard let host = host(of: string) else { return nil }
        for entry in hostSuffixes where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            return entry.platform
        }
        return nil
    }

    /// The single front-end gate for the Transcribe-URL surfaces. `true` for any
    /// plausible media URL: an `http(s)` URL with a host, **or** a scheme-less
    /// string whose host we recognize (e.g. `youtube.com/watch?v=…`,
    /// `vimeo.com/123`). Deliberately permissive — yt-dlp decides what actually
    /// downloads; this just keeps the button from lighting up on arbitrary typed
    /// text.
    public static func isTranscribable(_ string: String) -> Bool {
        if DownloadableMediaURLValidator.isDownloadableMediaURL(string) { return true }
        // Scheme-less but recognizable host (typed without https://).
        return recognize(string) != nil
    }

    /// Normalizes a transcribable URL for the download layer, which requires an
    /// explicit scheme. Prepends `https://` to a scheme-less string (e.g. a typed
    /// `vimeo.com/123`) so everything the gate accepts is also accepted downstream
    /// (`DownloadableMediaURLValidator` / `YouTubeDownloader` reject scheme-less
    /// hosts). Strings that already carry a scheme — and empty input — are returned
    /// trimmed but otherwise untouched.
    public static func normalizedURLString(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        return "https://\(trimmed)"
    }

    // MARK: - Private

    private static func host(of string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: normalized)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }
}
