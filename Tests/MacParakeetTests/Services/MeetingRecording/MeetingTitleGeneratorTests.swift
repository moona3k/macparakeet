import XCTest
@testable import MacParakeetCore

final class MeetingTitleGeneratorTests: XCTestCase {
    func testShouldReplaceTimestampFallbackMeetingTitles() {
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Jun 17, 2026 at 09:59"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting June 17, 2026 at 9:59 AM"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting 6/17/2026"))
    }

    func testShouldPreserveCustomOrCalendarMeetingTitles() {
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Customer Expansion Review"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Weekly Product Sync"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Notes for Acme"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Product Review"))
    }

    func testValidatedTitleNormalizesSimpleProviderResponses() {
        XCTAssertEqual(
            MeetingTitleGenerator.validatedTitle(from: #"  "Product Roadmap Review."  "#),
            "Product Roadmap Review"
        )
        XCTAssertEqual(
            MeetingTitleGenerator.validatedTitle(from: "- Customer Onboarding Risks"),
            "Customer Onboarding Risks"
        )
        XCTAssertEqual(
            MeetingTitleGenerator.validatedTitle(from: "1. Mobile Beta Launch"),
            "Mobile Beta Launch"
        )
    }

    func testValidatedTitleRejectsLowConfidenceResponses() {
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "Meeting"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "Discussion"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "NO_TITLE"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "Meeting Jun 17, 2026"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "Product Review\nCustomer Followup"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "One"))
        XCTAssertNil(MeetingTitleGenerator.validatedTitle(from: "This title has far too many words to be a usable meeting title"))
    }
}
