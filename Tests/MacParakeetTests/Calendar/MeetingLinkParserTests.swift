import XCTest
@testable import MacParakeetCore

final class MeetingLinkParserTests: XCTestCase {
    let parser = MeetingLinkParser()

    // MARK: - Single-field extraction

    func testExtractsZoomFromText() {
        let text = "Join: https://zoom.us/j/1234567890"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://zoom.us/j/1234567890")
    }

    func testExtractsZoomWithSubdomain() {
        let text = "https://acme.zoom.us/j/9876?pwd=abc"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://acme.zoom.us/j/9876?pwd=abc")
    }

    func testExtractsGoogleMeet() {
        let text = "Meet me at https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://meet.google.com/abc-defg-hij")
    }

    func testExtractsTeams() {
        let text = "Teams: https://teams.microsoft.com/l/meetup-join/19%3aabc"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://teams.microsoft.com/l/meetup-join/19%3aabc")
    }

    func testExtractsWebex() {
        let text = "https://acme.webex.com/meet/jane"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://acme.webex.com/meet/jane")
    }

    func testExtractsAround() {
        let text = "https://around.co/r/standup"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://around.co/r/standup")
    }

    func testGenericFallbackForUnknownProvider() {
        let text = "Use https://example.com/meet/room-1 to join"
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://example.com/meet/room-1")
    }

    // MARK: - Zoom variants (#4 — false negatives)

    func testExtractsZoomPersonalRoom() {
        XCTAssertEqual(
            parser.extractMeetingUrl(from: "Join https://zoom.us/my/jane.doe"),
            "https://zoom.us/my/jane.doe"
        )
    }

    func testExtractsZoomWebinar() {
        XCTAssertEqual(
            parser.extractMeetingUrl(from: "https://company.zoom.us/w/1234567890"),
            "https://company.zoom.us/w/1234567890"
        )
    }

    func testExtractsZoomGov() {
        XCTAssertEqual(
            parser.extractMeetingUrl(from: "https://zoomgov.com/j/1234567890"),
            "https://zoomgov.com/j/1234567890"
        )
    }

    func testExtractsWhereby() {
        XCTAssertEqual(
            parser.extractMeetingUrl(from: "https://whereby.com/standup-room"),
            "https://whereby.com/standup-room"
        )
    }

    // MARK: - Generic precision (#4 — false positives)

    func testGenericDoesNotMatchCallSubstringInRecall() {
        XCTAssertFalse(parser.isMeetingUrl("https://example.com/recall"))
        XCTAssertFalse(parser.isMeetingUrl("https://example.com/teamcall"))
        XCTAssertFalse(parser.isMeetingUrl("https://site.com/page?utm_campaign=fallcall"))
    }

    func testGenericDoesNotMatchVideoSubstringInVideogame() {
        XCTAssertFalse(parser.isMeetingUrl("https://videogame.com/play"))
    }

    func testGenericStillMatchesDelimitedTokens() {
        XCTAssertTrue(parser.isMeetingUrl("https://example.com/video-call"))
        XCTAssertTrue(parser.isMeetingUrl("https://acme.com/conference/room"))
    }

    func testGenericIgnoresKeywordInQueryString() {
        // A keyword only in the query string (Jira/CRM links) is not a meeting.
        XCTAssertFalse(parser.isMeetingUrl("https://jira.corp.com?type=conference&id=PROJ-123"))
        XCTAssertFalse(parser.isMeetingUrl("https://helpdesk.com?mode=call&ticket=456"))
        XCTAssertFalse(parser.isMeetingUrl("https://example.com?video=1"))
    }

    func testGenericMatchesPathTokenEvenWithQuery() {
        // Token in the path is still a match, query after it is fine.
        XCTAssertTrue(parser.isMeetingUrl("https://example.com/conference?id=1"))
    }

    func testReturnsNilForPlainText() {
        XCTAssertNil(parser.extractMeetingUrl(from: "Just a calendar block, no link"))
    }

    func testReturnsNilForEmpty() {
        XCTAssertNil(parser.extractMeetingUrl(from: ""))
        XCTAssertNil(parser.extractMeetingUrl(from: nil))
    }

    // MARK: - Priority order (Zoom wins over generic)

    func testZoomBeatsGenericInSameText() {
        let text = "Old: https://example.com/conference/oldroom Join: https://zoom.us/j/12345"
        // Zoom should be preferred even though generic also matches
        XCTAssertEqual(parser.extractMeetingUrl(from: text), "https://zoom.us/j/12345")
    }

    // MARK: - Multi-field overload

    func testUrlFieldWinsWhenItIsAMeetingUrl() {
        let result = parser.extractMeetingUrl(
            location: "Zoom: https://zoom.us/j/2",
            notes: "Notes here",
            url: "https://zoom.us/j/1"
        )
        XCTAssertEqual(result, "https://zoom.us/j/1")
    }

    func testFallsBackToLocationWhenUrlFieldMissing() {
        let result = parser.extractMeetingUrl(
            location: "Zoom: https://zoom.us/j/2",
            notes: nil,
            url: nil
        )
        XCTAssertEqual(result, "https://zoom.us/j/2")
    }

    func testFallsBackToNotesWhenLocationMissing() {
        let result = parser.extractMeetingUrl(
            location: nil,
            notes: "Join: https://meet.google.com/xyz-abc-def",
            url: nil
        )
        XCTAssertEqual(result, "https://meet.google.com/xyz-abc-def")
    }

    func testIgnoresNonMeetingUrlField() {
        let result = parser.extractMeetingUrl(
            location: "Zoom: https://zoom.us/j/2",
            notes: nil,
            url: "https://google.com"  // not a meeting URL
        )
        XCTAssertEqual(result, "https://zoom.us/j/2")
    }

    func testReturnsNilWhenNoFieldsHaveLink() {
        XCTAssertNil(parser.extractMeetingUrl(location: "Office", notes: "Bring laptop", url: nil))
    }

    // MARK: - isMeetingUrl

    func testIsMeetingUrlPositive() {
        XCTAssertTrue(parser.isMeetingUrl("https://zoom.us/j/1"))
        XCTAssertTrue(parser.isMeetingUrl("https://meet.google.com/abc"))
    }

    func testIsMeetingUrlNegative() {
        XCTAssertFalse(parser.isMeetingUrl("https://google.com"))
        XCTAssertFalse(parser.isMeetingUrl(nil))
        XCTAssertFalse(parser.isMeetingUrl(""))
    }

    // MARK: - identifyService

    func testIdentifyService() {
        XCTAssertEqual(parser.identifyService(from: "https://zoom.us/j/1"), "Zoom")
        XCTAssertEqual(parser.identifyService(from: "https://meet.google.com/abc"), "Google Meet")
        XCTAssertEqual(parser.identifyService(from: "https://teams.microsoft.com/x"), "Microsoft Teams")
        XCTAssertEqual(parser.identifyService(from: "https://acme.webex.com/x"), "Webex")
        XCTAssertEqual(parser.identifyService(from: "https://around.co/r/x"), "Around")
        XCTAssertEqual(parser.identifyService(from: "https://zoomgov.com/j/1"), "Zoom")
        XCTAssertEqual(parser.identifyService(from: "https://whereby.com/room"), "Whereby")
        XCTAssertNil(parser.identifyService(from: "https://example.com"))
        XCTAssertNil(parser.identifyService(from: nil))
    }
}
