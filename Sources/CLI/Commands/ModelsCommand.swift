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
                if let whisperVariant = selection.whisperVariant,
                   !WhisperEngine.isModelDownloaded(model: whisperVariant) {
                    throw ValidationError(
                        "Whisper model is not downloaded. Run `macparakeet-cli models download \(whisperModelID(for: whisperVariant))` first."
                    )
                }

                selection.engine.save(to: defaults)
                if let whisperVariant = selection.whisperVariant {
                    SpeechEnginePreference.saveWhisperModelVariant(whisperVariant, defaults: defaults)
                }

                let selected = loadSelectableSpeechModels(defaults: defaults).first { $0.selected }
                    ?? SelectableSpeechModel(
                        id: selection.engine.rawValue,
                        name: selection.engine.displayName,
                        engine: selection.engine.rawValue,
                        variant: selection.whisperVariant,
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
                let sttClient = STTClient()
                var sttClientNeedsShutdown = true
                defer {
                    if sttClientNeedsShutdown {
                        Task { await sttClient.shutdown() }
                    }
                }
                let diarizationService = DiarizationService()
                let status = await loadSpeechStackStatus(
                    sttClient: sttClient,
                    diarizationService: diarizationService
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

        @Argument(help: "Model identifier. Use whisper-large-v3-v20240930-turbo-632MB for Whisper, vibevoice-asr-q4-k for VibeVoice.")
        var variant: String

        func run() async throws {
            let normalized = variant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            if normalized == "vibevoice-asr-q4-k" || normalized == "vibevoice" {
                try await downloadVibeVoice()
                return
            }

            // Whisper path (existing behavior)
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

        private func downloadVibeVoice() async throws {
            let dir = VibeVoiceModelDownloader.defaultModelDirectory()
            if VibeVoiceModelDownloader.areModelsInstalled(at: dir) {
                print("VibeVoice: already installed at \(dir.path)")
                return
            }
            print("VibeVoice: downloading ~10 GB to \(dir.path)...")
            let downloader = VibeVoiceModelDownloader()
            let lastPercent = OSAllocatedUnfairLock(initialState: -1)
            try await downloader.downloadAll(to: dir) { done, total in
                let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0
                let clamped = min(max(percent, 0), 100)
                let shouldPrint = lastPercent.withLock { last in
                    guard last != clamped else { return false }
                    last = clamped
                    return true
                }
                if shouldPrint {
                    print("VibeVoice: downloading \(clamped)%")
                }
            }
            print("VibeVoice: ready at \(dir.path)")
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
            let sttClient = STTClient()
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
            let sttClient = STTClient()
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
                log: { print($0) }
            )
            await sttClient.shutdown()
            sttClientNeedsShutdown = false
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Delete cached speech and speaker models."
        )

        func run() async throws {
            let sttClient = STTClient()
            await sttClient.clearModelCache()
            DiarizationService.clearModelCache()
            try? FileManager.default.removeItem(atPath: AppPaths.whisperModelsDir)
            print("Local speech and speaker model caches cleared")
        }
    }
}

func resolveWhisperDownloadModel(_ variant: String) throws -> String {
    let normalizedInput = variant.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedInput.isEmpty else {
        throw ValidationError("Model variant cannot be empty.")
    }
    guard normalizedInput.hasPrefix("whisper-") else {
        throw ValidationError("Only whisper-* model identifiers are supported by models download.")
    }
    return WhisperEngine.normalizeModelVariant(normalizedInput)
}

struct SpeechStackPayload: Encodable {
    let speechModelCached: Bool
    let speechRuntimeReady: Bool
    let speakerModelsCached: Bool
    let speakerModelsPrepared: Bool
    let whisperModelVariant: String
    let whisperModelDownloaded: Bool
    let vibevoiceModelInstalled: Bool
    let summary: String

    init(status: SpeechStackStatus) {
        self.speechModelCached = status.speechModelCached
        self.speechRuntimeReady = status.speechRuntimeReady
        self.speakerModelsCached = status.speakerModelsCached
        self.speakerModelsPrepared = status.speakerModelsPrepared
        self.whisperModelVariant = status.whisperModelVariant
        self.whisperModelDownloaded = status.whisperModelDownloaded
        self.vibevoiceModelInstalled = status.vibevoiceModelInstalled
        self.summary = status.summary
    }
}

struct SpeechStackStatus: Sendable, Equatable {
    let speechModelCached: Bool
    let speechRuntimeReady: Bool
    let speakerModelsCached: Bool
    let speakerModelsPrepared: Bool
    let whisperModelVariant: String
    let whisperModelDownloaded: Bool
    let vibevoiceModelInstalled: Bool

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

func loadSpeechStackStatus(
    sttClient: STTClientProtocol,
    diarizationService: DiarizationServiceProtocol,
    isSpeechModelCached: @escaping @Sendable () -> Bool = { STTClient.isModelCached() },
    whisperModelVariant: String = SpeechEnginePreference.whisperModelVariant(defaults: macParakeetAppDefaults()),
    isWhisperModelDownloaded: @escaping @Sendable (String) -> Bool = { WhisperEngine.isModelDownloaded(model: $0) },
    isVibeVoiceModelInstalled: @escaping @Sendable () -> Bool = { VibeVoiceModelDownloader.areModelsInstalled() }
) async -> SpeechStackStatus {
    async let speechRuntimeReady = sttClient.isReady()
    async let speakerModelsCached = diarizationService.hasCachedModels()
    async let speakerModelsPrepared = diarizationService.isReady()

    return await SpeechStackStatus(
        speechModelCached: isSpeechModelCached(),
        speechRuntimeReady: speechRuntimeReady,
        speakerModelsCached: speakerModelsCached,
        speakerModelsPrepared: speakerModelsPrepared,
        whisperModelVariant: whisperModelVariant,
        whisperModelDownloaded: isWhisperModelDownloaded(whisperModelVariant),
        vibevoiceModelInstalled: isVibeVoiceModelInstalled()
    )
}

func printSpeechStackStatus(_ status: SpeechStackStatus, includeHeader: Bool = true) {
    if includeHeader {
        print("Local speech stack:")
    }
    print("  Speech model cached:   \(status.speechModelCached ? "Yes" : "No")")
    print("  Speech runtime loaded: \(status.speechRuntimeReady ? "Yes" : "No")")
    print("  Speaker models cached: \(status.speakerModelsCached ? "Yes" : "No")")
    print("  Speaker models prepared: \(status.speakerModelsPrepared ? "Yes" : "No")")
    print("  Whisper model variant: \(status.whisperModelVariant)")
    print("  Whisper model downloaded: \(status.whisperModelDownloaded ? "Yes" : "No")")
    if status.vibevoiceModelInstalled {
        print("  VibeVoice model: installed")
    } else {
        print("  VibeVoice model: not installed (run `models download vibevoice-asr-q4-k`)")
    }
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
}

func loadSelectableSpeechModels(
    defaults: UserDefaults = macParakeetAppDefaults(),
    isParakeetModelCached: @escaping () -> Bool = { STTClient.isModelCached() },
    isWhisperModelDownloaded: @escaping (String) -> Bool = { WhisperEngine.isModelDownloaded(model: $0) }
) -> [SelectableSpeechModel] {
    let currentEngine = SpeechEnginePreference.current(defaults: defaults)
    let whisperVariant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)
    let whisperLanguage = SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)

    return [
        SelectableSpeechModel(
            id: SpeechEnginePreference.parakeet.rawValue,
            name: "Parakeet TDT 0.6B v3",
            engine: SpeechEnginePreference.parakeet.rawValue,
            variant: nil,
            size: "6 GB",
            installed: isParakeetModelCached(),
            selected: currentEngine == .parakeet,
            language: nil
        ),
        SelectableSpeechModel(
            id: whisperModelID(for: whisperVariant),
            name: "Whisper \(SpeechEnginePreference.friendlyVariantName(whisperVariant))",
            engine: SpeechEnginePreference.whisper.rawValue,
            variant: whisperVariant,
            size: whisperModelSizeLabel(for: whisperVariant),
            installed: isWhisperModelDownloaded(whisperVariant),
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

    if lowered == SpeechEnginePreference.parakeet.rawValue {
        return SelectableSpeechModelSelection(engine: .parakeet, whisperVariant: nil)
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
    log: @escaping @Sendable (String) -> Void
) async throws {
    log("Parakeet (STT): preparing...")
    try await runWithRetry(attempts: attempts, label: "Parakeet (STT)", log: log) { attempt in
        try await sttClient.warmUp { message in
            if attempt == 1 || message.contains("%") || message == "Ready" || message.contains("Loading model") {
                log("Parakeet (STT): \(message)")
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
        diarizationService: diarizationService
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
