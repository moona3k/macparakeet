import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionMeetingFinalizationRetryTests: XCTestCase {
    private var folder: URL!
    private var repository: MockTranscriptionRepository!
    private var viewModel: TranscriptionViewModel!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("microphone-raw.m4a"))
        repository = MockTranscriptionRepository()
        let suite = makeIsolatedDefaultsSuite("TranscriptionMeetingFinalizationRetryTests.")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        viewModel = TranscriptionViewModel(defaults: defaults)
        viewModel.configure(transcriptionService: MockTranscriptionService(), transcriptionRepo: repository)
    }

    override func tearDownWithError() throws {
        viewModel.onRetryMeetingFinalization = nil
        try FileManager.default.removeItem(at: folder)
    }

    private func savedMeeting(status: Transcription.TranscriptionStatus = .error) -> Transcription {
        Transcription(
            fileName: "Saved meeting",
            filePath: folder.appendingPathComponent("meeting-playback.m4a").path,
            meetingArtifactFolderPath: folder.path,
            status: status,
            sourceType: .meeting
        )
    }

    func testAcceptedRetryStaysPendingBehindOtherWorkAndReusesTheSameRow() async throws {
        let failed = savedMeeting()
        repository.transcriptions = [failed]
        viewModel.currentTranscription = failed
        viewModel.selectedTab = .chat
        var submittedIDs: [UUID] = []
        viewModel.onRetryMeetingFinalization = { submittedIDs.append($0.id) }

        await viewModel.retryMeetingFinalization(failed)
        await viewModel.retryMeetingFinalization(failed)

        XCTAssertEqual(submittedIDs, [failed.id])
        XCTAssertTrue(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertEqual(viewModel.currentTranscription?.status, .error, "The queued row can still have its old status")
        XCTAssertEqual(repository.transcriptions.map(\.id), [failed.id])

        var completed = failed
        completed.status = .completed
        completed.rawTranscript = "Recovered transcript"
        repository.transcriptions = [completed]
        let wasDetailRetry = viewModel.finishMeetingFinalizationRetry(id: failed.id)
        XCTAssertTrue(wasDetailRetry)
        viewModel.presentCompletedTranscription(
            completed, autoSave: false, runAutoPrompts: false, selectTranscription: !wasDetailRetry)

        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertEqual(viewModel.currentTranscription?.id, failed.id)
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Recovered transcript")
        XCTAssertEqual(viewModel.selectedTab, .chat)
        XCTAssertEqual(repository.transcriptions.count, 1)
    }

    func testAdmissionFailureStaysWithItsMeetingAfterNavigationAndCanRetryAgain() async throws {
        let failed = savedMeeting()
        let other = Transcription(fileName: "Other meeting", status: .completed, sourceType: .meeting)
        repository.transcriptions = [failed, other]
        viewModel.currentTranscription = failed
        let entered = expectation(description: "admission started")
        var release: CheckedContinuation<Void, Never>?
        viewModel.onRetryMeetingFinalization = { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
            throw RetryError.unavailable
        }
        let retry = Task { await viewModel.retryMeetingFinalization(failed) }
        await fulfillment(of: [entered], timeout: 2)
        viewModel.currentTranscription = other
        viewModel.selectedTab = .notes
        release?.resume()
        await retry.value

        XCTAssertEqual(viewModel.currentTranscription?.id, other.id)
        XCTAssertEqual(viewModel.selectedTab, .notes)
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertTrue(viewModel.meetingFinalizationRetryErrors[failed.id]?.contains("Queue unavailable") == true)
        XCTAssertNil(viewModel.meetingFinalizationRetryErrors[other.id])

        viewModel.currentTranscription = failed
        viewModel.onRetryMeetingFinalization = { _ in }
        await viewModel.retryMeetingFinalization(failed)
        XCTAssertTrue(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertNil(viewModel.meetingFinalizationRetryErrors[failed.id])
    }

    func testFastCompletionDuringAdmissionDoesNotReinstatePendingState() async {
        let failed = savedMeeting()
        repository.transcriptions = [failed]
        viewModel.currentTranscription = failed
        viewModel.onRetryMeetingFinalization = { [viewModel, repository] transcription in
            var completed = transcription
            completed.status = .completed
            repository?.transcriptions = [completed]
            viewModel?.finishMeetingFinalizationRetry(id: transcription.id)
            viewModel?.refreshCurrentTranscriptionIfMatching(id: transcription.id)
        }

        await viewModel.retryMeetingFinalization(failed)

        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertEqual(viewModel.currentTranscription?.status, .completed)
        XCTAssertEqual(repository.transcriptions.map(\.id), [failed.id])
    }

    func testQueuedFailureClearsPendingAfterNavigationAndAllowsAnotherRetry() async {
        let failed = savedMeeting(status: .cancelled)
        let other = Transcription(fileName: "Other", status: .completed)
        repository.transcriptions = [failed, other]
        viewModel.currentTranscription = failed
        viewModel.onRetryMeetingFinalization = { _ in }
        await viewModel.retryMeetingFinalization(failed)
        viewModel.currentTranscription = other

        var failedAgain = failed
        failedAgain.status = .error
        failedAgain.errorMessage = "Playback preparation failed"
        repository.transcriptions = [failedAgain, other]
        viewModel.finishMeetingFinalizationRetry(id: failed.id)
        viewModel.refreshCurrentTranscriptionIfMatching(id: failed.id)

        XCTAssertEqual(viewModel.currentTranscription?.id, other.id)
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
        viewModel.currentTranscription = failedAgain
        await viewModel.retryMeetingFinalization(failedAgain)
        XCTAssertTrue(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertEqual(repository.transcriptions.count, 2)
    }

    func testMissingBridgeOrSourcesExplainsWhyRetryCouldNotStart() async throws {
        let failed = savedMeeting()
        await viewModel.retryMeetingFinalization(failed)
        XCTAssertEqual(viewModel.meetingFinalizationRetryErrors[failed.id], "Meeting retry is not available.")
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))

        try FileManager.default.removeItem(at: folder.appendingPathComponent("microphone-raw.m4a"))
        viewModel.onRetryMeetingFinalization = { _ in XCTFail("Missing audio must not be submitted") }
        await viewModel.retryMeetingFinalization(failed)
        XCTAssertEqual(
            viewModel.meetingFinalizationRetryErrors[failed.id], "Saved meeting audio is no longer available.")
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
    }

    func testCompletedProcessingAndNonMeetingRowsCannotUseFinalizationRetry() async {
        viewModel.onRetryMeetingFinalization = { _ in XCTFail("This row is not retryable") }
        for status in [Transcription.TranscriptionStatus.completed, .processing] {
            let row = savedMeeting(status: status)
            await viewModel.retryMeetingFinalization(row)
            XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: row.id))
        }
        var file = savedMeeting()
        file.sourceType = .file
        await viewModel.retryMeetingFinalization(file)
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: file.id))
    }

    func testPendingRetryRejectsEditsIncludingADraftOpenedBeforeAdmission() async throws {
        let failed = savedMeeting()
        repository.transcriptions = [failed]
        viewModel.currentTranscription = failed
        let draftSnapshot = try XCTUnwrap(viewModel.makeTranscriptEditSnapshot())
        viewModel.onRetryMeetingFinalization = { _ in }

        await viewModel.retryMeetingFinalization(failed)

        XCTAssertNil(viewModel.makeTranscriptEditSnapshot())
        XCTAssertFalse(viewModel.updateCurrentTranscriptText(to: "Do not lose this draft", expected: draftSnapshot))
        XCTAssertNil(repository.transcriptions.first?.cleanTranscript)
        XCTAssertTrue(viewModel.transcriptEditFailure?.contains("processing finishes") == true)
    }

    func testPendingRetryRejectsSpeakerRenamesWithoutChangingMetadata() async {
        var failed = savedMeeting()
        failed.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        repository.transcriptions = [failed]
        viewModel.currentTranscription = failed
        viewModel.onRetryMeetingFinalization = { _ in }
        await viewModel.retryMeetingFinalization(failed)

        XCTAssertFalse(viewModel.renameSpeaker(id: "S1", to: "Alice"))
        XCTAssertEqual(viewModel.currentTranscription?.speakers?.first?.label, "Speaker 1")
        XCTAssertEqual(repository.transcriptions.first?.speakers?.first?.label, "Speaker 1")
        XCTAssertTrue(repository.updateSpeakersCalls.isEmpty)
        XCTAssertTrue(viewModel.errorMessage?.contains("processing finishes") == true)

        viewModel.finishMeetingFinalizationRetry(id: failed.id)
        let committed = expectation(description: "rename is available after the retry ends")
        XCTAssertTrue(
            viewModel.renameSpeaker(id: "S1", to: "Alice", offersEnrollment: false) { saved in
                XCTAssertTrue(saved)
                committed.fulfill()
            })
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(repository.transcriptions.first?.speakers?.first?.label, "Alice")
    }

    func testDetailRetryCompletionUsesQuietPresentationEvenWhenAutomaticOpeningIsRequested() async {
        let failed = savedMeeting()
        let other = Transcription(fileName: "Keep this detail open", status: .completed)
        repository.transcriptions = [failed, other]
        viewModel.currentTranscription = failed
        viewModel.onRetryMeetingFinalization = { _ in }
        await viewModel.retryMeetingFinalization(failed)
        viewModel.currentTranscription = other
        viewModel.selectedTab = .notes

        var completed = failed
        completed.status = .completed
        let canPresentFromRecordingFlow = true
        let openAppAfterMeetingEnd = true
        let wasDetailRetry = viewModel.finishMeetingFinalizationRetry(id: completed.id)
        viewModel.presentCompletedTranscription(
            completed, autoSave: false, runAutoPrompts: false,
            selectTranscription: canPresentFromRecordingFlow && !wasDetailRetry && openAppAfterMeetingEnd)

        XCTAssertTrue(wasDetailRetry)
        XCTAssertFalse(viewModel.isRetryingMeetingFinalization(id: failed.id))
        XCTAssertEqual(viewModel.currentTranscription?.id, other.id)
        XCTAssertEqual(viewModel.selectedTab, .notes)
        XCTAssertFalse(
            viewModel.finishMeetingFinalizationRetry(id: other.id), "Ordinary completion keeps its existing policy")
    }

    private enum RetryError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Queue unavailable" }
    }
}
