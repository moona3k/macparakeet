import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class EngineSettingsViewModel {
    public enum LocalModelStatus: Equatable {
        case unknown
        case checking
        case ready
        case notLoaded
        case notDownloaded
        case preparing
        case repairing
        case failed
    }

    public var speechEnginePreference: SpeechEnginePreference {
        didSet {
            guard !isApplyingSpeechEngineState else { return }
            applySpeechEngineChange(speechEnginePreference)
        }
    }
    /// Which Parakeet build (multilingual `v3`, English-only `v2`, or Unified)
    /// is active. Changing it live-reloads the model when Parakeet is the selected
    /// engine (downloading the target on first use); see
    /// `applyParakeetModelVariantChange`.
    public var parakeetModelVariant: ParakeetModelVariant {
        didSet {
            guard !isApplyingParakeetVariantState else { return }
            applyParakeetModelVariantChange(parakeetModelVariant)
        }
    }
    /// Which Nemotron build (multilingual vs English-only) is active. Changing
    /// it live-reloads the model when Nemotron is the selected engine
    /// (downloading the target on first use); see `applyNemotronModelVariantChange`.
    public var nemotronModelVariant: NemotronModelVariant {
        didSet {
            guard !isApplyingNemotronVariantState else { return }
            applyNemotronModelVariantChange(nemotronModelVariant)
        }
    }
    public var whisperDefaultLanguage: String {
        didSet {
            SpeechEnginePreference.saveWhisperDefaultLanguage(whisperDefaultLanguage, defaults: defaults)
            Telemetry.send(.settingChanged(setting: .whisperDefaultLanguage))
        }
    }
    /// Where Cohere runs its model — `.gpu` (fastest warm latency, pays a
    /// one-time ~2-minute Core ML optimization in the background after each
    /// launch) or `.ane` (slower warm, no startup wait). Persist-only: the
    /// engine re-reads it on its next construction (`STTRuntime.ensureCohereEngine`),
    /// so a change takes effect the next time Cohere loads rather than reloading
    /// the live engine. Mirrors the `whisperDefaultLanguage` save-on-didSet shape.
    public var cohereComputePolicy: CohereTranscribeEngine.ComputePolicy {
        didSet {
            cohereComputePolicy.save(to: defaults)
            Telemetry.send(.settingChanged(setting: .cohereComputePolicy))
        }
    }
    /// True when the selected compute policy differs from the one the engine
    /// loaded at launch — i.e. the change is persisted but not yet live, because
    /// the engine captures the policy at construction and only re-reads it on its
    /// next load. Drives the "Relaunch to apply" prompt in the Cohere card.
    /// (Conservative: if the engine had not loaded at launch, a fresh load would
    /// also pick up the change without a relaunch; relaunching is always safe.)
    public var cohereComputePolicyNeedsRelaunch: Bool {
        cohereComputePolicy != launchCohereComputePolicy
    }
    // The mutable state below is intentionally writable, not `private(set)`:
    // the Settings/Engine test suites inject it directly to stage preconditions
    // the async model-status refresh can't reproduce deterministically (e.g.
    // `whisperModelStatus`, `downloadedParakeetVariants`), and `SettingsView`
    // writes `speechEngineError`. Locking these down to "encapsulate" them
    // breaks the regression net — don't.
    public var speechEngineSwitching = false
    public var speechEngineSwitchTarget: SpeechEnginePreference?
    public var speechEngineSwitchDetail: String?
    public var pendingSpeechEngineSwitchConfirmation: SpeechEnginePreference?
    /// True while a Parakeet *build* swap is in flight, as opposed to
    /// an engine switch. Both set `speechEngineSwitchTarget = .parakeet`, so the
    /// banner needs this to avoid the misleading "Switching to Parakeet" copy
    /// when the user is already on Parakeet and only changing the build.
    public var isParakeetVariantSwitch = false
    /// Nemotron counterpart of `isParakeetVariantSwitch` (multilingual ↔
    /// English build swap while Nemotron is already the active engine).
    public var isNemotronVariantSwitch = false
    public var speechEngineSwitchAvailability: SpeechEngineSwitchAvailability = .available
    public var speechEngineError: String?
    public var whisperModelStatus: LocalModelStatus = .unknown
    public var whisperModelStatusDetail: String = "Not checked yet."
    public var whisperDownloading = false
    public var nemotronModelStatus: LocalModelStatus = .unknown
    public var nemotronModelStatusDetail: String = "Not checked yet."
    public var nemotronDownloading = false
    public var cohereModelStatus: LocalModelStatus = .unknown
    public var cohereModelStatusDetail: String = "Not checked yet."
    public var cohereDownloading = false
    public var cohereDeleting = false
    public var cohereCacheDirectoryExists = false
    public var isNemotronModelAvailable: Bool {
        nemotronModelStatus == .ready || nemotronModelStatus == .notLoaded
    }
    public var isWhisperModelDownloaded: Bool {
        whisperModelStatus == .ready || whisperModelStatus == .notLoaded
    }
    public var isCohereModelDownloaded: Bool {
        cohereModelStatus == .ready || cohereModelStatus == .notLoaded
    }
    /// Cohere's CoreML model has a large runtime footprint; on a low-memory Mac
    /// it risks an OS jetsam kill mid-transcription that no `catch` can recover.
    /// Selecting Cohere or downloading its model is gated to machines with at
    /// least ``cohereMinimumMemoryBytes`` of RAM.
    public static let cohereMinimumMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let cohereInsufficientMemoryMessage =
        "Cohere Transcribe needs 16 GB of memory or more — this Mac has less."
    public var cohereMeetsMemoryRequirement: Bool {
        physicalMemoryBytes() >= Self.cohereMinimumMemoryBytes
    }
    private var shouldBlockCohereSwitchForModelStatus: Bool {
        if cohereDeleting { return true }
        switch cohereModelStatus {
        case .ready, .notLoaded:
            return false
        case .checking:
            return !cohereModelCached()
        case .unknown, .notDownloaded, .preparing, .repairing, .failed:
            return true
        }
    }
    public var canDeleteCohereModel: Bool {
        isCohereModelDownloaded || cohereModelStatus == .failed || cohereCacheDirectoryExists
    }
    /// True once the active Whisper variant has paid its one-time on-device
    /// optimize, so the next load is fast. Drives cold ("Setup needed",
    /// minutes) vs warm ("Downloaded", seconds) status in the engine picker.
    /// Reads through `defaults`; the value flips after the first successful
    /// `WhisperEngine.prepare()`, surfaced on the next `refreshModelStatus()`.
    public var whisperHasBeenOptimized: Bool {
        SpeechEnginePreference.hasOptimizedWhisper(
            variant: SpeechEnginePreference.whisperModelVariant(defaults: defaults),
            defaults: defaults
        )
    }
    public var parakeetStatus: LocalModelStatus = .unknown
    public var parakeetStatusDetail: String = "Not checked yet."
    public var parakeetRepairing = false
    /// Which Parakeet builds are present on disk. Drives the per-variant
    /// download badges in the Parakeet Model card; refreshed in
    /// `refreshModelStatus()`.
    public var downloadedParakeetVariants: Set<ParakeetModelVariant> = []
    /// Which Nemotron builds are present on disk. Drives the per-variant
    /// download badges in the Nemotron Model card; refreshed in
    /// `refreshModelStatus()`. Both builds can be installed independently.
    public var downloadedNemotronVariants: Set<NemotronModelVariant> = []

    private var sttClient: STTClientProtocol?
    private var speechEngineSwitcher: SpeechEngineSwitching?
    private var speechEngineSwitchAvailabilityProvider: SpeechEngineSwitchAvailabilityProviding?
    private let defaults: UserDefaults
    /// The Cohere compute policy as it was at launch (what the running engine
    /// loaded). Compared against `cohereComputePolicy` to detect a persisted-but-
    /// not-yet-live change; see `cohereComputePolicyNeedsRelaunch`.
    private let launchCohereComputePolicy: CohereTranscribeEngine.ComputePolicy
    private let parakeetModelVariantCached: @Sendable (ParakeetModelVariant) -> Bool
    private let nemotronModelVariantCached: @Sendable (NemotronModelVariant, String?) -> Bool
    private let cohereModelCached: @Sendable () -> Bool
    private let cohereModelCacheDirectoryExistsOnDisk: @Sendable () -> Bool
    private let deleteParakeetModelOnDisk: @Sendable (ParakeetModelVariant) -> Bool
    private let deleteNemotronModelOnDisk: @Sendable (NemotronModelVariant, String?) -> Bool
    private let deleteWhisperModelOnDisk: @Sendable (String) -> Bool
    private let deleteCohereModelOnDisk: @Sendable () -> Bool
    /// Installed physical memory in bytes. Injected so the Cohere memory gate is
    /// testable on any host; defaults to this machine's RAM.
    private let physicalMemoryBytes: @Sendable () -> UInt64
    private var isApplyingSpeechEngineState = false
    private var isApplyingParakeetVariantState = false
    private var isApplyingNemotronVariantState = false
    private var modelStatusRefreshGeneration = 0

    public init(
        defaults: UserDefaults = .standard,
        parakeetModelVariantCached: @escaping @Sendable (ParakeetModelVariant) -> Bool = {
            if $0.usesUnifiedEngine { return ParakeetUnifiedEngine.isModelCached() }
            guard let version = $0.asrModelVersion else { return false }
            return STTRuntime.isModelCached(version: version)
        },
        nemotronModelVariantCached: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = {
            STTRuntime.isNemotronModelCached(modelVariant: $0, language: $1)
        },
        cohereModelCached: @escaping @Sendable () -> Bool = {
            CohereTranscribeEngine.isModelCached()
        },
        cohereModelCacheDirectoryExists: @escaping @Sendable () -> Bool = {
            CohereTranscribeEngine.hasModelCacheDirectory()
        },
        deleteParakeetModelOnDisk: @escaping @Sendable (ParakeetModelVariant) -> Bool = {
            if $0.usesUnifiedEngine { return ParakeetUnifiedEngine.deleteModel() }
            guard let version = $0.asrModelVersion else { return false }
            return STTRuntime.deleteParakeetModel(version: version)
        },
        deleteNemotronModelOnDisk: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = {
            STTRuntime.deleteNemotronModel(modelVariant: $0, language: $1)
        },
        deleteWhisperModelOnDisk: @escaping @Sendable (String) -> Bool = {
            STTRuntime.deleteWhisperModel(variant: $0)
        },
        deleteCohereModelOnDisk: @escaping @Sendable () -> Bool = {
            CohereTranscribeEngine.deleteModel()
        },
        physicalMemoryBytes: @escaping @Sendable () -> UInt64 = {
            ProcessInfo.processInfo.physicalMemory
        }
    ) {
        self.defaults = defaults
        self.parakeetModelVariantCached = parakeetModelVariantCached
        self.nemotronModelVariantCached = nemotronModelVariantCached
        self.cohereModelCached = cohereModelCached
        self.cohereModelCacheDirectoryExistsOnDisk = cohereModelCacheDirectoryExists
        self.deleteParakeetModelOnDisk = deleteParakeetModelOnDisk
        self.deleteNemotronModelOnDisk = deleteNemotronModelOnDisk
        self.deleteWhisperModelOnDisk = deleteWhisperModelOnDisk
        self.deleteCohereModelOnDisk = deleteCohereModelOnDisk
        self.physicalMemoryBytes = physicalMemoryBytes
        speechEnginePreference = SpeechEnginePreference.current(defaults: defaults)
        parakeetModelVariant = SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
        nemotronModelVariant = SpeechEnginePreference.nemotronModelVariant(defaults: defaults)
        whisperDefaultLanguage = SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults) ?? "auto"
        let launchPolicy = CohereTranscribeEngine.ComputePolicy.current(defaults: defaults)
        launchCohereComputePolicy = launchPolicy
        cohereComputePolicy = launchPolicy
    }

    public func configure(
        sttClient: STTClientProtocol? = nil,
        speechEngineSwitcher: SpeechEngineSwitching? = nil,
        speechEngineSwitchAvailabilityProvider: SpeechEngineSwitchAvailabilityProviding? = nil
    ) {
        self.sttClient = sttClient
        self.speechEngineSwitcher = speechEngineSwitcher
        self.speechEngineSwitchAvailabilityProvider = speechEngineSwitchAvailabilityProvider
            ?? (speechEngineSwitcher as? SpeechEngineSwitchAvailabilityProviding)
            ?? (sttClient as? SpeechEngineSwitchAvailabilityProviding)
    }

    public func refreshSpeechEngineSwitchAvailability() {
        Task { @MainActor [weak self] in
            _ = await self?.refreshSpeechEngineSwitchAvailabilityNow()
        }
    }

    @discardableResult
    public func refreshSpeechEngineSwitchAvailabilityNow() async -> SpeechEngineSwitchAvailability {
        guard let speechEngineSwitchAvailabilityProvider else {
            speechEngineSwitchAvailability = .available
            return .available
        }
        let availability = await speechEngineSwitchAvailabilityProvider.engineSwitchAvailability()
        speechEngineSwitchAvailability = availability
        return availability
    }

    public var speechEngineSwitchUnavailableMessage: String? {
        Self.speechEngineSwitchUnavailableMessage(for: speechEngineSwitchAvailability)
    }

    public static func speechEngineSwitchUnavailableMessage(
        for availability: SpeechEngineSwitchAvailability
    ) -> String? {
        switch availability {
        case .available:
            return nil
        case .meetingActive:
            return "Stop the meeting recording to switch engines"
        case .transcribing:
            return "Finishing transcription — switch when it completes"
        case .switchInProgress:
            return "Finishing engine switch — try again in a moment"
        case .unavailable:
            return "Speech engine is temporarily unavailable"
        }
    }

    public func requestSpeechEngineSwitchConfirmation(to preference: SpeechEnginePreference) {
        guard preference != speechEnginePreference,
              !speechEngineSwitching,
              pendingSpeechEngineSwitchConfirmation == nil else { return }
        speechEngineError = nil
        pendingSpeechEngineSwitchConfirmation = preference
    }

    public func cancelPendingSpeechEngineSwitchConfirmation() {
        pendingSpeechEngineSwitchConfirmation = nil
    }

    public func confirmPendingSpeechEngineSwitch() {
        guard let preference = pendingSpeechEngineSwitchConfirmation else { return }
        pendingSpeechEngineSwitchConfirmation = nil
        guard preference != speechEnginePreference else { return }
        guard !speechEngineSwitching else {
            speechEngineError = Self.speechEngineSwitchUnavailableMessage(for: .switchInProgress)
            return
        }
        speechEnginePreference = preference
    }

    public func refreshModelStatus() {
        modelStatusRefreshGeneration += 1
        let refreshGeneration = modelStatusRefreshGeneration
        let activeEngine = speechEnginePreference
        let activeVariant = parakeetModelVariant
        let whisperModelVariant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        let activeNemotronVariant = nemotronModelVariant
        let nemotronLanguage = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        let cohereOperationActiveAtRefreshStart = cohereDownloading || cohereDeleting

        let parakeetModelVariantCached = self.parakeetModelVariantCached
        let nemotronModelVariantCached = self.nemotronModelVariantCached
        let cohereModelCached = self.cohereModelCached
        let cohereModelCacheDirectoryExistsOnDisk = self.cohereModelCacheDirectoryExistsOnDisk

        guard let sttClient else {
            parakeetStatus = .unknown
            parakeetStatusDetail = "Unavailable in this runtime."
            nemotronModelStatus = .checking
            nemotronModelStatusDetail = "Checking model state..."
            whisperModelStatus = .checking
            whisperModelStatusDetail = "Checking model state..."
            if !cohereOperationActiveAtRefreshStart {
                cohereModelStatus = .checking
                cohereModelStatusDetail = "Checking model state..."
            }
            Task { @MainActor [weak self] in
                let disk = await Task.detached(priority: .userInitiated) {
                    (
                        parakeetDownloaded: Set(ParakeetModelVariant.allCases.filter(parakeetModelVariantCached)),
                        nemotronDownloaded: Set(NemotronModelVariant.allCases.filter {
                            nemotronModelVariantCached($0, nemotronLanguage)
                        }),
                        whisperDownloaded: WhisperEngine.isModelDownloaded(model: whisperModelVariant),
                        cohereDownloaded: cohereModelCached(),
                        cohereCacheDirectoryExists: cohereModelCacheDirectoryExistsOnDisk()
                    )
                }.value
                guard let self,
                      self.modelStatusRefreshGeneration == refreshGeneration,
                      self.speechEnginePreference == activeEngine,
                      self.parakeetModelVariant == activeVariant,
                      self.nemotronModelVariant == activeNemotronVariant else {
                    return
                }
                self.downloadedParakeetVariants = disk.parakeetDownloaded
                self.downloadedNemotronVariants = disk.nemotronDownloaded
                let canApplyCohereStatus = !cohereOperationActiveAtRefreshStart &&
                    !self.cohereDownloading &&
                    !self.cohereDeleting
                if canApplyCohereStatus {
                    self.cohereCacheDirectoryExists = disk.cohereCacheDirectoryExists
                }
                self.applyNemotronDownloadedStatus(disk.nemotronDownloaded.contains(activeNemotronVariant))
                self.applyWhisperDownloadedStatus(disk.whisperDownloaded)
                if canApplyCohereStatus {
                    self.applyCohereDownloadedStatus(disk.cohereDownloaded)
                }
            }
            return
        }

        parakeetStatus = .checking
        parakeetStatusDetail = "Checking model state..."
        nemotronModelStatus = .checking
        nemotronModelStatusDetail = "Checking model state..."
        whisperModelStatus = .checking
        whisperModelStatusDetail = "Checking model state..."
        if !cohereOperationActiveAtRefreshStart {
            cohereModelStatus = .checking
            cohereModelStatusDetail = "Checking model state..."
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // `sttClient.isReady()` returns the *active* engine's loaded state
            // (see STTRuntime.isReady), so we apply it to whichever engine is
            // currently selected and keep the inactive engine on its disk-cache
            // status. Without this branch, switching to Whisper left the
            // Whisper badge stuck at "Not Loaded" forever.
            //
            // Use the selection snapshot captured before the async work so a
            // mid-suspension toggle can't pair a new preference with old
            // readiness.
            async let activeEngineLoaded = sttClient.isReady()
            async let diskState = Task.detached(priority: .userInitiated) {
                (
                    parakeetDownloaded: Set(ParakeetModelVariant.allCases.filter(parakeetModelVariantCached)),
                    nemotronDownloaded: Set(NemotronModelVariant.allCases.filter {
                        nemotronModelVariantCached($0, nemotronLanguage)
                    }),
                    whisperDownloaded: WhisperEngine.isModelDownloaded(model: whisperModelVariant),
                    cohereDownloaded: cohereModelCached(),
                    cohereCacheDirectoryExists: cohereModelCacheDirectoryExistsOnDisk()
                )
            }.value

            let (activeEngineIsLoaded, modelDiskState) = await (activeEngineLoaded, diskState)
            guard self.modelStatusRefreshGeneration == refreshGeneration,
                  self.speechEnginePreference == activeEngine,
                  self.parakeetModelVariant == activeVariant,
                  self.nemotronModelVariant == activeNemotronVariant else {
                return
            }

            self.downloadedParakeetVariants = modelDiskState.parakeetDownloaded
            self.downloadedNemotronVariants = modelDiskState.nemotronDownloaded
            let canApplyCohereStatus = !cohereOperationActiveAtRefreshStart &&
                !self.cohereDownloading &&
                !self.cohereDeleting
            if canApplyCohereStatus {
                self.cohereCacheDirectoryExists = modelDiskState.cohereCacheDirectoryExists
            }
            let parakeetName = activeVariant.modelName
            if activeEngine == .parakeet, activeEngineIsLoaded {
                self.parakeetStatus = .ready
                self.parakeetStatusDetail = "\(parakeetName) · Loaded locally with Core ML."
            } else if modelDiskState.parakeetDownloaded.contains(activeVariant) {
                self.parakeetStatus = .notLoaded
                self.parakeetStatusDetail = "\(parakeetName) · Installed locally, loads when selected."
            } else {
                self.parakeetStatus = .notDownloaded
                self.parakeetStatusDetail = "\(parakeetName) · Needs model setup before use."
            }

            if activeEngine == .nemotron, activeEngineIsLoaded {
                self.nemotronModelStatus = .ready
                self.nemotronModelStatusDetail = "\(activeNemotronVariant.modelName) · Loaded in memory."
            } else {
                self.applyNemotronDownloadedStatus(modelDiskState.nemotronDownloaded.contains(activeNemotronVariant))
            }

            if activeEngine == .whisper, activeEngineIsLoaded {
                self.whisperModelStatus = .ready
                self.whisperModelStatusDetail = "\(self.whisperVariantFriendlyName) · Loaded in memory."
            } else {
                self.applyWhisperDownloadedStatus(modelDiskState.whisperDownloaded)
            }

            if activeEngine == .cohere, activeEngineIsLoaded, canApplyCohereStatus {
                self.cohereModelStatus = .ready
                self.cohereModelStatusDetail = "Cohere Transcribe · Loaded in memory."
            } else if canApplyCohereStatus {
                self.applyCohereDownloadedStatus(modelDiskState.cohereDownloaded)
            }
        }
    }

    public func refreshWhisperModelStatus() {
        applyWhisperDownloadedStatus(
            WhisperEngine.isModelDownloaded(model: SpeechEnginePreference.whisperModelVariant(defaults: defaults))
        )
    }

    public func refreshNemotronModelStatus() {
        let language = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        downloadedNemotronVariants = Set(NemotronModelVariant.allCases.filter {
            nemotronModelVariantCached($0, language)
        })
        applyNemotronDownloadedStatus(downloadedNemotronVariants.contains(nemotronModelVariant))
    }

    /// Applies the disk state of the *selected* Nemotron build to the Local
    /// Models row (per-build badges read `downloadedNemotronVariants`).
    private func applyNemotronDownloadedStatus(_ isDownloaded: Bool) {
        let variant = nemotronModelVariant
        if isDownloaded {
            nemotronModelStatus = .notLoaded
            nemotronModelStatusDetail = "\(variant.modelName) · Installed locally, loads when selected."
        } else {
            nemotronModelStatus = .notDownloaded
            nemotronModelStatusDetail = "\(variant.modelName) · Needs download before use."
        }
    }

    private func applyWhisperDownloadedStatus(_ isDownloaded: Bool) {
        let friendly = whisperVariantFriendlyName
        if isDownloaded {
            // Optimistic file-based check; `refreshModelStatus()` will upgrade
            // to `.ready` after asking the runtime if Whisper is the active
            // engine and currently loaded.
            whisperModelStatus = .notLoaded
            if whisperHasBeenOptimized {
                whisperModelStatusDetail = "\(friendly) · Installed locally, loads in seconds."
            } else {
                whisperModelStatusDetail = "\(friendly) · Installed locally. First switch can take 3-5 minutes while Core ML optimizes it."
            }
        } else {
            whisperModelStatus = .notDownloaded
            whisperModelStatusDetail = "\(friendly) · Needs download before use."
        }
    }

    private func applyCohereDownloadedStatus(_ isDownloaded: Bool) {
        if isDownloaded {
            cohereModelStatus = .notLoaded
            cohereModelStatusDetail = "Cohere Transcribe · Installed locally, loads when selected."
        } else {
            cohereModelStatus = .notDownloaded
            cohereModelStatusDetail = "Cohere Transcribe · Needs download before use."
        }
    }

    private var whisperVariantFriendlyName: String {
        SpeechEnginePreference.friendlyVariantName(
            SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        )
    }

    public func downloadNemotronModel() {
        guard !speechEngineSwitching else { return }
        guard !nemotronDownloading else { return }
        speechEngineError = nil
        nemotronDownloading = true
        nemotronModelStatus = .repairing
        let modelVariant = nemotronModelVariant
        let language = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        let operationContext = Observability.childOperationContext()
        nemotronModelStatusDetail = "Downloading \(modelVariant.modelName)..."
        Telemetry.send(.modelDownloadStarted(
            modelKind: .nemotronSTT,
            speechEngine: .nemotron,
            engineVariant: modelVariant.rawValue
        ))

        Task {
            do {
                try await STTRuntime.downloadNemotronModel(
                    modelVariant: modelVariant,
                    language: language,
                    emitTelemetry: false
                ) { message in
                    Task { @MainActor [weak self] in
                        self?.nemotronModelStatusDetail = message
                    }
                }
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelDownloadCompleted(
                    durationSeconds: durationSeconds,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .success,
                    stage: .download,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue,
                    durationSeconds: durationSeconds,
                    errorType: nil
                ))
                self.nemotronDownloading = false
                self.refreshNemotronModelStatus()
            } catch is CancellationError {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .cancelled,
                    stage: .download,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue,
                    durationSeconds: durationSeconds,
                    errorType: "CancellationError"
                ))
                self.nemotronDownloading = false
                self.refreshNemotronModelStatus()
            } catch {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                let errorType = TelemetryErrorClassifier.classify(error)
                Telemetry.send(.modelDownloadFailed(
                    errorType: errorType,
                    errorDetail: TelemetryErrorClassifier.errorDetail(error),
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .failure,
                    stage: .download,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue,
                    durationSeconds: durationSeconds,
                    errorType: errorType
                ))
                self.nemotronDownloading = false
                self.nemotronModelStatus = .failed
                self.nemotronModelStatusDetail = error.localizedDescription
            }
        }
    }

    public func downloadWhisperModel() {
        guard !speechEngineSwitching else { return }
        guard !whisperDownloading else { return }
        // The user has taken the action that resolves any pending
        // "Whisper isn't ready" error, so clear it. Otherwise the red
        // banner persists through a successful download (the engine
        // preference setter — the only other place that clears it —
        // never fires for the same-state assignment).
        speechEngineError = nil
        whisperDownloading = true
        whisperModelStatus = .repairing
        let modelVariant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        let friendly = SpeechEnginePreference.friendlyVariantName(modelVariant)
        let operationContext = Observability.childOperationContext()
        whisperModelStatusDetail = "Downloading Whisper \(friendly)..."
        Telemetry.send(.modelDownloadStarted(
            modelKind: .whisperSTT,
            speechEngine: .whisper,
            engineVariant: modelVariant
        ))

        Task {
            do {
                _ = try await WhisperEngine.downloadModel(
                    model: modelVariant
                ) { completed, total in
                    let percent = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded()) : 0
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.whisperModelStatusDetail = "Downloading Whisper \(friendly)... \(min(max(percent, 0), 100))%"
                    }
                }
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelDownloadCompleted(
                    durationSeconds: durationSeconds,
                    modelKind: .whisperSTT,
                    speechEngine: .whisper,
                    engineVariant: modelVariant
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .success,
                    stage: .download,
                    modelKind: .whisperSTT,
                    speechEngine: .whisper,
                    engineVariant: modelVariant,
                    durationSeconds: durationSeconds,
                    errorType: nil
                ))
                self.whisperDownloading = false
                self.refreshWhisperModelStatus()
            } catch is CancellationError {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .cancelled,
                    stage: .download,
                    modelKind: .whisperSTT,
                    speechEngine: .whisper,
                    engineVariant: modelVariant,
                    durationSeconds: durationSeconds,
                    errorType: "CancellationError"
                ))
                self.whisperDownloading = false
                self.refreshWhisperModelStatus()
            } catch {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                let errorType = TelemetryErrorClassifier.classify(error)
                Telemetry.send(.modelDownloadFailed(
                    errorType: errorType,
                    errorDetail: TelemetryErrorClassifier.errorDetail(error),
                    modelKind: .whisperSTT,
                    speechEngine: .whisper,
                    engineVariant: modelVariant
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .failure,
                    stage: .download,
                    modelKind: .whisperSTT,
                    speechEngine: .whisper,
                    engineVariant: modelVariant,
                    durationSeconds: durationSeconds,
                    errorType: errorType
                ))
                self.whisperDownloading = false
                self.whisperModelStatus = .failed
                self.whisperModelStatusDetail = error.localizedDescription
            }
        }
    }

    public func downloadCohereModel() {
        guard !speechEngineSwitching else { return }
        guard !cohereDownloading, !cohereDeleting else { return }
        guard cohereMeetsMemoryRequirement else {
            speechEngineError = Self.cohereInsufficientMemoryMessage
            return
        }
        speechEngineError = nil
        cohereDownloading = true
        cohereModelStatus = .repairing
        cohereModelStatusDetail = "Downloading Cohere Transcribe..."
        let operationContext = Observability.childOperationContext()
        let engineVariant = CohereTranscribeEngine.ComputePolicy.current(defaults: defaults).rawValue
        Telemetry.send(.modelDownloadStarted(
            modelKind: .cohereSTT,
            speechEngine: .cohere,
            engineVariant: engineVariant
        ))

        Task { @MainActor [weak self] in
            do {
                _ = try await CohereTranscribeEngine.downloadModel { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.cohereModelStatusDetail = message
                    }
                }
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelDownloadCompleted(
                    durationSeconds: durationSeconds,
                    modelKind: .cohereSTT,
                    speechEngine: .cohere,
                    engineVariant: engineVariant
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .success,
                    stage: .download,
                    modelKind: .cohereSTT,
                    speechEngine: .cohere,
                    engineVariant: engineVariant,
                    durationSeconds: durationSeconds,
                    errorType: nil
                ))
                guard let self else { return }
                self.cohereDownloading = false
                self.refreshModelStatus()
            } catch is CancellationError {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .cancelled,
                    stage: .download,
                    modelKind: .cohereSTT,
                    speechEngine: .cohere,
                    engineVariant: engineVariant,
                    durationSeconds: durationSeconds,
                    errorType: "CancellationError"
                ))
                guard let self else { return }
                self.cohereDownloading = false
                self.refreshModelStatus()
            } catch {
                let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
                let errorType = TelemetryErrorClassifier.classify(error)
                Telemetry.send(.modelDownloadFailed(
                    errorType: errorType,
                    errorDetail: TelemetryErrorClassifier.errorDetail(error),
                    modelKind: .cohereSTT,
                    speechEngine: .cohere,
                    engineVariant: engineVariant
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .failure,
                    stage: .download,
                    modelKind: .cohereSTT,
                    speechEngine: .cohere,
                    engineVariant: engineVariant,
                    durationSeconds: durationSeconds,
                    errorType: errorType
                ))
                guard let self else { return }
                self.cohereDownloading = false
                self.cohereModelStatus = .failed
                self.cohereModelStatusDetail = error.localizedDescription
            }
        }
    }

    private func applySpeechEngineChange(_ preference: SpeechEnginePreference) {
        speechEngineError = nil
        let previousPreference = SpeechEnginePreference.current(defaults: defaults)
        let operationContext = Observability.childOperationContext()
        let switchWasCold = SpeechEnginePreference.isColdSwitch(to: preference, defaults: defaults)

        if preference == .nemotron && !isNemotronModelAvailable {
            speechEngineError = "Download the Nemotron model before switching engines."
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: preference,
                outcome: .unavailable,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: .modelNotDownloaded,
                errorType: "model_not_downloaded",
                wasCold: switchWasCold
            ))
            isApplyingSpeechEngineState = true
            speechEnginePreference = previousPreference
            isApplyingSpeechEngineState = false
            return
        }

        if preference == .whisper && !isWhisperModelDownloaded {
            speechEngineError = "Download the Whisper model before switching engines."
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: preference,
                outcome: .unavailable,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: .modelNotDownloaded,
                errorType: "model_not_downloaded",
                wasCold: switchWasCold
            ))
            isApplyingSpeechEngineState = true
            speechEnginePreference = previousPreference
            isApplyingSpeechEngineState = false
            return
        }

        if preference == .cohere && !cohereMeetsMemoryRequirement {
            speechEngineError = Self.cohereInsufficientMemoryMessage
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: preference,
                outcome: .unavailable,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: .insufficientMemory,
                errorType: "insufficient_memory",
                wasCold: switchWasCold
            ))
            isApplyingSpeechEngineState = true
            speechEnginePreference = previousPreference
            isApplyingSpeechEngineState = false
            return
        }

        if preference == .cohere && shouldBlockCohereSwitchForModelStatus {
            speechEngineError = cohereDeleting
                ? "Finish deleting Cohere Transcribe before switching engines."
                : "Download Cohere Transcribe before switching engines."
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: preference,
                outcome: .unavailable,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: .modelNotDownloaded,
                errorType: "model_not_downloaded",
                wasCold: switchWasCold
            ))
            isApplyingSpeechEngineState = true
            speechEnginePreference = previousPreference
            isApplyingSpeechEngineState = false
            return
        }

        guard let speechEngineSwitcher else {
            preference.save(to: defaults)
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: preference,
                outcome: .success,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: nil,
                errorType: nil,
                wasCold: switchWasCold
            ))
            return
        }

        speechEngineSwitching = true
        speechEngineSwitchTarget = preference
        speechEngineSwitchDetail = Self.initialSpeechEngineSwitchDetail(
            for: preference,
            nemotronVariant: nemotronModelVariant
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            // `defer` fires even on cancellation or unexpected early exit, so
            // the segmented Picker can never get pinned in the disabled
            // "Switching..." state.
            defer {
                self.speechEngineSwitching = false
                self.speechEngineSwitchTarget = nil
                self.speechEngineSwitchDetail = nil
                self.refreshModelStatus()
            }
            let availability = await self.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                let blockedReason = Self.telemetrySpeechEngineSwitchBlockedReason(for: availability)
                self.speechEngineError = Self.speechEngineSwitchUnavailableMessage(for: availability)
                Telemetry.send(.speechEngineSwitchOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    fromEngine: previousPreference,
                    toEngine: preference,
                    outcome: .unavailable,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    blockedReason: blockedReason,
                    errorType: blockedReason?.rawValue,
                    wasCold: switchWasCold
                ))
                self.isApplyingSpeechEngineState = true
                self.speechEnginePreference = SpeechEnginePreference.current(defaults: self.defaults)
                self.isApplyingSpeechEngineState = false
                return
            }
            do {
                try await Observability.withOperationContext(operationContext) {
                    try await speechEngineSwitcher.setSpeechEngine(preference) { [weak self] message in
                        Task { @MainActor [weak self] in
                            self?.speechEngineSwitchDetail = message
                        }
                    }
                }
                preference.save(to: self.defaults)
                Telemetry.send(.speechEngineSwitchOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    fromEngine: previousPreference,
                    toEngine: preference,
                    outcome: .success,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    blockedReason: nil,
                    errorType: nil,
                    wasCold: switchWasCold
                ))
            } catch is CancellationError {
                Telemetry.send(.speechEngineSwitchOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    fromEngine: previousPreference,
                    toEngine: preference,
                    outcome: .cancelled,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    blockedReason: nil,
                    errorType: "CancellationError",
                    wasCold: switchWasCold
                ))
                self.isApplyingSpeechEngineState = true
                self.speechEnginePreference = SpeechEnginePreference.current(defaults: self.defaults)
                self.isApplyingSpeechEngineState = false
            } catch {
                let errorType = TelemetryErrorClassifier.classify(error)
                self.speechEngineError = error.localizedDescription
                Telemetry.send(.speechEngineSwitchOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    fromEngine: previousPreference,
                    toEngine: preference,
                    outcome: .failure,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    blockedReason: Self.telemetrySpeechEngineSwitchBlockedReason(for: error),
                    errorType: errorType,
                    wasCold: switchWasCold
                ))
                self.isApplyingSpeechEngineState = true
                self.speechEnginePreference = SpeechEnginePreference.current(defaults: self.defaults)
                self.isApplyingSpeechEngineState = false
            }
        }
    }

    /// Applies a Parakeet variant toggle (`v3`, `v2`, or `unified`). Mirrors
    /// `applySpeechEngineChange`: validates switch availability,
    /// drives the shared switch banner, persists only after the runtime reload
    /// succeeds, and reverts the published value on block/cancel/failure.
    private func applyParakeetModelVariantChange(_ variant: ParakeetModelVariant) {
        speechEngineError = nil
        let previousVariant = SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
        guard variant != previousVariant else { return }

        guard let speechEngineSwitcher else {
            // No runtime wired (previews/tests): just persist the choice.
            SpeechEnginePreference.saveParakeetModelVariant(variant, defaults: defaults)
            Telemetry.send(.settingChanged(setting: .parakeetModelVariant))
            return
        }

        speechEngineSwitching = true
        speechEngineSwitchTarget = .parakeet
        isParakeetVariantSwitch = true
        speechEngineSwitchDetail = "Preparing \(variant.modelName)..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.speechEngineSwitching = false
                self.speechEngineSwitchTarget = nil
                self.isParakeetVariantSwitch = false
                self.speechEngineSwitchDetail = nil
                self.refreshModelStatus()
            }
            let availability = await self.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                self.speechEngineError = Self.speechEngineSwitchUnavailableMessage(for: availability)
                self.revertParakeetModelVariant()
                return
            }
            do {
                try await speechEngineSwitcher.setParakeetModelVariant(variant) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.speechEngineSwitchDetail = message
                    }
                }
                SpeechEnginePreference.saveParakeetModelVariant(variant, defaults: self.defaults)
                Telemetry.send(.settingChanged(setting: .parakeetModelVariant))
            } catch is CancellationError {
                self.revertParakeetModelVariant()
            } catch {
                self.speechEngineError = error.localizedDescription
                self.revertParakeetModelVariant()
            }
        }
    }

    /// Snaps the published variant back to the persisted value without
    /// re-triggering a switch (the `isApplyingParakeetVariantState` guard).
    private func revertParakeetModelVariant() {
        isApplyingParakeetVariantState = true
        parakeetModelVariant = SpeechEnginePreference.parakeetModelVariant(defaults: defaults)
        isApplyingParakeetVariantState = false
    }

    /// Applies a Nemotron build toggle (multilingual ↔ English-only). Mirrors
    /// `applyParakeetModelVariantChange`: validates switch availability,
    /// drives the shared switch banner, persists only after the runtime reload
    /// succeeds, and reverts the published value on block/cancel/failure.
    private func applyNemotronModelVariantChange(_ variant: NemotronModelVariant) {
        speechEngineError = nil
        let previousVariant = SpeechEnginePreference.nemotronModelVariant(defaults: defaults)
        guard variant != previousVariant else { return }

        guard let speechEngineSwitcher else {
            // No runtime wired (previews/tests): just persist the choice.
            SpeechEnginePreference.saveNemotronModelVariant(variant, defaults: defaults)
            Telemetry.send(.settingChanged(setting: .nemotronModelVariant))
            return
        }

        speechEngineSwitching = true
        speechEngineSwitchTarget = .nemotron
        isNemotronVariantSwitch = true
        speechEngineSwitchDetail = "Preparing \(variant.modelName)..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.speechEngineSwitching = false
                self.speechEngineSwitchTarget = nil
                self.isNemotronVariantSwitch = false
                self.speechEngineSwitchDetail = nil
                self.refreshModelStatus()
            }
            let availability = await self.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                self.speechEngineError = Self.speechEngineSwitchUnavailableMessage(for: availability)
                self.revertNemotronModelVariant()
                return
            }
            do {
                try await speechEngineSwitcher.setNemotronModelVariant(variant) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.speechEngineSwitchDetail = message
                    }
                }
                SpeechEnginePreference.saveNemotronModelVariant(variant, defaults: self.defaults)
                Telemetry.send(.settingChanged(setting: .nemotronModelVariant))
            } catch is CancellationError {
                self.revertNemotronModelVariant()
            } catch {
                self.speechEngineError = error.localizedDescription
                self.revertNemotronModelVariant()
            }
        }
    }

    /// Snaps the published variant back to the persisted value without
    /// re-triggering a switch (the `isApplyingNemotronVariantState` guard).
    private func revertNemotronModelVariant() {
        isApplyingNemotronVariantState = true
        nemotronModelVariant = SpeechEnginePreference.nemotronModelVariant(defaults: defaults)
        isApplyingNemotronVariantState = false
    }

    public func repairParakeetModel() {
        guard let sttClient else { return }
        guard !speechEngineSwitching else { return }
        guard !parakeetRepairing else { return }
        speechEngineError = nil
        parakeetRepairing = true
        parakeetStatus = .repairing
        parakeetStatusDetail = "Preparing speech model..."
        let operationContext = Observability.childOperationContext()

        Task {
            do {
                try await Observability.withOperationContext(operationContext) {
                    try await runWithRetry(maxAttempts: 3, onRetry: { [weak self] attempt in
                        guard let self else { return }
                        self.parakeetStatusDetail = "Retrying speech model setup (attempt \(attempt)/3)..."
                    }) {
                        try await sttClient.warmUp { [weak self] progressMessage in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.parakeetStatusDetail = progressMessage
                            }
                        }
                    }
                }
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .repair,
                    outcome: .success,
                    stage: .warmUp,
                    modelKind: .parakeetSTT,
                    speechEngine: .parakeet,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    errorType: nil
                ))

                self.parakeetRepairing = false
                self.refreshModelStatus()
            } catch is CancellationError {
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .repair,
                    outcome: .cancelled,
                    stage: .warmUp,
                    modelKind: .parakeetSTT,
                    speechEngine: .parakeet,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    errorType: "CancellationError"
                ))
                self.parakeetRepairing = false
                self.refreshModelStatus()
            } catch {
                let errorType = TelemetryErrorClassifier.classify(error)
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .repair,
                    outcome: .failure,
                    stage: .warmUp,
                    modelKind: .parakeetSTT,
                    speechEngine: .parakeet,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    errorType: errorType
                ))
                self.parakeetRepairing = false
                self.parakeetStatus = .failed
                self.parakeetStatusDetail = error.localizedDescription
            }
        }
    }

    /// Removes a downloaded Parakeet build, freeing ~465 MB. The selected
    /// Parakeet build is protected — the UI only offers delete for the other,
    /// downloaded build, and the guards here enforce that even if a stale tap
    /// slips through. The "Downloaded" badge drops immediately; a disk refresh
    /// then confirms.
    public func deleteParakeetVariant(_ variant: ParakeetModelVariant) {
        guard !speechEngineSwitching else { return }
        // Never delete the selected Parakeet build. Even while Whisper is the
        // active engine, this is the build Parakeet would load after a switch.
        guard parakeetModelVariant != variant else { return }
        guard downloadedParakeetVariants.contains(variant) else { return }

        // Invalidate any in-flight status refresh so it can't re-add the badge
        // we're about to drop (the files linger on disk until the detached
        // delete runs).
        modelStatusRefreshGeneration += 1
        // Optimistic: drop the badge now so the row can't be tapped twice; the
        // refresh below reconciles against disk.
        downloadedParakeetVariants.remove(variant)

        let deleter = deleteParakeetModelOnDisk
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = deleter(variant)
            }.value
            guard let self else { return }
            self.refreshModelStatus()
        }
    }

    /// Removes a downloaded Nemotron build. The non-selected build is
    /// deletable any time (Nemotron Model card). The selected build is
    /// protected while Nemotron is the active engine; when Nemotron is
    /// inactive it keeps its existing delete affordance (Local Models
    /// overflow) so the next active use has an explicit download moment
    /// instead of a surprise re-fetch.
    public func deleteNemotronVariant(_ variant: NemotronModelVariant) {
        guard !speechEngineSwitching, !nemotronDownloading else { return }
        if speechEnginePreference == .nemotron, nemotronModelVariant == variant { return }
        guard downloadedNemotronVariants.contains(variant) else { return }

        let deleter = deleteNemotronModelOnDisk
        // Invalidate any in-flight status refresh so it can't re-add the badge
        // we're about to drop (the files linger on disk until the detached
        // delete runs).
        modelStatusRefreshGeneration += 1
        // Optimistic: drop the badge now so the row can't be tapped twice; the
        // refresh below reconciles against disk.
        downloadedNemotronVariants.remove(variant)
        if nemotronModelVariant == variant {
            applyNemotronDownloadedStatus(false)
        }
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = deleter(variant, nil)
            }.value
            guard let self else { return }
            self.refreshModelStatus()
        }
    }

    /// Removes the downloaded Whisper variant, freeing ~632 MB. Only callable
    /// while Parakeet is the active engine — deleting the model behind the
    /// active engine would force a silent re-download. State flips to
    /// "Not Downloaded" immediately; a disk refresh then confirms.
    public func deleteWhisperModel() {
        guard !speechEngineSwitching, !whisperDownloading else { return }
        // Protect the in-use engine's model.
        guard speechEnginePreference != .whisper else { return }
        guard isWhisperModelDownloaded else { return }

        let variant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        let deleter = deleteWhisperModelOnDisk
        // Invalidate any in-flight status refresh so it can't flip the badge
        // back to "Installed" (the file lingers until the detached delete runs)
        // and re-expose the delete action for a ghost second tap.
        modelStatusRefreshGeneration += 1
        // Optimistic: render the not-downloaded state now so the delete action
        // disappears before the async file work finishes.
        applyWhisperDownloadedStatus(false)
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = deleter(variant)
            }.value
            guard let self else { return }
            self.refreshModelStatus()
        }
    }

    public func deleteCohereModel() {
        guard !speechEngineSwitching, !cohereDownloading, !cohereDeleting else { return }
        // Protect the in-use engine's model; deleting it would force a silent
        // re-download the next time the active runtime prepares.
        guard speechEnginePreference != .cohere else { return }
        guard canDeleteCohereModel else { return }

        cohereDeleting = true
        modelStatusRefreshGeneration += 1
        cohereCacheDirectoryExists = false
        applyCohereDownloadedStatus(false)
        let deleter = deleteCohereModelOnDisk
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = deleter()
            }.value
            guard let self else { return }
            self.cohereDeleting = false
            self.refreshModelStatus()
        }
    }

    private static func telemetrySpeechEngineSwitchBlockedReason(
        for error: Error
    ) -> TelemetrySpeechEngineSwitchBlockedReason? {
        guard let sttError = error as? STTError else { return nil }
        switch sttError {
        case .engineBusy:
            return .engineBusy
        case .modelDownloadFailed, .modelNotLoaded:
            return .modelNotDownloaded
        case .engineNotRunning,
             .engineStartFailed,
             .transcriptionFailed,
             .timeout,
             .outOfMemory,
             .invalidResponse:
            return nil
        }
    }

    private static func telemetrySpeechEngineSwitchBlockedReason(
        for availability: SpeechEngineSwitchAvailability
    ) -> TelemetrySpeechEngineSwitchBlockedReason? {
        switch availability {
        case .available:
            return nil
        case .meetingActive:
            return .meetingActive
        case .transcribing:
            return .transcribing
        case .switchInProgress:
            return .switchInProgress
        case .unavailable:
            return .unavailable
        }
    }

    private static func initialSpeechEngineSwitchDetail(
        for preference: SpeechEnginePreference,
        nemotronVariant: NemotronModelVariant
    ) -> String {
        switch preference {
        case .parakeet:
            "Loading Parakeet with Core ML..."
        case .nemotron:
            nemotronVariant.isEnglishOnly
                ? "Loading Nemotron Speech EN Beta with Core ML..."
                : "Loading Nemotron 3.5 Beta with Core ML..."
        case .whisper:
            "Optimizing Whisper for this Mac..."
        case .cohere:
            "Loading Cohere with Core ML..."
        }
    }

    private func runWithRetry(
        maxAttempts: Int,
        onRetry: @escaping @MainActor (_ nextAttempt: Int) -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        var delayNs: UInt64 = 250_000_000
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                try await operation()
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                onRetry(attempt + 1)
                try await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }

        throw lastError ?? STTError.engineStartFailed("Model setup failed.")
    }
}
