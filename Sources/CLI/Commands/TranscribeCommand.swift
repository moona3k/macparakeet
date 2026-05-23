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

enum YouTubeAudioQualityOption: String, ExpressibleByArgument {
    case appDefault = "app-default"
    case m4a
    case bestAvailable = "best-available"
}

enum TranscribeOutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case text
    case transcript
    case json
}

enum TranscribeSpeechEngine: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appDefault = "app-default"
    case parakeet
    case whisper
}

enum SpeakerDetectionOption: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appDefault = "app-default"
    case on
    case off
}

struct TranscribeCommand: AsyncParsableCommand, CLITelemetryMetadataProviding {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file or YouTube URL.",
        discussion: """
        Telemetry: the root CLI runner emits one privacy-safe `cli_operation` \
        event per invocation; `transcribe` adds allowlisted input/output metadata \
        (input_kind, output_format, json). It never includes the path, URL, \
        transcript, language value, or user content. Disable with \
        `MACPARAKEET_TELEMETRY=0`, `DO_NOT_TRACK=1`, the persistent \
        `macparakeet-cli config set telemetry off`, or the GUI Settings toggle. \
        Auto-disabled in CI (CI/GITHUB_ACTIONS/etc.). See \
        https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md.
        """
    )

    @Argument(help: "Path to audio/video file or YouTube URL to transcribe.")
    var input: String

    @Option(name: .shortAndLong, help: "Output format: text, transcript, json.")
    var format: TranscribeOutputFormat = .text

    @Option(help: "Processing mode: raw, clean, app-default.")
    var mode: TranscribeMode = .appDefault

    @Option(help: "Speech engine: app-default, parakeet, whisper. Default: parakeet; app-default follows the saved GUI preference.")
    var engine: TranscribeSpeechEngine = .parakeet

    @Option(help: "Language hint for Whisper, as a Whisper code such as ko or en. Parakeet ignores this flag.")
    var language: String?

    @Option(help: "Downloaded YouTube audio retention: app-default, keep, delete.")
    var downloadedAudio: DownloadedAudioPolicy = .appDefault

    @Option(help: "YouTube audio quality: app-default, m4a, best-available.")
    var youtubeAudioQuality: YouTubeAudioQualityOption = .appDefault

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Option(name: .long, help: "Speaker detection: app-default, on, off. Default: app-default, which follows the saved GUI/CLI preference.")
    var speakerDetection: SpeakerDetectionOption = .appDefault

    @Flag(help: "Compatibility alias for --speaker-detection off.")
    var noDiarize: Bool = false

    @Flag(help: "Run retained entitlement checks before transcribing. Current free builds remain unlocked.")
    var enforceEntitlements: Bool = false

    @Flag(name: .long, help: "Do not save the completed transcription to MacParakeet history. YouTube audio is temporary.")
    var noHistory: Bool = false

    var cliTelemetryMetadata: CLITelemetry.OperationMetadata {
        CLITelemetry.OperationMetadata(
            command: Self.configuration.commandName ?? "transcribe",
            inputKind: Self.telemetryInputKind(for: input),
            outputFormat: format.rawValue,
            json: format == .json
        )
    }

    func validate() throws {
        if noHistory && downloadedAudio == .keep {
            throw ValidationError("--no-history cannot be combined with --downloaded-audio keep.")
        }
    }

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

    static func resolveYouTubeAudioQuality(
        _ quality: YouTubeAudioQualityOption,
        storedQuality: String?
    ) -> YouTubeAudioQuality {
        switch quality {
        case .bestAvailable:
            return .bestAvailable
        case .m4a:
            return .m4a
        case .appDefault:
            guard let storedQuality,
                  let quality = YouTubeAudioQuality(rawValue: storedQuality) else {
                return .m4a
            }
            return quality
        }
    }

    static func resolveSpeechEngine(
        _ engine: TranscribeSpeechEngine,
        storedEngine: String?,
        storedLanguage: String?,
        explicitLanguage: String?
    ) -> SpeechEngineSelection {
        let preference: SpeechEnginePreference
        let language: String?
        switch engine {
        case .appDefault:
            preference = SpeechEnginePreference(rawValue: storedEngine ?? "") ?? .parakeet
            language = preference == .whisper ? explicitLanguage ?? storedLanguage : nil
        case .parakeet:
            preference = .parakeet
            language = nil
        case .whisper:
            preference = .whisper
            language = explicitLanguage
        }
        return SpeechEngineSelection(engine: preference, language: language)
    }

    static func resolveSpeakerDetection(
        _ option: SpeakerDetectionOption,
        storedEnabled: Bool?,
        noDiarize: Bool
    ) -> Bool {
        if noDiarize { return false }
        switch option {
        case .appDefault:
            return storedEnabled ?? false
        case .on:
            return true
        case .off:
            return false
        }
    }

    static func localFileURL(for input: String) -> URL {
        URL(fileURLWithPath: expandTilde(input))
    }

    static func telemetryInputKind(for input: String) -> ObservabilityInputKind {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if YouTubeURLValidator.isYouTubeURL(trimmedInput) {
            return .youtube
        }
        return Observability.inputKind(for: Self.localFileURL(for: trimmedInput)) ?? .unknown
    }

    func run() async throws {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        var sttClient: STTClient?
        var whisperEngine: WhisperEngine?
        let runResult: Result<Void, Error>
        do {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let customWordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
            let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
            let defaults = macParakeetAppDefaults()
            let speechEngine = Self.resolveSpeechEngine(
                self.engine,
                storedEngine: defaults.string(forKey: SpeechEnginePreference.defaultsKey),
                storedLanguage: SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults),
                explicitLanguage: self.language
            )
            let speakerDetectionEnabled = Self.resolveSpeakerDetection(
                self.speakerDetection,
                storedEnabled: defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool,
                noDiarize: self.noDiarize
            )
            let processingMode = Self.resolveProcessingMode(
                self.mode,
                storedMode: defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
            )
            let resolvedYouTubeAudioQuality = Self.resolveYouTubeAudioQuality(
                self.youtubeAudioQuality,
                storedQuality: defaults.string(forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
            )
            let configuredShouldKeepDownloadedAudio: Bool = switch self.downloadedAudio {
            case .keep:
                true
            case .delete:
                false
            case .appDefault:
                defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool ?? true
            }
            let shouldKeepDownloadedAudio = self.noHistory ? false : configuredShouldKeepDownloadedAudio
            let sttTranscriber: STTTranscribing
            switch speechEngine.engine {
            case .parakeet:
                let createdSTTClient = STTClient()
                sttClient = createdSTTClient
                sttTranscriber = createdSTTClient
            case .whisper:
                let createdWhisperEngine = WhisperEngine(language: speechEngine.language)
                whisperEngine = createdWhisperEngine
                sttTranscriber = createdWhisperEngine
            }
            let audioProcessor = AudioProcessor()
            let youtubeDownloader = YouTubeDownloader(audioQuality: {
                resolvedYouTubeAudioQuality
            })
            let entitlementsService = enforceEntitlements ? makeEntitlementsService() : nil

            if let entitlementsService {
                await entitlementsService.bootstrapTrialIfNeeded()
                await entitlementsService.refreshValidationIfNeeded()
            }

            let diarizationService: DiarizationService? = speakerDetectionEnabled ? DiarizationService() : nil
            let service = TranscriptionService(
                audioProcessor: audioProcessor,
                sttTranscriber: sttTranscriber,
                transcriptionRepo: transcriptionRepo,
                entitlements: entitlementsService,
                customWordRepo: customWordRepo,
                snippetRepo: snippetRepo,
                processingMode: {
                    processingMode
                },
                shouldKeepDownloadedAudio: {
                    shouldKeepDownloadedAudio
                },
                shouldDiarize: { speakerDetectionEnabled },
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

                let progressHandler: @Sendable (TranscriptionProgress) -> Void = { progress in
                    switch progress {
                    case .converting: printProgressLine("Converting audio...")
                    case .downloading(let pct): printProgressLine("Downloading audio... \(pct)%")
                    case .transcribing(let pct): printProgressLine("Transcribing... \(pct)%")
                    case .identifyingSpeakers: printProgressLine("Identifying speakers...")
                    case .finalizing: printProgressLine("Finalizing...")
                    }
                }
                if self.noHistory {
                    result = try await service.transcribeURLTransient(
                        urlString: trimmedInput,
                        onProgress: progressHandler
                    )
                } else {
                    result = try await service.transcribeURL(
                        urlString: trimmedInput,
                        onProgress: progressHandler
                    )
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

                printErr("Transcribing \(url.lastPathComponent) with \(speechEngine.engine.rawValue)...")
                if self.noHistory {
                    result = try await service.transcribeTransient(fileURL: url)
                } else {
                    result = try await service.transcribe(fileURL: url)
                }
            }

            switch format {
            case .json:
                try printJSON(result)
            case .transcript:
                printTranscript(result)
            case .text:
                printText(result)
            }
            runResult = .success(())
        } catch {
            runResult = .failure(error)
        }

        await sttClient?.shutdown()
        await whisperEngine?.unload()
        try emitJSONOrRethrow(json: format == .json) {
            try runResult.get()
        }
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

    static func transcriptOutput(for t: Transcription) -> String {
        for candidate in [t.cleanTranscript, t.rawTranscript] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private func printTranscript(_ t: Transcription) {
        print(Self.transcriptOutput(for: t))
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
