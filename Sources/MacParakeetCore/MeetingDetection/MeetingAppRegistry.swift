import Foundation

/// Native conferencing apps that provide high-confidence meeting activity
/// metadata. ADR-023 uses these for app-quit auto-stop; ADR-024's activity
/// detection layer will extend this registry with browser and trust-tier data.
public enum MeetingAppRegistry {
    public static let nativeAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]

    public static func isRecognizedNativeApp(bundleID: String) -> Bool {
        nativeAppBundleIDs.contains(bundleID)
    }
}
