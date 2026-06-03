import Foundation

/// Coarse category of the macOS application a dictation was pasted into, or
/// that a Transform rewrote text inside.
///
/// Privacy contract: the frontmost app's bundle identifier is mapped to one of
/// a small fixed set of structural buckets on-device, and **only the bucket** is
/// transmitted. The bundle identifier itself never leaves the device, and any
/// app we do not recognize maps to `.other` — so a user's niche or otherwise
/// identifying app is never observable in telemetry.
///
/// Answers product questions like "what kinds of apps do people dictate into?"
/// and "where do Transforms get used?" without identifying individual apps.
public enum TelemetryAppCategory: String, Codable, Sendable, Equatable, CaseIterable {
    case messaging
    case email
    case browser
    case notes
    case docs
    case code
    case terminal
    case other

    /// Map a frontmost-app bundle identifier to a coarse category. Returns
    /// `.other` for a nil/empty/unknown identifier so unrecognized apps never
    /// leak.
    public init(bundleIdentifier: String?) {
        guard
            let raw = bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !raw.isEmpty
        else {
            self = .other
            return
        }
        self = Self.category(forBundleID: raw)
    }

    private static func category(forBundleID id: String) -> TelemetryAppCategory {
        // Vendor families with many sub-bundles are matched by prefix so we
        // catch Canary/Insiders/EAP variants without enumerating each one.
        if id.hasPrefix("com.jetbrains.") { return .code }
        if id.hasPrefix("com.microsoft.vscode") { return .code }
        if id.hasPrefix("com.google.chrome") { return .browser }

        if browserIDs.contains(id) { return .browser }
        if messagingIDs.contains(id) { return .messaging }
        if emailIDs.contains(id) { return .email }
        if notesIDs.contains(id) { return .notes }
        if docsIDs.contains(id) { return .docs }
        if codeIDs.contains(id) { return .code }
        if terminalIDs.contains(id) { return .terminal }
        return .other
    }

    // All identifiers are stored lowercased to match the normalized input.

    private static let browserIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "company.thebrowser.browser",     // Arc
        "company.thebrowser.dia",         // Dia
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi",
    ]

    private static let messagingIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",          // Slack
        "com.apple.ichat",                    // Messages (legacy id)
        "com.apple.mobilesms",                // Messages
        "net.whatsapp.whatsapp",              // WhatsApp
        "com.hnc.discord",                    // Discord
        "ru.keepcoder.telegram",              // Telegram (macOS)
        "org.telegram.desktop",               // Telegram Desktop
        "com.microsoft.teams",                // Teams
        "com.microsoft.teams2",               // Teams (new)
        "org.whispersystems.signal-desktop",  // Signal
        "com.facebook.archon",                // Messenger
    ]

    private static let emailIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-mac",         // Spark
        "it.bloop.airmail2",                  // Airmail
        "com.mimestream.mimestream",          // Mimestream
    ]

    private static let notesIDs: Set<String> = [
        "com.apple.notes",
        "md.obsidian",                        // Obsidian
        "net.shinyfrog.bear",                 // Bear
        "notion.id",                          // Notion
        "com.lukilabs.lukiapp",               // Craft
        "com.agiletortoise.drafts-osx",       // Drafts
    ]

    private static let docsIDs: Set<String> = [
        "com.apple.iwork.pages",              // Pages
        "com.apple.textedit",                 // TextEdit
        "com.microsoft.word",                 // Word
        "com.ulyssesapp.mac",                 // Ulysses
        "com.soulmen.ulysses3",               // Ulysses (older)
        "pro.writer.mac",                     // iA Writer
        "com.literatureandlatte.scrivener3",  // Scrivener
    ]

    private static let codeIDs: Set<String> = [
        "com.apple.dt.xcode",                 // Xcode
        "com.todesktop.230313mzl4w4u92",      // Cursor
        "com.sublimetext.4",                  // Sublime Text 4
        "com.sublimetext.3",                  // Sublime Text 3
        "dev.zed.zed",                        // Zed
        "com.panic.nova",                     // Nova
        "com.github.atom",                    // Atom
        "com.google.android.studio",          // Android Studio
    ]

    private static let terminalIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",              // iTerm2
        "dev.warp.warp-stable",               // Warp
        "com.mitchellh.ghostty",              // Ghostty
        "org.alacritty",                      // Alacritty
        "net.kovidgoyal.kitty",               // kitty
        "co.zeit.hyper",                      // Hyper
        "com.github.wez.wezterm",             // WezTerm
    ]
}

/// Bucketed elapsed time between onboarding completion and a user's first
/// completed dictation. Coarse buckets only — never the raw timestamp or
/// duration — so the activation funnel is observable without a per-install
/// clock that could be used to fingerprint.
public enum TelemetryActivationWindow: String, Sendable, Equatable, CaseIterable {
    case underMinute = "under_1m"
    case underHour = "under_1h"
    case underDay = "under_1d"
    case underWeek = "under_1w"
    case overWeek = "over_1w"
    /// No onboarding timestamp on record (e.g. a pre-existing install from
    /// before the timestamp was persisted), or a clock-skew negative value.
    case unknown

    public init(secondsSinceOnboarding seconds: TimeInterval?) {
        guard let seconds, seconds >= 0 else {
            self = .unknown
            return
        }
        switch seconds {
        case ..<60: self = .underMinute
        case ..<3_600: self = .underHour
        case ..<86_400: self = .underDay
        case ..<604_800: self = .underWeek
        default: self = .overWeek
        }
    }
}
