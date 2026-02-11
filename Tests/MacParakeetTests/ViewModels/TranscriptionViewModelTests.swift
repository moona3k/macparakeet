import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionViewModelTests: XCTestCase {
    var viewModel: TranscriptionViewModel!
    var mockService: MockTranscriptionService!
    var mockRepo: MockTranscriptionRepository!

    override func setUp() {
        mockService = MockTranscriptionService()
        mockRepo = MockTranscriptionRepository()
        viewModel = TranscriptionViewModel()
    }

    // MARK: - Configure

    func testConfigureLoadsTranscriptions() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        XCTAssertEqual(viewModel.transcriptions.count, 1)
        XCTAssertEqual(viewModel.transcriptions[0].fileName, "test.mp3")
    }

    func testConfigureWithEmptyRepo() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        XCTAssertTrue(viewModel.transcriptions.isEmpty)
    }

    // MARK: - Transcribe File

    func testTranscribeFileUpdatesState() async throws {
        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "Transcribed text",
            status: .completed
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        // The transcribeFile method uses a Task internally, so the state should be set synchronously first
        XCTAssertTrue(viewModel.isTranscribing, "Should be transcribing immediately after call")
        XCTAssertEqual(viewModel.progress, "Preparing...")
        XCTAssertNil(viewModel.errorMessage)

        // Wait for the async task to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing, "Should not be transcribing after completion")
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNotNil(viewModel.currentTranscription)
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Transcribed text")
    }

    func testTranscribeFileErrorHandling() async throws {
        await mockService.configure(error: NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Transcription failed"
        ]))

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        XCTAssertTrue(viewModel.isTranscribing)

        // Wait for the async task to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing, "Should not be transcribing after error")
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNotNil(viewModel.errorMessage, "Error message should be set")
        XCTAssertEqual(viewModel.errorMessage, "Transcription failed")
        XCTAssertNil(viewModel.currentTranscription, "No transcription on error")
    }

    func testTranscribeFileProgressMessage() async throws {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/myfile.wav")
        viewModel.transcribeFile(url: url)

        XCTAssertEqual(viewModel.progress, "Preparing...", "Initial progress should be 'Preparing...'")
    }

    func testTranscribeFileClearsErrorMessage() async throws {
        await mockService.configure(error: NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "First error"
        ]))

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        // First transcription: error
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(viewModel.errorMessage)

        // Second transcription: success
        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "OK",
            status: .completed
        )
        await mockService.configure(result: expectedResult)
        viewModel.transcribeFile(url: url)
        XCTAssertNil(viewModel.errorMessage, "Error should be cleared when starting new transcription")
    }

    // MARK: - Transcribe URL

    func testTranscribeURLUpdatesState() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"

        viewModel.transcribeURL()

        XCTAssertTrue(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "Preparing...")
        XCTAssertEqual(viewModel.urlInput, "")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "URL transcript")
        let callCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testTranscribeURLInvalidInputNoOp() async {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://notyoutube.com/watch?v=dQw4w9WgXcQ"

        viewModel.transcribeURL()

        XCTAssertFalse(viewModel.isTranscribing)
        let callCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Delete

    func testDeleteTranscription() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertEqual(viewModel.transcriptions.count, 1)

        viewModel.deleteTranscription(t)

        XCTAssertTrue(viewModel.transcriptions.isEmpty)
        XCTAssertTrue(mockRepo.deleteCalledWith.contains(t.id))
    }

    func testDeleteCurrentTranscriptionClearsSelection() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.deleteTranscription(t)

        XCTAssertNil(viewModel.currentTranscription, "Deleting current transcription should clear it")
    }

    func testDeleteDoesNotClearUnrelatedCurrentTranscription() {
        let t1 = Transcription(fileName: "one.mp3", rawTranscript: "First", status: .completed)
        let t2 = Transcription(fileName: "two.mp3", rawTranscript: "Second", status: .completed)
        mockRepo.transcriptions = [t1, t2]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t1

        viewModel.deleteTranscription(t2)

        XCTAssertNotNil(viewModel.currentTranscription)
        XCTAssertEqual(viewModel.currentTranscription?.id, t1.id)
    }

    // MARK: - Load

    func testLoadTranscriptionsRefreshesFromRepo() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertTrue(viewModel.transcriptions.isEmpty)

        // Add transcription to repo after configure
        let t = Transcription(fileName: "new.mp3", rawTranscript: "New", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.loadTranscriptions()

        XCTAssertEqual(viewModel.transcriptions.count, 1)
        XCTAssertEqual(viewModel.transcriptions[0].fileName, "new.mp3")
    }

    // MARK: - Unconfigured

    func testTranscribeFileBeforeConfigureIsNoOp() {
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        // Should not crash and state should remain unchanged
        XCTAssertFalse(viewModel.isTranscribing)
    }

    func testLoadTranscriptionsBeforeConfigureIsNoOp() {
        viewModel.loadTranscriptions()
        XCTAssertTrue(viewModel.transcriptions.isEmpty)
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(viewModel.transcriptions.isEmpty)
        XCTAssertNil(viewModel.currentTranscription)
        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isDragging)
    }
}
