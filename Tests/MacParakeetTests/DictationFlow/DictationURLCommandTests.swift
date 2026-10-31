import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class DictationURLCommandTests: XCTestCase {
    func testSupportedCommandsAndCaseInsensitiveAuthority() throws {
        for command in DictationURLCommand.allCases {
            XCTAssertEqual(DictationURLCommand(url: try url(command.rawValue)), command)
            let upper = try XCTUnwrap(URL(string: "MACPARAKEET://DICTATION/" + command.rawValue))
            XCTAssertEqual(DictationURLCommand(url: upper), command)
        }
    }

    func testRejectsMalformedCommandsAndParameters() throws {
        for raw in [
            "https://dictation/start", "macparakeet://meeting/start", "macparakeet://dictation/pause",
            "macparakeet://dictation/START", "macparakeet://dictation/start/", "macparakeet://dictation/%73tart",
            "macparakeet://user@dictation/start", "macparakeet://dictation:443/start",
            "macparakeet://dictation/start#fragment", "macparakeet://dictation/start#",
            "macparakeet://dictation/start?", "macparakeet://dictation/start?text=secret",
            "macparakeet://dictation/stop?x=1", "macparakeet://dictation/toggle?x=1",
            "macparakeet://dictation/" + String(repeating: "a", count: 8_192),
        ] {
            XCTAssertNil(DictationURLCommand(url: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testDevSchemeDoesNotClaimStableLinks() throws {
        let stable = try url("start")
        let dev = try XCTUnwrap(URL(string: "macparakeet-dev://dictation/start"))
        XCTAssertNil(DictationURLCommand(url: stable, scheme: "macparakeet-dev"))
        XCTAssertNil(DictationURLCommand(url: dev))
        XCTAssertEqual(DictationURLCommand(url: dev, scheme: "macparakeet-dev"), .start)
    }

    func testLifecyclePolicyPreservesActiveAndPendingWork() {
        let idle: [DictationFlowState] = [.idle, .ready]
        for state in idle {
            XCTAssertEqual(DictationURLCommand.start.action(for: state), .start)
            XCTAssertEqual(DictationURLCommand.toggle.action(for: state), .start)
            XCTAssertNil(DictationURLCommand.stop.action(for: state))
        }
        for mode: FnKeyStateMachine.RecordingMode in [.persistent, .holdToTalk] {
            let active: [DictationFlowState] = [
                .checkingEntitlements(mode: mode), .startingService(mode: mode), .recording(mode: mode),
            ]
            for state in active {
                XCTAssertNil(DictationURLCommand.start.action(for: state))
                XCTAssertEqual(DictationURLCommand.stop.action(for: state), .stop)
                XCTAssertEqual(DictationURLCommand.toggle.action(for: state), .stop)
            }
        }
        let protected: [DictationFlowState] = [
            .pendingStop(mode: .persistent), .pendingStop(mode: .holdToTalk), .processing, .cancelCountdown,
            .finishing(outcome: .success), .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("failure")), .finishing(outcome: .pasteFailedCopied("copied")),
        ]
        for state in protected {
            for command in DictationURLCommand.allCases {
                XCTAssertNil(command.action(for: state), "\(command) must preserve \(state)")
            }
        }
    }

    func testColdLaunchPreservesCommandOrderAndDoesNotReplay() throws {
        var received: [DictationURLCommand] = []
        let router = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        router.open(try ["start", "stop"].map { try url($0) })
        XCTAssertTrue(received.isEmpty)
        router.finishLaunching()
        XCTAssertEqual(received, [.start, .stop])
        router.finishLaunching()
        XCTAssertEqual(received.count, 2)
        router.open([try url("start"), try url("stop")])
        XCTAssertEqual(received.suffix(2), [.start, .stop])
    }

    func testDisabledRequestsAreNotSavedAndRevocationDropsQueuedRequests() throws {
        var enabled = false
        var received: [DictationURLCommand] = []
        let router = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) { received.append($0) }
        router.open([try url("start")])
        enabled = true
        router.finishLaunching()
        XCTAssertTrue(received.isEmpty)
        router.open([try url("start")])
        enabled = false
        router.open([try url("stop")])
        XCTAssertEqual(received, [.start])

        enabled = true
        let cold = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) { received.append($0) }
        cold.open([try url("start")])
        enabled = false
        cold.finishLaunching()
        enabled = true
        cold.finishLaunching()
        XCTAssertEqual(received, [.start])
    }

    func testReadyBatchRechecksConsentAndDoesNotReplayRevokedCommands() throws {
        var enabled = true
        var received: [DictationURLCommand] = []
        let router = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { enabled }) {
            received.append($0)
            // Dispatch can enter a modal loop where consent is revoked.
            enabled = false
        }
        router.finishLaunching()
        router.open([try url("start"), try url("stop"), try url("start")])
        XCTAssertEqual(received, [.start])

        enabled = true
        router.finishLaunching()
        XCTAssertEqual(received, [.start], "Revoked commands must not be queued for later replay")
        router.open([try url("stop")])
        XCTAssertEqual(received, [.start, .stop])
    }

    func testFailedStartupDiscardsCommandsAndQueueIsBounded() throws {
        var received: [DictationURLCommand] = []
        let router = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        router.open([try url("start")])
        router.discardPending()
        router.finishLaunching()
        XCTAssertTrue(received.isEmpty)
        let cold = DictationURLCommandRouter(scheme: "macparakeet", isEnabled: { true }) { received.append($0) }
        cold.open(Array(repeating: try url("start"), count: 100))
        cold.finishLaunching()
        XCTAssertEqual(received.count, 16)
    }

    private func url(_ suffix: String) throws -> URL {
        try XCTUnwrap(URL(string: "macparakeet://dictation/" + suffix))
    }
}
