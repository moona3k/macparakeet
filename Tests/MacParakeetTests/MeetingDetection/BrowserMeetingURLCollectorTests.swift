import Foundation
import XCTest
@testable import MacParakeet

final class BrowserMeetingURLCollectorTests: XCTestCase {
    func testMissingAccessibilityPermissionDoesNotReadBrowserMetadata() async {
        let collector = BrowserMeetingURLCollector(
            isTrusted: { false },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 1)] },
            readSnapshot: { _ in
                XCTFail("Must not read AX without access"); return BrowserMeetingObservation()
            }
        )
        let result = await collector.snapshotDetailed()
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertEqual(result.runningBrowserBundleIDs, ["com.google.Chrome"])
    }

    func testSnapshotLimitsObservationToRequestedRegisteredBrowsersAndMeetingDocuments() async throws {
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let normal = try XCTUnwrap(URL(string: "https://example.com/"))
        let spoof = try XCTUnwrap(URL(string: "https://meet.google.com.evil.test/abc-defg-hij"))
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: {
                [
                    .init(bundleID: "com.google.Chrome", pid: 1),
                    .init(bundleID: "com.apple.Safari", pid: 2),
                    .init(bundleID: "unrelated.app", pid: 3),
                ]
            },
            readSnapshot: { processes in
                XCTAssertEqual(processes, [.init(bundleID: "com.google.Chrome", pid: 1)])
                return BrowserMeetingObservation(urls: [
                    "com.google.Chrome": [normal, room, spoof, room],
                    "com.apple.Safari": [room],
                    "unrelated.app": [room],
                ])
            }
        )
        let result = await collector.snapshot(bundleIDs: ["com.google.Chrome", "unrelated.app"])
        XCTAssertEqual(result, ["com.google.Chrome": [room]])
    }

    func testEmptyOrUnavailableObservationDoesNotPretendToKnowPreviousRoom() async {
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.apple.Safari", pid: 1)] },
            readSnapshot: { _ in BrowserMeetingObservation() }
        )
        let result = await collector.snapshot()
        XCTAssertTrue(result.isEmpty)
    }

    func testDocumentMetadataAcceptsURLAndStringButNotTitlesOrLocalFiles() throws {
        let url = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(BrowserMeetingURLCollector.documentURL(url), url)
        XCTAssertEqual(BrowserMeetingURLCollector.documentURL(url.absoluteString), url)
        XCTAssertNil(BrowserMeetingURLCollector.documentURL("Weekly meeting - Google Meet"))
        XCTAssertNil(BrowserMeetingURLCollector.documentURL(URL(fileURLWithPath: "/tmp/meeting.html")))
        XCTAssertNil(BrowserMeetingURLCollector.documentURL("javascript:alert(1)"))
        XCTAssertNil(BrowserMeetingURLCollector.documentURL(42))
    }

    func testPrejoinAndOrdinaryPageTextCannotConfirmMeeting() {
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXButton", labels: ["Join now"]))
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXButton", labels: ["Ask to join"]))
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXStaticText", labels: ["Leave call"]))
        XCTAssertFalse(
            BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXButton", labels: ["Learn how to leave call"]))
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXButton", labels: ["Leave callback"]))
    }

    func testInCallButtonLabelsSupportEnglishAndPolishFixtures() {
        for label in ["Leave call", "Leave call (⌘ + W)", "Opuść rozmowę", "Opuść połączenie"] {
            XCTAssertTrue(BrowserMeetingURLCollector.isMeetLeaveControl(role: "AXButton", labels: [label]), label)
        }
    }

    func testIndependentInCallEvidenceIsLimitedToObservedGoogleMeetDocuments() async throws {
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let unseen = try XCTUnwrap(URL(string: "https://meet.google.com/xyz-abcd-efg"))
        let zoom = try XCTUnwrap(URL(string: "https://us02web.zoom.us/j/12345678901"))
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 1)] },
            readSnapshot: { _ in
                BrowserMeetingObservation(
                    urls: ["com.google.Chrome": [room, zoom]],
                    inCallURLs: ["com.google.Chrome": [room, unseen, zoom], "unrelated.app": [room]]
                )
            }
        )
        let result = await collector.snapshotDetailed()
        XCTAssertEqual(result.urls, ["com.google.Chrome": [room, zoom]])
        XCTAssertEqual(result.inCallURLs, ["com.google.Chrome": [room]])
    }

    func testPreJoinButtonLabelsSupportEnglishAndPolishFixtures() {
        for label in ["Join now", "Ask to join", "Rejoin", "Dołącz teraz", "Poproś o dołączenie"] {
            XCTAssertTrue(BrowserMeetingURLCollector.isMeetPreJoinControl(role: "AXButton", labels: [label]), label)
        }
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetPreJoinControl(role: "AXStaticText", labels: ["Join now"]))
        XCTAssertFalse(BrowserMeetingURLCollector.isMeetPreJoinControl(role: "AXButton", labels: ["Join now tutorial"]))
    }

    func testLeaveControlOverridesPrejoinEvidenceForSameObservedRoom() async throws {
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 1)] },
            readSnapshot: { _ in
                BrowserMeetingObservation(
                    urls: ["com.google.Chrome": [room]],
                    inCallURLs: [
                        "com.google.Chrome": [room.appending(queryItems: [.init(name: "authuser", value: "1")])]
                    ],
                    preJoinURLs: [
                        "com.google.Chrome": [room.appending(queryItems: [.init(name: "authuser", value: "0")])]
                    ]
                )
            }
        )
        let result = await collector.snapshotDetailed()
        XCTAssertEqual(result.inCallURLs, ["com.google.Chrome": [room]])
        XCTAssertTrue(result.preJoinURLs.isEmpty)
    }

    func testLinkAndControlNodesNeverRequestDocumentOrDestinationAttributes() {
        for role in ["AXLink", "AXButton", "AXStaticText", "AXTextField"] {
            var requested: [String] = []
            let metadata = BrowserMeetingURLCollector.documentMetadata { attribute in
                requested.append(attribute)
                return attribute == "AXRole" ? role : "https://meet.google.com/abc-defg-hij"
            }
            XCTAssertEqual(requested, ["AXRole"], role)
            XCTAssertNil(metadata.url)
        }
        var requested: [String] = []
        let metadata = BrowserMeetingURLCollector.documentMetadata { attribute in
            requested.append(attribute)
            if attribute == "AXRole" { return "AXWebArea" }
            if attribute == "AXURL" { return "https://meet.google.com/abc-defg-hij" }
            return nil
        }
        XCTAssertEqual(requested, ["AXRole", "AXDocument", "AXURL"])
        XCTAssertEqual(metadata.url?.host, "meet.google.com")
    }

    func testPreJoinEvidenceIsScopedToProviderRoomAndSpecificControl() throws {
        let meet = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let zoom = try XCTUnwrap(URL(string: "https://us02web.zoom.us/j/12345678901"))
        let teams = try XCTUnwrap(URL(string: "https://teams.microsoft.com/meet/12345678"))
        let other = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertTrue(
            BrowserMeetingURLCollector.isPreJoinControl(documentURL: meet, role: "AXButton", labels: ["Rejoin"]))
        XCTAssertTrue(
            BrowserMeetingURLCollector.isPreJoinControl(documentURL: zoom, role: "AXButton", labels: ["Join meeting"]))
        XCTAssertTrue(
            BrowserMeetingURLCollector.isPreJoinControl(documentURL: teams, role: "AXButton", labels: ["Join now"]))
        XCTAssertFalse(
            BrowserMeetingURLCollector.isPreJoinControl(documentURL: other, role: "AXButton", labels: ["Join now"]))
        XCTAssertFalse(
            BrowserMeetingURLCollector.isPreJoinControl(documentURL: zoom, role: "AXButton", labels: ["Join"]))
        XCTAssertFalse(
            BrowserMeetingURLCollector.isPreJoinControl(
                documentURL: teams, role: "AXButton", labels: ["Join room tutorial"]))
    }

}
