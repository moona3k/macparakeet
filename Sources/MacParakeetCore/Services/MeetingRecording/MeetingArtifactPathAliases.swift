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
}
