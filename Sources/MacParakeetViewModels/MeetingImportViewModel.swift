import Foundation
import MacParakeetCore

/// App-owned state for one external-recording import. Its task deliberately
/// outlives the sheet that observes it, so dismissal never abandons a durable
/// meeting after publication.
@MainActor
@Observable
public final class MeetingImportViewModel {
    public struct Draft: Equatable, Sendable {
        public let sourceURL: URL
        public var title: String
        public var startedAt: Date
        fileprivate let defaultTitle: String
    }

    public enum Stage: Equatable, Sendable {
        case preparing
        case published
        case transcribing
        case finishing
        case automating

        public var message: String {
            switch self {
            case .preparing: "Preparing audio"
            case .published: "Meeting saved"
            case .transcribing: "Transcribing recording"
            case .finishing: "Finishing meeting"
            case .automating: "Running meeting notes"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case completed
        case partial
        case needsRetry
        case failed
    }

    public struct TerminalResult: Sendable {
        public let transcription: Transcription?
        public let outcome: Outcome
        public let warnings: [String]
        public let errorMessage: String?
    }

    public private(set) var draft: Draft?
    public private(set) var stage: Stage?
    public private(set) var terminalResult: TerminalResult?
    public private(set) var validationMessage: String?
    public private(set) var isStopping = false

    public var isProcessing: Bool { processingTask != nil }
    public var canImport: Bool {
        guard let draft, !isProcessing else { return false }
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var hasPublishedMeeting: Bool { publishedMeeting != nil }

    private typealias Run =
        @Sendable (
            MeetingImportRequest, @escaping @Sendable (MeetingImportProgress) -> Void
        ) async throws -> MeetingImportResult

    private var run: Run?
    private var onMeetingPublished: @MainActor @Sendable (Transcription) -> Void = { _ in }
    private var processingTask: Task<Void, Never>?
    private var processingGeneration = UUID()
    private var publishedMeeting: Transcription?

    public init() {}

    public init(
        run:
            @escaping @Sendable (
                MeetingImportRequest, @escaping @Sendable (MeetingImportProgress) -> Void
            ) async throws -> MeetingImportResult,
        onMeetingPublished: @escaping @MainActor @Sendable (Transcription) -> Void = { _ in }
    ) {
        self.run = run
        self.onMeetingPublished = onMeetingPublished
    }

    public func configure(
        service: MeetingImportService,
        onMeetingPublished: @escaping @MainActor @Sendable (Transcription) -> Void = { _ in }
    ) {
        run = { request, progress in
            try await service.importMeeting(request, onProgress: progress)
        }
        self.onMeetingPublished = onMeetingPublished
    }

    /// Validates a picker selection before showing it in the form. A new
    /// selection is intentionally refused while a prior import is running.
    @discardableResult
    public func select(sourceURL: URL) -> Bool {
        guard !isProcessing else { return false }
        do {
            let defaults = try MeetingImportRequest(sourceURL: sourceURL).resolveDefaults()
            draft = Draft(
                sourceURL: sourceURL, title: defaults.title,
                startedAt: defaults.startedAt, defaultTitle: defaults.title
            )
            terminalResult = nil
            validationMessage = nil
            publishedMeeting = nil
            return true
        } catch {
            draft = nil
            validationMessage = Self.message(for: error)
            return false
        }
    }

    public func updateTitle(_ title: String) {
        guard var draft, !isProcessing else { return }
        draft.title = title
        self.draft = draft
        validationMessage =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter a meeting title." : nil
    }

    public func updateStartedAt(_ startedAt: Date) {
        guard var draft, !isProcessing else { return }
        draft.startedAt = startedAt
        self.draft = draft
    }

    @discardableResult
    public func startImport() -> Bool {
        guard let run, let draft, canImport else { return false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MeetingImportRequest(
            sourceURL: draft.sourceURL,
            titleOverride: title == draft.defaultTitle ? nil : title,
            startedAt: draft.startedAt
        )
        let generation = UUID()
        processingGeneration = generation
        stage = .preparing
        terminalResult = nil
        validationMessage = nil
        publishedMeeting = nil
        isStopping = false

        processingTask = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (MeetingImportProgress) -> Void = { [weak self] update in
                Task { @MainActor in
                    guard let self, self.processingGeneration == generation, self.isProcessing else { return }
                    self.apply(update)
                }
            }
            do {
                let result = try await run(request, progress)
                guard processingGeneration == generation else { return }
                publishIfNeeded(result.transcription)
                terminalResult = TerminalResult(
                    transcription: result.transcription,
                    outcome: Self.outcome(for: result.completion),
                    warnings: result.warnings.map {
                        $0.userFacingMessage(for: result.transcription.status)
                    },
                    errorMessage: nil
                )
            } catch is CancellationError {
                guard processingGeneration == generation else { return }
                if let publishedMeeting {
                    terminalResult = TerminalResult(
                        transcription: publishedMeeting,
                        outcome: .needsRetry,
                        warnings: ["Transcription was stopped. The saved meeting can be retried."],
                        errorMessage: nil
                    )
                } else {
                    terminalResult = nil
                    validationMessage = "Import stopped before the meeting was saved."
                }
            } catch {
                guard processingGeneration == generation else { return }
                if let publishedMeeting {
                    terminalResult = TerminalResult(
                        transcription: publishedMeeting,
                        outcome: .needsRetry,
                        warnings: ["Transcription needs another try. The saved meeting is available in Meetings."],
                        errorMessage: nil
                    )
                } else {
                    terminalResult = TerminalResult(
                        transcription: nil, outcome: .failed, warnings: [], errorMessage: Self.message(for: error)
                    )
                }
            }
            guard processingGeneration == generation else { return }
            stage = nil
            isStopping = false
            processingTask = nil
        }
        return true
    }

    public func stop() {
        guard isProcessing else { return }
        isStopping = true
        processingTask?.cancel()
    }

    /// Removes terminal presentation state after the person has opened or
    /// dismissed it. It never cancels a still-running import.
    public func acknowledgeResult() {
        guard !isProcessing else { return }
        terminalResult = nil
        validationMessage = nil
        draft = nil
        publishedMeeting = nil
    }

    private func apply(_ update: MeetingImportProgress) {
        switch update {
        case .preparingMedia:
            stage = .preparing
        case .published(let transcription):
            stage = .published
            publishIfNeeded(transcription)
        case .transcription(let progress):
            switch progress {
            case .identifyingSpeakers, .finalizing:
                stage = .finishing
            case .converting, .downloading, .preparingSpeechModel, .transcribing:
                stage = .transcribing
            }
        case .automation:
            stage = .automating
        }
    }

    private func publishIfNeeded(_ transcription: Transcription) {
        guard publishedMeeting == nil else { return }
        publishedMeeting = transcription
        onMeetingPublished(transcription)
    }

    private static func outcome(for completion: MeetingImportResult.Completion) -> Outcome {
        switch completion {
        case .completed: .completed
        case .partial: .partial
        case .needsRetry: .needsRetry
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? MeetingImportError {
            return error.errorDescription ?? "Choose another recording and try again."
        }
        return "Couldn't import this recording. Choose another file and try again."
    }
}
