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
    public var errorMessage: String?
    public var isDragging = false
    public var urlInput: String = ""

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?

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
        errorMessage = nil

        Task {
            do {
                progress = "Transcribing \(url.lastPathComponent)..."
                let result = try await service.transcribe(fileURL: url)
                currentTranscription = result
                isTranscribing = false
                progress = ""
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                loadTranscriptions()
            }
        }
    }

    public func transcribeURL() {
        guard let service = transcriptionService else { return }
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeURLValidator.isYouTubeURL(url) else { return }

        isTranscribing = true
        progress = "Downloading audio..."
        errorMessage = nil
        urlInput = ""

        Task {
            do {
                progress = "Transcribing..."
                let result = try await service.transcribeURL(urlString: url)
                currentTranscription = result
                isTranscribing = false
                progress = ""
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                loadTranscriptions()
            }
        }
    }

    public func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                guard AudioFileConverter.supportedExtensions.contains(ext) else { return }

                Task { @MainActor in
                    self.transcribeFile(url: url)
                }
            }
        }
        return true
    }

    public func deleteTranscription(_ transcription: Transcription) {
        guard let repo = transcriptionRepo else { return }
        _ = try? repo.delete(id: transcription.id)
        if currentTranscription?.id == transcription.id {
            currentTranscription = nil
        }
        loadTranscriptions()
    }
}
