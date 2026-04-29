import ArgumentParser
import Foundation
import MacParakeetCore
import os

enum TranscribeMode: String, ExpressibleByArgument {
    case raw
    case clean
    case appDefault = "app-default"
}

enum DownloadedAudioPolicy: String, ExpressibleByArgument {
    case appDefault = "app-default"
    case keep
    case delete
}

enum TranscribeOutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case text
    case json
}

enum TranscribeSpeechEngine: String, ExpressibleByArgument, CaseIterable, Sendable {
    case parakeet
    case whisper
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file or YouTube URL.",
        discussion: """
        Telemetry: emits one privacy-safe `cli_operation` event per invocation with \
        allowlisted invocation metadata (command, outcome, duration, input_kind, \
        output_format, json, exit_code, error_type). It never includes the path, \
        URL, transcript, language value, or user content. Disable with \
        `MACPARAKEET_TELEMETRY=0`, `DO_NOT_TRACK=1`, the persistent \
        `macparakeet-cli config set telemetry off`, or the GUI Settings toggle. \
        Auto-disabled in CI (CI/GITHUB_ACTIONS/etc.). See \
        https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md.
        """
    )

    @Argument(help: "Path to audio/video file or YouTube URL to transcribe.")
    var input: String

    @Option(name: .shortAndLong, help: "Output format: text, json.")
    var format: TranscribeOutputFormat = .text

    @Option(help: "Processing mode: raw, clean, app-default.")
    var mode: TranscribeMode = .appDefault

    @Option(help: "Speech engine: parakeet, whisper.")
    var engine: TranscribeSpeechEngine = .parakeet

    @Option(help: "Language hint for Whisper, as a Whisper code such as ko or en. Parakeet ignores this flag.")
    var language: String?

    @Option(help: "Downloaded YouTube audio retention: app-default, keep, delete.")
    var downloadedAudio: DownloadedAudioPolicy = .appDefault

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Flag(help: "Disable speaker diarization.")
    var noDiarize: Bool = false

    @Flag(help: "Run retained entitlement checks before transcribing. Current free builds remain unlocked.")
    var enforceEntitlements: Bool = false

    static func resolveProcessingMode(_ mode: TranscribeMode, storedMode: String?) -> Dictation.ProcessingMode {
        switch mode {
        case .raw:
            return .raw
        case .clean:
            return .clean
        case .appDefault:
            return Dictation.ProcessingMode(rawValue: storedMode ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw
        }
    }

    static func localFileURL(for input: String) -> URL {
        URL(fileURLWithPath: expandTilde(input))
    }

    func run() async throws {
        CLITelemetry.configureIfNeeded()
        let cliOperationContext = ObservabilityOperationContext()
        let cliOperationID = cliOperationContext.operationID
        let cliStartedAt = cliOperationContext.startedAt
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputKind: ObservabilityInputKind = YouTubeURLValidator.isYouTubeURL(trimmedInput)
            ? .youtube
            : (Observability.inputKind(for: Self.localFileURL(for: trimmedInput)) ?? .unknown)

        var sttClient: STTClient?
        var whisperEngine: WhisperEngine?
        let runResult: Result<Void, Error>
        do {
            try await Observability.withOperationContext(cliOperationContext) {
                try AppPaths.ensureDirectories()
                let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                let customWordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
                let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
                let sttTranscriber: STTTranscribing
                switch engine {
                case .parakeet:
                    let createdSTTClient = STTClient()
                    sttClient = createdSTTClient
                    sttTranscriber = createdSTTClient
                case .whisper:
                    let createdWhisperEngine = WhisperEngine(language: language)
                    whisperEngine = createdWhisperEngine
                    sttTranscriber = createdWhisperEngine
                }
                let audioProcessor = AudioProcessor()
                let youtubeDownloader = YouTubeDownloader()
                let entitlementsService = enforceEntitlements ? makeEntitlementsService() : nil

                if let entitlementsService {
                    await entitlementsService.bootstrapTrialIfNeeded()
                    await entitlementsService.refreshValidationIfNeeded()
                }

                let diarizationService: DiarizationService? = noDiarize ? nil : DiarizationService()
                let service = TranscriptionService(
                    audioProcessor: audioProcessor,
                    sttTranscriber: sttTranscriber,
                    transcriptionRepo: transcriptionRepo,
                    entitlements: entitlementsService,
                    customWordRepo: customWordRepo,
                    snippetRepo: snippetRepo,
                    processingMode: {
                        let defaults = macParakeetAppDefaults()
                        return Self.resolveProcessingMode(self.mode, storedMode: defaults.string(forKey: "processingMode"))
                    },
                    shouldKeepDownloadedAudio: {
                        switch self.downloadedAudio {
                        case .keep:
                            return true
                        case .delete:
                            return false
                        case .appDefault:
                            let defaults = macParakeetAppDefaults()
                            return defaults.object(forKey: "saveTranscriptionAudio") as? Bool ?? true
                        }
                    },
                    youtubeDownloader: youtubeDownloader,
                    diarizationService: diarizationService
                )

                let result: Transcription

                if YouTubeURLValidator.isYouTubeURL(trimmedInput) {
                    let lastProgressLine = OSAllocatedUnfairLock(initialState: "")
                    @Sendable func printProgressLine(_ line: String) {
                        let shouldPrint = lastProgressLine.withLock { lastLine in
                            guard lastLine != line else { return false }
                            lastLine = line
                            return true
                        }
                        if shouldPrint {
                            printErr(line)
                        }
                    }

                    result = try await service.transcribeURL(urlString: trimmedInput) { progress in
                        switch progress {
                        case .converting: printProgressLine("Converting audio...")
                        case .downloading(let pct): printProgressLine("Downloading audio... \(pct)%")
                        case .transcribing(let pct): printProgressLine("Transcribing... \(pct)%")
                        case .identifyingSpeakers: printProgressLine("Identifying speakers...")
                        case .finalizing: printProgressLine("Finalizing...")
                        }
                    }
                } else {
                    let url = Self.localFileURL(for: trimmedInput)

                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw CLIError.fileNotFound(url.path)
                    }

                    let ext = url.pathExtension.lowercased()
                    guard AudioFileConverter.supportedExtensions.contains(ext) else {
                        throw CLIError.unsupportedFormat(ext)
                    }

                    printErr("Transcribing \(url.lastPathComponent) with \(engine.rawValue)...")
                    result = try await service.transcribe(fileURL: url)
                }

                switch format {
                case .json:
                    try printJSON(result)
                case .text:
                    printText(result)
                }
            }
            runResult = .success(())
        } catch {
            runResult = .failure(error)
        }

        await sttClient?.shutdown()
        await whisperEngine?.unload()
        let cliOutcome: ObservabilityOutcome
        let exitCode: Int
        let errorType: String?
        switch runResult {
        case .success:
            cliOutcome = .success
            exitCode = 0
            errorType = nil
        case .failure(let error):
            cliOutcome = .failure
            exitCode = 1
            errorType = Observability.errorType(for: error)
        }
        await CLITelemetry.sendOperationAndFlush(
            operationID: cliOperationID,
            operationContext: cliOperationContext,
            command: "transcribe",
            outcome: cliOutcome,
            startedAt: cliStartedAt,
            inputKind: inputKind,
            outputFormat: format.rawValue,
            json: format == .json,
            exitCode: exitCode,
            errorType: errorType
        )
        try runResult.get()
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
        if let speakers = t.speakers, !speakers.isEmpty {
            print("Speakers: \(speakers.map(\.label).joined(separator: ", "))")
        }
        print()

        // Show transcript with speaker labels at turn changes when available
        if let words = t.wordTimestamps, !words.isEmpty,
           let speakers = t.speakers, !speakers.isEmpty,
           words.contains(where: { $0.speakerId != nil }) {
            let speakerMap = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
            var lastSpeakerId: String? = nil
            for w in words {
                if let sid = w.speakerId {
                    if sid != lastSpeakerId, let label = speakerMap[sid] {
                        print()
                        print("\(label):")
                    }
                    lastSpeakerId = sid
                }
                Swift.print(w.word, terminator: " ")
            }
            print()
        } else {
            print(t.cleanTranscript ?? t.rawTranscript ?? "(no transcript)")
        }
        print()

        if let words = t.wordTimestamps, !words.isEmpty {
            print("--- Word Timestamps ---")
            for w in words {
                let start = String(format: "%.2f", Double(w.startMs) / 1000.0)
                let end = String(format: "%.2f", Double(w.endMs) / 1000.0)
                let speaker = w.speakerId.map { " [\($0)]" } ?? ""
                print("[\(start)-\(end)] \(w.word) (\(String(format: "%.0f", w.confidence * 100))%)\(speaker)")
            }
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
