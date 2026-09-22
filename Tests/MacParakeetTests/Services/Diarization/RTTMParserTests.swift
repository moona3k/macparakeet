import XCTest
@testable import MacParakeetCore

final class RTTMParserTests: XCTestCase {

    func testParsesSpeakerLinesIntoMillisecondSegments() throws {
        let contents = """
        # comment
        SPEAKER fixture 1 1.230 0.450 <NA> <NA> speaker_a <NA> <NA>
        SPEAKER fixture 1 2.000 1.250 <NA> <NA> speaker_b <NA> <NA> # trailing comment
        """

        let segments = try RTTMParser.parse(contents)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], LabeledSegment(recordingId: "fixture", speakerId: "speaker_a", startMs: 1230, endMs: 1680))
        XCTAssertEqual(segments[1], LabeledSegment(recordingId: "fixture", speakerId: "speaker_b", startMs: 2000, endMs: 3250))
    }

    func testIgnoresBlankCommentsAndNonSpeakerLines() throws {
        let contents = """

        # comment
        FILE fixture 1 0 0 <NA> <NA> metadata <NA> <NA>
        SPEAKER fixture 1 0.000 1.000 <NA> <NA> speaker_a <NA> <NA>
        """

        let segments = try RTTMParser.parse(contents)

        XCTAssertEqual(segments, [
            LabeledSegment(recordingId: "fixture", speakerId: "speaker_a", startMs: 0, endMs: 1000)
        ])
    }

    func testThrowsForMalformedSpeakerLine() {
        XCTAssertThrowsError(try RTTMParser.parse("SPEAKER fixture 1 0.000")) { error in
            XCTAssertEqual(error as? RTTMParser.ParseError, .invalidSpeakerLine(lineNumber: 1))
        }
    }

    func testThrowsForInvalidTiming() {
        let contents = "SPEAKER fixture 1 nope 1.000 <NA> <NA> speaker_a <NA> <NA>"

        XCTAssertThrowsError(try RTTMParser.parse(contents)) { error in
            XCTAssertEqual(error as? RTTMParser.ParseError, .invalidTime(lineNumber: 1))
        }
    }
}
