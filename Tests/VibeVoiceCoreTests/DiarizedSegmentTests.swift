import XCTest
@testable import VibeVoiceCore

/// Pins the JSON shape that `vv_capi_asr` returns. Real output from the
/// spike on a 60s TED clip was:
///   [{"Start":0,"End":12.7,"Speaker":0,"Content":"So in college..."}, ...]
final class DiarizedSegmentTests: XCTestCase {

    func testDecodesSingleSegment() throws {
        let json = #"""
        [{"Start":0,"End":12.7,"Speaker":0,"Content":"So in college, I was a government major."}]
        """#.data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startSec, 0)
        XCTAssertEqual(segments[0].endSec, 12.7)
        XCTAssertEqual(segments[0].speakerId, 0)
        XCTAssertEqual(segments[0].text, "So in college, I was a government major.")
    }

    func testDecodesMultipleSegmentsWithDifferentSpeakers() throws {
        let json = #"""
        [
          {"Start":0,"End":2.5,"Speaker":0,"Content":"Hello."},
          {"Start":2.5,"End":5.0,"Speaker":1,"Content":"Hi there."}
        ]
        """#.data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerId, 0)
        XCTAssertEqual(segments[0].startSec, 0)
        XCTAssertEqual(segments[0].endSec, 2.5)
        XCTAssertEqual(segments[0].text, "Hello.")
        XCTAssertEqual(segments[1].speakerId, 1)
        XCTAssertEqual(segments[1].startSec, 2.5)
        XCTAssertEqual(segments[1].endSec, 5.0)
        XCTAssertEqual(segments[1].text, "Hi there.")
    }

    func testDecodesEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertTrue(segments.isEmpty)
    }
}
