import Foundation
import MacParakeetCore
import SwiftUI

@MainActor
@Observable
public final class TranscriptionViewModel {
    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription?
    public var isTranscribing = false
    public var progress: String = ""
    public var transcriptionProgress: Double?
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
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil

        Task {
            do {
                let result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
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

        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil
        urlInput = ""

        Task {
            do {
                let result = try await service.transcribeURL(urlString: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        // Parse percentage from phase text (e.g. "Downloading... XX%")
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
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
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil
        currentTranscription = nil

        Task {
            do {
                var result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                // Preserve original metadata
                result.fileName = original.fileName
                result.sourceURL = original.sourceURL
                try? transcriptionRepo?.save(result)
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
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
}
