import Foundation
import MacParakeetCore

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
    let clipboardService: ClipboardService
    let exportService: ExportService
    let permissionService: PermissionService
    let accessibilityService: AccessibilityService
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
        quickPromptRepo = QuickPromptRepository(dbQueue: databaseManager.dbQueue)

        // Services
        let runtimePreferences = UserDefaultsAppRuntimePreferences()
        self.runtimePreferences = runtimePreferences
        let selectedInputDeviceUIDProvider: @Sendable () -> String? = { [runtimePreferences] in
            runtimePreferences.selectedMicrophoneDeviceUID
        }
        let meetingAudioSourceModeProvider: @Sendable () -> MeetingAudioSourceMode = { [runtimePreferences] in
            runtimePreferences.meetingAudioSourceMode
        }

        sttRuntime = STTRuntime(
            speechEngine: SpeechEnginePreference.current(),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant()
        )
        sttScheduler = STTScheduler(runtime: sttRuntime)
        // Mic capture is routed through Apple's Voice Processing I/O
        // (built-in AEC + NS + AGC). If VPIO can't engage on a given device,
        // capture falls back to raw mic with no AEC — `configureMicConditioner`
        // logs a warning so the case shows up in telemetry. Flip to `.raw` here
        // only as a last-resort kill switch.
        let meetingMicProcessingMode: MeetingMicProcessingMode = .vpioPreferred
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
        audioProcessor = AudioProcessor(sharedMicStream: sharedMicStream)
        meetingRecordingService = MeetingRecordingService(
            micProcessingMode: meetingMicProcessingMode,
            audioCaptureService: MeetingAudioCaptureService(
                micProcessingMode: meetingMicProcessingMode,
                sourceModeProvider: meetingAudioSourceModeProvider,
                sharedMicStream: sharedMicStream
            ),
            sttTranscriber: sttScheduler
        )
        clipboardService = ClipboardService()
        exportService = ExportService()
        permissionService = PermissionService()
        accessibilityService = AccessibilityService()
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

        let aiFormatterEnabledClosure: @Sendable () -> Bool = { [runtimePreferences] in
            runtimePreferences.aiFormatterEnabled
        }

        let aiFormatterPromptClosure: @Sendable () -> String = { [runtimePreferences] in
            runtimePreferences.aiFormatterPrompt
        }

        llmClient = RoutingLLMClient()
        llmConfigStore = LLMConfigStore()
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
            llmService: llmService,
            shouldUseAIFormatter: aiFormatterEnabledClosure,
            aiFormatterPromptTemplate: aiFormatterPromptClosure,
            markFirstDictationCompleted: { [runtimePreferences] in
                runtimePreferences.markFirstDictationCompleted()
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
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: processingModeClosure,
            llmService: llmService,
            shouldUseAIFormatter: aiFormatterEnabledClosure,
            aiFormatterPromptTemplate: aiFormatterPromptClosure,
            shouldKeepDownloadedAudio: { [runtimePreferences] in runtimePreferences.shouldSaveTranscriptionAudio },
            shouldDiarize: { [runtimePreferences] in runtimePreferences.shouldDiarize },
            youtubeDownloader: youtubeDownloader,
            diarizationService: diarizationService
        )

        meetingRecordingRecoveryService = MeetingRecordingRecoveryService(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo
        )

        derivedFieldsBackfill = DerivedFieldsBackfillService(dbQueue: databaseManager.dbQueue)
        derivedFieldsBackfill.runInBackground()
    }
}
