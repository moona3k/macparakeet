import Foundation
import MacParakeetCore

#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class FeedbackViewModel {
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
            let data = try Data(contentsOf: url)
            let maxSize = 5 * 1024 * 1024 // 5 MB
            guard data.count <= maxSize else {
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

        submissionState = .submitting

        let payload = FeedbackPayload(
            category: category,
            message: message,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshotBase64: screenshotData?.base64EncodedString(),
            screenshotFilename: screenshotFilename,
            systemInfo: systemInfo
        )

        Task {
            do {
                try await service.submitFeedback(payload)
                submissionState = .success
                // Auto-reset after 3 seconds
                try? await Task.sleep(for: .seconds(3))
                if submissionState == .success {
                    resetForm()
                }
            } catch {
                submissionState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Reset

    public func resetForm() {
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
