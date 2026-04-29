import Foundation
import Sparkle

/// Gates Sparkle update checks against two conditions where letting an update
/// proceed would lose user data or be wrong:
///
/// 1. **Active meeting recording.** ADR-019's recording-lock recovery covers a
///    crash, but a Sparkle-driven `Quit + relaunch` is an *orderly* terminate
///    that wouldn't trip the lock-file recovery path the same way -- and the
///    user would still lose the in-flight live notes from the 250 ms debounce
///    window. Easier to refuse the check entirely while a recording is in
///    progress and let the user re-check after they stop.
///
/// 2. **Dev / sentinel build versions.** A locally-built `0.0.0` / `dev` /
///    `*pdx*` binary running in release config could otherwise auto-update
///    itself to whatever's currently shipped at
///    `https://macparakeet.com/appcast.xml`, which is the wrong outcome -- a
///    developer running their work-in-progress shouldn't suddenly find their
///    app replaced with the production build mid-session.
///
/// Implemented by throwing from `updater(_:mayPerform:)` so both auto-checks
/// (background timer) and user-initiated checks (the menu item) are blocked
/// uniformly, and by returning `false` from `updaterShouldRelaunchApplication`
/// so an already-downloaded update cannot relaunch the app mid-recording.
/// Sparkle surfaces the localized description in its UI for user-initiated
/// checks; auto-checks just no-op.
@MainActor
final class SparkleUpdateGuard: NSObject {
    enum BlockReason: Equatable {
        case devBuild(version: String?)
        case meetingRecordingActive
    }

    private let isMeetingRecordingActive: () -> Bool

    init(isMeetingRecordingActive: @escaping () -> Bool) {
        self.isMeetingRecordingActive = isMeetingRecordingActive
        super.init()
    }

    /// Returns `true` for the local-build sentinel versions that should never
    /// trigger Sparkle. Treats `nil` and the empty string as "dev" because a
    /// missing `CFBundleShortVersionString` is itself a sign of a non-released
    /// build.
    static func isDevBuildVersion(_ version: String?) -> Bool {
        guard let raw = version else { return true }
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { return true }
        if normalized == "0.0.0" || normalized == "dev" { return true }
        if normalized.contains("pdx") { return true }
        return false
    }

    static func blockReason(appVersion: String?, isMeetingRecordingActive: Bool) -> BlockReason? {
        if isDevBuildVersion(appVersion) {
            return .devBuild(version: appVersion)
        }
        if isMeetingRecordingActive {
            return .meetingRecordingActive
        }
        return nil
    }

    private func currentBlockReason() -> BlockReason? {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if Self.isDevBuildVersion(appVersion) {
            return .devBuild(version: appVersion)
        }
        if isMeetingRecordingActive() {
            return .meetingRecordingActive
        }
        return nil
    }

    private static func error(for reason: BlockReason) -> NSError {
        let message: String = switch reason {
        case .devBuild(let version):
            "Dev builds skip update checks (version: \(version ?? "<missing>"))."
        case .meetingRecordingActive:
            "Update checks are paused while a meeting recording is active. Stop the recording and try again."
        }
        return NSError(
            domain: "com.macparakeet.update-guard",
            code: reason.errorCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

extension SparkleUpdateGuard: SPUUpdaterDelegate {
    /// Sparkle calls this before every update check (auto and manual). Throw
    /// to refuse the check; the thrown NSError's `localizedDescription` is
    /// shown in Sparkle's user-initiated check UI.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = currentBlockReason() {
            throw Self.error(for: reason)
        }
    }

    /// Sparkle calls this when installing an already-downloaded update. This is
    /// the data-loss gate for the case where the check/download happened before
    /// a meeting started but the relaunch prompt fires during the recording.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        currentBlockReason() == nil
    }
}

private extension SparkleUpdateGuard.BlockReason {
    var errorCode: Int {
        switch self {
        case .devBuild: return 1
        case .meetingRecordingActive: return 2
        }
    }
}
