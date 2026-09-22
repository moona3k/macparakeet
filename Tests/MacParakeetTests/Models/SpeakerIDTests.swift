import XCTest
@testable import MacParakeetCore

final class SpeakerIDTests: XCTestCase {
    func testMicrophoneSourceID() {
        XCTAssertEqual(SpeakerID.source(for: "microphone"), .microphone)
        XCTAssertTrue(SpeakerID.isSourceOnly("microphone"))
    }

    func testSystemSourceOnlyID() {
        XCTAssertEqual(SpeakerID.source(for: "system"), .system)
        XCTAssertTrue(SpeakerID.isSourceOnly("system"))
    }

    func testSystemDiarizedID() {
        let speakerID = SpeakerID.systemSpeaker("S2")

        XCTAssertEqual(speakerID, "system:S2")
        XCTAssertEqual(SpeakerID.source(for: speakerID), .system)
        XCTAssertFalse(SpeakerID.isSourceOnly(speakerID))
    }

    func testPlainFileSpeakerIDHasNoMeetingSource() {
        XCTAssertNil(SpeakerID.source(for: "S1"))
        XCTAssertFalse(SpeakerID.isSourceOnly("S1"))
    }

    func testNilSpeakerIDHasNoSource() {
        XCTAssertNil(SpeakerID.source(for: nil))
        XCTAssertFalse(SpeakerID.isSourceOnly(nil))
    }
}
