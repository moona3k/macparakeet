import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class TranscriptNotesActionGateTests: XCTestCase {
    func testRepeatedNavigationSharesPendingFlushAndNavigatesOnce() async throws {
        let gate = TranscriptNotesActionGate()
        let started = expectation(description: "Navigation flush started")
        var releaseFlush: (() -> Void)?
        var actions: [String] = []
        let first = try XCTUnwrap(
            gate.start(
                flush: {
                    started.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseFlush = { continuation.resume() }
                    }
                    return true
                }, isCurrent: { true }
            ) { actions.append("Back") })
        await fulfillment(of: [started], timeout: 1)
        for action in ["Back", "New"] {
            XCTAssertNil(
                gate.start(
                    flush: {
                        XCTFail("Must share the first flush"); return true
                    }, isCurrent: { true }
                ) {
                    actions.append(action)
                })
        }
        releaseFlush?()
        await first.value
        XCTAssertEqual(actions, ["Back"])
    }

    func testObsoleteFailedNavigationCannotChangeReplacementMeetingsTab() async throws {
        let gate = TranscriptNotesActionGate()
        let started = expectation(description: "Navigation flush started")
        var releaseFlush: (() -> Void)?
        var isCurrent = true
        let task = try XCTUnwrap(
            gate.start(
                flush: {
                    started.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseFlush = { continuation.resume() }
                    }
                    return false
                },
                isCurrent: { isCurrent },
                onFailure: { XCTFail("A stale failure cannot select the new meeting's Notes tab") }
            ) { XCTFail("Failed notes cannot navigate") })
        await fulfillment(of: [started], timeout: 1)
        isCurrent = false
        releaseFlush?()
        await task.value
        XCTAssertFalse(gate.isRunning)
    }

    func testFailedFlushDoesNotSubmitAction() async throws {
        let gate = TranscriptNotesActionGate()
        var didFail = false
        let task = try XCTUnwrap(
            gate.start(flush: { false }, isCurrent: { true }, onFailure: { didFail = true }) {
                XCTFail("An action cannot use notes that failed to save")
            })
        await task.value
        XCTAssertTrue(didFail)
        XCTAssertFalse(gate.isRunning)
    }

    func testChangedSelectionOrChatInputWhileSavingDoesNotSubmit() async throws {
        let gate = TranscriptNotesActionGate()
        let started = expectation(description: "Flush started")
        var releaseFlush: (() -> Void)?
        var isCurrent = true
        let task = try XCTUnwrap(
            gate.start(
                flush: {
                    started.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseFlush = { continuation.resume() }
                    }
                    return true
                }, isCurrent: { isCurrent }
            ) {
                XCTFail("A changed selection, conversation, or input invalidates the send")
            })
        await fulfillment(of: [started], timeout: 1)
        isCurrent = false
        releaseFlush?()
        await task.value
        XCTAssertFalse(gate.isRunning)
    }

    func testReturningToSameSelectionCannotReviveOldActionOrClearNewAction() async throws {
        let gate = TranscriptNotesActionGate()
        let oldStarted = expectation(description: "Old flush started")
        let newStarted = expectation(description: "New flush started")
        var releaseOldFlush: (() -> Void)?
        var releaseNewFlush: (() -> Void)?
        var submissions: [String] = []
        let oldTask = try XCTUnwrap(
            gate.start(
                flush: {
                    oldStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseOldFlush = { continuation.resume() }
                    }
                    return true
                }, isCurrent: { true }
            ) {
                submissions.append("old")
            })
        await fulfillment(of: [oldStarted], timeout: 1)
        XCTAssertNil(
            gate.start(flush: { true }, isCurrent: { true }) {
                XCTFail("Repeated clicks cannot duplicate a pending request")
            })

        // Navigation A -> B -> A leaves identity predicates true again, but
        // the original request token must remain invalidated.
        gate.invalidate()
        let newTask = try XCTUnwrap(
            gate.start(
                flush: {
                    newStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseNewFlush = { continuation.resume() }
                    }
                    return true
                }, isCurrent: { true }
            ) {
                submissions.append("new")
            })
        await fulfillment(of: [newStarted], timeout: 1)
        releaseOldFlush?()
        await oldTask.value
        XCTAssertTrue(gate.isRunning)
        XCTAssertTrue(submissions.isEmpty)
        releaseNewFlush?()
        await newTask.value
        XCTAssertEqual(submissions, ["new"])
        XCTAssertFalse(gate.isRunning)
    }

    func testRichContextUsesRevisionPublishedByNotesFlush() async throws {
        let gate = TranscriptNotesActionGate()
        let loader = TranscriptRichContextLoader { transcription, _ in
            transcription.rawTranscript ?? ""
        }
        let transcription = Transcription(fileName: "Meeting", rawTranscript: "Speech", status: .completed)
        var revision: UInt64 = 1
        var submissions: [String] = []
        let task = try XCTUnwrap(
            gate.start(
                flush: {
                    revision = 2
                    return true
                }, isCurrent: { true }
            ) {
                let prepared = loader.startPromptAction(
                    transcription: transcription,
                    mode: .richTranscript,
                    contentRevision: revision,
                    isCurrent: { $0.contentRevision == revision },
                    onStale: { XCTFail("The notes commit must not invalidate its own action") },
                    action: { submissions.append($0) }
                )
                await prepared?.value
            })
        await task.value
        XCTAssertEqual(submissions, ["Speech"])
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(loader.preparingPromptContext)
    }
}
