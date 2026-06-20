import XCTest
@testable import MacParakeetCore

final class MeetingAudioFileTests: XCTestCase {

    // MARK: - mixedAudioURL

    func testMixedAudioURLReturnsNilForFileSource() {
        let transcription = makeTranscription(
            fileName: "lecture.mp3",
            filePath: "/tmp/lecture.mp3",
            sourceType: .file
        )
        XCTAssertNil(MeetingAudioFile.mixedAudioURL(for: transcription))
    }

    func testMixedAudioURLReturnsNilForYouTubeSource() {
        let transcription = makeTranscription(
            fileName: "interview.m4a",
            filePath: "/tmp/interview.m4a",
            sourceType: .youtube
        )
        XCTAssertNil(MeetingAudioFile.mixedAudioURL(for: transcription))
    }

    func testMixedAudioURLReturnsNilWhenFilePathIsMissing() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: nil,
            sourceType: .meeting
        )
        XCTAssertNil(MeetingAudioFile.mixedAudioURL(for: transcription))
    }

    func testMixedAudioURLReturnsNilWhenFilePathIsWhitespace() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: "   ",
            sourceType: .meeting
        )
        XCTAssertNil(MeetingAudioFile.mixedAudioURL(for: transcription))
    }

    func testMixedAudioURLReturnsResolvedURLForMeeting() throws {
        let path = "/tmp/MacParakeetTests/meeting.m4a"
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: path,
            sourceType: .meeting
        )
        let url = try XCTUnwrap(MeetingAudioFile.mixedAudioURL(for: transcription))
        XCTAssertEqual(url.path, path)
    }

    // MARK: - isAvailable

    func testIsAvailableReturnsFalseForMissingFile() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: "/tmp/macparakeet-tests-nonexistent-\(UUID().uuidString).m4a",
            sourceType: .meeting
        )
        XCTAssertFalse(MeetingAudioFile.isAvailable(for: transcription))
    }

    func testIsAvailableReturnsTrueWhenFileExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("meeting.m4a")
        try Data([0x00, 0x01]).write(to: file)

        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: file.path,
            sourceType: .meeting
        )
        XCTAssertTrue(MeetingAudioFile.isAvailable(for: transcription))
    }

    func testIsAvailableReturnsFalseWhenPathIsADirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: directory.path,
            sourceType: .meeting
        )
        XCTAssertFalse(MeetingAudioFile.isAvailable(for: transcription))
    }

    // MARK: - state

    func testStateReturnsNotMeetingWhenStatusIsProcessing() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audioURL)

        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: audioURL.path,
            sourceType: .meeting,
            status: .processing
        )

        XCTAssertEqual(MeetingAudioFile.state(for: transcription), .notMeeting)
        XCTAssertFalse(MeetingAudioFile.isAvailable(for: transcription))
    }

    func testStateReturnsNotMeetingForNonMeetingSource() {
        let transcription = makeTranscription(
            fileName: "lecture.mp3",
            filePath: "/tmp/lecture.mp3",
            sourceType: .file
        )

        XCTAssertEqual(MeetingAudioFile.state(for: transcription), .notMeeting)
    }

    func testStateReturnsRemovedForMeetingWithoutFilePath() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: nil,
            sourceType: .meeting
        )

        XCTAssertEqual(MeetingAudioFile.state(for: transcription), .removed)
    }

    func testStateReturnsMissingWhenMeetingPathDoesNotExist() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: "/tmp/macparakeet-tests-missing-\(UUID().uuidString).m4a",
            sourceType: .meeting
        )

        XCTAssertEqual(MeetingAudioFile.state(for: transcription), .missing)
    }

    func testStateReturnsSavedWhenMeetingAudioExists() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audioURL)

        let transcription = makeTranscription(
            fileName: "Meeting",
            filePath: audioURL.path,
            sourceType: .meeting
        )

        XCTAssertEqual(MeetingAudioFile.state(for: transcription), .saved)
    }

    // MARK: - suggestedExportStem

    func testSuggestedExportStemPrefersDerivedTitleWithDate() {
        let transcription = makeTranscription(
            fileName: "Meeting May 11, 2026 at 1:32 PM",
            sourceType: .meeting,
            derivedTitle: "Q4 planning sync",
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertEqual(stem, "Q4 planning sync - 2026-05-11")
    }

    func testSuggestedExportStemFallsBackToFileName() {
        let transcription = makeTranscription(
            fileName: "Meeting May 11, 2026 at 1:32 PM",
            sourceType: .meeting,
            derivedTitle: nil,
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertEqual(stem, "Meeting May 11, 2026 at 1 32 PM")
        // Colon in `1:32` is sanitized to a space — Finder allows colons in
        // display, but they map to `/` on the filesystem layer and we'd
        // rather show a clean save-as preview.
    }

    func testSuggestedExportStemIgnoresWhitespaceOnlyDerivedTitle() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            sourceType: .meeting,
            derivedTitle: "   ",
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertEqual(stem, "Meeting")
    }

    func testSuggestedExportStemFallsBackToConstantWhenFileNameIsEmpty() {
        let transcription = makeTranscription(
            fileName: "   ",
            sourceType: .meeting,
            derivedTitle: nil,
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertEqual(stem, "Meeting")
    }

    func testSuggestedExportStemSanitizesPathSeparators() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            sourceType: .meeting,
            derivedTitle: "Eng/Design sync: roadmap",
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        // "/" and ":" both replaced with spaces, then collapsed.
        XCTAssertEqual(stem, "Eng Design sync roadmap - 2026-05-11")
    }

    func testSuggestedExportStemStripsControlCharacters() {
        let transcription = makeTranscription(
            fileName: "Meeting",
            sourceType: .meeting,
            derivedTitle: "Hello\u{0007}World\nLine\tTab",
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertEqual(stem, "Hello World Line Tab - 2026-05-11")
    }

    func testSuggestedExportStemCapsLongDerivedTitle() {
        let veryLongTitle = String(repeating: "A", count: 500)
        let transcription = makeTranscription(
            fileName: "Meeting",
            sourceType: .meeting,
            derivedTitle: veryLongTitle,
            createdAt: makeDate(year: 2026, month: 5, day: 11)
        )
        let stem = MeetingAudioFile.suggestedExportStem(for: transcription)
        XCTAssertLessThanOrEqual(stem.count, MeetingAudioFile.maxStemLength)
        XCTAssertTrue(stem.hasPrefix("AAAAA"), "stem should retain a recognizable prefix")
    }

    // MARK: - safeCopy

    func testSafeCopyIsNoOpWhenSourceEqualsDestination() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meeting.m4a")
        try Data("hello".utf8).write(to: url)

        try MeetingAudioFile.safeCopy(from: url, to: url)

        // Source file must still exist with original contents.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url), "hello")
    }

    func testSafeCopyCreatesNewDestination() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("dest.m4a")
        try Data("audio bytes".utf8).write(to: source)

        try MeetingAudioFile.safeCopy(from: source, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination), "audio bytes")
    }

    func testSafeCopyAtomicallyReplacesExistingDestination() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("dest.m4a")
        try Data("fresh".utf8).write(to: source)
        try Data("stale".utf8).write(to: destination)

        try MeetingAudioFile.safeCopy(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination), "fresh")
        XCTAssertEqual(try String(contentsOf: source), "fresh", "source must be untouched")
    }

    func testSafeCopyLeavesNoTempSiblingsOnSuccess() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("dest.m4a")
        try Data("data".utf8).write(to: source)

        try MeetingAudioFile.safeCopy(from: source, to: destination)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(contents), ["source.m4a", "dest.m4a"])
    }

    func testSafeCopyThrowsWhenSourceMissing() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("does-not-exist.m4a")
        let destination = directory.appendingPathComponent("dest.m4a")

        XCTAssertThrowsError(try MeetingAudioFile.safeCopy(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-audio-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTranscription(
        fileName: String,
        filePath: String? = nil,
        sourceType: Transcription.SourceType,
        status: Transcription.TranscriptionStatus = .completed,
        derivedTitle: String? = nil,
        createdAt: Date = Date()
    ) -> Transcription {
        Transcription(
            createdAt: createdAt,
            fileName: fileName,
            filePath: filePath,
            status: status,
            sourceType: sourceType,
            derivedTitle: derivedTitle
        )
    }

    /// Construct a date pegged to noon in the test machine's local
    /// timezone. `MeetingAudioFile.isoDateFormatter` intentionally uses
    /// the system timezone so the date a user sees in a save filename
    /// matches the day they remember the meeting happening (a meeting
    /// recorded at 11:30 PM Friday locally should not show up as
    /// "Saturday" because some renderer-side timezone diverged from the
    /// recording-side timezone). The test follows the same rule so the
    /// suite is robust across CI machines in any timezone — without
    /// this, `TZ='Asia/Tokyo' swift test` flakes because noon LA
    /// crosses the dateline into "tomorrow" Tokyo-local.
    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)!
    }
}
