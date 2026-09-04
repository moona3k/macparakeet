import Foundation

/// Decides how the timed transcript body is laid out.
///
/// The Library "freeze at 100% CPU" bug (macOS 26) is a self-feeding SwiftUI
/// update loop between a `LazyVStack`'s view cache (item phase mutations and
/// estimate measurement re-instantiating rows) and the per-row text-selection
/// platform overlays those rows carry, kept alive by hover re-dispatch after
/// every update. It appears after scrolling down and back up, when realized
/// row heights differ from the lazy estimates. A plain `VStack` has no view
/// cache, so small transcripts, which gain nothing from laziness, render
/// non-lazily. Very long transcripts keep the lazy stack so one card cannot
/// become an unbounded subtree (issue #845 / #848).
enum TranscriptBodyLayout {
    /// Largest transcript (total timed rows) rendered without a lazy stack.
    /// The #845 reporter case was 964 rows; typical meetings are far smaller.
    static let nonLazyRowLimit = 400

    static func usesLazyStack(
        rowCount: Int,
        environment: [String: String] = launchEnvironment
    ) -> Bool {
        if let override = debugOverride(named: "MACPARAKEET_DEBUG_TRANSCRIPT_LAZY", environment: environment) {
            return override
        }
        return rowCount > nonLazyRowLimit
    }

    /// Per-row `.textSelection(.enabled)` in the timed view. On by default; the
    /// DEBUG override exists so the platform-overlay contribution to the freeze
    /// can be bisected at launch without a rebuild.
    static func rowTextSelectionEnabled(environment: [String: String] = launchEnvironment) -> Bool {
        debugOverride(named: "MACPARAKEET_DEBUG_TRANSCRIPT_SELECTION", environment: environment) ?? true
    }

    static var rowTextSelectionEnabled: Bool {
        rowTextSelectionEnabled(environment: launchEnvironment)
    }

    /// Read once: the launch environment never changes, and these lookups run
    /// from SwiftUI `body`, so rebuilding the dictionary per pass is waste.
    private static let launchEnvironment = ProcessInfo.processInfo.environment

    /// DEBUG-only launch overrides, e.g.
    /// `open MacParakeet-Dev.app --env MACPARAKEET_DEBUG_TRANSCRIPT_LAZY=0`.
    /// Values `1`/`true`/`yes` enable, `0`/`false`/`no` disable; anything else
    /// (or a release build) leaves the product default in place.
    static func debugOverride(
        named name: String,
        environment: [String: String] = launchEnvironment
    ) -> Bool? {
        #if DEBUG
        guard let raw = environment[name]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
