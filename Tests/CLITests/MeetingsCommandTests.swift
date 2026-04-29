import XCTest
@testable import CLI

final class MeetingsCommandTests: XCTestCase {
    func testMeetingsCommandIsRegisteredAtTopLevel() {
        XCTAssertTrue(
            CLI.configuration.subcommands.contains { $0 == MeetingsCommand.self },
            "meetings must be available from macparakeet-cli"
        )
    }

    func testExecutableSubcommandsParse() throws {
        XCTAssertNoThrow(try MeetingsCommand.ListSubcommand.parse(["--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ShowSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.TranscriptSubcommand.parse(["abcd", "--format", "srt"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "Decision: ship"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.ClearSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ExportSubcommand.parse(["abcd", "--format", "md", "--stdout"]))
    }

    func testListRejectsNegativeLimit() {
        XCTAssertThrowsError(try MeetingsCommand.ListSubcommand.parse(["--limit", "-1"]))
    }

    func testNotesSetRequiresOneInputSource() {
        XCTAssertThrowsError(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd"]))
        XCTAssertThrowsError(
            try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "note", "--stdin"])
        )
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "note"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--stdin"]))
    }

    func testNotesAppendRequiresOneInputSource() {
        XCTAssertThrowsError(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd"]))
        XCTAssertThrowsError(
            try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "note", "--stdin"])
        )
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "note"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--stdin"]))
    }

    func testFormatRawValues() {
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "text"), .text)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "json"), .json)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "srt"), .srt)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "vtt"), .vtt)
        XCTAssertEqual(MeetingExportFormat(rawValue: "md"), .md)
        XCTAssertEqual(MeetingExportFormat(rawValue: "json"), .json)
    }
}
