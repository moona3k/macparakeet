import ArgumentParser
import Foundation
import MacParakeetCore
import os

enum RetranscribeRecordKind: String, ExpressibleByArgument, CaseIterable {
    case auto
    case dictation
    case transcription
    case meeting
}

enum CLIRetranscribeError: Error, LocalizedError {
    case noRetainedAudio(kind: String, id: UUID)
    case missingAudio(path: String)
    case ambiguousRecord(String)
    case noMatch(String)
    case kindMismatch(expected: RetranscribeRecordKind, actual: RetranscribeRecordKind)
    case dictationDoesNotSupportSpeakerOptions

    var errorDescription: String? {
        switch self {
        case .noRetainedAudio(let kind, let id):
            return "The \(kind) '\(id.uuidString)' has no retained source audio to retranscribe."
        case .missingAudio(let path):
            return "Retained source audio is missing: \(path)"
        case .ambiguousRecord(let value):
            return "Multiple saved records match '\(value)'. Retry with --kind or a longer UUID prefix."
        case .noMatch(let value):
            return "No saved dictation, transcription, or meeting matching '\(value)'."
        case .kindMismatch(let expected, let actual):
            return "Record is a \(actual.rawValue), not a \(expected.rawValue). Retry with --kind \(actual.rawValue)."
        case .dictationDoesNotSupportSpeakerOptions:
            return "Speaker-detection options apply only to saved transcriptions and meetings, not dictations."
        }
    }

    var isValidationMisuse: Bool {
        switch self {
        case .kindMismatch, .dictationDoesNotSupportSpeakerOptions:
            return true
        case .noRetainedAudio, .missingAudio, .ambiguousRecord, .noMatch:
            return false
        }
    }
}

enum RetranscribeTarget {
    case dictation(Dictation)
    case transcription(Transcription)
    case meeting(Transcription)

    var kind: RetranscribeRecordKind {
        switch self {
        case .dictation:
            return .dictation
        case .transcription:
            return .transcription
        case .meeting:
            return .meeting
        }
    }

    var id: UUID {
        switch self {
        case .dictation(let dictation):
            return dictation.id
        case .transcription(let transcription), .meeting(let transcription):
            return transcription.id
        }
    }
}

enum RetranscribeRecordPayload: Encodable {
    case dictation(Dictation)
    case transcription(Transcription)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .dictation(let dictation):
            try dictation.encode(to: encoder)
        case .transcription(let transcription):
            try transcription.encode(to: encoder)
        }
    }
}

struct RetranscribeResult: Encodable {
    let kind: String
    let id: UUID
    let shortID: String
    let sourcePath: String
    let updatedAt: Date
    let record: RetranscribeRecordPayload

    init(kind: RetranscribeRecordKind, sourcePath: String, dictation: Dictation) {
        self.kind = kind.rawValue
        self.id = dictation.id
        self.shortID = String(dictation.id.uuidString.prefix(8))
        self.sourcePath = sourcePath
        self.updatedAt = dictation.updatedAt
        self.record = .dictation(dictation)
    }

    init(kind: RetranscribeRecordKind, sourcePath: String, transcription: Transcription) {
        self.kind = kind.rawValue
        self.id = transcription.id
        self.shortID = String(transcription.id.uuidString.prefix(8))
        self.sourcePath = sourcePath
        self.updatedAt = transcription.updatedAt
        self.record = .transcription(transcription)
    }
}

struct RetranscribeCommand: AsyncParsableCommand, CLITelemetryMetadataProviding {
    static let configuration = CommandConfiguration(
        commandName: "retranscribe",
        abstract: "Retranscribe retained source audio for an existing saved record in place.",
        discussion: """
        Resolves a saved dictation, transcription, or meeting by UUID, UUID \
        prefix, or exact title/name where safe. The command requires --update \
        because it replaces transcript-derived fields on the existing row.
        """
    )

    @Argument(help: "Saved record UUID, UUID prefix, or exact transcription/meeting title.")
    var record: String

    @Option(help: "Record kind to resolve: auto, dictation, transcription, meeting.")
    var kind: RetranscribeRecordKind = .auto

    @Flag(help: "Required. Confirms this command updates the existing saved record in place.")
    var update: Bool = false

    @Flag(name: .long, help: "Emit the updated record as JSON.")
    var json: Bool = false

    @Flag(name: .long, help: "Emit a success/failure envelope.")
    var envelope: Bool = false

    @Option(help: "Text processing mode: raw, clean, app-default.")
    var mode: TranscribeMode = .appDefault

    @Option(help: "Speech engine: app-default, parakeet, nemotron, whisper, cohere. Parakeet is the local default; app-default follows the saved GUI preference.")
    var engine: TranscribeSpeechEngine = .parakeet

    @Option(help: "Language hint for Nemotron, Whisper, or Cohere, such as ko, en, or en-US. Cohere requires a supported language; Parakeet and the English-only Nemotron build ignore this flag.")
    var language: String?

    @Option(name: .long, help: "Parakeet build: app-default, v3 (English + supported European languages), v2 (English word timestamps), unified (readable English, no word timestamps). Ignored for Nemotron, Cohere, and Whisper.")
    var parakeetModel: TranscribeParakeetModel = .appDefault

    @Option(name: .long, help: "Nemotron Beta build: app-default, multilingual-1120ms, english-1120ms. Ignored for Parakeet, Cohere, and Whisper.")
    var nemotronModel: TranscribeNemotronModel = .appDefault

    @Option(name: .long, help: "Speaker detection for saved transcriptions/meetings: app-default, on, off.")
    var speakerDetection: SpeakerDetectionOption = .appDefault

    @Option(name: .long, help: "Exact speaker count for this retranscription. Mutually exclusive with --speaker-min/--speaker-max.")
    var speakerCount: Int?

    @Option(name: .long, help: "Minimum speaker count for this retranscription. Can be combined with --speaker-max.")
    var speakerMin: Int?

    @Option(name: .long, help: "Maximum speaker count for this retranscription. Can be combined with --speaker-min.")
    var speakerMax: Int?

    @Flag(help: "Compatibility alias for --speaker-detection off.")
    var noDiarize: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    var cliTelemetryMetadata: CLITelemetry.OperationMetadata {
        CLITelemetry.OperationMetadata(
            command: Self.configuration.commandName ?? "retranscribe",
            outputFormat: (json || envelope) ? "json" : nil,
            json: json || envelope
        )
    }

    func validate() throws {
        guard update else {
            throw ValidationError("Pass --update to confirm replacing transcript fields on the existing saved record.")
        }
        if json && envelope {
            throw ValidationError("--json and --envelope cannot be combined.")
        }
        try TranscribeCommand.validateSpeakerConstraintOptions(
            speakerDetection: speakerDetection,
            noDiarize: noDiarize,
            speakerCount: speakerCount,
            speakerMin: speakerMin,
            speakerMax: speakerMax
        )
    }

    func run() async throws {
        let wantsMachineReadableOutput = json || envelope
        let runResult: Result<RetranscribeResult, Error>
        var sttClient: STTClient?

        do {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
            let customWordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
            let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
            let promptResultRepo = PromptResultRepository(dbQueue: dbManager.dbQueue)
            let defaults = macParakeetAppDefaults()
            let target = try Self.resolveTarget(
                record,
                kind: kind,
                transcriptionRepo: transcriptionRepo,
                dictationRepo: dictationRepo
            )
            if case .dictation = target {
                try validateDictationOnlyOptions()
            }

            let speechEngine = resolveSpeechEngine(defaults: defaults)
            try TranscribeCommand.validateCohereLanguageOverride(language, speechEngine: speechEngine)
            let parakeetVariant = TranscribeCommand.resolveParakeetModelVariant(
                parakeetModel,
                storedVariant: SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
            )
            let nemotronVariant = TranscribeCommand.resolveNemotronModelVariant(
                nemotronModel,
                storedVariant: SpeechEnginePreference.nemotronModelVariant(defaults: defaults)
            )
            if speechEngine.engine == .nemotron, nemotronVariant.isEnglishOnly, language != nil {
                printErr("Note: --language is ignored by the English-only Nemotron build.")
            }

            let client = STTClient(
                parakeetModelVariant: parakeetVariant,
                speechEngine: speechEngine.engine,
                nemotronModelVariant: nemotronVariant,
                defaults: defaults
            )
            sttClient = client

            switch target {
            case .dictation(let dictation):
                let result = try await retranscribeDictation(
                    dictation,
                    sttClient: client,
                    speechEngine: speechEngine,
                    dictationRepo: dictationRepo,
                    customWordRepo: customWordRepo,
                    snippetRepo: snippetRepo,
                    defaults: defaults
                )
                runResult = .success(result)
            case .transcription(let transcription):
                let result = try await retranscribeTranscription(
                    transcription,
                    speechEngine: speechEngine,
                    transcriptionRepo: transcriptionRepo,
                    promptResultRepo: promptResultRepo,
                    customWordRepo: customWordRepo,
                    snippetRepo: snippetRepo,
                    defaults: defaults,
                    sttTranscriber: client
                )
                runResult = .success(result)
            case .meeting(let transcription):
                let result = try await retranscribeMeeting(
                    transcription,
                    speechEngine: speechEngine,
                    transcriptionRepo: transcriptionRepo,
                    promptResultRepo: promptResultRepo,
                    customWordRepo: customWordRepo,
                    snippetRepo: snippetRepo,
                    defaults: defaults,
                    sttTranscriber: client
                )
                runResult = .success(result)
            }
        } catch {
            runResult = .failure(error)
        }

        await sttClient?.shutdown()

        try emitJSONOrRethrow(json: wantsMachineReadableOutput) {
            let result = try runResult.get()
            try printResult(result)
        }
    }

    private func resolveSpeechEngine(defaults: UserDefaults) -> SpeechEngineSelection {
        TranscribeCommand.resolveSpeechEngine(
            engine,
            storedEngine: defaults.string(forKey: SpeechEnginePreference.defaultsKey),
            storedLanguage: SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults),
            storedNemotronLanguage: SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults),
            storedCohereLanguage: SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults),
            explicitLanguage: language
        )
    }

    private func validateDictationOnlyOptions() throws {
        let hasSpeakerOption = speakerDetection != .appDefault
            || noDiarize
            || speakerCount != nil
            || speakerMin != nil
            || speakerMax != nil
        if hasSpeakerOption {
            throw CLIRetranscribeError.dictationDoesNotSupportSpeakerOptions
        }
    }

    private func retranscribeDictation(
        _ original: Dictation,
        sttClient: STTClient,
        speechEngine: SpeechEngineSelection,
        dictationRepo: DictationRepository,
        customWordRepo: CustomWordRepository,
        snippetRepo: TextSnippetRepository,
        defaults: UserDefaults
    ) async throws -> RetranscribeResult {
        let sourceURL = try Self.retainedAudioURL(path: original.audioPath, kind: "dictation", id: original.id)
        let progress = Self.progressHandler(prefix: "Transcribing saved dictation")
        printErr("Retranscribing dictation \(original.id.uuidString) with \(speechEngine.engine.rawValue)...")
        let sttResult = try await sttClient.transcribe(
            audioPath: sourceURL.path,
            job: .dictation,
            speechEngine: speechEngine,
            onProgress: progress.sttProgress
        )

        let processingMode = TranscribeCommand.resolveProcessingMode(
            mode,
            storedMode: defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
        )
        var customWords: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if processingMode.usesDeterministicPipeline {
            customWords = try customWordRepo.fetchEnabled()
            snippets = try snippetRepo.fetchEnabled()
        }
        for trigger in UserDefaultsAppRuntimePreferences(defaults: defaults).voiceReturnTriggers {
            snippets.append(TextSnippet(
                trigger: trigger,
                expansion: KeyAction.returnKey.label,
                action: .returnKey
            ))
        }

        let refinement = await TextRefinementService().refine(
            rawText: sttResult.text,
            mode: processingMode,
            customWords: customWords,
            snippets: snippets
        )
        let finalText = refinement.text ?? sttResult.text
        var updated = Self.clearingDictationFormatterMetadata(original)
        updated.durationMs = Self.dictationDurationMs(from: sttResult, fallback: original.durationMs)
        updated.rawTranscript = sttResult.text
        updated.cleanTranscript = refinement.text
        updated.processingMode = processingMode
        updated.status = .completed
        updated.errorMessage = nil
        updated.updatedAt = Date()
        updated.wordCount = Observability.wordCount(finalText)
        updated.engine = sttResult.engine.rawValue
        updated.engineVariant = sttResult.engineVariant
        updated.language = SpeechEnginePreference.normalizeKnownLanguage(sttResult.language)

        try dictationRepo.save(updated)
        if !refinement.expandedSnippetIDs.isEmpty {
            try? snippetRepo.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }
        return RetranscribeResult(kind: .dictation, sourcePath: sourceURL.path, dictation: updated)
    }

    static func clearingDictationFormatterMetadata(_ dictation: Dictation) -> Dictation {
        var updated = dictation
        updated.aiFormatterProfileID = nil
        updated.aiFormatterProfileName = nil
        updated.aiFormatterProfileMatchKind = nil
        return updated
    }

    private func retranscribeTranscription(
        _ original: Transcription,
        speechEngine: SpeechEngineSelection,
        transcriptionRepo: TranscriptionRepository,
        promptResultRepo: PromptResultRepository,
        customWordRepo: CustomWordRepository,
        snippetRepo: TextSnippetRepository,
        defaults: UserDefaults,
        sttTranscriber: STTTranscribing
    ) async throws -> RetranscribeResult {
        let sourceURL = try Self.retainedAudioURL(path: original.filePath, kind: "transcription", id: original.id)
        let service = makeTranscriptionService(
            sttTranscriber: sttTranscriber,
            transcriptionRepo: transcriptionRepo,
            promptResultRepo: promptResultRepo,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            defaults: defaults
        )
        printErr("Retranscribing \(original.fileName) with \(speechEngine.engine.rawValue)...")
        let updated = try await service.retranscribe(
            existing: original,
            fileURL: sourceURL,
            source: Self.telemetrySource(for: original.sourceType),
            speechEngineOverride: speechEngine,
            onProgress: Self.progressHandler(prefix: "Retranscribing").transcriptionProgress
        )
        let preserved = Self.preserveOriginalTranscriptionMetadata(updated, original: original)
        try transcriptionRepo.save(preserved)
        return RetranscribeResult(kind: .transcription, sourcePath: sourceURL.path, transcription: preserved)
    }

    private func retranscribeMeeting(
        _ original: Transcription,
        speechEngine: SpeechEngineSelection,
        transcriptionRepo: TranscriptionRepository,
        promptResultRepo: PromptResultRepository,
        customWordRepo: CustomWordRepository,
        snippetRepo: TextSnippetRepository,
        defaults: UserDefaults,
        sttTranscriber: STTTranscribing
    ) async throws -> RetranscribeResult {
        let mixedAudioURL = try Self.retainedAudioURL(path: original.filePath, kind: "meeting", id: original.id)
        let service = makeTranscriptionService(
            sttTranscriber: sttTranscriber,
            transcriptionRepo: transcriptionRepo,
            promptResultRepo: promptResultRepo,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            defaults: defaults
        )
        printErr("Retranscribing meeting \(original.fileName) with \(speechEngine.engine.rawValue)...")
        let progress = Self.progressHandler(prefix: "Retranscribing meeting")
        let updated: Transcription
        if let archived = Self.archivedMeetingRecording(for: original, mixedAudioURL: mixedAudioURL) {
            updated = try await service.retranscribeMeeting(
                existing: original,
                recording: archived,
                speechEngineOverride: speechEngine,
                onProgress: progress.transcriptionProgress
            )
        } else {
            updated = try await service.retranscribe(
                existing: original,
                fileURL: mixedAudioURL,
                source: .meeting,
                speechEngineOverride: speechEngine,
                onProgress: progress.transcriptionProgress
            )
        }
        let preserved = Self.preserveOriginalTranscriptionMetadata(updated, original: original)
        try transcriptionRepo.save(preserved)
        return RetranscribeResult(kind: .meeting, sourcePath: mixedAudioURL.path, transcription: preserved)
    }

    private func makeTranscriptionService(
        sttTranscriber: STTTranscribing,
        transcriptionRepo: TranscriptionRepository,
        promptResultRepo: PromptResultRepository,
        customWordRepo: CustomWordRepository,
        snippetRepo: TextSnippetRepository,
        defaults: UserDefaults
    ) -> TranscriptionService {
        let resolvedSpeakerDetection = TranscribeCommand.resolveSpeakerDetection(
            speakerDetection,
            storedEnabled: defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool,
            noDiarize: noDiarize,
            speakerCount: speakerCount,
            speakerMin: speakerMin,
            speakerMax: speakerMax
        )
        let processingMode = TranscribeCommand.resolveProcessingMode(
            mode,
            storedMode: defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
        )
        return TranscriptionService(
            audioProcessor: AudioProcessor(),
            sttTranscriber: sttTranscriber,
            transcriptionRepo: transcriptionRepo,
            promptResultRepo: promptResultRepo,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: { processingMode },
            shouldDiarize: { resolvedSpeakerDetection.enabled },
            diarizationService: TranscribeCommand.makeDiarizationService(for: resolvedSpeakerDetection)
        )
    }

    static func resolveTarget(
        _ value: String,
        kind: RetranscribeRecordKind,
        transcriptionRepo: TranscriptionRepository,
        dictationRepo: DictationRepository
    ) throws -> RetranscribeTarget {
        switch kind {
        case .dictation:
            return .dictation(try findDictation(id: value, repo: dictationRepo))
        case .meeting:
            return .meeting(try findMeeting(idOrName: value, repo: transcriptionRepo))
        case .transcription:
            let transcription = try findTranscription(id: value, repo: transcriptionRepo)
            guard transcription.sourceType != .meeting else {
                throw CLIRetranscribeError.kindMismatch(expected: .transcription, actual: .meeting)
            }
            return .transcription(transcription)
        case .auto:
            return try resolveAutoTarget(value, transcriptionRepo: transcriptionRepo, dictationRepo: dictationRepo)
        }
    }

    private static func resolveAutoTarget(
        _ value: String,
        transcriptionRepo: TranscriptionRepository,
        dictationRepo: DictationRepository
    ) throws -> RetranscribeTarget {
        var matches: [RetranscribeTarget] = []
        var deferredLookupError: CLILookupError?

        do {
            let transcription = try findTranscription(id: value, repo: transcriptionRepo)
            matches.append(transcription.sourceType == .meeting ? .meeting(transcription) : .transcription(transcription))
        } catch let error as CLILookupError {
            switch error {
            case .ambiguous:
                throw error
            case .emptyID, .shortUUIDPrefix:
                deferredLookupError = error
            case .notFound:
                break
            }
        }

        do {
            matches.append(.dictation(try findDictation(id: value, repo: dictationRepo)))
        } catch let error as CLILookupError {
            switch error {
            case .ambiguous:
                throw error
            case .emptyID, .shortUUIDPrefix:
                deferredLookupError = deferredLookupError ?? error
            case .notFound:
                break
            }
        }

        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            throw CLIRetranscribeError.ambiguousRecord(value)
        }
        if let deferredLookupError {
            throw deferredLookupError
        }
        throw CLIRetranscribeError.noMatch(value)
    }

    static func retainedAudioURL(path: String?, kind: String, id: UUID) throws -> URL {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIRetranscribeError.noRetainedAudio(kind: kind, id: id)
        }
        let url = URL(fileURLWithPath: expandTilde(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIRetranscribeError.missingAudio(path: url.path)
        }
        return url
    }

    static func preserveOriginalTranscriptionMetadata(
        _ result: Transcription,
        original: Transcription
    ) -> Transcription {
        var updated = result
        updated.id = original.id
        updated.createdAt = original.createdAt
        updated.fileName = original.fileName
        updated.filePath = original.filePath
        updated.meetingArtifactFolderPath = original.meetingArtifactFolderPath
        updated.sourceURL = original.sourceURL
        updated.thumbnailURL = original.thumbnailURL
        updated.channelName = original.channelName
        updated.videoDescription = original.videoDescription
        updated.isFavorite = original.isFavorite
        updated.sourceType = original.sourceType
        updated.recoveredFromCrash = original.recoveredFromCrash
        updated.userNotes = original.userNotes ?? result.userNotes
        updated.chatMessages = original.chatMessages ?? result.chatMessages
        return updated
    }

    private static func telemetrySource(for sourceType: Transcription.SourceType) -> TelemetryTranscriptionSource {
        switch sourceType {
        case .file:
            return .file
        case .youtube:
            return .youtube
        case .podcast:
            return .podcast
        case .meeting:
            return .meeting
        }
    }

    private static func archivedMeetingRecording(
        for original: Transcription,
        mixedAudioURL: URL
    ) -> MeetingRecordingOutput? {
        let durationSeconds = Double(original.durationMs ?? 0) / 1000.0
        return try? MeetingRecordingOutput.loadArchived(
            displayName: original.fileName,
            mixedAudioURL: mixedAudioURL,
            durationSeconds: durationSeconds
        )
    }

    private static func dictationDurationMs(from result: STTResult, fallback: Int) -> Int {
        if let lastWord = result.words.last {
            return lastWord.endMs
        }
        if fallback > 0 {
            return fallback
        }
        return Observability.wordCount(result.text) * 150
    }

    private static func progressHandler(prefix: String) -> (
        transcriptionProgress: @Sendable (TranscriptionProgress) -> Void,
        sttProgress: @Sendable (Int, Int) -> Void
    ) {
        let lastProgressLine = OSAllocatedUnfairLock(initialState: "")
        @Sendable func printProgressLine(_ line: String) {
            let shouldPrint = lastProgressLine.withLock { lastLine in
                guard lastLine != line else { return false }
                lastLine = line
                return true
            }
            if shouldPrint { printErr(line) }
        }
        let transcriptionProgress: @Sendable (TranscriptionProgress) -> Void = { progress in
            switch progress {
            case .converting:
                printProgressLine("Converting audio...")
            case .downloading(let percent):
                printProgressLine("Downloading audio... \(percent)%")
            case .transcribing(let percent):
                printProgressLine("\(prefix)... \(percent)%")
            case .identifyingSpeakers:
                printProgressLine("Identifying speakers...")
            case .finalizing:
                printProgressLine("Finalizing...")
            }
        }
        let sttProgress: @Sendable (Int, Int) -> Void = { current, total in
            let percent = total > 0 ? min(Int(Double(current) / Double(total) * 100), 99) : 0
            printProgressLine("\(prefix)... \(percent)%")
        }
        return (transcriptionProgress, sttProgress)
    }

    private func printResult(_ result: RetranscribeResult) throws {
        if envelope {
            try printEnvelope(command: "retranscribe", data: result)
            return
        }
        if json {
            try printJSON(result)
            return
        }
        print("Retranscribed \(result.kind) \(result.shortID).")
        print("Source: \(result.sourcePath)")
    }
}
