import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

// MARK: - Mock

final class MockFeedbackService: FeedbackServiceProtocol, @unchecked Sendable {
    var submitCallCount = 0
    var lastPayload: FeedbackPayload?
    var submitError: Error?

    func submitFeedback(_ feedback: FeedbackPayload) async throws {
        submitCallCount += 1
        lastPayload = feedback
        if let error = submitError {
            throw error
        }
    }
}

@MainActor
final class FeedbackViewModelTests: XCTestCase {
    var viewModel: FeedbackViewModel!
    var mockService: MockFeedbackService!

    override func setUp() {
        mockService = MockFeedbackService()
        viewModel = FeedbackViewModel()
        viewModel.configure(feedbackService: mockService)
    }

    // MARK: - Initial State

    func testDefaultState() {
        XCTAssertEqual(viewModel.category, .bug)
        XCTAssertEqual(viewModel.message, "")
        XCTAssertEqual(viewModel.email, "")
        XCTAssertNil(viewModel.screenshotData)
        XCTAssertNil(viewModel.screenshotFilename)
        XCTAssertFalse(viewModel.showSystemInfo)
        XCTAssertEqual(viewModel.submissionState, .idle)
    }

    // MARK: - canSubmit

    func testCanSubmitFalseWithEmptyMessage() {
        viewModel.message = ""
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testCanSubmitFalseWithWhitespaceOnly() {
        viewModel.message = "   \n  "
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testCanSubmitTrueWithMessage() {
        viewModel.message = "Something is broken"
        XCTAssertTrue(viewModel.canSubmit)
    }

    // MARK: - Submit Success

    func testSuccessfulSubmission() async throws {
        viewModel.category = .featureRequest
        viewModel.message = "Please add dark mode"
        viewModel.email = "user@test.com"

        viewModel.submit()

        // Give the Task time to run
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockService.submitCallCount, 1)
        XCTAssertEqual(mockService.lastPayload?.category, .featureRequest)
        XCTAssertEqual(mockService.lastPayload?.message, "Please add dark mode")
        XCTAssertEqual(mockService.lastPayload?.email, "user@test.com")
        XCTAssertEqual(viewModel.submissionState, .success)
    }

    func testSuccessfulSubmissionTrimsEmail() async throws {
        viewModel.message = "Test"
        viewModel.email = "  "

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(mockService.lastPayload?.email, "Whitespace-only email should be sent as nil")
    }

    // MARK: - Submit Failure

    func testFailedSubmission() async throws {
        mockService.submitError = FeedbackError.network("Connection refused")
        viewModel.message = "Test bug report"

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        if case .error(let msg) = viewModel.submissionState {
            XCTAssertTrue(msg.contains("Connection refused"))
        } else {
            XCTFail("Expected error state, got \(viewModel.submissionState)")
        }
    }

    // MARK: - Reset

    func testResetFormClearsEverything() {
        viewModel.category = .featureRequest
        viewModel.message = "Some text"
        viewModel.email = "a@b.com"
        viewModel.screenshotData = Data([0x00])
        viewModel.screenshotFilename = "test.png"
        viewModel.showSystemInfo = true
        viewModel.submissionState = .error("something")

        viewModel.resetForm()

        XCTAssertEqual(viewModel.category, .bug)
        XCTAssertEqual(viewModel.message, "")
        XCTAssertEqual(viewModel.email, "")
        XCTAssertNil(viewModel.screenshotData)
        XCTAssertNil(viewModel.screenshotFilename)
        XCTAssertFalse(viewModel.showSystemInfo)
        XCTAssertEqual(viewModel.submissionState, .idle)
    }

    // MARK: - Dismiss Error

    func testDismissErrorResetsToIdle() {
        viewModel.submissionState = .error("Some error")
        viewModel.dismissError()
        XCTAssertEqual(viewModel.submissionState, .idle)
    }

    // MARK: - Screenshot

    func testRemoveScreenshot() {
        viewModel.screenshotData = Data([0x89, 0x50, 0x4E, 0x47])
        viewModel.screenshotFilename = "bug.png"

        viewModel.removeScreenshot()

        XCTAssertNil(viewModel.screenshotData)
        XCTAssertNil(viewModel.screenshotFilename)
    }

    // MARK: - System Info

    func testSystemInfoReturnsCurrentInfo() {
        let info = viewModel.systemInfo
        XCTAssertFalse(info.macOSVersion.isEmpty)
        XCTAssertFalse(info.chipType.isEmpty)
    }

    // MARK: - canSubmit During Submission

    func testCanSubmitFalseWhileSubmitting() {
        viewModel.message = "Test"
        viewModel.submissionState = .submitting
        XCTAssertFalse(viewModel.canSubmit)
    }
}
