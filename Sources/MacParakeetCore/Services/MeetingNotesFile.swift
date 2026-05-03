import Foundation

/// Writes the user's typed meeting notes to a `notes.md` file in the meeting
/// session folder so they can be inspected outside the app (Finder, any text
/// editor) — the canonical store remains `transcriptions.userNotes` in
/// SQLite. The file is a snapshot taken at meeting finalize / crash-recovery
/// time and is NOT kept in sync with later DB edits (e.g. via the
/// `macparakeet-cli meetings notes` subcommands). If you need the latest
/// notes, read the DB.
///
/// Empty / whitespace-only / nil notes do not produce a file. If a stale
/// file exists from a prior write, it is removed so the file's presence is
/// always a faithful "the user typed something" signal.
enum MeetingNotesFile {
    static let fileName = "notes.md"

    static func fileURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(fileName)
    }

    static func write(
        notes: String?,
        displayName: String,
        to folderURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = fileURL(for: folderURL)

        guard !trimmedNotes.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = trimmedName.isEmpty ? "" : "# \(trimmedName)\n\n"
        let content = header + trimmedNotes + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
