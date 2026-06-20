import AppKit
import Foundation
import MacParakeetCore

@MainActor
enum MeetingArtifactActions {
    static func folderURL(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let url = MeetingArtifactStore.sessionFolderURL(for: transcription) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    @discardableResult
    static func openFolder(for transcription: Transcription) -> Bool {
        guard let url = folderURL(for: transcription) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    @discardableResult
    static func copyFolderPath(for transcription: Transcription) -> Bool {
        guard let url = folderURL(for: transcription) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        return true
    }
}
