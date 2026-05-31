import Foundation

/// Expands a mixed list of dropped/selected URLs (files and folders) into a
/// flat, de-duplicated, name-sorted list of supported audio/video files for
/// batch transcription.
///
/// Folders are enumerated recursively; hidden files and package contents are
/// skipped, and only regular files with a supported extension are kept. The
/// result is bounded by `maxFiles` so a stray drop of a huge tree can't enqueue
/// thousands of jobs — any overflow is reported through `droppedCount` /
/// `truncated` rather than silently discarded.
public enum AudioFileEnumerator {
    public struct Result: Equatable, Sendable {
        public let files: [URL]
        public let droppedCount: Int
        public var truncated: Bool { droppedCount > 0 }

        public init(files: [URL], droppedCount: Int) {
            self.files = files
            self.droppedCount = droppedCount
        }
    }

    public static let defaultMaxFiles = 200

    public static func expand(
        urls: [URL],
        maxFiles: Int = defaultMaxFiles,
        fileManager: FileManager = .default
    ) -> Result {
        var collected: [URL] = []
        var seen: Set<String> = []
        var dropped = 0

        func consider(_ url: URL, isKnownRegularFile: Bool) {
            let standardized = url.standardizedFileURL
            guard isSupportedExtension(standardized) else { return }
            if !isKnownRegularFile {
                let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { return }
            }
            guard seen.insert(standardized.path).inserted else { return }
            if collected.count < maxFiles {
                collected.append(standardized)
            } else {
                dropped += 1
            }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
                    if values?.isRegularFile == true {
                        consider(child, isKnownRegularFile: true)
                    }
                }
            } else {
                consider(url, isKnownRegularFile: true)
            }
        }

        // Natural name order so dropping lecture01…lecture40 processes in order.
        collected.sort { lhs, rhs in
            let byName = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        return Result(files: collected, droppedCount: dropped)
    }

    private static func isSupportedExtension(_ url: URL) -> Bool {
        AudioFileConverter.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
