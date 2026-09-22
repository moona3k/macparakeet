import XCTest
@testable import MacParakeetCore

extension XCTestCase {
    /// Creates an independently leased recordings root whose child folder is
    /// still positively identified as app-managed by production cleanup.
    func makeTemporaryManagedMeetingFolder() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folderURL = rootURL.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(
                    meetingOriginHostTime: nil,
                    microphone: nil,
                    system: nil
                )
            ),
            folderURL: folderURL
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return folderURL
    }

    /// Session folder outside the app recordings root, with its own lease
    /// parent. A direct child of `temporaryDirectory` would lock all of
    /// `$TMPDIR` and flake against parallel tests.
    func makeTemporaryUnmanagedMeetingFolder() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unmanaged-\(UUID().uuidString)", isDirectory: true)
        let folderURL = rootURL.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return folderURL
    }
}
