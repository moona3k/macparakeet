import Foundation
import MacParakeetCore
import SwiftUI

@MainActor
@Observable
public final class TranscriptionViewModel {
    public enum SourceKind: Sendable {
        case localFile
        case youtubeURL
    }

    public enum ProgressPhase: Int, CaseIterable, Sendable {
        case preparing
        case downloading
        case converting
        case transcribing
        case finalizing
    }

    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription?
    public var isTranscribing = false
    public var progress: String = ""
    public var transcriptionProgress: Double?
    public private(set) var sourceKind: SourceKind = .localFile
    public private(set) var progressPhase: ProgressPhase = .preparing
    public private(set) var progressHeadline: String = "Preparing transcription pipeline"
    public var errorMessage: String?
    public var isDragging = false
    public var urlInput: String = ""

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var activeDropRequestID: UUID?
    private var dropPendingCount = 0
    private var dropAccepted = false
    private static let progressPercentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#)

    public init() {}

    public func configure(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        loadTranscriptions()
    }

    public func loadTranscriptions() {
        guard let repo = transcriptionRepo else { return }
        transcriptions = (try? repo.fetchAll(limit: 50)) ?? []
    }

    public func transcribeFile(url: URL) {
        guard let service = transcriptionService else { return }
        beginTranscription(source: .localFile)

        Task {
            do {
                let result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
            }
        }
    }

    public func transcribeURL() {
        guard let service = transcriptionService else { return }
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoID = YouTubeURLValidator.extractVideoID(url) else { return }

        // Check for existing transcription of the same video
        if let existing = try? transcriptionRepo?.fetchCompletedByVideoID(videoID) {
            currentTranscription = existing
            urlInput = ""
            return
        }

        beginTranscription(source: .youtubeURL)
        urlInput = ""

        Task {
            do {
                let result = try await service.transcribeURL(urlString: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
            }
        }
    }

    public func handleFileDrop(
        providers: [NSItemProvider],
        onAccepted: (() -> Void)? = nil
    ) -> Bool {
        guard !isTranscribing else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        let requestID = UUID()
        activeDropRequestID = requestID
        dropPendingCount = fileProviders.count
        dropAccepted = false

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                let droppedURL: URL?
                if let data = item as? Data {
                    droppedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    droppedURL = nil
                }

                Task { @MainActor in
                    guard self.activeDropRequestID == requestID else { return }
                    defer {
                        self.dropPendingCount -= 1
                        if self.dropPendingCount == 0 {
                            if !self.dropAccepted {
                                self.errorMessage = self.unsupportedDropMessage
                            }
                            self.activeDropRequestID = nil
                        }
                    }

                    guard let droppedURL else { return }
                    let ext = droppedURL.pathExtension.lowercased()
                    guard AudioFileConverter.supportedExtensions.contains(ext) else { return }
                    guard !self.dropAccepted, !self.isTranscribing else { return }

                    self.dropAccepted = true
                    self.errorMessage = nil
                    onAccepted?()
                    self.transcribeFile(url: droppedURL)
                }
            }
        }
        return true
    }

    private var unsupportedDropMessage: String {
        let formats = AudioFileConverter.supportedExtensions
            .sorted()
            .map { $0.uppercased() }
            .joined(separator: ", ")
        return "Unsupported file type. Supported formats: \(formats)."
    }

    public func retranscribe(_ original: Transcription) {
        guard let service = transcriptionService,
              let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let url = URL(fileURLWithPath: filePath)
        beginTranscription(source: .localFile)
        currentTranscription = nil

        Task {
            do {
                var result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                // Preserve original metadata
                result.fileName = original.fileName
                result.sourceURL = original.sourceURL
                try? transcriptionRepo?.save(result)
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
            }
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        guard let repo = transcriptionRepo else { return }

        if transcription.sourceURL != nil, let audioPath = transcription.filePath {
            try? FileManager.default.removeItem(atPath: audioPath)
        }
        _ = try? repo.delete(id: transcription.id)
        if currentTranscription?.id == transcription.id {
            currentTranscription = nil
        }
        loadTranscriptions()
    }

    // MARK: - Progress State

    private func beginTranscription(source: SourceKind) {
        sourceKind = source
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
        errorMessage = nil
    }

    private func endTranscription() {
        isTranscribing = false
        progress = ""
        transcriptionProgress = nil
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
    }

    private func updateProgress(with phaseText: String) {
        progress = phaseText
        transcriptionProgress = Self.parseProgressFraction(from: phaseText)
        progressPhase = Self.parsePhase(from: phaseText)
        progressHeadline = Self.headline(for: progressPhase)
    }

    private static func parsePhase(from phaseText: String) -> ProgressPhase {
        let normalized = phaseText.lowercased()
        if normalized.contains("download") {
            return .downloading
        }
        if normalized.contains("convert") {
            return .converting
        }
        if normalized.contains("transcrib") {
            return .transcribing
        }
        if normalized.contains("saving") || normalized.contains("final") {
            return .finalizing
        }
        if normalized.contains("prepar") {
            return .preparing
        }
        return .transcribing
    }

    private static func headline(for phase: ProgressPhase) -> String {
        switch phase {
        case .preparing:
            return "Preparing transcription pipeline"
        case .downloading:
            return "Fetching source audio"
        case .converting:
            return "Normalizing audio stream"
        case .transcribing:
            return "Running speech recognition"
        case .finalizing:
            return "Finalizing transcript"
        }
    }

    private static func parseProgressFraction(from phaseText: String) -> Double? {
        let range = NSRange(phaseText.startIndex..., in: phaseText)
        guard let match = progressPercentRegex.firstMatch(in: phaseText, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: phaseText),
              let percent = Double(phaseText[numberRange]),
              percent >= 0 else {
            return nil
        }

        return min(percent, 100) / 100
    }
}
