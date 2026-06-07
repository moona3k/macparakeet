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
    private nonisolated static let diagnosticLogFilename = "dictation-audio.log"

    // Form fields
    public var category: FeedbackCategory = .bug
    public var message: String = ""
    public var email: String = ""
    public var screenshotAttachments: [FeedbackScreenshotAttachment] = []
    public var includeDiagnosticLog: Bool = false {
        didSet {
            // Turning diagnostics off clears the advanced full-history opt-in,
            // so re-enabling always starts from the privacy-preferring recent
            // window rather than silently re-attaching the entire log.
            if !includeDiagnosticLog {
                includeFullDiagnosticHistory = false
            }
        }
    }
    /// Advanced opt-in: attach the entire local diagnostics history instead of
    /// just the recent window. Off by default — uploads scope to the last week
    /// (see `DiagnosticLogScope.recent`). Only meaningful while
    /// `includeDiagnosticLog` is on; cleared whenever `includeDiagnosticLog`
    /// flips off.
    public var includeFullDiagnosticHistory: Bool = false
    public var showSystemInfo: Bool = false
    public private(set) var diagnosticLogIsAvailable: Bool = false
    public private(set) var diagnosticLogAvailabilityDescription: String = "Run dictation or meeting recording once to create this log."
    private var pendingScreenshotFilename: String?

    public var screenshotData: Data? {
        get { screenshotAttachments.first?.data }
        set {
            guard let newValue else {
                screenshotAttachments = []
                pendingScreenshotFilename = nil
                return
            }
            if let first = screenshotAttachments.first {
                screenshotAttachments[0] = FeedbackScreenshotAttachment(
                    id: first.id,
                    filename: first.filename,
                    data: newValue
                )
            } else {
                let filename = pendingScreenshotFilename ?? "screenshot.png"
                screenshotAttachments = [FeedbackScreenshotAttachment(filename: filename, data: newValue)]
            }
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

    public var diagnosticLogURL: URL {
        diagnosticLogURLOverride ?? AudioCaptureDiagnostics.diagnosticLogFileURL
    }

    public var diagnosticLogFilename: String {
        Self.diagnosticLogFilename
    }

    private let diagnosticLogURLOverride: URL?
    private var feedbackService: (any FeedbackServiceProtocol)?
    private var submitTask: Task<Void, Never>?
    private var diagnosticLogStatusTask: Task<Void, Never>?

    public init(diagnosticLogURL: URL? = nil) {
        self.diagnosticLogURLOverride = diagnosticLogURL
    }

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

    // MARK: - Diagnostic Log

    public func refreshDiagnosticLogStatus() {
        diagnosticLogStatusTask?.cancel()

        let diagnosticLogURL = diagnosticLogURL
        diagnosticLogStatusTask = Task { [weak self] in
            let status = await Self.loadDiagnosticLogStatus(diagnosticLogURL: diagnosticLogURL)
            guard let self, !Task.isCancelled else { return }

            diagnosticLogIsAvailable = status.isAvailable
            diagnosticLogAvailabilityDescription = status.description
            if !status.isAvailable {
                includeDiagnosticLog = false
            }
            diagnosticLogStatusTask = nil
        }
    }

    private nonisolated static func loadDiagnosticLogStatus(diagnosticLogURL: URL) async -> DiagnosticLogStatus {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: diagnosticLogURL.path) else {
                return DiagnosticLogStatus(
                    isAvailable: false,
                    description: "Run dictation or meeting recording once to create this log."
                )
            }

            let fileSize = try? diagnosticLogURL
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize
            if let fileSize, fileSize >= 0 {
                let sizeDescription = ByteCountFormatter.string(
                    fromByteCount: Int64(fileSize),
                    countStyle: .file
                )
                return DiagnosticLogStatus(
                    isAvailable: true,
                    description: "\(Self.diagnosticLogFilename) · \(sizeDescription)"
                )
            }

            return DiagnosticLogStatus(
                isAvailable: true,
                description: Self.diagnosticLogFilename
            )
        }.value
    }

    private struct DiagnosticLogStatus: Sendable {
        let isAvailable: Bool
        let description: String
    }

    private nonisolated static func readDiagnosticLogAttachmentIfNeeded(
        includeDiagnosticLog: Bool,
        includeFullHistory: Bool,
        diagnosticLogURL: URL
    ) async throws -> FeedbackDiagnosticLog? {
        guard includeDiagnosticLog else { return nil }

        return try await Task.detached(priority: .userInitiated) {
            do {
                guard FileManager.default.fileExists(atPath: diagnosticLogURL.path) else {
                    throw DiagnosticLogAttachmentError.missing
                }

                let data = try Data(contentsOf: diagnosticLogURL)
                // Scope to a recent window by default; the on-disk file is
                // already byte-capped, so `.full` only lifts the time window.
                let scoped = AudioCaptureDiagnostics.scopedLogForUpload(
                    String(decoding: data, as: UTF8.self),
                    scope: includeFullHistory ? .full : .recent
                )
                guard !scoped.isEmpty else {
                    throw DiagnosticLogAttachmentError.empty
                }

                return FeedbackDiagnosticLog(
                    filename: Self.diagnosticLogFilename,
                    base64: Data(scoped.utf8).base64EncodedString()
                )
            } catch {
                if error is DiagnosticLogAttachmentError {
                    throw error
                }
                throw DiagnosticLogAttachmentError.readFailed(error.localizedDescription)
            }
        }.value
    }

    private enum DiagnosticLogAttachmentError: LocalizedError {
        case missing
        case empty
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "No diagnostic log found yet."
            case .empty:
                return "The diagnostic log is empty."
            case .readFailed(let detail):
                return "Failed to read diagnostic log: \(detail)"
            }
        }
    }

    // MARK: - Submit

    public func submit() {
        guard canSubmit else { return }
        guard let service = feedbackService else { return }

        submitTask?.cancel()
        submissionState = .submitting

        let shouldIncludeDiagnosticLog = includeDiagnosticLog
        let shouldIncludeFullDiagnosticHistory = includeFullDiagnosticHistory
        let diagnosticLogURL = diagnosticLogURL
        let category = category
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshots = screenshotAttachments.map {
            FeedbackScreenshot(filename: $0.filename, base64: $0.data.base64EncodedString())
        }
        let systemInfo = systemInfo

        submitTask = Task { [weak self] in
            guard let self else { return }
            defer { submitTask = nil }

            let operationContext = Observability.childOperationContext()
            do {
                let diagnosticLog = try await Self.readDiagnosticLogAttachmentIfNeeded(
                    includeDiagnosticLog: shouldIncludeDiagnosticLog,
                    includeFullHistory: shouldIncludeFullDiagnosticHistory,
                    diagnosticLogURL: diagnosticLogURL
                )
                guard !Task.isCancelled else { return }

                let payload = FeedbackPayload(
                    category: category,
                    message: trimmedMessage,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                    screenshotBase64: screenshots.first?.base64,
                    screenshotFilename: screenshots.first?.filename,
                    screenshots: screenshots,
                    diagnosticLog: diagnosticLog,
                    systemInfo: systemInfo
                )
                let hasScreenshots = !payload.screenshots.isEmpty
                let hasDiagnosticLog = payload.diagnosticLog != nil

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
                        diagnosticLogAttached: hasDiagnosticLog,
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
                        diagnosticLogAttached: hasDiagnosticLog,
                        systemInfoIncluded: true,
                        errorType: Observability.errorType(for: error)
                    ))
                    submissionState = .error(error.localizedDescription)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Telemetry.send(.feedbackOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    category: category.rawValue,
                    outcome: .failure,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    screenshotAttached: !screenshots.isEmpty,
                    diagnosticLogAttached: shouldIncludeDiagnosticLog,
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
        includeDiagnosticLog = false
        includeFullDiagnosticHistory = false
        pendingScreenshotFilename = nil
        showSystemInfo = false
        submissionState = .idle
        refreshDiagnosticLogStatus()
    }

    public func dismissError() {
        submissionState = .idle
    }
}
