import ArgumentParser
import Foundation
import MacParakeetCore

enum TranscribeMode: String, ExpressibleByArgument {
    case raw
    case clean
    case formal
    case email
    case code
    case appDefault = "app-default"
}

enum DownloadedAudioPolicy: String, ExpressibleByArgument {
    case appDefault = "app-default"
    case keep
    case delete
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file or YouTube URL."
    )

    @Argument(help: "Path to audio/video file or YouTube URL to transcribe.")
    var input: String

    @Option(name: .shortAndLong, help: "Output format: text, json.")
    var format: String = "text"

    @Option(help: "Processing mode: raw, clean, formal, email, code, app-default.")
    var mode: TranscribeMode = .appDefault

    @Option(help: "Downloaded YouTube audio retention: app-default, keep, delete.")
    var downloadedAudio: DownloadedAudioPolicy = .appDefault

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Flag(help: "Enable entitlement/trial checks to mirror GUI gating behavior.")
    var enforceEntitlements: Bool = false

    static func resolveProcessingMode(_ mode: TranscribeMode, storedMode: String?) -> Dictation.ProcessingMode {
        switch mode {
        case .raw:
            return .raw
        case .clean:
            return .clean
        case .formal:
            return .formal
        case .email:
            return .email
        case .code:
            return .code
        case .appDefault:
            return Dictation.ProcessingMode(rawValue: storedMode ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw
        }
    }

    func run() async throws {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Set up services
        try AppPaths.ensureDirectories()
        let dbPathOpt = database?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDBPath = (dbPathOpt?.isEmpty == false) ? dbPathOpt! : AppPaths.databasePath
        if resolvedDBPath != AppPaths.databasePath {
            let dir = URL(fileURLWithPath: resolvedDBPath).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let dbManager = try DatabaseManager(path: resolvedDBPath)
        let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let customWordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
        let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
        let sttClient = STTClient()
        let llmService = MLXLLMService()
        let audioProcessor = AudioProcessor()
        let youtubeDownloader = YouTubeDownloader()
        let entitlementsService = enforceEntitlements ? makeEntitlementsService() : nil

        if let entitlementsService {
            await entitlementsService.bootstrapTrialIfNeeded()
            await entitlementsService.refreshValidationIfNeeded()
        }

        let service = TranscriptionService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            transcriptionRepo: transcriptionRepo,
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            llmService: llmService,
            processingMode: {
                Self.resolveProcessingMode(self.mode, storedMode: UserDefaults.standard.string(forKey: "processingMode"))
            },
            shouldKeepDownloadedAudio: {
                switch self.downloadedAudio {
                case .keep:
                    return true
                case .delete:
                    return false
                case .appDefault:
                    return UserDefaults.standard.object(forKey: "saveTranscriptionAudio") as? Bool ?? true
                }
            },
            youtubeDownloader: youtubeDownloader
        )

        let result: Transcription

        if YouTubeURLValidator.isYouTubeURL(trimmedInput) {
            result = try await service.transcribeURL(urlString: trimmedInput) { phase in
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

    private func makeEntitlementsService() -> EntitlementsService {
        let checkoutURLString =
            (Bundle.main.object(forInfoDictionaryKey: "MacParakeetCheckoutURL") as? String)
            ?? ProcessInfo.processInfo.environment["MACPARAKEET_CHECKOUT_URL"]
        let checkoutURL = checkoutURLString
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(URL.init(string:))

        let expectedVariantID: Int? = {
            if let n = Bundle.main.object(forInfoDictionaryKey: "MacParakeetLemonSqueezyVariantID") as? NSNumber {
                return n.intValue
            }
            let s =
                (Bundle.main.object(forInfoDictionaryKey: "MacParakeetLemonSqueezyVariantID") as? String)
                ?? ProcessInfo.processInfo.environment["MACPARAKEET_LS_VARIANT_ID"]
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }()

        let config = LicensingConfig(checkoutURL: checkoutURL, expectedVariantID: expectedVariantID)
        let serviceName = Bundle.main.bundleIdentifier ?? "com.macparakeet"
        let store = KeychainKeyValueStore(service: serviceName)
        return EntitlementsService(config: config, store: store, api: LemonSqueezyLicenseAPI())
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
        print(t.cleanTranscript ?? t.rawTranscript ?? "(no transcript)")
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
        if let text = t.rawTranscript { dict["rawTranscript"] = text }
        if let text = t.cleanTranscript { dict["cleanTranscript"] = text }
        if let preferred = (t.cleanTranscript ?? t.rawTranscript) { dict["text"] = preferred }
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
    case localLLMSmokeTestFailed(String)
    case invalidQuestion
    case transcriptFileNotFound(String)
    case transcriptFileReadFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext). Supported: \(AudioFileConverter.supportedExtensions.sorted().joined(separator: ", "))"
        case .localLLMSmokeTestFailed(let output):
            return "LLM smoke test failed (unexpected response): \(output)"
        case .invalidQuestion:
            return "Question cannot be empty."
        case .transcriptFileNotFound(let path):
            return "Transcript file not found: \(path)"
        case .transcriptFileReadFailed(let path, let underlying):
            return "Failed to read transcript file at \(path): \(underlying.localizedDescription)"
        }
    }
}
