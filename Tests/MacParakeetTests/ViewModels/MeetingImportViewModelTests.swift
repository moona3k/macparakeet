import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingImportViewModelTests: XCTestCase {
    private var sourceURL: URL!

    override func setUpWithError() throws {
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-import-\(UUID().uuidString).m4a")
        try Data().write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceURL)
    }

    func testSelectUsesFilenameDefaultsAndRejectsBlankTitle() throws {
        let viewModel = MeetingImportViewModel(run: { _, _ in throw CancellationError() })

        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertEqual(viewModel.draft?.title, sourceURL.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(viewModel.canImport)

        viewModel.updateTitle("  ")
        XCTAssertFalse(viewModel.canImport)
        XCTAssertEqual(viewModel.validationMessage, "Enter a meeting title.")
        XCTAssertFalse(viewModel.startImport())
    }

    func testPublishedMeetingRefreshesOnceAndPartialResultRemainsUntilAcknowledged() async throws {
        let transcription = meeting(status: .completed)
        let counter = MainActorCounter()
        let viewModel = MeetingImportViewModel(
            run: { _, progress in
                progress(.preparingMedia)
                progress(.published(transcription))
                progress(.transcription(.finalizing))
                progress(.published(transcription))
                return MeetingImportResult(
                    transcription: transcription,
                    warnings: [.automationCancelled]
                )
            },
            onMeetingPublished: { _ in counter.value += 1 }
        )
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())

        try await waitUntil { !viewModel.isProcessing }
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(viewModel.terminalResult?.outcome, .partial)
        XCTAssertEqual(
            viewModel.terminalResult?.warnings,
            ["Meeting notes stopped before they finished. The transcript is ready."]
        )

        viewModel.acknowledgeResult()
        XCTAssertNil(viewModel.terminalResult)
        XCTAssertNil(viewModel.draft)
    }

    func testCompletedSettlementWarningDoesNotSuggestRetryingTranscription() async throws {
        let transcription = meeting(status: .completed)
        let viewModel = MeetingImportViewModel(
            run: { _, _ in
                MeetingImportResult(
                    transcription: transcription,
                    warnings: [.settlementFailed(message: "private cleanup detail")]
                )
            }
        )
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())

        try await waitUntil { !viewModel.isProcessing }

        XCTAssertEqual(viewModel.terminalResult?.outcome, .partial)
        XCTAssertEqual(
            viewModel.terminalResult?.warnings,
            ["Some saved-meeting details need attention. The transcript is ready."]
        )
    }

    func testPrepublicationInvalidAudioPresentsSafeFailedResult() async throws {
        let viewModel = MeetingImportViewModel(run: { _, _ in throw MeetingImportError.invalidAudio })
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())

        try await waitUntil { !viewModel.isProcessing }

        XCTAssertEqual(viewModel.terminalResult?.outcome, .failed)
        XCTAssertNil(viewModel.terminalResult?.transcription)
        XCTAssertEqual(viewModel.terminalResult?.errorMessage, "The file does not contain playable audio.")
        XCTAssertNil(viewModel.stage)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testStopBeforePublicationReturnsToEditableDraft() async throws {
        let gate = ImportGate()
        let viewModel = MeetingImportViewModel(run: { _, progress in
            progress(.preparingMedia)
            await gate.wait()
            try Task.checkCancellation()
            progress(.automation(.init(completedCount: 1, totalCount: 1, promptName: "ignored")))
            throw CancellationError()
        })
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())
        try await waitUntil { viewModel.isProcessing }

        viewModel.stop()
        await gate.open()
        try await waitUntil { !viewModel.isProcessing }

        XCTAssertNil(viewModel.terminalResult)
        XCTAssertNotNil(viewModel.draft)
        XCTAssertEqual(viewModel.validationMessage, "Import stopped before the meeting was saved.")
        XCTAssertNil(viewModel.stage)
    }

    func testCancellationAfterPublicationKeepsMeetingAvailableForRetry() async throws {
        let transcription = meeting(status: .processing)
        let viewModel = MeetingImportViewModel(run: { _, progress in
            progress(.published(transcription))
            await Task.yield()
            throw CancellationError()
        })
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())

        try await waitUntil { !viewModel.isProcessing }

        XCTAssertEqual(viewModel.terminalResult?.outcome, .needsRetry)
        XCTAssertEqual(viewModel.terminalResult?.transcription?.id, transcription.id)
        XCTAssertTrue(viewModel.hasPublishedMeeting)
    }

    func testLateProgressCannotOverwriteANewSelection() async throws {
        let progressBox = ProgressBox()
        let transcription = meeting(status: .completed)
        let viewModel = MeetingImportViewModel(run: { _, progress in
            await progressBox.store(progress)
            return MeetingImportResult(transcription: transcription)
        })
        XCTAssertTrue(viewModel.select(sourceURL: sourceURL))
        XCTAssertTrue(viewModel.startImport())
        try await waitUntil { !viewModel.isProcessing }

        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-\(UUID().uuidString).m4a")
        try Data().write(to: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }
        XCTAssertTrue(viewModel.select(sourceURL: replacement))

        await progressBox.send(.transcription(.finalizing))
        await Task.yield()

        XCTAssertNil(viewModel.stage)
        XCTAssertEqual(viewModel.draft?.sourceURL, replacement)
    }

    private func meeting(status: Transcription.TranscriptionStatus) -> Transcription {
        Transcription(
            fileName: "Quarterly planning",
            durationMs: 90_000,
            status: status,
            sourceType: .meeting
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !predicate() {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class MainActorCounter {
    var value = 0
}

private actor ImportGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ProgressBox {
    private var progress: (@Sendable (MeetingImportProgress) -> Void)?

    func store(_ progress: @escaping @Sendable (MeetingImportProgress) -> Void) {
        self.progress = progress
    }

    func send(_ update: MeetingImportProgress) {
        progress?(update)
    }
}
