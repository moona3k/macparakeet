import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class MeetingURLCommandTests: XCTestCase {
    func testSupportedCommandsAndPercentEncodedTitle() throws {
        let examples: [(String, MeetingURLCommand)] = [
            ("macparakeet://meeting/start", .start(title: nil)),
            ("macparakeet://meeting/start?title=", .start(title: nil)),
            ("macparakeet://meeting/start?title=%20%20", .start(title: nil)),
            ("macparakeet://meeting/start?title=Caf%C3%A9%20%26%20R%2BD%20%231", .start(title: "Café & R+D #1")),
            ("macparakeet://meeting/stop", .stop),
            ("macparakeet://meeting/pause", .pause),
            ("macparakeet://meeting/resume", .resume),
        ]
        for (raw, expected) in examples {
            XCTAssertEqual(MeetingURLCommand(url: try XCTUnwrap(URL(string: raw))), expected)
        }
    }

    func testMalformedOrAmbiguousCommandsAreRejected() throws {
        for raw in [
            "https://meeting/start", "macparakeet://other/start", "macparakeet://meeting/toggle",
            "macparakeet://meeting/start/", "macparakeet://meeting/%73tart",
            "macparakeet://user@meeting/start", "macparakeet://meeting:443/start",
            "macparakeet://meeting/start#fragment", "macparakeet://meeting/start?title",
            "macparakeet://meeting/start?title=one&title=two", "macparakeet://meeting/start?unknown=1",
            "macparakeet://meeting/stop?title=one", "macparakeet://meeting/pause?x=1",
            "macparakeet://meeting/start?title=a%00b", "macparakeet://meeting/start?title=a%0Ab",
            "macparakeet://meeting/start?title=" + String(repeating: "a", count: 501),
            "macparakeet://meeting/start?title=" + String(repeating: "%61", count: 3000),
        ] {
            XCTAssertNil(MeetingURLCommand(url: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testDevSchemeDoesNotClaimStableLinks() throws {
        let stable = try XCTUnwrap(URL(string: "macparakeet://meeting/start"))
        let dev = try XCTUnwrap(URL(string: "macparakeet-dev://meeting/start"))
        XCTAssertNil(MeetingURLCommand(url: stable, scheme: "macparakeet-dev"))
        XCTAssertNil(MeetingURLCommand(url: dev))
        XCTAssertEqual(MeetingURLCommand(url: dev, scheme: "macparakeet-dev"), .start(title: nil))
    }

    func testColdLaunchPreservesCommandOrderAndDoesNotReplay() throws {
        var received: [MeetingURLCommand] = []
        let router = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        router.open(try ["start?title=Planning", "stop"].map { try url($0) })
        XCTAssertTrue(received.isEmpty)
        router.finishLaunching()
        XCTAssertEqual(received, [.start(title: "Planning"), .stop])
        router.finishLaunching()
        XCTAssertEqual(received.count, 2)
        router.open([try url("pause"), try url("resume")])
        XCTAssertEqual(received.suffix(2), [.pause, .resume])
    }

    func testDisabledRequestsAreNotSavedAndRevocationDropsQueuedRequests() throws {
        var enabled = false
        var received: [MeetingURLCommand] = []
        let router = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) { received.append($0) }
        router.open([try url("start")])
        enabled = true
        router.finishLaunching()
        XCTAssertTrue(received.isEmpty)
        router.open([try url("pause")])
        enabled = false
        router.open([try url("resume")])
        XCTAssertEqual(received, [.pause])

        enabled = true
        let cold = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) { received.append($0) }
        cold.open([try url("start")])
        enabled = false
        cold.finishLaunching()
        enabled = true
        cold.finishLaunching()
        XCTAssertEqual(received, [.pause])
    }

    func testReadyBatchRechecksConsentAndDoesNotReplayRevokedCommands() throws {
        var enabled = true
        var received: [MeetingURLCommand] = []
        let router = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) {
            received.append($0)
            // Dispatch can enter a modal loop where consent is revoked.
            enabled = false
        }
        router.finishLaunching()
        router.open([try url("pause"), try url("resume"), try url("start?title=Later")])
        XCTAssertEqual(received, [.pause])

        enabled = true
        router.finishLaunching()
        XCTAssertEqual(received, [.pause], "Revoked commands must not be queued for later replay")
        router.open([try url("resume")])
        XCTAssertEqual(received, [.pause, .resume])
    }

    func testFailedStartupDiscardsCommandsAndQueueIsBounded() throws {
        var received: [MeetingURLCommand] = []
        let router = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        router.open([try url("start")])
        router.discardPending()
        router.finishLaunching()
        XCTAssertTrue(received.isEmpty)
        let cold = MeetingURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        cold.open(Array(repeating: try url("pause"), count: 100))
        cold.finishLaunching()
        XCTAssertEqual(received.count, 16)
    }

    private func url(_ suffix: String) throws -> URL {
        try XCTUnwrap(URL(string: "macparakeet://meeting/" + suffix))
    }
}
