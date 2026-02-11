import ArgumentParser
import Foundation
import MacParakeetCore

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file or YouTube URL."
    )

    @Argument(help: "Path to audio/video file or YouTube URL to transcribe.")
    var input: String

    @Option(name: .shortAndLong, help: "Output format: text, json.")
    var format: String = "text"

    func run() async throws {
        // Set up services
        try AppPaths.ensureDirectories()
        let dbManager = try DatabaseManager(path: AppPaths.databasePath)
        let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let pythonBootstrap = PythonBootstrap()
        let sttClient = STTClient(pythonBootstrap: pythonBootstrap)
        let audioProcessor = AudioProcessor()
        let youtubeDownloader = YouTubeDownloader(pythonBootstrap: pythonBootstrap)

        let service = TranscriptionService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            transcriptionRepo: transcriptionRepo,
            youtubeDownloader: youtubeDownloader
        )

        let result: Transcription

        if YouTubeURLValidator.isYouTubeURL(input) {
            result = try await service.transcribeURL(urlString: input) { phase in
                print(phase)
            }
        } else {
            let url = URL(fileURLWithPath: input)

            guard FileManager.default.fileExists(atPath: input) else {
                throw CLIError.fileNotFound(input)
            }

            let ext = url.pathExtension.lowercased()
            guard AudioFileConverter.supportedExtensions.contains(ext) else {
                throw CLIError.unsupportedFormat(ext)
            }

            print("Transcribing \(url.lastPathComponent)...")
            result = try await service.transcribe(fileURL: url)
        }

        switch format {
        case "json":
            printJSON(result)
        default:
            printText(result)
        }

        await sttClient.shutdown()
    }

    private func printText(_ t: Transcription) {
        print()
        print("File: \(t.fileName)")
        if let ms = t.durationMs {
            let seconds = ms / 1000
            let min = seconds / 60
            let sec = seconds % 60
            print("Duration: \(min)m \(sec)s")
        }
        print()
        print(t.rawTranscript ?? "(no transcript)")
        print()

        if let words = t.wordTimestamps, !words.isEmpty {
            print("--- Word Timestamps ---")
            for w in words {
                let start = String(format: "%.2f", Double(w.startMs) / 1000.0)
                let end = String(format: "%.2f", Double(w.endMs) / 1000.0)
                print("[\(start)-\(end)] \(w.word) (\(String(format: "%.0f", w.confidence * 100))%)")
            }
        }
    }

    private func printJSON(_ t: Transcription) {
        var dict: [String: Any] = [
            "id": t.id.uuidString,
            "fileName": t.fileName,
            "status": "\(t.status)",
        ]
        if let text = t.rawTranscript { dict["text"] = text }
        if let ms = t.durationMs { dict["durationMs"] = ms }
        if let words = t.wordTimestamps {
            dict["words"] = words.map { w in
                [
                    "word": w.word,
                    "startMs": w.startMs,
                    "endMs": w.endMs,
                    "confidence": w.confidence,
                ] as [String: Any]
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8)
        {
            print(str)
        }
    }
}

enum CLIError: Error, LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext). Supported: \(AudioFileConverter.supportedExtensions.sorted().joined(separator: ", "))"
        }
    }
}
