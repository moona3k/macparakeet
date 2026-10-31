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

    func testEmptyObservationYieldsNoBrowserURLs() async {
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

    func testDuplicateZoomAndTeamsRoomURLsRetainPreJoinVetoWithoutPositiveCallEvidence() async throws {
        for address in [
            "https://us02web.zoom.us/j/12345678901",
            "https://teams.microsoft.com/meet/12345678",
        ] {
            let room = try XCTUnwrap(URL(string: address))
            let duplicate = room.appending(queryItems: [.init(name: "source", value: "another-tab")])
            let collector = BrowserMeetingURLCollector(
                isTrusted: { true },
                processes: { [.init(bundleID: "com.google.Chrome", pid: 1)] },
                readSnapshot: { _ in
                    BrowserMeetingObservation(
                        urls: ["com.google.Chrome": [room, duplicate]],
                        preJoinURLs: ["com.google.Chrome": [room]]
                    )
                }
            )
            let result = await collector.snapshotDetailed()
            XCTAssertEqual(result.urls, ["com.google.Chrome": [room, duplicate]])
            XCTAssertEqual(result.preJoinURLs, ["com.google.Chrome": [room, duplicate]])
            XCTAssertTrue(result.inCallURLs.isEmpty)
        }
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

    func testBlockedFirstBrowserDoesNotStarveLaterBrowserObservation() async throws {
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let releaseFirst = AsyncStream<Void>.makeStream()
        let laterStarted = expectation(description: "Later browser scans while the first reader is waiting")
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: {
                [.init(bundleID: "com.apple.Safari", pid: 1), .init(bundleID: "com.google.Chrome", pid: 2)]
            },
            readProcess: { process, _ in
                if process.pid == 1 {
                    for await _ in releaseFirst.stream { break }
                    return .init()
                }
                laterStarted.fulfill()
                return .init(
                    observation: .init(urls: [process.bundleID: [room]]), hasWindows: true,
                    hasPopulatedWebArea: true)
            }
        )
        let pending = Task { await collector.snapshotDetailed() }
        await fulfillment(of: [laterStarted], timeout: 2)
        releaseFirst.continuation.yield(())
        releaseFirst.continuation.finish()
        let result = await pending.value
        XCTAssertEqual(result.urls, ["com.google.Chrome": [room]])
        XCTAssertEqual(result.runningBrowserBundleIDs, ["com.apple.Safari", "com.google.Chrome"])
    }

    func testChromiumActivationIsNotRepeatedForHealthyPageAndRetriesAfterTreeDisappears() async {
        let probe = BrowserProcessReadProbe(readiness: [true, false, true])
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 2)] },
            readProcess: { process, activate in await probe.read(process: process, activate: activate) }
        )
        _ = await collector.snapshotDetailed()
        _ = await collector.snapshotDetailed()
        _ = await collector.snapshotDetailed()
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true, false, true])
    }

    func testWindowlessChromiumKeepsActivationAndReactivatesWhenANewWindowNeedsATree() async {
        let probe = BrowserProcessReadProbe(
            readiness: [false, false, false, true, true],
            windowPresence: [false, false, true, true, true]
        )
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 2)] },
            readProcess: { process, activate in await probe.read(process: process, activate: activate) }
        )
        for _ in 0..<5 { _ = await collector.snapshotDetailed() }
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true, false, false, true, false])
    }

    func testClosingAllWindowsDoesNotRepeatActivationAndReopeningCanRehydrate() async {
        let probe = BrowserProcessReadProbe(
            readiness: [true, false, false, false, true],
            windowPresence: [true, false, false, true, true]
        )
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [.init(bundleID: "com.google.Chrome", pid: 2)] },
            readProcess: { process, activate in await probe.read(process: process, activate: activate) }
        )
        for _ in 0..<5 { _ = await collector.snapshotDetailed() }
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true, false, false, false, true])
    }

    @MainActor
    func testRestartedChromiumProcessGetsAccessibilitySetupButSafariDoesNot() async {
        let probe = BrowserProcessReadProbe(readiness: [])
        var process = BrowserMeetingURLCollector.BrowserProcess(bundleID: "com.operasoftware.Opera", pid: 3)
        let collector = BrowserMeetingURLCollector(
            isTrusted: { true },
            processes: { [process] },
            readProcess: { process, activate in await probe.read(process: process, activate: activate) }
        )
        _ = await collector.snapshotDetailed()
        _ = await collector.snapshotDetailed()
        process = .init(bundleID: "com.operasoftware.Opera", pid: 4)
        _ = await collector.snapshotDetailed()
        process = .init(bundleID: "com.apple.Safari", pid: 5)
        _ = await collector.snapshotDetailed()
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true, false, true, false])
    }

    func testHydrationReadsFreshPageMetadataWithoutReactivatingTree() async throws {
        let oldRoom = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let newRoom = try XCTUnwrap(URL(string: "https://meet.google.com/xyz-abcd-efg"))
        let probe = BrowserHydrationReadProbe(results: [
            .init(
                observation: .init(urls: ["com.google.Chrome": [oldRoom]]), hasWindows: true,
                hasPopulatedWebArea: false),
            .init(
                observation: .init(
                    urls: ["com.google.Chrome": [newRoom]], inCallURLs: ["com.google.Chrome": [newRoom]]),
                hasWindows: true, hasPopulatedWebArea: true),
        ])
        let result = await BrowserMeetingURLCollector.readWithHydration(
            activateAccessibility: true,
            wait: {},
            scan: { await probe.scan(activate: $0) }
        )
        XCTAssertEqual(result.observation.urls, ["com.google.Chrome": [newRoom]])
        XCTAssertEqual(result.observation.inCallURLs, ["com.google.Chrome": [newRoom]])
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true, false])
    }

    func testHealthyTreeDoesNotWaitForHydration() async {
        let result = await BrowserMeetingURLCollector.readWithHydration(
            activateAccessibility: true,
            wait: { XCTFail("A populated page needs no hydration delay") },
            scan: { activate in
                XCTAssertTrue(activate)
                return .init(hasWindows: true, hasPopulatedWebArea: true)
            }
        )
        XCTAssertTrue(result.hasPopulatedWebArea)
    }

    func testWindowlessProcessDoesNotWaitOrRescanForHydration() async {
        let probe = BrowserHydrationReadProbe(results: [.init(hasWindows: false)])
        let result = await BrowserMeetingURLCollector.readWithHydration(
            activateAccessibility: true,
            wait: { XCTFail("A windowless browser has nothing to hydrate") },
            scan: { await probe.scan(activate: $0) }
        )
        XCTAssertFalse(result.hasWindows)
        let flags = await probe.activationFlags
        XCTAssertEqual(flags, [true])
    }

}

private actor BrowserProcessReadProbe {
    private var readiness: [Bool]
    private var windowPresence: [Bool]
    private(set) var activationFlags: [Bool] = []

    init(readiness: [Bool], windowPresence: [Bool] = []) {
        self.readiness = readiness
        self.windowPresence = windowPresence
    }

    func read(process: BrowserMeetingURLCollector.BrowserProcess, activate: Bool)
        -> BrowserMeetingURLCollector.ProcessReadResult
    {
        activationFlags.append(activate)
        let populated = readiness.isEmpty ? true : readiness.removeFirst()
        let hasWindows = windowPresence.isEmpty ? true : windowPresence.removeFirst()
        return .init(hasWindows: hasWindows, hasPopulatedWebArea: populated)
    }
}

private actor BrowserHydrationReadProbe {
    private var results: [BrowserMeetingURLCollector.ProcessReadResult]
    private(set) var activationFlags: [Bool] = []

    init(results: [BrowserMeetingURLCollector.ProcessReadResult]) { self.results = results }

    func scan(activate: Bool) -> BrowserMeetingURLCollector.ProcessReadResult {
        activationFlags.append(activate)
        guard !results.isEmpty else {
            XCTFail("Unexpected extra AX scan")
            return .init()
        }
        return results.removeFirst()
    }
}
