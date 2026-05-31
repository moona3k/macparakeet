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
        public let stoppedEarly: Bool
        public var truncated: Bool { droppedCount > 0 }

        public init(files: [URL], droppedCount: Int, stoppedEarly: Bool = false) {
            self.files = files
            self.droppedCount = droppedCount
            self.stoppedEarly = stoppedEarly
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
        var stoppedEarly = false
        var shouldStopFolderTraversal = false

        func consider(_ url: URL, isKnownRegularFile: Bool, stopOnOverflow: Bool) {
            let standardized = url.standardizedFileURL
            guard isSupportedExtension(standardized) else { return }
            if !isKnownRegularFile {
                let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { return }
            }
            guard seen.insert(standardized.path).inserted else { return }
            collected.append(standardized)
            if stopOnOverflow, collected.count > maxFiles {
                stoppedEarly = true
                shouldStopFolderTraversal = true
            }
        }

        for url in urls {
            guard !shouldStopFolderTraversal else { break }
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
                        consider(child, isKnownRegularFile: true, stopOnOverflow: true)
                    }
                    if shouldStopFolderTraversal {
                        break
                    }
                }
            } else {
                consider(url, isKnownRegularFile: true, stopOnOverflow: false)
            }
        }

        // Natural name order so dropping lecture01…lecture40 processes in order.
        // Sort BEFORE applying the cap so the kept subset is the name-first
        // `maxFiles` from the collected window. Recursive folder scans stop as
        // soon as overflow is detected so a huge drop cannot monopolize the UI.
        collected.sort { lhs, rhs in
            let byName = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        let dropped = max(0, collected.count - maxFiles)
        let files = dropped > 0 ? Array(collected.prefix(maxFiles)) : collected
        return Result(files: files, droppedCount: dropped, stoppedEarly: stoppedEarly)
    }

    private static func isSupportedExtension(_ url: URL) -> Bool {
        AudioFileConverter.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
