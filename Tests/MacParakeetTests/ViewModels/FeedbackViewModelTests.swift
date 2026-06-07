import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

// MARK: - Mock

final class MockFeedbackService: FeedbackServiceProtocol, @unchecked Sendable {
    var submitCallCount = 0
    var lastPayload: FeedbackPayload?
    var submitError: Error?
    var submitDelayMilliseconds: UInt64 = 0

    func submitFeedback(_ feedback: FeedbackPayload) async throws {
        submitCallCount += 1
        lastPayload = feedback
        if submitDelayMilliseconds > 0 {
            try await Task.sleep(nanoseconds: submitDelayMilliseconds * 1_000_000)
        }
        if let error = submitError {
            throw error
        }
    }
}

private final class FeedbackTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func clearQueue() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    func flush() async {}
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
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
        Telemetry.configure(NoOpTelemetryService())
    }

    /// An ISO-8601 timestamp `secondsAgo` before now, in the writer's format —
    /// used to build diagnostic-log fixtures whose recency the scoping logic
    /// (which uses the real `Date()`) will evaluate.
    static func iso(secondsAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    /// Polls until `condition` holds or `timeout` elapses, so async submission
    /// assertions wait for the detached submit task deterministically instead
    /// of racing a fixed delay on a loaded runner.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Initial State

    func testDefaultState() {
        XCTAssertEqual(viewModel.category, .bug)
        XCTAssertEqual(viewModel.message, "")
        XCTAssertEqual(viewModel.email, "")
        XCTAssertNil(viewModel.screenshotData)
        XCTAssertNil(viewModel.screenshotFilename)
        XCTAssertTrue(viewModel.screenshotAttachments.isEmpty)
        XCTAssertFalse(viewModel.includeDiagnosticLog)
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

    func testSuccessfulSubmissionTrimsMessagePayload() async throws {
        viewModel.message = "  Please fix this crash  "

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockService.lastPayload?.message, "Please fix this crash")
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

    func testResetFormCancelsInFlightSubmissionTask() async throws {
        mockService.submitDelayMilliseconds = 700
        viewModel.message = "Delayed submission"

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))
        viewModel.resetForm()

        XCTAssertEqual(viewModel.submissionState, .idle)
        XCTAssertEqual(viewModel.message, "")

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(viewModel.submissionState, .idle)
        XCTAssertEqual(viewModel.message, "")
    }

    // MARK: - Reset

    func testResetFormClearsEverything() {
        viewModel.category = .featureRequest
        viewModel.message = "Some text"
        viewModel.email = "a@b.com"
        viewModel.screenshotData = Data([0x00])
        viewModel.screenshotFilename = "test.png"
        viewModel.includeDiagnosticLog = true
        viewModel.includeFullDiagnosticHistory = true
        viewModel.showSystemInfo = true
        viewModel.submissionState = .error("something")

        viewModel.resetForm()

        XCTAssertEqual(viewModel.category, .bug)
        XCTAssertEqual(viewModel.message, "")
        XCTAssertEqual(viewModel.email, "")
        XCTAssertNil(viewModel.screenshotData)
        XCTAssertNil(viewModel.screenshotFilename)
        XCTAssertTrue(viewModel.screenshotAttachments.isEmpty)
        XCTAssertFalse(viewModel.includeDiagnosticLog)
        XCTAssertFalse(viewModel.includeFullDiagnosticHistory)
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

    func testSubmissionIncludesMultipleScreenshots() async throws {
        viewModel.message = "The form needs screenshots"
        viewModel.screenshotAttachments = [
            FeedbackScreenshotAttachment(filename: "first.png", data: Data([0x01, 0x02])),
            FeedbackScreenshotAttachment(filename: "second.jpg", data: Data([0x03, 0x04])),
        ]

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockService.lastPayload?.screenshots.count, 2)
        XCTAssertEqual(mockService.lastPayload?.screenshots[0].filename, "first.png")
        XCTAssertEqual(mockService.lastPayload?.screenshots[1].filename, "second.jpg")
        XCTAssertEqual(mockService.lastPayload?.screenshotFilename, "first.png")
        XCTAssertEqual(mockService.lastPayload?.screenshotBase64, Data([0x01, 0x02]).base64EncodedString())
    }

    func testRemoveScreenshotByIDKeepsOtherAttachments() {
        let first = FeedbackScreenshotAttachment(filename: "first.png", data: Data([0x01]))
        let second = FeedbackScreenshotAttachment(filename: "second.png", data: Data([0x02]))
        viewModel.screenshotAttachments = [first, second]

        viewModel.removeScreenshot(id: first.id)

        XCTAssertEqual(viewModel.screenshotAttachments, [second])
    }

    func testLegacyFilenameSetterBeforeDataDoesNotCreateEmptyAttachment() {
        viewModel.screenshotFilename = "later.png"

        XCTAssertTrue(viewModel.screenshotAttachments.isEmpty)

        viewModel.screenshotData = Data([0x01])

        XCTAssertEqual(viewModel.screenshotFilename, "later.png")
        XCTAssertEqual(viewModel.screenshotData, Data([0x01]))
    }

    func testLegacyDataSetterUpdatesFirstAttachmentWithoutDroppingOthers() {
        let first = FeedbackScreenshotAttachment(filename: "first.png", data: Data([0x01]))
        let second = FeedbackScreenshotAttachment(filename: "second.png", data: Data([0x02]))
        viewModel.screenshotAttachments = [first, second]

        viewModel.screenshotData = Data([0x09])

        XCTAssertEqual(viewModel.screenshotAttachments.count, 2)
        XCTAssertEqual(viewModel.screenshotAttachments[0].id, first.id)
        XCTAssertEqual(viewModel.screenshotAttachments[0].filename, "first.png")
        XCTAssertEqual(viewModel.screenshotAttachments[0].data, Data([0x09]))
        XCTAssertEqual(viewModel.screenshotAttachments[1], second)
    }

    // MARK: - Diagnostic Log

    func testRefreshDiagnosticLogStatusCachesAvailableLogDescription() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("available-dictation-audio-\(UUID().uuidString).log")
        try Data("dictation_capture_stop duration_s=1.400\n".utf8).write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)

        viewModel.refreshDiagnosticLogStatus()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(viewModel.diagnosticLogIsAvailable)
        XCTAssertTrue(viewModel.diagnosticLogAvailabilityDescription.contains("dictation-audio.log"))
    }

    func testRefreshDiagnosticLogStatusClearsOptInWhenLogIsMissing() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-status-dictation-audio-\(UUID().uuidString).log")
        viewModel = FeedbackViewModel(diagnosticLogURL: missingURL)
        viewModel.includeDiagnosticLog = true

        viewModel.refreshDiagnosticLogStatus()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.diagnosticLogIsAvailable)
        XCTAssertFalse(viewModel.includeDiagnosticLog)
        XCTAssertEqual(
            viewModel.diagnosticLogAvailabilityDescription,
            "Run dictation or meeting recording once to create this log."
        )
    }

    func testSubmissionIncludesDiagnosticLogWhenOptedIn() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-audio-\(UUID().uuidString).log")
        let logData = Data("dictation_capture_stop duration_s=1.400\n".utf8)
        try logData.write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockService.submitCallCount, 1)
        XCTAssertEqual(mockService.lastPayload?.diagnosticLog?.filename, "dictation-audio.log")
        XCTAssertEqual(
            mockService.lastPayload?.diagnosticLog?.base64,
            logData.base64EncodedString()
        )
    }

    func testSubmissionFailsWhenDiagnosticLogIsSelectedButMissing() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-dictation-audio-\(UUID().uuidString).log")
        viewModel = FeedbackViewModel(diagnosticLogURL: missingURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockService.submitCallCount, 0)
        if case .error(let message) = viewModel.submissionState {
            XCTAssertEqual(message, "No diagnostic log found yet.")
        } else {
            XCTFail("Expected missing diagnostic log error, got \(viewModel.submissionState)")
        }
    }

    func testDiagnosticLogReadFailureEmitsFeedbackOperationTelemetry() async throws {
        let telemetry = FeedbackTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-telemetry-dictation-audio-\(UUID().uuidString).log")
        viewModel = FeedbackViewModel(diagnosticLogURL: missingURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        try await Task.sleep(for: .milliseconds(100))

        let operation = telemetry.snapshot().compactMap { event -> (
            category: String,
            outcome: ObservabilityOutcome,
            screenshotAttached: Bool,
            diagnosticLogAttached: Bool,
            systemInfoIncluded: Bool,
            errorType: String?
        )? in
            guard case .feedbackOperation(
                _,
                _,
                let category,
                let outcome,
                _,
                let screenshotAttached,
                let diagnosticLogAttached,
                let systemInfoIncluded,
                let errorType
            ) = event else {
                return nil
            }
            return (
                category,
                outcome,
                screenshotAttached,
                diagnosticLogAttached,
                systemInfoIncluded,
                errorType
            )
        }.first

        XCTAssertEqual(operation?.category, FeedbackCategory.bug.rawValue)
        XCTAssertEqual(operation?.outcome, .failure)
        XCTAssertEqual(operation?.screenshotAttached, false)
        XCTAssertEqual(operation?.diagnosticLogAttached, true)
        XCTAssertEqual(operation?.systemInfoIncluded, true)
        XCTAssertNotNil(operation?.errorType)
    }

    func testSubmissionTrimsOversizedDiagnosticLogToRecentWindow() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-dictation-audio-\(UUID().uuidString).log")
        // A realistic, all-recent log far larger than the recent byte cap.
        let filler = String(repeating: "x", count: 800)
        let lines = (0..<3000).map { index in
            "\(Self.iso(secondsAgo: Double(3000 - index))) dictation_capture_stop seq=\(index) \(filler)"
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        await waitUntil { mockService.submitCallCount == 1 }

        // The oversized log is trimmed to the recent window, not rejected.
        XCTAssertEqual(mockService.submitCallCount, 1)
        let base64 = try XCTUnwrap(mockService.lastPayload?.diagnosticLog?.base64)
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertLessThanOrEqual(decoded.count, AudioCaptureDiagnostics.recentUploadMaxBytes)
        let text = String(decoding: decoded, as: UTF8.self)
        XCTAssertTrue(text.contains("seq=2999"), "newest line should survive")
        XCTAssertFalse(text.contains("seq=0 "), "oldest line should be trimmed")
    }

    func testSubmissionAttachesOnlyRecentWindowByDefault() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("windowed-dictation-audio-\(UUID().uuidString).log")
        let raw = """
        \(Self.iso(secondsAgo: 240 * 3600)) dictation_capture_stop seq=old
        \(Self.iso(secondsAgo: 3600)) dictation_capture_stop seq=recent
        """ + "\n"
        try Data(raw.utf8).write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        await waitUntil { mockService.submitCallCount == 1 }

        let base64 = try XCTUnwrap(mockService.lastPayload?.diagnosticLog?.base64)
        let text = String(decoding: try XCTUnwrap(Data(base64Encoded: base64)), as: UTF8.self)
        XCTAssertTrue(text.contains("seq=recent"))
        XCTAssertFalse(text.contains("seq=old"), "entries older than the window should be dropped by default")
    }

    func testSubmissionAttachesFullHistoryWhenRequested() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fullhistory-dictation-audio-\(UUID().uuidString).log")
        let raw = """
        \(Self.iso(secondsAgo: 240 * 3600)) dictation_capture_stop seq=old
        \(Self.iso(secondsAgo: 3600)) dictation_capture_stop seq=recent
        """ + "\n"
        try Data(raw.utf8).write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true
        viewModel.includeFullDiagnosticHistory = true

        viewModel.submit()
        await waitUntil { mockService.submitCallCount == 1 }

        let base64 = try XCTUnwrap(mockService.lastPayload?.diagnosticLog?.base64)
        let text = String(decoding: try XCTUnwrap(Data(base64Encoded: base64)), as: UTF8.self)
        XCTAssertTrue(text.contains("seq=recent"))
        XCTAssertTrue(text.contains("seq=old"), "full history should include entries older than the window")
    }

    func testSubmissionFailsWhenDiagnosticLogIsEmpty() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-dictation-audio-\(UUID().uuidString).log")
        try Data().write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        viewModel = FeedbackViewModel(diagnosticLogURL: logURL)
        viewModel.configure(feedbackService: mockService)
        viewModel.message = "Dictation acted weird"
        viewModel.includeDiagnosticLog = true

        viewModel.submit()
        await waitUntil {
            if case .error = viewModel.submissionState { return true }
            return false
        }

        XCTAssertEqual(mockService.submitCallCount, 0)
        if case .error(let message) = viewModel.submissionState {
            XCTAssertEqual(message, "The diagnostic log is empty.")
        } else {
            XCTFail("Expected empty diagnostic log error, got \(viewModel.submissionState)")
        }
    }

    func testTurningDiagnosticsOffResetsFullHistoryOptIn() {
        viewModel.includeDiagnosticLog = true
        viewModel.includeFullDiagnosticHistory = true

        // Disabling diagnostics must clear the advanced full-history opt-in so
        // re-enabling later starts from the privacy-preferring recent window.
        viewModel.includeDiagnosticLog = false

        XCTAssertFalse(viewModel.includeFullDiagnosticHistory)
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
