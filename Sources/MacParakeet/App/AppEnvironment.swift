import Foundation
import MacParakeetCore
import MacParakeetViewModels
import OSLog

/// Service container: creates and wires up all dependencies.
@MainActor
final class AppEnvironment {
    let databaseManager: DatabaseManager
    let dictationRepo: DictationRepository
    let transcriptionRepo: TranscriptionRepository
    let customWordRepo: CustomWordRepository
    let snippetRepo: TextSnippetRepository
    let chatConversationRepo: ChatConversationRepository
    let promptRepo: PromptRepository
    let promptResultRepo: PromptResultRepository
    let llmRunRepo: LLMRunRepository
    let aiFormatterProfileRepo: AIFormatterProfileRepository
    let transformHistoryRepo: TransformHistoryRepository
    let quickPromptRepo: QuickPromptRepository
    let sttRuntime: STTRuntime
    let sttScheduler: STTScheduler
    let sharedMicStream: SharedMicrophoneStream
    let audioProcessor: AudioProcessor
    let meetingRecordingService: MeetingRecordingService
    let meetingRecordingRecoveryService: MeetingRecordingRecoveryService
    let dictationService: DictationService
    let transcriptionService: TranscriptionService
    let youtubeDownloader: YouTubeDownloader
    let diarizationService: DiarizationService
    /// Stateless; fetches the Silero VAD model for VAD-guided meeting live
    /// chunking. Consumed by `AppDelegate.scheduleDeferredSpeechPreWarm` on every
    /// launch (gated on `AppFeatures.meetingVadLiveChunkingEnabled`) so the
    /// installed base — not just fresh installs — acquires the model. See
    /// `MeetingVADLaunchPrep` and the VAD plan §6 (Phase 4.5).
    let meetingVADModelPreparer: any MeetingVADModelPreparing = MeetingVADModelPreparer()
    let clipboardService: ClipboardService
    let systemMediaController: SystemMediaController
    let exportService: ExportService
    let permissionService: PermissionService
    let accessibilityService: AccessibilityService
    let focusedAppContextService: FocusedAppContextService
    let entitlementsService: EntitlementsService
    let launchAtLoginService: LaunchAtLoginService
    let checkoutURL: URL?
    let telemetryService: TelemetryService
    let llmClient: RoutingLLMClient
    let llmConfigStore: LLMConfigStore
    let llmService: LLMService
    let runtimePreferences: AppRuntimePreferencesProtocol
    let derivedFieldsBackfill: DerivedFieldsBackfillService

    init(databaseManager: DatabaseManager) throws {
        self.databaseManager = databaseManager

        // Repositories
        dictationRepo = DictationRepository(dbQueue: databaseManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: databaseManager.dbQueue)
        customWordRepo = CustomWordRepository(dbQueue: databaseManager.dbQueue)
        snippetRepo = TextSnippetRepository(dbQueue: databaseManager.dbQueue)
        chatConversationRepo = ChatConversationRepository(dbQueue: databaseManager.dbQueue)
        promptRepo = PromptRepository(dbQueue: databaseManager.dbQueue)
        promptResultRepo = PromptResultRepository(dbQueue: databaseManager.dbQueue)
        llmRunRepo = LLMRunRepository(dbQueue: databaseManager.dbQueue)
        aiFormatterProfileRepo = AIFormatterProfileRepository(dbQueue: databaseManager.dbQueue)
        transformHistoryRepo = TransformHistoryRepository(dbQueue: databaseManager.dbQueue)
        quickPromptRepo = QuickPromptRepository(dbQueue: databaseManager.dbQueue)

        // Services
        let llmConfigStore = LLMConfigStore()
        Self.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: .standard,
            configStore: llmConfigStore
        )
        let runtimePreferences = UserDefaultsAppRuntimePreferences()
        self.runtimePreferences = runtimePreferences
        let selectedInputDeviceUIDProvider: @Sendable () -> String? = { [runtimePreferences] in
            runtimePreferences.selectedMicrophoneDeviceUID
        }
        let meetingAudioSourceModeProvider: @Sendable () -> MeetingAudioSourceMode = { [runtimePreferences] in
            runtimePreferences.meetingAudioSourceMode
        }

        sttRuntime = STTRuntime(
            modelVersion: SpeechEnginePreference.parakeetModelVariant().asrModelVersion,
            speechEngine: SpeechEnginePreference.current(),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant()
        )
        sttScheduler = STTScheduler(runtime: sttRuntime)
        // Ship raw meeting mic capture by default. VPIO remains available for
        // explicit experiments, but enabling it during live calls can degrade
        // the outgoing mic heard by other participants.
        let meetingMicProcessingMode: MeetingMicProcessingMode = .raw
        // Build the device-attempt chain lazily on each engine start so a
        // user changing their mic in Settings between meetings sees the new
        // selection.
        let attemptsBuilder: AVAudioEngineMicrophonePlatform.DeviceAttemptsBuilder = {
            let selectedUID = AudioDeviceManager.normalizedUID(selectedInputDeviceUIDProvider())
            let selectedID = selectedUID.flatMap { AudioDeviceManager.inputDeviceID(forUID: $0) }
            let defaultID = AudioDeviceManager.defaultInputDevice()
            let builtInID = AudioDeviceManager.builtInMicrophone()
            return meetingInputDeviceAttempts(
                selectedUID: selectedUID,
                selectedInputDeviceID: { _ in selectedID },
                defaultInputDevice: { defaultID },
                builtInMicrophone: { builtInID }
            )
        }
        sharedMicStream = SharedMicrophoneStream(
            platform: AVAudioEngineMicrophonePlatform(deviceAttemptsBuilder: attemptsBuilder)
        )
        // The Instant Dictation warm lease asks this before holding the mic
        // open while idle. First attempt in the chain = the device the engine
        // will start on (selected if resolvable, else system default).
        // Bluetooth inputs are suppressed: an idle open mic pins the headset
        // in HFP/SCO and degrades playback the whole time (issue #481).
        let warmCaptureInputIsBluetooth: @Sendable () -> Bool = {
            // Fail closed: an unresolvable input (mid device transition —
            // exactly when Bluetooth headsets are settling) skips the warm
            // hold for this round. The hold is an opt-in optimization;
            // the next refresh or post-dictation restart retries.
            guard let deviceID = attemptsBuilder().first?.deviceID else { return true }
            return AudioDeviceManager.isBluetoothInput(deviceID)
        }
        audioProcessor = AudioProcessor(
            sharedMicStream: sharedMicStream,
            isBluetoothInputProvider: warmCaptureInputIsBluetooth,
            // Default-input-change notifications arrive in bursts during
            // Bluetooth profile transitions; one trailing window collapses a
            // burst into a single warm-engine restart (issue #481).
            warmCaptureRefreshDebounce: 0.5
        )
        meetingRecordingService = MeetingRecordingService(
            micProcessingMode: meetingMicProcessingMode,
            audioCaptureService: MeetingAudioCaptureService(
                micProcessingMode: meetingMicProcessingMode,
                sourceModeProvider: meetingAudioSourceModeProvider,
                sharedMicStream: sharedMicStream
            ),
            sttTranscriber: sttScheduler,
            // Wire the real feature flag here (the service defaults to fixed
            // chunking so tests stay deterministic regardless of the flag).
            isVadLiveChunkingEnabled: { AppFeatures.meetingVadLiveChunkingEnabled }
        )
        clipboardService = ClipboardService()
        systemMediaController = SystemMediaController()
        exportService = ExportService()
        permissionService = PermissionService()
        accessibilityService = AccessibilityService()
        focusedAppContextService = FocusedAppContextService()
        launchAtLoginService = LaunchAtLoginService()

        // Retained purchase activation / entitlements. Current free/GPL builds
        // always report unlocked, but the old activation plumbing is preserved
        // as future-option support for official paid distribution/support.
        //
        // Production builds should embed these values in Info.plist via the dist script.
        // We still support env vars for local development.
        let checkoutURLString =
            (Bundle.main.object(forInfoDictionaryKey: "MacParakeetCheckoutURL") as? String)
            ?? ProcessInfo.processInfo.environment["MACPARAKEET_CHECKOUT_URL"]
        checkoutURL = checkoutURLString
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

        let licensingConfig = LicensingConfig(checkoutURL: checkoutURL, expectedVariantID: expectedVariantID)
        let serviceName = Bundle.main.bundleIdentifier ?? "com.macparakeet"
        let keychain = KeychainKeyValueStore(service: serviceName)
        entitlementsService = EntitlementsService(
            config: licensingConfig,
            store: keychain,
            api: LemonSqueezyLicenseAPI()
        )

        let processingModeClosure: @Sendable () -> Dictation.ProcessingMode = { [runtimePreferences] in
            runtimePreferences.processingMode
        }

        let dictationInsertionStyleClosure: @Sendable () -> DictationInsertionStyle = { [runtimePreferences] in
            runtimePreferences.dictationInsertionStyle
        }

        let binaryBootstrap = BinaryBootstrap()
        youtubeDownloader = YouTubeDownloader(
            binaryBootstrap: binaryBootstrap,
            audioQuality: { [runtimePreferences] in runtimePreferences.youtubeAudioQuality }
        )
        Task.detached(priority: .utility) {
            await binaryBootstrap.autoUpdateYtDlpIfNeeded()
        }
        diarizationService = DiarizationService()

        let voiceReturnTriggerClosure: @Sendable () -> String? = { [runtimePreferences] in
            runtimePreferences.voiceReturnTrigger
        }

        // File/meeting transcripts gate the AI Formatter on BOTH the
        // availability switch and the transcripts-specific switch, mirroring
        // the dictation gate below. Before #493 transcripts followed provider
        // availability alone, with no way to opt out.
        let transcriptionAIFormatterEnabledClosure: @Sendable () -> Bool = { [runtimePreferences] in
            runtimePreferences.aiFormatterEnabled && runtimePreferences.aiFormatterEnabledForTranscriptions
        }

        // Dictation gates the AI Formatter on BOTH the global switch and the
        // dictation-specific switch, so users can keep AI formatting for
        // file/meeting transcripts (which use
        // `transcriptionAIFormatterEnabledClosure`) while keeping live
        // dictation fast. See issue #408.
        let dictationAIFormatterEnabledClosure: @Sendable () -> Bool = { [runtimePreferences] in
            runtimePreferences.aiFormatterEnabled && runtimePreferences.aiFormatterEnabledForDictation
        }

        let aiFormatterPromptClosure: @Sendable () -> String = { [runtimePreferences] in
            runtimePreferences.aiFormatterPrompt
        }
        let aiFormatterPromptResolver: any AIFormatterPromptResolving
        if AppFeatures.aiFormatterProfilesEnabled {
            aiFormatterPromptResolver = AIFormatterProfilePromptResolver(
                profileRepository: aiFormatterProfileRepo,
                globalPromptTemplate: aiFormatterPromptClosure,
                smartDefaultsPolicy: { AIFormatterSmartDefaultsPolicy.current() },
                onFetchError: { error in
                    // A failed profile fetch degrades to the fallback prompt by
                    // design; log it so a corrupted DB doesn't silently route
                    // every dictation past the user's profiles.
                    Logger(subsystem: "com.macparakeet.app", category: "AIFormatter")
                        .error("Formatter profile fetch failed; using fallback prompt error=\(error.localizedDescription, privacy: .public)")
                }
            )
        } else {
            aiFormatterPromptResolver = AIFormatterGlobalPromptResolver(
                promptTemplate: aiFormatterPromptClosure
            )
        }

        llmClient = RoutingLLMClient()
        self.llmConfigStore = llmConfigStore
        llmService = LLMService(
            client: llmClient,
            contextResolver: StoredLLMExecutionContextResolver(
                configStore: llmConfigStore,
                cliConfigStore: LocalCLIConfigStore()
            )
        )

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttTranscriber: sttScheduler,
            dictationRepo: dictationRepo,
            shouldSaveAudio: { [runtimePreferences] in runtimePreferences.shouldSaveAudioRecordings },
            shouldSaveDictationHistory: { [runtimePreferences] in runtimePreferences.shouldSaveDictationHistory },
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            voiceReturnTrigger: voiceReturnTriggerClosure,
            processingMode: processingModeClosure,
            dictationInsertionStyle: dictationInsertionStyleClosure,
            llmService: llmService,
            llmRunRepo: llmRunRepo,
            shouldUseAIFormatter: dictationAIFormatterEnabledClosure,
            aiFormatterPromptResolver: aiFormatterPromptResolver,
            shouldAttemptLiveDictationTranscription: {
                SpeechEnginePreference.current() == .nemotron
            },
            markFirstDictationCompleted: { [runtimePreferences] in
                // Fire the activation milestone exactly once, the first time a
                // dictation ever completes on this install. `activation_window`
                // buckets the time since onboarding completed (coarse only).
                guard runtimePreferences.markFirstDictationCompleted() else { return }
                let secondsSinceOnboarding = UserDefaults.standard
                    .string(forKey: OnboardingViewModel.onboardingCompletedKey)
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                    .map { Date().timeIntervalSince($0) }
                Telemetry.send(.firstDictationCompleted(
                    activationWindow: TelemetryActivationWindow(secondsSinceOnboarding: secondsSinceOnboarding)
                ))
            }
        )

        let telemetry = TelemetryService()
        telemetryService = telemetry
        Telemetry.configure(telemetry)
        Telemetry.send(.appLaunched)
        Task {
            await CrashReporter.sendPendingReport(via: telemetry)
        }

        transcriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttTranscriber: sttScheduler,
            transcriptionRepo: transcriptionRepo,
            promptResultRepo: promptResultRepo,
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: processingModeClosure,
            llmService: llmService,
            llmRunRepo: llmRunRepo,
            shouldUseAIFormatter: transcriptionAIFormatterEnabledClosure,
            aiFormatterPromptTemplate: aiFormatterPromptClosure,
            shouldKeepDownloadedAudio: { [runtimePreferences] in runtimePreferences.shouldSaveTranscriptionAudio },
            shouldDiarize: { [runtimePreferences] in runtimePreferences.shouldDiarize },
            youtubeDownloader: youtubeDownloader,
            podcastResolver: PodcastEpisodeResolver(),
            podcastSearchResolver: PodcastQueryResolver(),
            podcastAudioFetcher: PodcastAudioDownloader(),
            diarizationService: diarizationService
        )

        meetingRecordingRecoveryService = MeetingRecordingRecoveryService(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo
        )

        derivedFieldsBackfill = DerivedFieldsBackfillService(dbQueue: databaseManager.dbQueue)
        derivedFieldsBackfill.runInBackground()
    }

    nonisolated static func syncAIFormatterAvailabilityWithLLMConfiguration(
        defaults: UserDefaults,
        configStore: LLMConfigStoreProtocol
    ) {
        let config: LLMProviderConfig?
        do {
            config = try configStore.loadConfig()
        } catch {
            return
        }
        let hasDictationRoutingPreference = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey
        ) != nil
        if config != nil {
            let legacyFormatterWasEnabled = defaults.object(
                forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey
            ) as? Bool == true
            if !hasDictationRoutingPreference {
                defaults.set(
                    legacyFormatterWasEnabled,
                    forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey
                )
            }
            defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        } else {
            defaults.removeObject(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
            if !hasDictationRoutingPreference {
                defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)
            }
        }
    }
}
