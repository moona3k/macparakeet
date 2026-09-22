import Foundation

/// Canonical set of equivalent on-disk paths for a meeting artifact URL.
/// Settlement's belongs-to-folder check and recovery's existing-row matching
/// must agree on aliasing, so both go through this helper.
enum MeetingArtifactPathAliases {
    static func aliases(for url: URL) -> Set<String> {
        var paths = Set([
            url.path,
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
        ])
        for path in Array(paths) {
            if path.hasPrefix("/private/var/") {
                paths.insert(String(path.dropFirst("/private".count)))
            } else if path.hasPrefix("/var/") {
                paths.insert("/private" + path)
            }
        }
        return paths
    }

    /// True when `candidate` names the same on-disk location as `url`. Exact
    /// alias match first; falls back to case-insensitive comparison because
    /// the default APFS volume is case-insensitive but case-preserving, so a
    /// stored path may differ from a freshly derived one only by case.
    static func matches(_ candidate: String, for url: URL) -> Bool {
        let aliases = aliases(for: url)
        if aliases.contains(candidate) {
            return true
        }
        return aliases.contains {
            $0.compare(candidate, options: .caseInsensitive) == .orderedSame
        }
    }
}
