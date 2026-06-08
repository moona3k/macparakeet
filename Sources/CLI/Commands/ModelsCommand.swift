import ArgumentParser
import Foundation
import MacParakeetCore
import os

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect and manage the local speech and speaker models.",
        subcommands: [
            List.self,
            Select.self,
            Status.self,
            Download.self,
            WarmUp.self,
            Repair.self,
            Delete.self,
            Clear.self,
        ]
    )
}

extension ModelsCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List selectable speech models."
        )

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let models = loadSelectableSpeechModels()
                if json {
                    try printJSON(models)
                } else {
                    printSelectableSpeechModels(models)
                }
            }
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select",
            abstract: "Set the shared app/CLI default speech model."
        )

        @Argument(help: "Model ID from `models list`.")
        var id: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let defaults = macParakeetAppDefaults()
                let selection = try resolveSelectableSpeechModel(id, defaults: defaults)
                try validateSelectableSpeechModelDownload(selection, defaults: defaults)

                selection.engine.save(to: defaults)
                if let whisperVariant = selection.whisperVariant {
                    SpeechEnginePreference.saveWhisperModelVariant(whisperVariant, defaults: defaults)
                }
                if let parakeetVariant = selection.parakeetVariant {
                    SpeechEnginePreference.saveParakeetModelVariant(parakeetVariant, defaults: defaults)
                }

                let selected = loadSelectableSpeechModels(defaults: defaults).first { $0.selected }
                    ?? SelectableSpeechModel(
                        id: selection.engine.rawValue,
                        name: selection.engine.displayName,
                        engine: selection.engine.rawValue,
                        variant: selection.whisperVariant ?? selection.nemotronVariant?.rawValue,
                        size: nil,
                        installed: true,
                        selected: true,
                        language: nil
                    )
                if json {
                    try printJSON(selected)
                } else {
                    print("Selected: \(selected.id) (\(selected.name))")
                }
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show speech-stack status without forcing downloads."
        )

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                let defaults = macParakeetAppDefaults()
                let sttClient = makeConfiguredSTTClient(defaults: defaults)
                var sttClientNeedsShutdown = true
                defer {
                    if sttClientNeedsShutdown {
                        Task { await sttClient.shutdown() }
                    }
                }
                let diarizationService = DiarizationService()
                let status = await loadSpeechStackStatus(
                    sttClient: sttClient,
                    diarizationService: diarizationService,
                    defaults: defaults
                )
                await sttClient.shutdown()
                sttClientNeedsShutdown = false
                if json {
                    try printJSON(SpeechStackPayload(status: status))
                } else {
                    printSpeechStackStatus(status)
                }
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Download a local speech model without starting a transcription."
        )

        @Argument(help: "Model identifier from `models list`, e.g. parakeet-v2, parakeet-v3, nemotron-multilingual-1120ms, or whisper-large-v3-v20240930-turbo-632MB.")
        var variant: String

        func run() async throws {
            let lowered = variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let parakeetVariant = parakeetDownloadVariant(from: lowered) {
                print("Parakeet: downloading \(parakeetVariant.modelName)...")
                let lastMessage = OSAllocatedUnfairLock(initialState: "")
                try await STTRuntime.downloadParakeetModel(version: parakeetVariant.asrModelVersion) { message in
                    let shouldPrint = lastMessage.withLock { last in
                        guard last != message else { return false }
                        last = message
                        return true
                    }
                    if shouldPrint { print("Parakeet: \(message)") }
                }
                print("Parakeet: ready (\(parakeetVariant.modelName))")
                return
            }

            if let nemotronVariant = nemotronDownloadVariant(from: lowered) {
                let language = SpeechEnginePreference.nemotronDefaultLanguage(defaults: macParakeetAppDefaults())
                print("Nemotron: downloading \(nemotronVariant.modelName)...")
                let lastMessage = OSAllocatedUnfairLock(initialState: "")
                try await STTRuntime.downloadNemotronModel(modelVariant: nemotronVariant, language: language) { message in
                    let shouldPrint = lastMessage.withLock { last in
                        guard last != message else { return false }
                        last = message
                        return true
                    }
                    if shouldPrint { print("Nemotron: \(message)") }
                }
                print("Nemotron: ready (\(nemotronVariant.modelName))")
                return
            }

            let model = try resolveWhisperDownloadModel(variant)
            print("Whisper: downloading \(model)...")
            let lastPercent = OSAllocatedUnfairLock(initialState: -1)
            let modelURL = try await WhisperEngine.downloadModel(model: model) { completed, total in
                let percent = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded()) : 0
                let clamped = min(max(percent, 0), 100)
                let shouldPrint = lastPercent.withLock { last in
                    guard last != clamped else { return false }
                    last = clamped
                    return true
                }
                if shouldPrint {
                    print("Whisper: downloading \(clamped)%")
                }
            }
            print("Whisper: ready at \(modelURL.path)")
        }
    }

    struct WarmUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "warm-up",
            abstract: "Warm up the local speech stack. May download on first run."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 1

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let defaults = macParakeetAppDefaults()
            let sttClient = makeConfiguredSTTClient(defaults: defaults)
            var sttClientNeedsShutdown = true
            defer {
                if sttClientNeedsShutdown {
                    Task { await sttClient.shutdown() }
                }
            }
            let diarizationService = DiarizationService()
            try await prepareSpeechStack(
                attempts: attempts,
                sttClient: sttClient,
                diarizationService: diarizationService,
                defaults: defaults,
                log: { print($0) }
            )
            await sttClient.shutdown()
            sttClientNeedsShutdown = false
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair",
            abstract: "Best-effort retry for the local speech stack."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 3

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let defaults = macParakeetAppDefaults()
            let sttClient = makeConfiguredSTTClient(defaults: defaults)
            var sttClientNeedsShutdown = true
            defer {
                if sttClientNeedsShutdown {
                    Task { await sttClient.shutdown() }
                }
            }
            let diarizationService = DiarizationService()
            try await prepareSpeechStack(
                attempts: attempts,
                sttClient: sttClient,
                diarizationService: diarizationService,
                defaults: defaults,
                log: { print($0) }
            )
            await sttClient.shutdown()
            sttClientNeedsShutdown = false
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one downloaded speech model, freeing its disk space.",
            discussion: """
                Removes a single model (one Parakeet build, Nemotron, or the Whisper variant) \
                while leaving every other model in place — unlike `models clear`, \
                which wipes the whole local stack.

                The model currently in use is protected: deleting it would force a \
                silent re-download on the next transcription. Switch models first, \
                or pass --force to delete it anyway.
                """
        )

        @Argument(help: "Model identifier from `models list`, e.g. parakeet-v2, parakeet-v3, nemotron-multilingual-1120ms, or whisper-large-v3-v20240930-turbo-632MB.")
        var id: String

        @Flag(name: .long, help: "Delete even the model currently in use (it will re-download on next use).")
        var force: Bool = false

        func run() async throws {
            let defaults = macParakeetAppDefaults()
            let target = try resolveModelDeletionTarget(id, defaults: defaults)

            if isModelInUse(target, defaults: defaults) {
                guard force else {
                    throw ValidationError(
                        "\(target.displayName) is the model currently in use. Switch to another model first, "
                            + "or pass --force to delete it anyway (it re-downloads on next use)."
                    )
                }
                // --force overrides the guard; make the consequence explicit since
                // there's no interactive confirmation on the CLI.
                printErr("Warning: deleting \(target.displayName), the model currently in use. It will re-download on next use.")
            }

            switch target.kind {
            case .parakeet(let variant):
                guard STTClient.isModelCached(version: variant.asrModelVersion) else {
                    print("\(variant.modelName) is not downloaded — nothing to delete.")
                    return
                }
                let removed = STTRuntime.deleteParakeetModel(version: variant.asrModelVersion)
                guard removed else {
                    throw ModelDeletionError.deleteFailed("Could not delete \(variant.modelName). It may be missing or in use by another process.")
                }
                print("Deleted \(target.displayName) · freed \(variant.approximateDownloadSize).")
            case .nemotron(let variant):
                let removed = STTRuntime.deleteNemotronModel(modelVariant: variant, language: nil)
                guard removed else {
                    print("\(variant.modelName) is not downloaded — nothing to delete.")
                    return
                }
                print("Deleted \(target.displayName) · freed \(variant.approximateDownloadSize).")
            case .whisper(let variant):
                guard WhisperEngine.isModelDownloaded(model: variant) else {
                    print("Whisper \(SpeechEnginePreference.friendlyVariantName(variant)) is not downloaded — nothing to delete.")
                    return
                }
                let removed = STTRuntime.deleteWhisperModel(variant: variant, defaults: defaults)
                guard removed else {
                    throw ModelDeletionError.deleteFailed("Could not delete Whisper \(SpeechEnginePreference.friendlyVariantName(variant)). It may be missing or in use by another process.")
                }
                let freed = whisperModelSizeLabel(for: variant).map { " · freed \($0)" } ?? ""
                print("Deleted \(target.displayName)\(freed).")
            }
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Delete cached speech and speaker models."
        )

        func run() async throws {
            let sttClient = makeParakeetSTTClient()
            await sttClient.clearModelCache()
            DiarizationService.clearModelCache()
            try? FileManager.default.removeItem(atPath: AppPaths.whisperModelsDir)
            print("Local speech and speaker model caches cleared")
        }
    }
}

/// Recognizes the Parakeet ids surfaced by `models list` (`parakeet-v3`,
/// `parakeet-v2`), the bare `parakeet` (current build), and the `:`/alias
/// spellings. Returns nil for non-Parakeet ids so Nemotron/Whisper parsing runs.
func parakeetDownloadVariant(
    from lowered: String,
    defaults: UserDefaults = macParakeetAppDefaults()
) -> ParakeetModelVariant? {
    if lowered == SpeechEnginePreference.parakeet.rawValue {
        return SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
    }
    return parseParakeetSelectionVariant(lowered)
}

func nemotronDownloadVariant(from lowered: String) -> NemotronModelVariant? {
    if lowered == SpeechEnginePreference.nemotron.rawValue {
        return SpeechEnginePreference.defaultNemotronModelVariant
    }
    return parseNemotronSelectionVariant(lowered)
}

func resolveWhisperDownloadModel(_ variant: String) throws -> String {
    let normalizedInput = variant.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedInput.isEmpty else {
        throw ValidationError("Model variant cannot be empty.")
    }
    guard normalizedInput.hasPrefix("whisper-") else {
        throw ValidationError("Unsupported model identifier '\(variant)'. Use a parakeet-v2, parakeet-v3, nemotron-multilingual-1120ms, or whisper-* id from `models list`.")
    }
    return WhisperEngine.normalizeModelVariant(normalizedInput)
}

struct SpeechStackPayload: Encodable {
    let speechEngine: String
    let speechModelCached: Bool
    let speechRuntimeReady: Bool
    let speakerModelsCached: Bool
    let speakerModelsPrepared: Bool
    let parakeetModelVariant: String
    let parakeetModelDownloaded: Bool
    let nemotronModelVariant: String
    let nemotronModelDownloaded: Bool
    let whisperModelVariant: String
    let whisperModelDownloaded: Bool
    let summary: String

    init(status: SpeechStackStatus) {
        self.speechEngine = status.speechEngine.rawValue
        self.speechModelCached = status.speechModelCached
        self.speechRuntimeReady = status.speechRuntimeReady
        self.speakerModelsCached = status.speakerModelsCached
        self.speakerModelsPrepared = status.speakerModelsPrepared
        self.parakeetModelVariant = status.parakeetModelVariant.rawValue
        self.parakeetModelDownloaded = status.parakeetModelDownloaded
        self.nemotronModelVariant = status.nemotronModelVariant.rawValue
        self.nemotronModelDownloaded = status.nemotronModelDownloaded
        self.whisperModelVariant = status.whisperModelVariant
        self.whisperModelDownloaded = status.whisperModelDownloaded
        self.summary = status.summary
    }
}

struct SpeechStackStatus: Sendable, Equatable {
    let speechEngine: SpeechEnginePreference
    let speechModelCached: Bool
    let speechRuntimeReady: Bool
    let speakerModelsCached: Bool
    let speakerModelsPrepared: Bool
    let parakeetModelVariant: ParakeetModelVariant
    let parakeetModelDownloaded: Bool
    let nemotronModelVariant: NemotronModelVariant
    let nemotronModelDownloaded: Bool
    let whisperModelVariant: String
    let whisperModelDownloaded: Bool

    var summary: String {
        if speechRuntimeReady && speakerModelsPrepared {
            return "Ready"
        }
        if speechModelCached && speakerModelsCached {
            return "Downloaded (loads on demand)"
        }
        if speechModelCached {
            return "Speech model present, speaker models missing"
        }
        if speakerModelsCached {
            return "Speaker models present, speech model missing"
        }
        return "Not downloaded"
    }
}

func validatedAttempts(_ attempts: Int) throws -> Int {
    guard attempts >= 1 else {
        throw ValidationError("--attempts must be >= 1")
    }
    return attempts
}

/// Builds the CLI's standalone STT client from the persisted app/CLI defaults,
/// so `warm-up`/`repair`/`status` exercise the engine the user selected.
func makeConfiguredSTTClient(defaults: UserDefaults = macParakeetAppDefaults()) -> STTClient {
    STTClient(
        modelVersion: SpeechEnginePreference.parakeetModelVariant(defaults: defaults).asrModelVersion,
        speechEngine: SpeechEnginePreference.current(defaults: defaults),
        nemotronModelVariant: SpeechEnginePreference.defaultNemotronModelVariant,
        whisperModelVariant: SpeechEnginePreference.whisperModelVariant(defaults: defaults),
        defaults: defaults
    )
}

func makeParakeetSTTClient(defaults: UserDefaults = macParakeetAppDefaults()) -> STTClient {
    STTClient(
        modelVersion: SpeechEnginePreference.parakeetModelVariant(defaults: defaults).asrModelVersion,
        speechEngine: .parakeet,
        defaults: defaults
    )
}

func loadSpeechStackStatus(
    sttClient: STTClientProtocol,
    diarizationService: DiarizationServiceProtocol,
    defaults: UserDefaults = macParakeetAppDefaults(),
    isParakeetModelCached: (@Sendable (ParakeetModelVariant) -> Bool)? = nil,
    nemotronModelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
    isNemotronModelDownloaded: (@Sendable (NemotronModelVariant) -> Bool)? = nil,
    whisperModelVariant: String? = nil,
    isWhisperModelDownloaded: (@Sendable (String) -> Bool)? = nil
) async -> SpeechStackStatus {
    let speechEngine = SpeechEnginePreference.current(defaults: defaults)
    let parakeetModelVariant = SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
    let nemotronLanguage = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
    let whisperModelVariant = whisperModelVariant ?? SpeechEnginePreference.whisperModelVariant(defaults: defaults)
    let parakeetDownloaded = (isParakeetModelCached ?? { variant in
        STTClient.isModelCached(version: variant.asrModelVersion)
    })(parakeetModelVariant)
    let nemotronDownloaded = (isNemotronModelDownloaded ?? { variant in
        STTClient.isNemotronModelCached(modelVariant: variant, language: nemotronLanguage)
    })(nemotronModelVariant)
    let whisperDownloaded = (isWhisperModelDownloaded ?? { variant in
        WhisperEngine.isModelDownloaded(model: variant)
    })(whisperModelVariant)
    let activeSpeechModelCached = switch speechEngine {
    case .parakeet:
        parakeetDownloaded
    case .nemotron:
        nemotronDownloaded
    case .whisper:
        whisperDownloaded
    }

    async let speechRuntimeReady = sttClient.isReady()
    async let speakerModelsCached = diarizationService.hasCachedModels()
    async let speakerModelsPrepared = diarizationService.isReady()

    return await SpeechStackStatus(
        speechEngine: speechEngine,
        speechModelCached: activeSpeechModelCached,
        speechRuntimeReady: speechRuntimeReady,
        speakerModelsCached: speakerModelsCached,
        speakerModelsPrepared: speakerModelsPrepared,
        parakeetModelVariant: parakeetModelVariant,
        parakeetModelDownloaded: parakeetDownloaded,
        nemotronModelVariant: nemotronModelVariant,
        nemotronModelDownloaded: nemotronDownloaded,
        whisperModelVariant: whisperModelVariant,
        whisperModelDownloaded: whisperDownloaded
    )
}

func printSpeechStackStatus(_ status: SpeechStackStatus, includeHeader: Bool = true) {
    if includeHeader {
        print("Local speech stack:")
    }
    print("  Active speech engine: \(status.speechEngine.displayName)")
    print("  Active speech model cached: \(status.speechModelCached ? "Yes" : "No")")
    print("  Speech runtime loaded: \(status.speechRuntimeReady ? "Yes" : "No")")
    print("  Speaker models cached: \(status.speakerModelsCached ? "Yes" : "No")")
    print("  Speaker models prepared: \(status.speakerModelsPrepared ? "Yes" : "No")")
    print("  Parakeet model variant: \(status.parakeetModelVariant.rawValue)")
    print("  Parakeet model downloaded: \(status.parakeetModelDownloaded ? "Yes" : "No")")
    print("  Nemotron model variant: \(status.nemotronModelVariant.rawValue)")
    print("  Nemotron model downloaded: \(status.nemotronModelDownloaded ? "Yes" : "No")")
    print("  Whisper model variant: \(status.whisperModelVariant)")
    print("  Whisper model downloaded: \(status.whisperModelDownloaded ? "Yes" : "No")")
    print("  Status: \(status.summary)")
}

struct SelectableSpeechModel: Encodable, Equatable {
    let id: String
    let name: String
    let engine: String
    let variant: String?
    let size: String?
    let installed: Bool
    let selected: Bool
    let language: String?
}

struct SelectableSpeechModelSelection: Equatable {
    let engine: SpeechEnginePreference
    let whisperVariant: String?
    var nemotronVariant: NemotronModelVariant? = nil
    /// Set when the selection targets a specific Parakeet build; `nil` leaves
    /// the persisted Parakeet variant untouched (e.g. a Whisper selection).
    var parakeetVariant: ParakeetModelVariant? = nil
}

func loadSelectableSpeechModels(
    defaults: UserDefaults = macParakeetAppDefaults(),
    isParakeetModelCached: ((ParakeetModelVariant) -> Bool)? = nil,
    isNemotronModelDownloaded: ((NemotronModelVariant) -> Bool)? = nil,
    isWhisperModelDownloaded: ((String) -> Bool)? = nil
) -> [SelectableSpeechModel] {
    let checkParakeetModelCached = isParakeetModelCached ?? {
        STTClient.isModelCached(version: $0.asrModelVersion)
    }
    let currentEngine = SpeechEnginePreference.current(defaults: defaults)
    let currentParakeetVariant = SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
    let nemotronLanguage = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
    let checkNemotronModelDownloaded = isNemotronModelDownloaded ?? {
        STTClient.isNemotronModelCached(modelVariant: $0, language: nemotronLanguage)
    }
    let checkWhisperModelDownloaded = isWhisperModelDownloaded ?? { WhisperEngine.isModelDownloaded(model: $0) }
    let whisperVariant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)
    let whisperLanguage = SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)

    let parakeetModels = ParakeetModelVariant.allCases.map { variant in
        SelectableSpeechModel(
            id: parakeetModelID(for: variant),
            name: "\(variant.modelName) (\(variant.displayName))",
            engine: SpeechEnginePreference.parakeet.rawValue,
            variant: variant.rawValue,
            size: variant.approximateDownloadSize,
            installed: checkParakeetModelCached(variant),
            selected: currentEngine == .parakeet && currentParakeetVariant == variant,
            language: variant.isEnglishOnly ? "en" : nil
        )
    }

    let nemotronModels = NemotronModelVariant.allCases.map { variant in
        SelectableSpeechModel(
            id: nemotronModelID(for: variant),
            name: "\(variant.modelName) (\(variant.displayName))",
            engine: SpeechEnginePreference.nemotron.rawValue,
            variant: variant.rawValue,
            size: variant.approximateDownloadSize,
            installed: checkNemotronModelDownloaded(variant),
            selected: currentEngine == .nemotron,
            language: nemotronLanguage ?? "auto"
        )
    }

    return parakeetModels + nemotronModels + [
        SelectableSpeechModel(
            id: whisperModelID(for: whisperVariant),
            name: "Whisper \(SpeechEnginePreference.friendlyVariantName(whisperVariant))",
            engine: SpeechEnginePreference.whisper.rawValue,
            variant: whisperVariant,
            size: whisperModelSizeLabel(for: whisperVariant),
            installed: checkWhisperModelDownloaded(whisperVariant),
            selected: currentEngine == .whisper,
            language: whisperLanguage ?? WhisperLanguageCatalog.autoCode
        ),
    ]
}

func resolveSelectableSpeechModel(
    _ id: String,
    defaults: UserDefaults = macParakeetAppDefaults()
) throws -> SelectableSpeechModelSelection {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    guard !trimmed.isEmpty else {
        throw ValidationError("Model ID cannot be empty.")
    }

    // Bare "parakeet" keeps the persisted variant; "parakeet-v2" / "parakeet:v3"
    // / "parakeet-english" target a specific build.
    if lowered == SpeechEnginePreference.parakeet.rawValue {
        return SelectableSpeechModelSelection(
            engine: .parakeet,
            whisperVariant: nil,
            parakeetVariant: SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
        )
    }

    if let parakeetVariant = parseParakeetSelectionVariant(lowered) {
        return SelectableSpeechModelSelection(
            engine: .parakeet,
            whisperVariant: nil,
            nemotronVariant: nil,
            parakeetVariant: parakeetVariant
        )
    }

    if lowered == "nemotron" {
        return SelectableSpeechModelSelection(
            engine: .nemotron,
            whisperVariant: nil,
            nemotronVariant: SpeechEnginePreference.defaultNemotronModelVariant
        )
    }

    if let nemotronVariant = parseNemotronSelectionVariant(lowered) {
        return SelectableSpeechModelSelection(
            engine: .nemotron,
            whisperVariant: nil,
            nemotronVariant: nemotronVariant
        )
    }

    if lowered == "whisper" {
        return SelectableSpeechModelSelection(
            engine: .whisper,
            whisperVariant: SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        )
    }

    let variantInput: String?
    if lowered.hasPrefix("whisper:") {
        variantInput = String(trimmed.dropFirst("whisper:".count))
    } else if lowered.hasPrefix("whisper-") {
        variantInput = String(trimmed.dropFirst("whisper-".count))
    } else {
        variantInput = nil
    }

    guard let variantInput,
          !variantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("Unknown model ID: '\(id)'. Run `macparakeet-cli models list` for valid IDs.")
    }

    return SelectableSpeechModelSelection(
        engine: .whisper,
        whisperVariant: WhisperEngine.normalizeModelVariant(variantInput)
    )
}

func validateSelectableSpeechModelDownload(
    _ selection: SelectableSpeechModelSelection,
    defaults: UserDefaults = macParakeetAppDefaults(),
    isNemotronModelDownloaded: ((NemotronModelVariant, String?) -> Bool)? = nil,
    isWhisperModelDownloaded: ((String) -> Bool)? = nil
) throws {
    if let nemotronVariant = selection.nemotronVariant {
        let language = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        let downloaded = (isNemotronModelDownloaded ?? { variant, language in
            STTClient.isNemotronModelCached(modelVariant: variant, language: language)
        })(nemotronVariant, language)
        guard downloaded else {
            throw ValidationError(
                "Nemotron model is not downloaded. Run `macparakeet-cli models download \(nemotronModelID(for: nemotronVariant))` first."
            )
        }
    }

    if let whisperVariant = selection.whisperVariant {
        let downloaded = (isWhisperModelDownloaded ?? { WhisperEngine.isModelDownloaded(model: $0) })(whisperVariant)
        guard downloaded else {
            throw ValidationError(
                "Whisper model is not downloaded. Run `macparakeet-cli models download \(whisperModelID(for: whisperVariant))` first."
            )
        }
    }
}

/// One concrete model that `models delete` can target, resolved from a
/// `models list` id. Carries a user-facing `displayName` for messages.
struct ModelDeletionTarget: Equatable {
    enum Kind: Equatable {
        case parakeet(ParakeetModelVariant)
        case nemotron(NemotronModelVariant)
        /// Normalized Whisper variant id (matches the stored preference).
        case whisper(String)
    }

    let kind: Kind
    let displayName: String
}

enum ModelDeletionError: Error, Equatable, LocalizedError {
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let message):
            return message
        }
    }
}

/// Maps a `models list` id (`parakeet-v2`, `whisper-…`, bare `parakeet` /
/// `whisper`) to a single deletable model, reusing the selection parser so the
/// delete and select grammars never drift. Throws `ValidationError` on an
/// unknown id.
func resolveModelDeletionTarget(
    _ id: String,
    defaults: UserDefaults = macParakeetAppDefaults()
) throws -> ModelDeletionTarget {
    let selection = try resolveSelectableSpeechModel(id, defaults: defaults)
    if let parakeetVariant = selection.parakeetVariant {
        return ModelDeletionTarget(
            kind: .parakeet(parakeetVariant),
            displayName: "\(parakeetVariant.modelName) (\(parakeetVariant.displayName))"
        )
    }
    if let nemotronVariant = selection.nemotronVariant {
        return ModelDeletionTarget(
            kind: .nemotron(nemotronVariant),
            displayName: "\(nemotronVariant.modelName) (\(nemotronVariant.displayName))"
        )
    }
    if let whisperVariant = selection.whisperVariant {
        return ModelDeletionTarget(
            kind: .whisper(whisperVariant),
            displayName: "Whisper \(SpeechEnginePreference.friendlyVariantName(whisperVariant))"
        )
    }
    throw ValidationError("Unknown model ID: '\(id)'. Run `macparakeet-cli models list` for valid IDs.")
}

/// Whether `target` is protected from deletion without `--force`. The selected
/// Parakeet build is protected even while Whisper is active because it is the
/// build Parakeet would load after a switch; Whisper's single surfaced variant
/// is protected only while Whisper is active.
func isModelInUse(
    _ target: ModelDeletionTarget,
    defaults: UserDefaults = macParakeetAppDefaults()
) -> Bool {
    let currentEngine = SpeechEnginePreference.current(defaults: defaults)
    switch target.kind {
    case .parakeet(let variant):
        return SpeechEnginePreference.parakeetModelVariant(defaults: defaults) == variant
    case .nemotron(let variant):
        return currentEngine == .nemotron
            && variant == SpeechEnginePreference.defaultNemotronModelVariant
    case .whisper(let variant):
        return currentEngine == .whisper
            && SpeechEnginePreference.whisperModelVariant(defaults: defaults) == variant
    }
}

/// Recognizes `parakeet-v2`, `parakeet:v3`, `parakeet-english`,
/// `parakeet-multilingual`, etc. Returns `nil` when `id` isn't a Parakeet
/// variant selector so the caller can fall through to Whisper parsing.
private func parseParakeetSelectionVariant(_ lowered: String) -> ParakeetModelVariant? {
    // Normalize underscores to hyphens so `parakeet_v2` / `parakeet_english`
    // resolve the same as their hyphenated forms — matching how
    // `ConfigCommand.parseParakeetModelVariant` canonicalizes the setting.
    let normalized = lowered.replacingOccurrences(of: "_", with: "-")
    let prefix = SpeechEnginePreference.parakeet.rawValue
    let suffix: String
    if normalized.hasPrefix("\(prefix):") {
        suffix = String(normalized.dropFirst(prefix.count + 1))
    } else if normalized.hasPrefix("\(prefix)-") {
        suffix = String(normalized.dropFirst(prefix.count + 1))
    } else {
        return nil
    }
    switch suffix {
    case "v3", "multilingual", "multi":
        return .v3
    case "v2", "english", "english-only", "en":
        return .v2
    default:
        return nil
    }
}

/// Recognizes `nemotron-multilingual-1120ms`, `nemotron:multilingual-1120ms`,
/// and a few intent aliases. Returns nil for non-Nemotron ids.
private func parseNemotronSelectionVariant(_ lowered: String) -> NemotronModelVariant? {
    let normalized = lowered.replacingOccurrences(of: "_", with: "-")
    let prefix = SpeechEnginePreference.nemotron.rawValue
    let suffix: String
    if normalized.hasPrefix("\(prefix):") {
        suffix = String(normalized.dropFirst(prefix.count + 1))
    } else if normalized.hasPrefix("\(prefix)-") {
        suffix = String(normalized.dropFirst(prefix.count + 1))
    } else {
        return nil
    }
    switch suffix {
    case "multilingual-1120ms", "multilingual", "multi", "beta":
        return .multilingual1120
    default:
        return nil
    }
}

func parakeetModelID(for variant: ParakeetModelVariant) -> String {
    "\(SpeechEnginePreference.parakeet.rawValue)-\(variant.rawValue)"
}

func nemotronModelID(for variant: NemotronModelVariant) -> String {
    "\(SpeechEnginePreference.nemotron.rawValue)-\(variant.rawValue)"
}

func whisperModelID(for variant: String) -> String {
    "whisper-\(variant.replacingOccurrences(of: "_turbo_", with: "-turbo-").replacingOccurrences(of: "_", with: "-"))"
}

func whisperModelSizeLabel(for variant: String) -> String? {
    let tokens = variant.split(separator: "_")
    guard let last = tokens.last else { return nil }
    let raw = String(last)
    let lowered = raw.lowercased()
    if lowered.hasSuffix("mb") {
        return "\(raw.dropLast(2)) MB"
    }
    if lowered.hasSuffix("gb") {
        return "\(raw.dropLast(2)) GB"
    }
    return nil
}

func printSelectableSpeechModels(_ models: [SelectableSpeechModel]) {
    print("\(paddedModelColumn("ID", width: 44)) \(paddedModelColumn("NAME", width: 28)) \(paddedModelColumn("SIZE", width: 10)) INSTALLED")
    for model in models {
        let marker = model.selected ? "*" : " "
        let size = model.size ?? "-"
        let installed = model.installed ? "yes" : "no"
        print("\(marker) \(paddedModelColumn(model.id, width: 42)) \(paddedModelColumn(model.name, width: 28)) \(paddedModelColumn(size, width: 10)) \(installed)")
    }
}

private func paddedModelColumn(_ value: String, width: Int) -> String {
    let padding = max(0, width - value.count)
    return value + String(repeating: " ", count: padding)
}

func prepareSpeechStack(
    attempts: Int,
    sttClient: STTClientProtocol,
    diarizationService: DiarizationServiceProtocol,
    defaults: UserDefaults = macParakeetAppDefaults(),
    log: @escaping @Sendable (String) -> Void
) async throws {
    let speechLabel = "\(SpeechEnginePreference.current(defaults: defaults).displayName) (STT)"
    log("\(speechLabel): preparing...")
    try await runWithRetry(attempts: attempts, label: speechLabel, log: log) { attempt in
        try await sttClient.warmUp { message in
            if attempt == 1 || message.contains("%") || message == "Ready" || message.contains("Loading model") {
                log("\(speechLabel): \(message)")
            }
        }
    }

    log("Speaker models: preparing...")
    try await runWithRetry(attempts: attempts, label: "Speaker models", log: log) { _ in
        try await diarizationService.prepareModels { message in
            log("Speaker models: \(message)")
        }
    }

    let status = await loadSpeechStackStatus(
        sttClient: sttClient,
        diarizationService: diarizationService,
        defaults: defaults
    )
    log("Speech stack: \(status.summary)")
}

private func runWithRetry(
    attempts: Int,
    label: String,
    log: @escaping @Sendable (String) -> Void,
    operation: @escaping @Sendable (_ attempt: Int) async throws -> Void
) async throws {
    var backoffNs: UInt64 = 250_000_000
    var lastError: Error?

    for attempt in 1...attempts {
        do {
            try await operation(attempt)
            return
        } catch {
            lastError = error
            guard attempt < attempts else { break }
            let nextAttempt = attempt + 1
            log("\(label): attempt \(attempt) failed (\(error.localizedDescription)). Retrying \(nextAttempt)/\(attempts)...")
            try await Task.sleep(nanoseconds: backoffNs)
            backoffNs *= 2
        }
    }

    throw lastError ?? STTError.engineStartFailed("\(label) warm-up failed.")
}
