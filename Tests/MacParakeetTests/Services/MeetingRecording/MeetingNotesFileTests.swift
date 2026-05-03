import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingNotesFileTests: XCTestCase {
    private var folderURL: URL!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotesFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        folderURL = nil
    }

    func testWritesNotesWithDisplayNameHeader() async throws {
        try await MeetingNotesFile.write(
            notes: "decision: ship Friday\nQA owns smoke tests",
            displayName: "Q2 Planning",
            to: folderURL
        )

        let url = MeetingNotesFile.fileURL(for: folderURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "# Q2 Planning\n\ndecision: ship Friday\nQA owns smoke tests\n")
    }

    func testEmptyNotesProducesNoFile() async throws {
        try await MeetingNotesFile.write(notes: "", displayName: "Empty", to: folderURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MeetingNotesFile.fileURL(for: folderURL).path)
        )
    }

    func testNilNotesProducesNoFile() async throws {
        try await MeetingNotesFile.write(notes: nil, displayName: "Nil", to: folderURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MeetingNotesFile.fileURL(for: folderURL).path)
        )
    }

    func testWhitespaceOnlyNotesProducesNoFile() async throws {
        try await MeetingNotesFile.write(notes: "   \n\t  ", displayName: "WS", to: folderURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MeetingNotesFile.fileURL(for: folderURL).path)
        )
    }

    func testEmptyDisplayNameOmitsHeader() async throws {
        try await MeetingNotesFile.write(
            notes: "raw note",
            displayName: "",
            to: folderURL
        )
        let content = try String(
            contentsOf: MeetingNotesFile.fileURL(for: folderURL),
            encoding: .utf8
        )
        XCTAssertEqual(content, "raw note\n")
    }

    func testWhitespaceDisplayNameOmitsHeader() async throws {
        try await MeetingNotesFile.write(
            notes: "raw note",
            displayName: "   ",
            to: folderURL
        )
        let content = try String(
            contentsOf: MeetingNotesFile.fileURL(for: folderURL),
            encoding: .utf8
        )
        XCTAssertEqual(content, "raw note\n")
    }

    func testRewriteReplacesPreviousContent() async throws {
        try await MeetingNotesFile.write(notes: "first", displayName: "M", to: folderURL)
        try await MeetingNotesFile.write(notes: "second", displayName: "M", to: folderURL)
        let content = try String(
            contentsOf: MeetingNotesFile.fileURL(for: folderURL),
            encoding: .utf8
        )
        XCTAssertEqual(content, "# M\n\nsecond\n")
    }

    func testEmptyNotesRemovesStaleFile() async throws {
        // Pre-existing file from a prior run with notes...
        try await MeetingNotesFile.write(notes: "old notes", displayName: "M", to: folderURL)
        let url = MeetingNotesFile.fileURL(for: folderURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // ...is removed when notes get cleared.
        try await MeetingNotesFile.write(notes: nil, displayName: "M", to: folderURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNotesAreTrimmedBeforeWriting() async throws {
        try await MeetingNotesFile.write(
            notes: "\n\n  body  \n\n",
            displayName: "M",
            to: folderURL
        )
        let content = try String(
            contentsOf: MeetingNotesFile.fileURL(for: folderURL),
            encoding: .utf8
        )
        XCTAssertEqual(content, "# M\n\nbody\n")
    }

    func testInternalLineBreaksArePreserved() async throws {
        try await MeetingNotesFile.write(
            notes: "line one\n\nline two\n- bullet\n- bullet two",
            displayName: "M",
            to: folderURL
        )
        let content = try String(
            contentsOf: MeetingNotesFile.fileURL(for: folderURL),
            encoding: .utf8
        )
        XCTAssertEqual(
            content,
            "# M\n\nline one\n\nline two\n- bullet\n- bullet two\n"
        )
    }

    func testFileNameIsNotesMd() {
        XCTAssertEqual(MeetingNotesFile.fileName, "notes.md")
        XCTAssertEqual(
            MeetingNotesFile.fileURL(for: folderURL).lastPathComponent,
            "notes.md"
        )
    }
}
