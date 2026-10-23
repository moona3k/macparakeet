import Foundation

public enum MeetingApp: String, Sendable, Equatable, CaseIterable {
    case zoom
    case teams
    case webex
    case slack
    case facetime
    case browser
}

public enum MeetingAppTrustTier: String, Sendable, Equatable {
    case dedicated
    case chat
    case browser
}

public struct MeetingAppDescriptor: Sendable, Equatable {
    public let app: MeetingApp
    public let trustTier: MeetingAppTrustTier

    public init(app: MeetingApp, trustTier: MeetingAppTrustTier) {
        self.app = app
        self.trustTier = trustTier
    }
}

/// Conferencing apps that provide high-confidence meeting activity metadata.
/// ADR-023 uses the native subset for app-quit auto-stop; ADR-024 uses the
/// descriptors to apply trust-tiered activity detection.
public enum MeetingAppRegistry {
    public static let nativeAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]

    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
    ]

    public static func isRecognizedNativeApp(bundleID: String) -> Bool {
        nativeAppBundleIDs.contains(bundleID)
    }

    public static func descriptor(forBundleID bundleID: String) -> MeetingAppDescriptor? {
        switch bundleID {
        case "us.zoom.xos":
            return MeetingAppDescriptor(app: .zoom, trustTier: .dedicated)
        case "com.microsoft.teams2", "com.microsoft.teams":
            return MeetingAppDescriptor(app: .teams, trustTier: .dedicated)
        case "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark":
            return MeetingAppDescriptor(app: .webex, trustTier: .dedicated)
        case "com.apple.FaceTime":
            return MeetingAppDescriptor(app: .facetime, trustTier: .dedicated)
        case "com.tinyspeck.slackmacgap":
            return MeetingAppDescriptor(app: .slack, trustTier: .chat)
        default:
            guard browserBundleIDs.contains(bundleID) else { return nil }
            return MeetingAppDescriptor(app: .browser, trustTier: .browser)
        }
    }

    public static func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    /// Chromium attributes microphone use to helper processes. Only accept
    /// helpers belonging to a known browser, not arbitrary prefix matches or
    /// shared WebKit processes that cannot identify their owning browser.
    public static func normalizedBrowserBundleID(for bundleID: String) -> String? {
        if browserBundleIDs.contains(bundleID) { return bundleID }
        return browserBundleIDs.sorted().first { browserID in
            [".helper", ".Helper"].contains { suffix in
                bundleID == browserID + suffix || bundleID.hasPrefix(browserID + suffix + ".")
            }
        }
    }
}
