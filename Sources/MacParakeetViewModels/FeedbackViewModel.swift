import Foundation
import MacParakeetCore

#if canImport(AppKit)
import AppKit
#endif

public struct FeedbackScreenshotAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let data: Data

    public init(id: UUID = UUID(), filename: String, data: Data) {
        self.id = id
        self.filename = filename
        self.data = data
    }
}

@MainActor
@Observable
public final class FeedbackViewModel {
    private static let maxScreenshotSizeBytes = 5 * 1024 * 1024
    private static let maxScreenshotCount = 5

    // Form fields
    public var category: FeedbackCategory = .bug
    public var message: String = ""
    public var email: String = ""
    public var screenshotAttachments: [FeedbackScreenshotAttachment] = []
    public var showSystemInfo: Bool = false
    private var pendingScreenshotFilename: String?

    public var screenshotData: Data? {
        get { screenshotAttachments.first?.data }
        set {
            guard let newValue else {
                screenshotAttachments = []
                pendingScreenshotFilename = nil
                return
            }
            let filename = screenshotFilename ?? pendingScreenshotFilename ?? "screenshot.png"
            screenshotAttachments = [FeedbackScreenshotAttachment(filename: filename, data: newValue)]
            pendingScreenshotFilename = nil
        }
    }

    public var screenshotFilename: String? {
        get { screenshotAttachments.first?.filename }
        set {
            guard let newValue else {
                screenshotAttachments = []
                pendingScreenshotFilename = nil
                return
            }
            guard let first = screenshotAttachments.first else {
                pendingScreenshotFilename = newValue
                return
            }
            screenshotAttachments[0] = FeedbackScreenshotAttachment(id: first.id, filename: newValue, data: first.data)
        }
    }

    public var canAttachMoreScreenshots: Bool {
        screenshotAttachments.count < Self.maxScreenshotCount
    }

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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        attachScreenshots(from: panel.urls)
        #endif
    }

    public func handleScreenshotDrop(url: URL) {
        attachScreenshots(from: [url])
    }

    public func removeScreenshot(id: FeedbackScreenshotAttachment.ID) {
        screenshotAttachments.removeAll { $0.id == id }
    }

    public func removeScreenshot() {
        screenshotAttachments = []
        pendingScreenshotFilename = nil
    }

    private func attachScreenshots(from urls: [URL]) {
        var nextAttachments = screenshotAttachments
        for url in urls {
            guard nextAttachments.count < Self.maxScreenshotCount else {
                submissionState = .error("Attach up to \(Self.maxScreenshotCount) screenshots.")
                break
            }

            do {
                nextAttachments.append(try readScreenshotAttachment(from: url))
            } catch {
                submissionState = .error(error.localizedDescription)
                break
            }
        }
        screenshotAttachments = nextAttachments
    }

    private func readScreenshotAttachment(from url: URL) throws -> FeedbackScreenshotAttachment {
        do {
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > Self.maxScreenshotSizeBytes {
                throw ScreenshotAttachmentError.tooLarge
            }

            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxScreenshotSizeBytes else {
                throw ScreenshotAttachmentError.tooLarge
            }

            return FeedbackScreenshotAttachment(filename: url.lastPathComponent, data: data)
        } catch {
            if error is ScreenshotAttachmentError {
                throw error
            }
            throw ScreenshotAttachmentError.readFailed(error.localizedDescription)
        }
    }

    private enum ScreenshotAttachmentError: LocalizedError {
        case tooLarge
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "Each screenshot must be 5 MB or smaller."
            case .readFailed(let detail):
                return "Failed to read screenshot: \(detail)"
            }
        }
    }

    // MARK: - Submit

    public func submit() {
        guard canSubmit else { return }
        guard let service = feedbackService else { return }

        submitTask?.cancel()
        submissionState = .submitting
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationContext = Observability.childOperationContext()
        let screenshots = screenshotAttachments.map {
            FeedbackScreenshot(filename: $0.filename, base64: $0.data.base64EncodedString())
        }

        let payload = FeedbackPayload(
            category: category,
            message: trimmedMessage,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            screenshotBase64: screenshots.first?.base64,
            screenshotFilename: screenshots.first?.filename,
            screenshots: screenshots,
            systemInfo: systemInfo
        )
        let hasScreenshots = !payload.screenshots.isEmpty

        submitTask = Task { [weak self] in
            guard let self else { return }
            defer { submitTask = nil }

            do {
                try await service.submitFeedback(payload)
                guard !Task.isCancelled else { return }

                Telemetry.send(.feedbackSubmitted(category: payload.category.rawValue))
                Telemetry.send(.feedbackOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    category: payload.category.rawValue,
                    outcome: .success,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    screenshotAttached: hasScreenshots,
                    systemInfoIncluded: true,
                    errorType: nil
                ))
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
                Telemetry.send(.feedbackOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    category: payload.category.rawValue,
                    outcome: .failure,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    screenshotAttached: hasScreenshots,
                    systemInfoIncluded: true,
                    errorType: Observability.errorType(for: error)
                ))
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
        screenshotAttachments = []
        pendingScreenshotFilename = nil
        showSystemInfo = false
        submissionState = .idle
    }

    public func dismissError() {
        submissionState = .idle
    }
}
