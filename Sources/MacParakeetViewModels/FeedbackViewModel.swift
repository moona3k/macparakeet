import Foundation
import MacParakeetCore

#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class FeedbackViewModel {
    private static let maxScreenshotSizeBytes = 5 * 1024 * 1024

    // Form fields
    public var category: FeedbackCategory = .bug
    public var message: String = ""
    public var email: String = ""
    public var screenshotData: Data?
    public var screenshotFilename: String?
    public var showSystemInfo: Bool = false

    // Submission state
    public enum SubmissionState: Equatable {
        case idle
        case submitting
        case success
        case error(String)
    }

    public var submissionState: SubmissionState = .idle

    public var canSubmit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && submissionState != .submitting
    }

    public var systemInfo: SystemInfo {
        SystemInfo.current
    }

    private var feedbackService: (any FeedbackServiceProtocol)?
    private var submitTask: Task<Void, Never>?

    public init() {}

    public func configure(feedbackService: any FeedbackServiceProtocol) {
        self.feedbackService = feedbackService
    }

    // MARK: - Screenshot

    public func attachScreenshot() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Attach Screenshot"
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > Self.maxScreenshotSizeBytes {
                submissionState = .error("Screenshot must be 5 MB or smaller.")
                return
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Self.maxScreenshotSizeBytes else {
                submissionState = .error("Screenshot must be 5 MB or smaller.")
                return
            }

            screenshotData = data
            screenshotFilename = url.lastPathComponent
        } catch {
            submissionState = .error("Failed to read screenshot: \(error.localizedDescription)")
        }
        #endif
    }

    public func removeScreenshot() {
        screenshotData = nil
        screenshotFilename = nil
    }

    // MARK: - Submit

    public func submit() {
        guard canSubmit else { return }
        guard let service = feedbackService else { return }

        submitTask?.cancel()
        submissionState = .submitting
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload = FeedbackPayload(
            category: category,
            message: trimmedMessage,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            screenshotBase64: screenshotData?.base64EncodedString(),
            screenshotFilename: screenshotFilename,
            systemInfo: systemInfo
        )

        submitTask = Task { [weak self] in
            guard let self else { return }
            defer { submitTask = nil }

            do {
                try await service.submitFeedback(payload)
                guard !Task.isCancelled else { return }

                submissionState = .success
                // Auto-reset after 3 seconds
                try await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }

                if submissionState == .success {
                    resetForm()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                submissionState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Reset

    public func resetForm() {
        submitTask?.cancel()
        submitTask = nil
        category = .bug
        message = ""
        email = ""
        screenshotData = nil
        screenshotFilename = nil
        showSystemInfo = false
        submissionState = .idle
    }

    public func dismissError() {
        submissionState = .idle
    }
}
