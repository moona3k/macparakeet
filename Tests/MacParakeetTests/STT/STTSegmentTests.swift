import XCTest
@testable import MacParakeetCore

final class STTSegmentTests: XCTestCase {

    func testSegmentWithoutSpeakerHasNilSpeakerId() {
        let seg = STTSegment(startMs: 0, endMs: 1500, text: "Hello.")
        XCTAssertNil(seg.speakerId)
    }

    func testSegmentWithSpeakerCarriesSpeakerId() {
        let seg = STTSegment(startMs: 0, endMs: 1500, text: "Hello.", speakerId: 2)
        XCTAssertEqual(seg.speakerId, 2)
    }

    func testEqualityIncludesSpeakerId() {
        let a = STTSegment(startMs: 0, endMs: 1500, text: "Hi.", speakerId: 0)
        let b = STTSegment(startMs: 0, endMs: 1500, text: "Hi.", speakerId: 1)
        XCTAssertNotEqual(a, b)
    }

    func testCodableRoundTripPreservesSpeakerId() throws {
        let original = STTSegment(startMs: 100, endMs: 2500, text: "Test", speakerId: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(STTSegment.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableDecodesLegacyJSONWithoutSpeakerId() throws {
        // Old persisted segments without speakerId must still decode (key missing → nil).
        let legacyJSON = #"{"startMs":0,"endMs":1500,"text":"Legacy"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(STTSegment.self, from: legacyJSON)
        XCTAssertEqual(decoded.text, "Legacy")
        XCTAssertNil(decoded.speakerId)
    }
}
