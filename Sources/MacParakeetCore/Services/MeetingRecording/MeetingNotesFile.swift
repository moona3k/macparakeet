import Foundation

/// Writes the user's typed meeting notes to `notes.md` in the meeting session
/// folder so they can be inspected outside the app. SQLite
/// `transcriptions.userNotes` remains canonical; `MeetingArtifactStore`
/// rewrites this file when materializing the current artifact contract.
///
/// Empty / whitespace-only / nil notes do not produce a file. If a stale
/// file exists from a prior write, it is removed so the file's presence is
/// always a faithful "the user typed something" signal.
enum MeetingNotesFile {
    static let fileName = "notes.md"

    struct SendableFileManager: @unchecked Sendable {
        fileprivate let value: FileManager

        init(_ value: FileManager = .default) {
            self.value = value
        }
    }

    static func fileURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(fileName)
    }

    static func write(
        notes: String?,
        displayName: String,
        to folderURL: URL,
        fileManager: SendableFileManager = SendableFileManager()
    ) async throws {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = fileURL(for: folderURL)

        try await Task.detached(priority: .utility) {
            guard !trimmedNotes.isEmpty else {
                if fileManager.value.fileExists(atPath: url.path) {
                    try fileManager.value.removeItem(at: url)
                }
                return
            }

            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = trimmedName.isEmpty ? "" : "# \(trimmedName)\n\n"
            let content = header + trimmedNotes + "\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }
}
