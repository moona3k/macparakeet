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

enum TranscribeParakeetModel: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appDefault = "app-default"
    case v3
    case v2
}

enum SpeakerDetectionOption: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appDefault = "app-default"
    case on
    case off
}

struct ResolvedSpeakerDetection: Equatable, Sendable {
    let enabled: Bool
    let constraint: SpeakerDiarizationConstraint?
}

struct TranscribeCommand: AsyncParsableCommand, CLITelemetryMetadataProviding {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file or media URL.",
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

    @Argument(help: "One or more audio/video file paths, folders, YouTube URLs, or HTTP(S) media URLs supported by yt-dlp. Multiple inputs (or --output-dir) transcribe in sequence, writing one file each.")
    var inputs: [String]

    @Option(name: .long, help: "Directory to write one transcript per input. Implies batch mode; created if missing. When omitted with multiple inputs, the current directory is used.")
    var outputDir: String?

    @Option(name: .shortAndLong, help: "Output format: text, transcript, json.")
    var format: TranscribeOutputFormat = .text

    @Option(help: "Processing mode: raw, clean, app-default.")
    var mode: TranscribeMode = .appDefault

    @Option(help: "Speech engine: app-default, parakeet, whisper. Default: parakeet; app-default follows the saved GUI preference.")
    var engine: TranscribeSpeechEngine = .parakeet

    @Option(help: "Language hint for Whisper, as a Whisper code such as ko or en. Parakeet ignores this flag.")
    var language: String?

    @Option(name: .long, help: "Parakeet build: app-default, v3 (multilingual), v2 (English-only). app-default follows the saved preference; ignored for Whisper.")
    var parakeetModel: TranscribeParakeetModel = .appDefault

    @Option(help: "Downloaded media retention: app-default, keep, delete.")
    var downloadedAudio: DownloadedAudioPolicy = .appDefault

    @Option(name: .customLong("media-audio-quality"), help: "Downloaded media audio quality: app-default, m4a, best-available.")
    var mediaAudioQuality: YouTubeAudioQualityOption?

    @Option(name: .customLong("youtube-audio-quality"), help: .hidden)
    var legacyYouTubeAudioQuality: YouTubeAudioQualityOption?

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Option(name: .long, help: "Speaker detection: app-default, on, off. Default: app-default, which follows the saved GUI/CLI preference.")
    var speakerDetection: SpeakerDetectionOption = .appDefault

    @Option(name: .long, help: "Exact speaker count for this run. Mutually exclusive with --speaker-min/--speaker-max; implies speaker detection for app-default.")
    var speakerCount: Int?

    @Option(name: .long, help: "Minimum speaker count for this run. Can be combined with --speaker-max; implies speaker detection for app-default.")
    var speakerMin: Int?

    @Option(name: .long, help: "Maximum speaker count for this run. Can be combined with --speaker-min; implies speaker detection for app-default.")
    var speakerMax: Int?

    @Flag(help: "Compatibility alias for --speaker-detection off.")
    var noDiarize: Bool = false

    @Flag(help: "Run retained entitlement checks before transcribing. Current free builds remain unlocked.")
    var enforceEntitlements: Bool = false

    @Flag(name: .long, help: "Do not save the completed transcription to MacParakeet history. Downloaded media is temporary.")
    var noHistory: Bool = false

    var cliTelemetryMetadata: CLITelemetry.OperationMetadata {
        CLITelemetry.OperationMetadata(
            command: Self.configuration.commandName ?? "transcribe",
            inputKind: Self.telemetryInputKind(for: inputs.first ?? ""),
            outputFormat: format.rawValue,
            json: format == .json
        )
    }

    var effectiveMediaAudioQuality: YouTubeAudioQualityOption {
        mediaAudioQuality ?? legacyYouTubeAudioQuality ?? .appDefault
    }

    func validate() throws {
        if inputs.isEmpty {
            throw ValidationError("Provide at least one file path, folder, or media URL to transcribe.")
        }
        if noHistory && downloadedAudio == .keep {
            throw ValidationError("--no-history cannot be combined with --downloaded-audio keep.")
        }
        if mediaAudioQuality != nil && legacyYouTubeAudioQuality != nil {
            throw ValidationError("--media-audio-quality and --youtube-audio-quality cannot be combined.")
        }
        try Self.validateSpeakerConstraintOptions(
            speakerDetection: speakerDetection,
            noDiarize: noDiarize,
            speakerCount: speakerCount,
            speakerMin: speakerMin,
            speakerMax: speakerMax
        )
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

    static func resolveMediaAudioQuality(
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

    static func resolveParakeetModelVariant(
        _ option: TranscribeParakeetModel,
        storedVariant: ParakeetModelVariant
    ) -> ParakeetModelVariant {
        switch option {
        case .appDefault:
            return storedVariant
        case .v3:
            return .v3
        case .v2:
            return .v2
        }
    }

    static func resolveSpeakerDetection(
        _ option: SpeakerDetectionOption,
        storedEnabled: Bool?,
        noDiarize: Bool
    ) -> Bool {
        resolveSpeakerDetection(
            option,
            storedEnabled: storedEnabled,
            noDiarize: noDiarize,
            speakerCount: nil,
            speakerMin: nil,
            speakerMax: nil
        ).enabled
    }

    static func resolveSpeakerDetection(
        _ option: SpeakerDetectionOption,
        storedEnabled: Bool?,
        noDiarize: Bool,
        speakerCount: Int?,
        speakerMin: Int?,
        speakerMax: Int?
    ) -> ResolvedSpeakerDetection {
        if noDiarize { return ResolvedSpeakerDetection(enabled: false, constraint: nil) }

        let constraint = speakerConstraint(
            speakerCount: speakerCount,
            speakerMin: speakerMin,
            speakerMax: speakerMax
        )

        switch option {
        case .appDefault:
            return ResolvedSpeakerDetection(
                enabled: constraint != nil || (storedEnabled ?? false),
                constraint: constraint
            )
        case .on:
            return ResolvedSpeakerDetection(enabled: true, constraint: constraint)
        case .off:
            return ResolvedSpeakerDetection(enabled: false, constraint: nil)
        }
    }

    static func validateSpeakerConstraintOptions(
        speakerDetection: SpeakerDetectionOption,
        noDiarize: Bool,
        speakerCount: Int?,
        speakerMin: Int?,
        speakerMax: Int?
    ) throws {
        let hasConstraint = speakerCount != nil || speakerMin != nil || speakerMax != nil
        guard hasConstraint else { return }

        if noDiarize {
            throw ValidationError("--no-diarize cannot be combined with speaker count constraints.")
        }
        if speakerDetection == .off {
            throw ValidationError("--speaker-detection off cannot be combined with speaker count constraints.")
        }
        if let speakerCount, speakerCount < 1 {
            throw ValidationError("--speaker-count must be at least 1.")
        }
        if let speakerMin, speakerMin < 1 {
            throw ValidationError("--speaker-min must be at least 1.")
        }
        if let speakerMax, speakerMax < 1 {
            throw ValidationError("--speaker-max must be at least 1.")
        }
        if speakerCount != nil && (speakerMin != nil || speakerMax != nil) {
            throw ValidationError("--speaker-count cannot be combined with --speaker-min or --speaker-max.")
        }
        if let speakerMin, let speakerMax, speakerMin > speakerMax {
            throw ValidationError("--speaker-min cannot be greater than --speaker-max.")
        }
    }

    static func speakerConstraint(
        speakerCount: Int?,
        speakerMin: Int?,
        speakerMax: Int?
    ) -> SpeakerDiarizationConstraint? {
        if let speakerCount {
            return .exact(speakerCount)
        }
        guard speakerMin != nil || speakerMax != nil else { return nil }
        if let speakerMin, let speakerMax, speakerMin == speakerMax {
            return .exact(speakerMin)
        }
        return .range(min: speakerMin, max: speakerMax)
    }

    static func makeDiarizationService(
        for speakerDetection: ResolvedSpeakerDetection
    ) -> DiarizationService? {
        guard speakerDetection.enabled else { return nil }
        guard let constraint = speakerDetection.constraint else {
            return DiarizationService()
        }
        return DiarizationService(speakerConstraint: constraint)
    }

    static func localFileURL(for input: String) -> URL {
        URL(fileURLWithPath: expandTilde(input))
    }

    static func telemetryInputKind(for input: String) -> ObservabilityInputKind {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if YouTubeURLValidator.isYouTubeURL(trimmedInput) {
            return .youtube
        }
        if DownloadableMediaURLValidator.isDownloadableMediaURL(trimmedInput) {
            return .media
        }
        return Observability.inputKind(for: Self.localFileURL(for: trimmedInput)) ?? .unknown
    }

    static func isDownloadableURLInput(_ input: String) -> Bool {
        downloadableURLInput(input) != nil
    }

    static func downloadableURLInput(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard YouTubeURLValidator.isYouTubeURL(trimmed)
            || DownloadableMediaURLValidator.isDownloadableMediaURL(trimmed)
        else {
            return nil
        }
        return trimmed
    }

    func run() async throws {
        // Expand folder arguments and de-duplicate. Single resolved input with
        // no --output-dir keeps the original stdout behavior; anything else is
        // batch/file-output mode.
        let resolvedInputs = Self.expandInputs(
            inputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
        let writeToFiles = resolvedInputs.count > 1 || outputDir != nil

        var sttClient: STTClient?
        var whisperEngine: WhisperEngine?
        let runResult: Result<Void, Error>
        do {
            guard !resolvedInputs.isEmpty else {
                throw ValidationError("No transcribable inputs found — folders contained no supported audio/video files.")
            }
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
            let resolvedSpeakerDetection = Self.resolveSpeakerDetection(
                self.speakerDetection,
                storedEnabled: defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool,
                noDiarize: self.noDiarize,
                speakerCount: self.speakerCount,
                speakerMin: self.speakerMin,
                speakerMax: self.speakerMax
            )
            let processingMode = Self.resolveProcessingMode(
                self.mode,
                storedMode: defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
            )
            let resolvedMediaAudioQuality = Self.resolveMediaAudioQuality(
                self.effectiveMediaAudioQuality,
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
                let parakeetVariant = Self.resolveParakeetModelVariant(
                    self.parakeetModel,
                    storedVariant: SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
                )
                let createdSTTClient = STTClient(modelVersion: parakeetVariant.asrModelVersion)
                sttClient = createdSTTClient
                sttTranscriber = createdSTTClient
            case .whisper:
                let createdWhisperEngine = WhisperEngine(language: speechEngine.language)
                whisperEngine = createdWhisperEngine
                sttTranscriber = createdWhisperEngine
            }
            let audioProcessor = AudioProcessor()
            let youtubeDownloader = YouTubeDownloader(audioQuality: {
                resolvedMediaAudioQuality
            })
            let entitlementsService = enforceEntitlements ? makeEntitlementsService() : nil

            if let entitlementsService {
                await entitlementsService.bootstrapTrialIfNeeded()
                await entitlementsService.refreshValidationIfNeeded()
            }

            let diarizationService = Self.makeDiarizationService(for: resolvedSpeakerDetection)
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
                shouldDiarize: { resolvedSpeakerDetection.enabled },
                youtubeDownloader: youtubeDownloader,
                diarizationService: diarizationService
            )

            if writeToFiles {
                try await runBatch(
                    inputs: resolvedInputs,
                    service: service,
                    speechEngine: speechEngine
                )
            } else {
                let result = try await transcribeOne(
                    input: resolvedInputs[0],
                    service: service,
                    speechEngine: speechEngine
                )
                switch format {
                case .json:
                    try printJSON(result)
                case .transcript:
                    printTranscript(result)
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
        try emitJSONOrRethrow(json: format == .json) {
            try runResult.get()
        }
    }

    // MARK: - Batch

    /// Transcribe each resolved input in sequence, writing one transcript file
    /// per input. A failed input is logged to stderr and counted, never
    /// aborting the run; if any failed, throws `CLIBatchError.someFailed` so the
    /// process exits non-zero.
    private func runBatch(
        inputs: [String],
        service: TranscriptionService,
        speechEngine: SpeechEngineSelection
    ) async throws {
        let dir = try Self.prepareOutputDir(outputDir)
        var ok = 0
        var failed = 0
        for (index, input) in inputs.enumerated() {
            printErr("[\(index + 1)/\(inputs.count)] \(Self.displayName(for: input))")
            do {
                let result = try await transcribeOne(
                    input: input,
                    service: service,
                    speechEngine: speechEngine
                )
                let url = try Self.writeOutput(result, to: dir, format: format)
                printErr("  \u{2192} \(url.path)")
                ok += 1
            } catch {
                printErr("  \u{2717} \(error.localizedDescription)")
                failed += 1
            }
        }
        if failed == 0 {
            printErr("Done: \(ok) transcribed \u{2192} \(dir.path)")
        } else {
            printErr("Done: \(ok) ok, \(failed) failed \u{2192} \(dir.path)")
            throw CLIBatchError.someFailed(ok: ok, failed: failed)
        }
    }

    /// Transcribe a single resolved input (media URL or local file) and
    /// return the record. Progress is reported on stderr; this throws on
    /// missing/unsupported files or transcription errors so callers can either
    /// surface it (single mode) or count and continue (batch mode).
    private func transcribeOne(
        input: String,
        service: TranscriptionService,
        speechEngine: SpeechEngineSelection
    ) async throws -> Transcription {
        let lastProgressLine = OSAllocatedUnfairLock(initialState: "")
        @Sendable func printProgressLine(_ line: String) {
            let shouldPrint = lastProgressLine.withLock { lastLine in
                guard lastLine != line else { return false }
                lastLine = line
                return true
            }
            if shouldPrint { printErr(line) }
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

        if let mediaURL = Self.downloadableURLInput(input) {
            if noHistory {
                return try await service.transcribeURLTransient(urlString: mediaURL, onProgress: progressHandler)
            }
            return try await service.transcribeURL(urlString: mediaURL, onProgress: progressHandler)
        }

        let url = Self.localFileURL(for: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(url.path)
        }
        let ext = url.pathExtension.lowercased()
        guard AudioFileConverter.supportedExtensions.contains(ext) else {
            throw CLIError.unsupportedFormat(ext)
        }
        printErr("Transcribing \(url.lastPathComponent) with \(speechEngine.engine.rawValue)...")
        if noHistory {
            return try await service.transcribeTransient(fileURL: url)
        }
        return try await service.transcribe(fileURL: url)
    }

    /// Expand folder arguments into their supported audio files and
    /// de-duplicate while preserving order. Media URLs and individual file
    /// paths pass through unchanged (existence/support is checked per file in
    /// `transcribeOne`).
    static func expandInputs(_ inputs: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for input in inputs {
            if let mediaURL = Self.downloadableURLInput(input) {
                if seen.insert(mediaURL).inserted { result.append(mediaURL) }
                continue
            }
            let url = localFileURL(for: input).standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                for file in AudioFileEnumerator.expand(urls: [url]).files where seen.insert(file.path).inserted {
                    result.append(file.path)
                }
            } else if seen.insert(url.standardizedFileURL.path).inserted {
                // Standardized key matches the folder-expansion keys, so a loose
                // file that also lives inside a dropped folder isn't transcribed twice.
                result.append(url.path)
            }
        }
        return result
    }

    static func prepareOutputDir(_ outputDir: String?) throws -> URL {
        let dir = outputDir.map { URL(fileURLWithPath: expandTilde($0), isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func displayName(for input: String) -> String {
        if let mediaURL = Self.downloadableURLInput(input) {
            return displayNameForMediaURL(mediaURL)
        }
        return localFileURL(for: input).lastPathComponent
    }

    static func displayNameForMediaURL(_ mediaURL: String) -> String {
        let trimmed = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let queryOrFragmentIndex = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
            return trimmed
        }
        return String(trimmed[..<queryOrFragmentIndex])
    }

    /// Write one transcript file for `t` into `dir`, named after the source and
    /// suffixed by format (`.json` for json, `.txt` otherwise). Never
    /// overwrites — collisions get a `-2`, `-3`, … suffix.
    static func writeOutput(_ t: Transcription, to dir: URL, format: TranscribeOutputFormat) throws -> URL {
        let ext = format == .json ? "json" : "txt"
        let base = sanitizedBasename(t.fileName)
        let url = uniqueURL(dir.appendingPathComponent(base).appendingPathExtension(ext))
        let contents: String
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            contents = String(data: try encoder.encode(t), encoding: .utf8) ?? ""
        case .transcript:
            contents = transcriptOutput(for: t)
        case .text:
            contents = plainTextOutput(for: t)
        }
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func sanitizedBasename(_ name: String) -> String {
        // Only strip a *known* media extension — otherwise a metadata-derived
        // title with a natural dot (e.g. "Dr. Smith Lecture 1") would lose its
        // tail to `deletingPathExtension`.
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        let stem = AudioFileConverter.supportedExtensions.contains(ext) ? ns.deletingPathExtension : name
        let candidate = stem.isEmpty ? name : stem
        var invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        invalid.formUnion(.newlines)
        invalid.formUnion(.controlCharacters)
        let safe = candidate.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "transcript" : safe
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// String form of the verbose `--format text` output, for file writing.
    /// (Single-input stdout still routes through `printText` so its exact
    /// layout is preserved.)
    static func plainTextOutput(for t: Transcription) -> String {
        var lines: [String] = ["", "File: \(t.fileName)"]
        if let ms = t.durationMs {
            let seconds = ms / 1000
            lines.append("Duration: \(seconds / 60)m \(seconds % 60)s")
        }
        if let speakers = t.speakers, !speakers.isEmpty {
            lines.append("Speakers: \(speakers.map(\.label).joined(separator: ", "))")
        }
        lines.append("")

        if let words = t.wordTimestamps, !words.isEmpty,
           let speakers = t.speakers, !speakers.isEmpty,
           words.contains(where: { $0.speakerId != nil }) {
            let speakerMap = speakerLabelMap(speakers)
            var lastSpeakerId: String?
            var current = ""
            for w in words {
                if let sid = w.speakerId, sid != lastSpeakerId {
                    if !current.isEmpty { lines.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                    if let label = speakerMap[sid] { lines.append(""); lines.append("\(label):") }
                    lastSpeakerId = sid
                }
                current += w.word + " "
            }
            if !current.isEmpty { lines.append(current.trimmingCharacters(in: .whitespaces)) }
        } else {
            lines.append(t.cleanTranscript ?? t.rawTranscript ?? "(no transcript)")
        }

        if let words = t.wordTimestamps, !words.isEmpty {
            lines.append("")
            lines.append("--- Word Timestamps ---")
            for w in words {
                let start = String(format: "%.2f", Double(w.startMs) / 1000.0)
                let end = String(format: "%.2f", Double(w.endMs) / 1000.0)
                let speaker = w.speakerId.map { " [\($0)]" } ?? ""
                lines.append("[\(start)-\(end)] \(w.word) (\(String(format: "%.0f", w.confidence * 100))%)\(speaker)")
            }
        }
        return lines.joined(separator: "\n")
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
            let speakerMap = Self.speakerLabelMap(speakers)
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

    private static func speakerLabelMap(_ speakers: [SpeakerInfo]) -> [String: String] {
        Dictionary(speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
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

enum CLIBatchError: Error, LocalizedError {
    case someFailed(ok: Int, failed: Int)

    var errorDescription: String? {
        switch self {
        case .someFailed(let ok, let failed):
            return "\(failed) input\(failed == 1 ? "" : "s") failed to transcribe (\(ok) succeeded)."
        }
    }
}
