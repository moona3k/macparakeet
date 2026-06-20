import AppKit
import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class SettingsViewModel {
    public typealias LocalModelStatus = EngineSettingsViewModel.LocalModelStatus

    public enum MicrophoneTestState: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    public struct MicrophoneDeviceOption: Identifiable, Equatable, Sendable {
        public let id: String
        public let uid: String
        public let name: String
        public let transportLabel: String
        public let isDefault: Bool
        public let isAvailable: Bool

        public var displayName: String {
            if !isAvailable { return "\(name) (unavailable)" }
            return isDefault ? "\(name) (System Default)" : name
        }

        public var detail: String {
            isAvailable ? transportLabel : "Reconnect this microphone or choose another input."
        }
    }

    public static let systemDefaultMicrophoneSelection = "__system_default__"
    private static let microphoneTestSilenceThreshold: Float = 0.01
    public let engine: EngineSettingsViewModel

    // General
    public var launchAtLogin: Bool {
        didSet {
            guard !isApplyingLaunchAtLoginState else { return }
            applyLaunchAtLoginChange(launchAtLogin)
        }
    }
    public var launchAtLoginDetail: String = ""
    public var launchAtLoginError: String?
    public var menuBarOnlyMode: Bool {
        didSet {
            defaults.set(menuBarOnlyMode, forKey: AppPreferences.menuBarOnlyModeKey)
            NotificationCenter.default.post(name: .macParakeetMenuBarOnlyModeDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .menuBarOnly))
        }
    }
    public var appAppearanceMode: AppAppearanceMode {
        didSet {
            defaults.set(appAppearanceMode.rawValue, forKey: AppPreferences.appearanceModeKey)
            NotificationCenter.default.post(name: .macParakeetAppearanceModeDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .appAppearance))
        }
    }
    public var showIdlePill: Bool {
        didSet {
            defaults.set(showIdlePill, forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey)
            NotificationCenter.default.post(name: .macParakeetShowIdlePillDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .hidePill))
        }
    }
    public var telemetryEnabled: Bool {
        didSet {
            defaults.set(telemetryEnabled, forKey: AppPreferences.telemetryEnabledKey)
            if !telemetryEnabled {
                Telemetry.clearQueue()
                Telemetry.send(.telemetryOptedOut)
                Task { await Telemetry.flush() }
            }
        }
    }
    /// Play a chime (and, when MacParakeet is in the background, post a banner)
    /// when a file/URL transcription or a batch finishes. Default on.
    public var notifyOnTranscriptionComplete: Bool {
        didSet {
            defaults.set(
                notifyOnTranscriptionComplete,
                forKey: UserDefaultsAppRuntimePreferences.notifyOnTranscriptionCompleteKey
            )
            Telemetry.send(.settingChanged(setting: .transcriptionCompletionNotification))
        }
    }

    // Dictation
    public var hotkeyTrigger: HotkeyTrigger {
        didSet {
            hotkeyTrigger.save(to: defaults)
            NotificationCenter.default.post(name: .macParakeetHotkeyTriggerDidChange, object: nil)
            Telemetry.send(hotkeyTrigger.customizedEvent(surface: .dictation))
        }
    }
    public var pushToTalkHotkeyTrigger: HotkeyTrigger {
        didSet {
            pushToTalkHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetPushToTalkHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(pushToTalkHotkeyTrigger.customizedEvent(surface: .pushToTalk))
        }
    }
    public var meetingHotkeyTrigger: HotkeyTrigger {
        didSet {
            meetingHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.meetingDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetMeetingHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(meetingHotkeyTrigger.customizedEvent(surface: .meeting))
        }
    }
    public var fileTranscriptionHotkeyTrigger: HotkeyTrigger {
        didSet {
            fileTranscriptionHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetFileTranscriptionHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(fileTranscriptionHotkeyTrigger.customizedEvent(surface: .fileTranscription))
        }
    }
    public var youtubeTranscriptionHotkeyTrigger: HotkeyTrigger {
        didSet {
            youtubeTranscriptionHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetYouTubeTranscriptionHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(youtubeTranscriptionHotkeyTrigger.customizedEvent(surface: .youtubeTranscription))
        }
    }
    public var silenceAutoStop: Bool {
        didSet {
            defaults.set(silenceAutoStop, forKey: UserDefaultsAppRuntimePreferences.silenceAutoStopKey)
            Telemetry.send(.settingChanged(setting: .silenceAutoStop))
        }
    }
    public var silenceDelay: Double {
        didSet { defaults.set(silenceDelay, forKey: UserDefaultsAppRuntimePreferences.silenceDelayKey) }
    }
    public var keepDictationOnClipboard: Bool {
        didSet {
            defaults.set(
                keepDictationOnClipboard,
                forKey: UserDefaultsAppRuntimePreferences.keepDictationOnClipboardKey
            )
            Telemetry.send(.settingChanged(setting: .keepDictationOnClipboard))
        }
    }
    public var selectedMicrophoneDeviceUID: String {
        didSet {
            let normalized = Self.normalizedMicrophoneSelection(selectedMicrophoneDeviceUID)
            if selectedMicrophoneDeviceUID != normalized {
                selectedMicrophoneDeviceUID = normalized
                return
            }
            if normalized == Self.systemDefaultMicrophoneSelection {
                defaults.removeObject(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)
            } else {
                defaults.set(normalized, forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)
            }
            microphoneTestTask?.cancel()
            microphoneTestTask = nil
            microphoneTestState = .idle
            microphoneTestLevel = 0
            NotificationCenter.default.post(name: .macParakeetMicrophoneSelectionDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .microphoneSelection))
        }
    }
    public var meetingAudioSourceMode: MeetingAudioSourceMode {
        didSet {
            defaults.set(
                meetingAudioSourceMode.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey
            )
            Telemetry.send(.settingChanged(setting: .meetingAudioSourceMode))
        }
    }
    public var meetingAutoStopEnabled: Bool {
        didSet {
            defaults.set(
                meetingAutoStopEnabled,
                forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey
            )
            NotificationCenter.default.post(name: .macParakeetMeetingAutoStopDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .meetingAutoStop))
        }
    }
    public var pauseMediaDuringDictation: Bool {
        didSet {
            defaults.set(
                pauseMediaDuringDictation,
                forKey: UserDefaultsAppRuntimePreferences.pauseMediaDuringDictationKey
            )
            Telemetry.send(.settingChanged(setting: .pauseMediaDuringDictation))
        }
    }
    public var instantDictationEnabled: Bool {
        didSet {
            defaults.set(
                instantDictationEnabled,
                forKey: UserDefaultsAppRuntimePreferences.instantDictationEnabledKey
            )
            NotificationCenter.default.post(name: .macParakeetInstantDictationDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .instantDictation))
        }
    }
    public var showLiveDictationPreview: Bool {
        didSet {
            defaults.set(
                showLiveDictationPreview,
                forKey: UserDefaultsAppRuntimePreferences.showLiveDictationPreviewKey
            )
            Telemetry.send(.settingChanged(setting: .liveDictationPreview))
        }
    }

    public var dictationPreviewTextSize: DictationPreviewTextSize {
        didSet {
            guard dictationPreviewTextSize != oldValue else { return }
            defaults.set(
                dictationPreviewTextSize.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.dictationPreviewTextSizeKey
            )
            // Let an active dictation overlay re-read the size and resize live.
            NotificationCenter.default.post(name: .macParakeetDictationPreviewTextSizeDidChange, object: nil)
            // Reuses the live-preview setting channel — size is part of the same
            // feature, so no separate telemetry setting name is needed.
            Telemetry.send(.settingChanged(setting: .liveDictationPreview))
        }
    }
    public var microphoneDeviceOptions: [MicrophoneDeviceOption] = []
    public var microphoneTestState: MicrophoneTestState = .idle
    public var microphoneTestLevel: Float = 0
    public var selectedMicrophoneStatusText: String {
        if selectedMicrophoneDeviceUID == Self.systemDefaultMicrophoneSelection {
            if meetingAudioSourceMode == .systemOnly {
                if let currentDefault = microphoneDeviceOptions.first(where: \.isDefault) {
                    return "Using macOS System Default for dictation: \(currentDefault.name). Meeting recording is set to \(MeetingAudioSourceMode.systemOnly.displayTitle)."
                }
                return "Using macOS System Default for dictation. Meeting recording is set to \(MeetingAudioSourceMode.systemOnly.displayTitle)."
            }
            if let currentDefault = microphoneDeviceOptions.first(where: \.isDefault) {
                return "Using macOS System Default: \(currentDefault.name)."
            }
            return "Using macOS System Default."
        }
        guard let selected = microphoneDeviceOptions.first(where: { $0.uid == selectedMicrophoneDeviceUID }) else {
            return "Selected microphone is unavailable. MacParakeet will use System Default until it returns."
        }
        guard selected.isAvailable else {
            return "Selected microphone is unavailable. MacParakeet will use System Default until it returns."
        }
        if meetingAudioSourceMode == .systemOnly {
            return "Using \(selected.name) for dictation. Meeting recording is set to \(MeetingAudioSourceMode.systemOnly.displayTitle)."
        }
        return "Using \(selected.name) for dictation and meeting microphone capture."
    }

    // Voice Return
    public var voiceReturnEnabled: Bool {
        didSet {
            defaults.set(voiceReturnEnabled, forKey: UserDefaultsAppRuntimePreferences.voiceReturnEnabledKey)
            Telemetry.send(.settingChanged(setting: .voiceReturn))
        }
    }
    public var voiceReturnTrigger: String {
        didSet { defaults.set(voiceReturnTrigger, forKey: UserDefaultsAppRuntimePreferences.voiceReturnTriggerKey) }
    }

    // Processing
    public var processingMode: String {
        didSet {
            guard Dictation.ProcessingMode(rawValue: processingMode) != nil else {
                // didSet doesn't re-trigger when assigning within itself,
                // so execute side effects explicitly for the fallback.
                let fallback = Dictation.ProcessingMode.raw.rawValue
                processingMode = fallback
                defaults.set(fallback, forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
                return
            }
            defaults.set(processingMode, forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
            Telemetry.send(.processingModeChanged(mode: processingMode))
        }
    }
    public var dictationInsertionStyle: DictationInsertionStyle {
        didSet {
            defaults.set(
                dictationInsertionStyle.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.dictationInsertionStyleKey
            )
            Telemetry.send(.settingChanged(setting: .dictationInsertionStyle))
        }
    }
    public var customWordCount: Int = 0
    public var snippetCount: Int = 0

    // Storage
    public var saveDictationHistory: Bool {
        didSet {
            defaults.set(saveDictationHistory, forKey: UserDefaultsAppRuntimePreferences.saveDictationHistoryKey)
            Telemetry.send(.settingChanged(setting: .saveHistory))
        }
    }
    public var saveAudioRecordings: Bool {
        didSet {
            defaults.set(saveAudioRecordings, forKey: UserDefaultsAppRuntimePreferences.saveAudioRecordingsKey)
            Telemetry.send(.settingChanged(setting: .audioRetention))
        }
    }
    public var saveTranscriptionAudio: Bool {
        didSet {
            defaults.set(saveTranscriptionAudio, forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey)
            Telemetry.send(.settingChanged(setting: .saveTranscriptionAudio))
        }
    }
    public var meetingAudioRetention: MeetingAudioRetention {
        didSet {
            guard meetingAudioRetention != oldValue else { return }
            UserDefaultsAppRuntimePreferences.saveMeetingAudioRetention(
                meetingAudioRetention,
                defaults: defaults
            )
            NotificationCenter.default.post(name: .macParakeetMeetingAudioRetentionDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .meetingAudioRetention))
        }
    }
    public var saveMeetingAudio: Bool {
        get { meetingAudioRetention.shouldSaveFreshAudio }
        set {
            setMeetingAudioRetention(newValue ? .keepForever : .deleteImmediately)
        }
    }
    public var savedMeetingAudioRetentionDays: Int {
        UserDefaultsAppRuntimePreferences.meetingAudioRetentionDeleteAfterDays(defaults: defaults)
    }

    // Transcription
    public var youtubeAudioQuality: YouTubeAudioQuality {
        didSet {
            defaults.set(youtubeAudioQuality.rawValue, forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
            Telemetry.send(.settingChanged(setting: .youtubeAudioQuality))
        }
    }
    public var speakerDiarization: Bool {
        didSet {
            defaults.set(speakerDiarization, forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey)
            Telemetry.send(.settingChanged(setting: .speakerDiarization))
        }
    }
    public private(set) var pendingMeetingRecoveryCount = 0
    public var onRecoverPendingMeetingRecordings: (() -> Void)?

    /// Reports whether a meeting capture session is currently writing into the
    /// managed recordings directory. Wired from the meeting pill state in the
    /// app layer. `clearMeetingAudio()` refuses to wipe the directory while
    /// this is true so an in-progress recording is never deleted out from
    /// under the live writer (ADR-015 allows recording while Settings is open).
    public var meetingRecordingActiveProvider: (@MainActor () -> Bool)?

    public var isMeetingRecordingActive: Bool {
        meetingRecordingActiveProvider?() ?? false
    }

    // Auto-save (transcription)
    public var autoSaveTranscripts: Bool {
        didSet {
            defaults.set(autoSaveTranscripts, forKey: AutoSaveService.enabledKey)
            Telemetry.send(.settingChanged(setting: .autoSave))
        }
    }
    public var autoSaveFormat: AutoSaveFormat {
        didSet {
            defaults.set(autoSaveFormat.rawValue, forKey: AutoSaveService.formatKey)
        }
    }
    public var autoSaveFolderPath: String?

    // Auto-save (meeting)
    public var meetingAutoSave: Bool {
        didSet {
            defaults.set(meetingAutoSave, forKey: AutoSaveScope.meeting.enabledKey)
            Telemetry.send(.settingChanged(setting: .meetingAutoSave))
        }
    }
    public var meetingAutoSaveFormat: AutoSaveFormat {
        didSet {
            defaults.set(meetingAutoSaveFormat.rawValue, forKey: AutoSaveScope.meeting.formatKey)
        }
    }
    public var meetingAutoSaveFolderPath: String?

    // Calendar auto-start (ADR-017)
    //
    // Each `didSet` writes the value through to `UserDefaults`, fires the
    // shared `macParakeetCalendarSettingsDidChange` notification (so the
    // coordinator re-reads its config without waiting for the next poll
    // tick), and emits a typed telemetry event. Excluded calendar IDs flow
    // through the same notification — the coordinator's filter changes the
    // moment a checkbox is toggled.
    public var calendarAutoStartMode: CalendarAutoStartMode {
        didSet {
            defaults.set(calendarAutoStartMode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
            // Guard ALL side effects (not just the auth prompt). Onboarding
            // posts the cross-VM notification itself; if we re-post here
            // during the resulting reload, the observer cycles indefinitely
            // (the .common-mode Task hop drops the re-entrancy guard before
            // the observer fires again). The originator already emitted
            // telemetry — don't double-emit on sync.
            guard !isResolvingCalendarSettings else { return }
            NotificationCenter.default.post(name: .macParakeetCalendarSettingsDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .calendarAutoStartMode))
            // Enabling reminders requires notification authorization. The
            // Calendar grant flow requests this in tandem with Calendar
            // access, but a user who granted Calendar earlier (or via
            // System Settings) and *now* flips the mode picker to non-`.off`
            // would otherwise hit the silent-drop path: coordinator marks
            // the event reminded, finds notifications unauthorized, returns
            // without delivering.
            if calendarAutoStartMode != .off {
                Task { await CalendarNotificationAuthorization.requestIfNeeded() }
            }
        }
    }
    public var calendarReminderMinutes: Int {
        didSet {
            defaults.set(calendarReminderMinutes, forKey: CalendarAutoStartPreferences.reminderMinutesKey)
            guard !isResolvingCalendarSettings else { return }
            NotificationCenter.default.post(name: .macParakeetCalendarSettingsDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .calendarReminderMinutes))
        }
    }
    public var meetingTriggerFilter: MeetingTriggerFilter {
        didSet {
            defaults.set(meetingTriggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
            guard !isResolvingCalendarSettings else { return }
            NotificationCenter.default.post(name: .macParakeetCalendarSettingsDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .calendarTriggerFilter))
        }
    }
    public var calendarExcludedIdentifiers: Set<String> {
        didSet {
            defaults.set(Array(calendarExcludedIdentifiers), forKey: CalendarAutoStartPreferences.excludedCalendarIdsKey)
            guard !isResolvingCalendarSettings else { return }
            NotificationCenter.default.post(name: .macParakeetCalendarSettingsDidChange, object: nil)
            Telemetry.send(.settingChanged(setting: .calendarIncludedCalendars))
        }
    }
    /// Three-state Calendar permission. Settings UI needs to distinguish
    /// `.denied` from `.notDetermined` because macOS only shows the
    /// EventKit prompt once — after denial, the only recovery path is
    /// System Settings, so the Settings button label has to change too.
    public var calendarPermissionStatus: CalendarService.PermissionStatus = .notDetermined
    /// Convenience derived from `calendarPermissionStatus` for callers that
    /// only care about the granted-or-not boolean (onboarding gating, etc.).
    public var calendarPermissionGranted: Bool {
        calendarPermissionStatus == .granted
    }
    /// Whether macOS notification authorization is granted. Calendar reminders
    /// (`.notify`, and the pre-meeting reminder in `.autoStart`) are delivered
    /// via `UNUserNotificationCenter`, a *separate* TCC scope from Calendar —
    /// so a user can grant Calendar yet have reminders silently dropped.
    /// Settings surfaces this; refreshed by the view (defaults to `true` so the
    /// warning never flashes before the first async check resolves).
    public var calendarNotificationsAuthorized: Bool = true

    // Permission status
    public var microphoneGranted = false
    public var accessibilityGranted = false
    public var screenRecordingGranted = false

    // Stats
    public var dictationCount = 0
    public var youtubeDownloadCount = 0
    public var youtubeDownloadStorageMB: Double = 0
    public var meetingAudioRecordingCount = 0
    public var meetingAudioStorageMB: Double = 0
    public var storageCleanupError: String?
    public var formattedYouTubeStorage: String {
        Self.formatStorageMB(youtubeDownloadStorageMB)
    }
    public var formattedMeetingAudioStorage: String {
        Self.formatStorageMB(meetingAudioStorageMB)
    }

    private static func formatStorageMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    // Licensing / entitlements
    public var entitlementsSummary: String = ""
    public var entitlementsDetail: String = ""
    public var isUnlocked: Bool = false
    public var licenseKeyInput: String = ""
    public var licensingBusy: Bool = false
    public var licensingError: String?
    public var checkoutURL: URL?

    private var permissionService: PermissionServiceProtocol?
    private var dictationRepo: DictationRepositoryProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var transformHistoryRepo: TransformHistoryRepositoryProtocol?
    private var customWordRepo: CustomWordRepositoryProtocol?
    private var snippetRepo: TextSnippetRepositoryProtocol?
    private var entitlementsService: EntitlementsService?
    private var launchAtLoginService: LaunchAtLoginControlling?
    private var meetingRecoveryService: MeetingRecordingRecoveryServicing?
    private var sharedMicStream: SharedMicrophoneStream?
    private let defaults: UserDefaults
    private let youtubeDownloadsDirPath: @Sendable () -> String
    private let meetingRecordingsDirPath: @Sendable () -> String
    private let inputDevicesProvider: @Sendable () -> [AudioDeviceManager.InputDevice]
    private let defaultInputDeviceUIDProvider: @Sendable () -> String?
    private let permissionPollingInterval: Duration
    private var isApplyingLaunchAtLoginState = false
    private var storageStatsRefreshGeneration = 0
    // `deinit` is nonisolated even though this type is `@MainActor`.
    // These handles are only mutated on the main actor during the view
    // model lifetime; unsafe access lets deinit cancel/unregister.
    @ObservationIgnored nonisolated(unsafe) private var permissionPollingTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var microphoneTestTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var storageStatsTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var calendarSettingsObserver: NSObjectProtocol?
    /// Re-entrancy guard so `observeCalendarSettings()` doesn't fire `didSet`
    /// → notification → re-resolve → `didSet` → … on every user toggle.
    private var isResolvingCalendarSettings = false
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "SettingsViewModel")

    public init(
        defaults: UserDefaults = .standard,
        youtubeDownloadsDirPath: @escaping @Sendable () -> String = { AppPaths.youtubeDownloadsDir },
        meetingRecordingsDirPath: @escaping @Sendable () -> String = { AppPaths.meetingRecordingsDir },
        parakeetModelVariantCached: @escaping @Sendable (ParakeetModelVariant) -> Bool = {
            // Unified is a separate FluidAudio runtime with no `AsrModelVersion`;
            // dispatch it to its own engine's cache check.
            if $0.usesUnifiedEngine { return ParakeetUnifiedEngine.isModelCached() }
            guard let version = $0.asrModelVersion else { return false }
            return STTRuntime.isModelCached(version: version)
        },
        nemotronModelVariantCached: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = {
            STTRuntime.isNemotronModelCached(modelVariant: $0, language: $1)
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
        inputDevicesProvider: @escaping @Sendable () -> [AudioDeviceManager.InputDevice] = {
            AudioDeviceManager.inputDevices()
        },
        defaultInputDeviceUIDProvider: @escaping @Sendable () -> String? = {
            AudioDeviceManager.defaultInputDeviceInfo()?.uid
        },
        permissionPollingInterval: Duration = .seconds(2)
    ) {
        AutoSaveService.migrateLegacyMeetingSettingsIfNeeded(defaults: defaults)
        self.defaults = defaults
        self.youtubeDownloadsDirPath = youtubeDownloadsDirPath
        self.meetingRecordingsDirPath = meetingRecordingsDirPath
        self.inputDevicesProvider = inputDevicesProvider
        self.defaultInputDeviceUIDProvider = defaultInputDeviceUIDProvider
        self.permissionPollingInterval = permissionPollingInterval
        self.engine = EngineSettingsViewModel(
            defaults: defaults,
            parakeetModelVariantCached: parakeetModelVariantCached,
            nemotronModelVariantCached: nemotronModelVariantCached,
            deleteParakeetModelOnDisk: deleteParakeetModelOnDisk,
            deleteNemotronModelOnDisk: deleteNemotronModelOnDisk,
            deleteWhisperModelOnDisk: deleteWhisperModelOnDisk
        )
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        menuBarOnlyMode = AppPreferences.isMenuBarOnlyModeEnabled(defaults: defaults)
        appAppearanceMode = AppPreferences.appearanceMode(defaults: defaults)
        showIdlePill = defaults.object(forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey) as? Bool ?? true
        telemetryEnabled = AppPreferences.isTelemetryEnabled(defaults: defaults)
        notifyOnTranscriptionComplete = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.notifyOnTranscriptionCompleteKey
        ) as? Bool ?? true
        let resolvedDictationHotkeys = Self.resolveDictationHotkeyTriggers(defaults: defaults)
        hotkeyTrigger = resolvedDictationHotkeys.handsFree
        pushToTalkHotkeyTrigger = resolvedDictationHotkeys.pushToTalk
        if resolvedDictationHotkeys.shouldPersistHandsFree {
            resolvedDictationHotkeys.handsFree.save(to: defaults)
        }
        if resolvedDictationHotkeys.shouldPersistPushToTalk {
            resolvedDictationHotkeys.pushToTalk.save(to: defaults, defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey)
        }
        meetingHotkeyTrigger = Self.resolveMeetingHotkeyTrigger(defaults: defaults)
        fileTranscriptionHotkeyTrigger = Self.resolveTranscriptionHotkeyTrigger(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey
        )
        youtubeTranscriptionHotkeyTrigger = Self.resolveTranscriptionHotkeyTrigger(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey
        )
        silenceAutoStop = defaults.bool(forKey: UserDefaultsAppRuntimePreferences.silenceAutoStopKey)
        let delay = defaults.double(forKey: UserDefaultsAppRuntimePreferences.silenceDelayKey)
        silenceDelay = delay == 0 ? 2.0 : delay
        keepDictationOnClipboard = defaults.bool(
            forKey: UserDefaultsAppRuntimePreferences.keepDictationOnClipboardKey
        )
        selectedMicrophoneDeviceUID = Self.normalizedMicrophoneSelection(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)
        )
        meetingAudioSourceMode = MeetingAudioSourceMode.current(defaults: defaults)
        meetingAutoStopEnabled = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey
        ) as? Bool ?? false
        pauseMediaDuringDictation = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.pauseMediaDuringDictationKey
        ) as? Bool ?? false
        instantDictationEnabled = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.instantDictationEnabledKey
        ) as? Bool ?? false
        showLiveDictationPreview = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.showLiveDictationPreviewKey
        ) as? Bool ?? true
        dictationPreviewTextSize = DictationPreviewTextSize.current(defaults: defaults)
        voiceReturnEnabled = defaults.bool(forKey: UserDefaultsAppRuntimePreferences.voiceReturnEnabledKey)
        voiceReturnTrigger = defaults.string(forKey: UserDefaultsAppRuntimePreferences.voiceReturnTriggerKey) ?? "press return"
        processingMode = Self.normalizedProcessingMode(defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey))
        dictationInsertionStyle = DictationInsertionStyle.current(defaults: defaults)
        saveDictationHistory = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveDictationHistoryKey) as? Bool ?? true
        saveAudioRecordings = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveAudioRecordingsKey) as? Bool ?? true
        saveTranscriptionAudio = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool ?? true
        meetingAudioRetention = UserDefaultsAppRuntimePreferences.meetingAudioRetention(defaults: defaults)
        youtubeAudioQuality = YouTubeAudioQuality.current(defaults: defaults)
        speakerDiarization = defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool ?? false
        // Ensure auto-save folders are configured before reading paths.
        // Idempotent: existing user-chosen folders are preserved; only
        // unset bookmarks get the default. This guarantees the read
        // below sees a non-nil path in the common case so the toggle
        // can never sit in the bad "ON · no folder" combination.
        AutoSaveService.ensureFolderConfigured(scope: .transcription, defaults: defaults)
        AutoSaveService.ensureFolderConfigured(scope: .meeting, defaults: defaults)

        autoSaveTranscripts = defaults.bool(forKey: AutoSaveService.enabledKey)
        autoSaveFormat = AutoSaveFormat(rawValue: defaults.string(forKey: AutoSaveService.formatKey) ?? "md") ?? .md
        autoSaveFolderPath = Self.resolveAutoSaveFolderPath(defaults: defaults, scope: .transcription)
        meetingAutoSave = defaults.bool(forKey: AutoSaveScope.meeting.enabledKey)
        meetingAutoSaveFormat = AutoSaveFormat(rawValue: defaults.string(forKey: AutoSaveScope.meeting.formatKey) ?? "md") ?? .md
        meetingAutoSaveFolderPath = Self.resolveAutoSaveFolderPath(defaults: defaults, scope: .meeting)
        calendarAutoStartMode = Self.resolveCalendarAutoStartMode(defaults: defaults)
        calendarReminderMinutes = Self.resolveCalendarReminderMinutes(defaults: defaults)
        meetingTriggerFilter = Self.resolveMeetingTriggerFilter(defaults: defaults)
        calendarExcludedIdentifiers = Self.resolveCalendarExcludedIdentifiers(defaults: defaults)

        // Defense-in-depth self-heal: in the rare case that
        // `ensureFolderConfigured` couldn't create the default folder
        // (disk full, `~/Documents` not writable, stale bookmark
        // unresolvable), folder may still be nil. Toggling ON in that
        // state silently no-ops every save, so reset the toggle to
        // match reality. Writes through to defaults because didSet
        // doesn't fire during init.
        if autoSaveTranscripts && autoSaveFolderPath == nil {
            autoSaveTranscripts = false
            defaults.set(false, forKey: AutoSaveService.enabledKey)
        }
        if meetingAutoSave && meetingAutoSaveFolderPath == nil {
            meetingAutoSave = false
            defaults.set(false, forKey: AutoSaveScope.meeting.enabledKey)
        }

        refreshMicrophoneDevices()
        observeCalendarSettings()
    }

    deinit {
        permissionPollingTask?.cancel()
        microphoneTestTask?.cancel()
        storageStatsTask?.cancel()
        if let calendarSettingsObserver {
            NotificationCenter.default.removeObserver(calendarSettingsObserver)
        }
    }

    /// Onboarding writes calendar settings directly to UserDefaults (it
    /// doesn't own a `SettingsViewModel`). Without this observer, an open
    /// Settings window would show stale mode/lead/filter until Settings was
    /// closed and re-opened. Re-resolving from defaults keeps every UI
    /// surface that holds a `SettingsViewModel` in sync.
    private func observeCalendarSettings() {
        let center = NotificationCenter.default
        calendarSettingsObserver = center.addObserver(
            forName: .macParakeetCalendarSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadCalendarSettings() }
        }
    }

    private func reloadCalendarSettings() {
        // Avoid the `didSet` → post-notification → reload → `didSet` loop:
        // re-resolving has to skip the `didSet` write-through. The flag
        // guards the entire batch so partial updates can't fire telemetry
        // for a value the user didn't actually change.
        guard !isResolvingCalendarSettings else { return }
        isResolvingCalendarSettings = true
        defer { isResolvingCalendarSettings = false }

        let resolvedMode = Self.resolveCalendarAutoStartMode(defaults: defaults)
        if calendarAutoStartMode != resolvedMode { calendarAutoStartMode = resolvedMode }

        let resolvedMinutes = Self.resolveCalendarReminderMinutes(defaults: defaults)
        if calendarReminderMinutes != resolvedMinutes { calendarReminderMinutes = resolvedMinutes }

        let resolvedFilter = Self.resolveMeetingTriggerFilter(defaults: defaults)
        if meetingTriggerFilter != resolvedFilter { meetingTriggerFilter = resolvedFilter }

        let resolvedExcluded = Self.resolveCalendarExcludedIdentifiers(defaults: defaults)
        if calendarExcludedIdentifiers != resolvedExcluded { calendarExcludedIdentifiers = resolvedExcluded }
    }

    public func setMeetingAudioRetention(_ retention: MeetingAudioRetention) {
        meetingAudioRetention = MeetingAudioRetention.make(
            mode: retention.mode,
            days: retention.mode == .deleteAfterDays
                ? retention.deleteAfterDays
                : savedMeetingAudioRetentionDays
        )
    }

    public func requiresMeetingAudioRetentionConfirmation(for retention: MeetingAudioRetention) -> Bool {
        retention.automaticallyDeletesAudio
            && !meetingAudioRetention.automaticallyDeletesAudio
            && !defaults.bool(forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionAutoDeleteConfirmedKey)
    }

    public func confirmMeetingAudioRetentionChange(_ retention: MeetingAudioRetention) {
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionAutoDeleteConfirmedKey)
        setMeetingAudioRetention(retention)
    }

    private static func resolveCalendarAutoStartMode(defaults: UserDefaults) -> CalendarAutoStartMode {
        guard let raw = defaults.string(forKey: CalendarAutoStartPreferences.modeKey),
              let mode = CalendarAutoStartMode(rawValue: raw) else {
            return .off  // Off by default — opt-in only via onboarding or Settings.
        }
        return mode
    }

    private static func resolveCalendarReminderMinutes(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: CalendarAutoStartPreferences.reminderMinutesKey) != nil else {
            return CalendarAutoStartPreferences.defaultReminderMinutes
        }
        return defaults.integer(forKey: CalendarAutoStartPreferences.reminderMinutesKey)
    }

    private static func resolveMeetingTriggerFilter(defaults: UserDefaults) -> MeetingTriggerFilter {
        guard let raw = defaults.string(forKey: CalendarAutoStartPreferences.triggerFilterKey),
              let filter = MeetingTriggerFilter(rawValue: raw) else {
            return .withLink
        }
        return filter
    }

    private static func resolveCalendarExcludedIdentifiers(defaults: UserDefaults) -> Set<String> {
        guard let raw = defaults.array(forKey: CalendarAutoStartPreferences.excludedCalendarIdsKey) as? [String] else {
            return []
        }
        return Set(raw)
    }

    private static func normalizedMicrophoneSelection(_ uid: String?) -> String {
        AudioDeviceManager.normalizedUID(uid) ?? systemDefaultMicrophoneSelection
    }

    /// Resolve the stored bookmark to a display path.
    private static func resolveAutoSaveFolderPath(defaults: UserDefaults, scope: AutoSaveScope = .transcription) -> String? {
        AutoSaveService.resolveFolder(scope: scope, defaults: defaults)?.path
    }

    public func chooseAutoSaveFolder(url: URL) {
        if let path = AutoSaveService.storeFolder(url, scope: .transcription, defaults: defaults) {
            autoSaveFolderPath = path
        }
    }

    /// Reset the auto-save destination to the default location
    /// (`~/Documents/MacParakeet/Transcriptions`). The toggle is left in
    /// whatever state the user had it — folder is *always* set, so the
    /// toggle is a pure on/off feature flag. This replaces the older
    /// "Clear" semantic (which was a footgun: ON + no folder silently
    /// no-op'd every save).
    public func resetAutoSaveFolder() {
        if let url = AutoSaveService.resetFolderToDefault(scope: .transcription, defaults: defaults) {
            autoSaveFolderPath = url.path
        }
    }

    public func chooseMeetingAutoSaveFolder(url: URL) {
        if let path = AutoSaveService.storeFolder(url, scope: .meeting, defaults: defaults) {
            meetingAutoSaveFolderPath = path
        }
    }

    public func resetMeetingAutoSaveFolder() {
        if let url = AutoSaveService.resetFolderToDefault(scope: .meeting, defaults: defaults) {
            meetingAutoSaveFolderPath = url.path
        }
    }

    private static func resolveMeetingHotkeyTrigger(defaults: UserDefaults) -> HotkeyTrigger {
        HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.meetingDefaultsKey,
            fallback: .defaultMeetingRecording
        )
    }

    private static func resolveDictationHotkeyTriggers(defaults: UserDefaults) -> (
        handsFree: HotkeyTrigger,
        pushToTalk: HotkeyTrigger,
        shouldPersistHandsFree: Bool,
        shouldPersistPushToTalk: Bool
    ) {
        let hasHandsFreeTrigger = defaults.object(forKey: HotkeyTrigger.defaultsKey) != nil
        let hasDedicatedPushToTalkTrigger = defaults.object(forKey: HotkeyTrigger.pushToTalkDefaultsKey) != nil

        if !hasHandsFreeTrigger {
            let pushToTalk = hasDedicatedPushToTalkTrigger
                ? HotkeyTrigger.current(
                    defaults: defaults,
                    defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
                    fallback: .defaultPushToTalk
                )
                : .defaultPushToTalk
            return (
                defaultHandsFreeTrigger(avoiding: pushToTalk),
                pushToTalk,
                true,
                !hasDedicatedPushToTalkTrigger
            )
        }

        let storedHandsFree = HotkeyTrigger.current(defaults: defaults, fallback: .defaultDictation)
        if !hasDedicatedPushToTalkTrigger {
            if storedHandsFree.isDisabled {
                return (.disabled, .disabled, false, true)
            }
            if storedHandsFree == .fnSpace {
                return (.defaultDictation, .defaultPushToTalk, true, true)
            }
            let handsFree = defaultHandsFreeTrigger(avoiding: storedHandsFree)
            return (
                handsFree,
                storedHandsFree,
                handsFree != storedHandsFree,
                true
            )
        }

        let pushToTalk = HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
            fallback: .defaultPushToTalk
        )
        if storedHandsFree == .fnSpace,
           pushToTalk == .defaultPushToTalk {
            return (.defaultDictation, .defaultPushToTalk, true, false)
        }
        if !storedHandsFree.isDisabled,
           !pushToTalk.isDisabled,
           storedHandsFree == pushToTalk {
            return (storedHandsFree, pushToTalk, false, false)
        }
        if !storedHandsFree.isDisabled,
           !pushToTalk.isDisabled,
           storedHandsFree != pushToTalk,
           storedHandsFree.overlaps(with: pushToTalk) {
            return (defaultHandsFreeTrigger(avoiding: pushToTalk), pushToTalk, true, false)
        }
        return (storedHandsFree, pushToTalk, false, false)
    }

    private static func defaultHandsFreeTrigger(avoiding pushToTalk: HotkeyTrigger) -> HotkeyTrigger {
        if pushToTalk == .defaultPushToTalk {
            return .defaultDictation
        }
        guard !pushToTalk.isDisabled,
              HotkeyTrigger.defaultDictation.overlaps(with: pushToTalk) else {
            return .defaultDictation
        }
        return .disabled
    }

    /// Transcription hotkeys (file / YouTube) default to `.disabled` — users opt in.
    private static func resolveTranscriptionHotkeyTrigger(
        defaults: UserDefaults,
        defaultsKey: String
    ) -> HotkeyTrigger {
        HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: defaultsKey,
            fallback: .disabled
        )
    }

    public func configure(
        permissionService: PermissionServiceProtocol,
        dictationRepo: DictationRepositoryProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        transformHistoryRepo: TransformHistoryRepositoryProtocol? = nil,
        entitlementsService: EntitlementsService,
        launchAtLoginService: LaunchAtLoginControlling? = nil,
        checkoutURL: URL?,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        sttClient: STTClientProtocol? = nil,
        speechEngineSwitcher: SpeechEngineSwitching? = nil,
        speechEngineSwitchAvailabilityProvider: SpeechEngineSwitchAvailabilityProviding? = nil,
        meetingRecoveryService: MeetingRecordingRecoveryServicing? = nil,
        sharedMicStream: SharedMicrophoneStream? = nil
    ) {
        self.permissionService = permissionService
        self.dictationRepo = dictationRepo
        self.transcriptionRepo = transcriptionRepo
        self.transformHistoryRepo = transformHistoryRepo
        self.entitlementsService = entitlementsService
        self.launchAtLoginService = launchAtLoginService
        self.checkoutURL = checkoutURL
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        engine.configure(
            sttClient: sttClient,
            speechEngineSwitcher: speechEngineSwitcher,
            speechEngineSwitchAvailabilityProvider: speechEngineSwitchAvailabilityProvider
        )
        self.meetingRecoveryService = meetingRecoveryService
        self.sharedMicStream = sharedMicStream
        refreshLaunchAtLoginStatus()
        refreshPermissions()
        refreshStats()
        refreshEntitlements()
        engine.refreshModelStatus()
        engine.refreshSpeechEngineSwitchAvailability()
        refreshPendingMeetingRecoveries()
    }

    public func refreshPendingMeetingRecoveries() {
        guard let meetingRecoveryService else {
            pendingMeetingRecoveryCount = 0
            return
        }

        Task {
            do {
                let recoveries = try await meetingRecoveryService.discoverPendingRecoveries()
                pendingMeetingRecoveryCount = recoveries.count
            } catch {
                logger.error("Failed to load pending meeting recoveries: \(error.localizedDescription)")
                pendingMeetingRecoveryCount = 0
            }
        }
    }

    public func requestPendingMeetingRecovery() {
        onRecoverPendingMeetingRecordings?()
    }

    public func refreshLaunchAtLoginStatus() {
        guard let service = launchAtLoginService else {
            launchAtLoginDetail = ""
            launchAtLoginError = nil
            return
        }

        applyLaunchAtLoginStatus(service.currentStatus())
        launchAtLoginError = nil
    }

    public func refreshPermissions() {
        refreshMicrophoneDevices()
        Task {
            if let service = permissionService {
                let micStatus = await service.checkMicrophonePermission()
                let accStatus = service.checkAccessibilityPermission()
                let screenRecordingStatus = service.checkScreenRecordingPermission()
                microphoneGranted = micStatus == .granted
                accessibilityGranted = accStatus
                screenRecordingGranted = screenRecordingStatus
            }
            refreshCalendarPermission()
        }
    }

    public func refreshMicrophoneDevices() {
        let defaultUID = defaultInputDeviceUIDProvider()
        microphoneDeviceOptions = inputDevicesProvider().map { device in
            MicrophoneDeviceOption(
                id: device.uid,
                uid: device.uid,
                name: device.name,
                transportLabel: device.transportLabel,
                isDefault: device.uid == defaultUID,
                isAvailable: true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if selectedMicrophoneDeviceUID != Self.systemDefaultMicrophoneSelection,
           !microphoneDeviceOptions.contains(where: { $0.uid == selectedMicrophoneDeviceUID }) {
            microphoneDeviceOptions.append(
                MicrophoneDeviceOption(
                    id: selectedMicrophoneDeviceUID,
                    uid: selectedMicrophoneDeviceUID,
                    name: "Selected microphone",
                    transportLabel: "unavailable",
                    isDefault: false,
                    isAvailable: false
                )
            )
        }
    }

    public func testSelectedMicrophone() {
        microphoneTestTask?.cancel()
        microphoneTestTask = nil
        microphoneTestLevel = 0
        microphoneTestState = .testing

        guard let sharedMicStream else {
            microphoneTestState = .failed("Microphone test is unavailable until audio services are ready.")
            return
        }

        let levelBox = MicrophoneLevelBox()

        microphoneTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let capture = MicrophoneCapture(sharedStream: sharedMicStream)
            do {
                _ = try await capture.start(processingMode: .raw) { buffer, _ in
                    levelBox.record(buffer.rmsLevel)
                }
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(50))
                    microphoneTestLevel = levelBox.latestLevel
                }
                capture.stop()
                guard !Task.isCancelled else { return }
                microphoneTestState = levelBox.maxLevel > Self.microphoneTestSilenceThreshold
                    ? .succeeded
                    : .failed("No input detected. Check the selected microphone and try again.")
            } catch {
                capture.stop()
                guard !Task.isCancelled else { return }
                microphoneTestState = .failed(error.localizedDescription)
            }
            microphoneTestTask = nil
        }
    }

    public func cancelMicrophoneTest() {
        microphoneTestTask?.cancel()
        microphoneTestTask = nil
        microphoneTestLevel = 0
        microphoneTestState = .idle
    }

    public func requestScreenRecordingAccess() {
        guard let permissionService else { return }
        Telemetry.send(.permissionPrompted(permission: .screenRecording))
        _ = permissionService.requestScreenRecordingPermission()
        refreshPermissions()
    }

    public func openScreenRecordingSystemSettings() {
        permissionService?.openScreenRecordingSettings()
    }

    /// Refresh calendar permission via the shared service. Cheap — no
    /// network or disk; just reads `EKEventStore.authorizationStatus` (which
    /// is `nonisolated` on the actor, so no await needed).
    public func refreshCalendarPermission() {
        calendarPermissionStatus = CalendarService.shared.permissionStatus
    }

    /// Trigger the EventKit permission prompt if not yet decided. Returns the
    /// granted state. On grant, also requests notification authorization so
    /// the eventual reminder isn't silently dropped by macOS — this single
    /// async hop pairs the two permissions the feature actually needs.
    @discardableResult
    public func requestCalendarPermission() async -> Bool {
        Telemetry.send(.permissionPrompted(permission: .calendar))
        let granted = await CalendarService.shared.requestPermission()
        // Re-read the status (rather than just assigning .granted/.denied
        // from the bool) so `.restricted` from MDM-managed Macs is reflected
        // accurately — the service maps it to `.denied` so callers don't
        // need a fourth case, but a fresh read is the source of truth.
        calendarPermissionStatus = CalendarService.shared.permissionStatus
        Telemetry.send(granted ? .permissionGranted(permission: .calendar) : .permissionDenied(permission: .calendar))
        if granted {
            await CalendarNotificationAuthorization.requestIfNeeded()
            // A user who explicitly grants Calendar access from Settings
            // intends to use the feature, so default them into the safe
            // .notify mode. Only when still .off — never clobber an existing
            // .autoStart choice.
            if calendarAutoStartMode == .off {
                calendarAutoStartMode = .notify
            }
        }
        return granted
    }

    public func openCalendarSystemSettings() {
        if NSWorkspace.shared.open(CalendarService.settingsURL) { return }
    }

    /// Refresh the cached notification-authorization state. Cheap async read
    /// of `UNUserNotificationCenter` settings; the view calls this on appear
    /// and when the calendar mode changes.
    public func refreshCalendarNotificationAuthorization() async {
        calendarNotificationsAuthorized = await CalendarNotificationAuthorization.isAuthorized()
    }

    /// Deep-link to the Notifications pane in System Settings. The pane id
    /// changed across macOS versions, so try the modern one first.
    public func openNotificationSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    public func startPermissionPolling() {
        guard permissionPollingTask == nil else { return }
        refreshPermissions()
        engine.refreshSpeechEngineSwitchAvailability()
        permissionPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.permissionPollingInterval)
                guard !Task.isCancelled else { break }
                self.refreshPermissions()
                self.engine.refreshSpeechEngineSwitchAvailability()
            }
        }
    }

    public func stopPermissionPolling() {
        permissionPollingTask?.cancel()
        permissionPollingTask = nil
    }

    public func refreshStats() {
        guard let repo = dictationRepo else { return }
        do { dictationCount = try repo.stats().visibleCount }
        catch { logger.error("Failed to load dictation stats: \(error.localizedDescription)") }
        do { customWordCount = try customWordRepo?.fetchAll().count ?? 0 }
        catch { logger.error("Failed to load custom word count: \(error.localizedDescription)") }
        do { snippetCount = try snippetRepo?.fetchAll().count ?? 0 }
        catch { logger.error("Failed to load snippet count: \(error.localizedDescription)") }

        refreshStorageStats()
    }

    public func refreshEntitlements() {
        guard let service = entitlementsService else { return }
        licensingError = nil
        Task {
            let state = await service.currentState(now: Date())
            await MainActor.run {
                self.applyEntitlementsState(state)
            }
        }
    }

    public func activateLicense() {
        guard let service = entitlementsService else { return }
        let key = licenseKeyInput
        licensingBusy = true
        licensingError = nil
        Task {
            do {
                let state = try await service.activate(licenseKey: key, now: Date())
                await MainActor.run {
                    self.licensingBusy = false
                    self.applyEntitlementsState(state)
                    self.licenseKeyInput = ""
                    Telemetry.send(.licenseActivated)
                }
            } catch {
                await MainActor.run {
                    self.licensingBusy = false
                    self.licensingError = error.localizedDescription
                    Telemetry.send(.licenseActivationFailed(errorType: TelemetryErrorClassifier.classify(error), errorDetail: TelemetryErrorClassifier.errorDetail(error)))
                }
            }
        }
    }

    public func deactivateLicense() {
        guard let service = entitlementsService else { return }
        licensingBusy = true
        licensingError = nil
        Task {
            do {
                let state = try await service.deactivate(now: Date())
                await MainActor.run {
                    self.licensingBusy = false
                    self.applyEntitlementsState(state)
                }
            } catch {
                await MainActor.run {
                    self.licensingBusy = false
                    self.licensingError = error.localizedDescription
                }
            }
        }
    }

    private func applyEntitlementsState(_ state: EntitlementsState) {
        switch state.access {
        case .unlocked:
            isUnlocked = true
            entitlementsSummary = "Unlocked"
            if let masked = state.licenseKeyMasked {
                entitlementsDetail = "License: \(masked)"
            } else {
                entitlementsDetail = ""
            }
        case .trialActive(let daysRemaining, let endsAt):
            isUnlocked = false
            entitlementsSummary = "Trial: \(daysRemaining) day(s) left"
            entitlementsDetail = "Ends \(endsAt.formatted(date: .abbreviated, time: .omitted))"
        case .trialExpired(let endedAt):
            isUnlocked = false
            entitlementsSummary = "Trial ended"
            entitlementsDetail = "Ended \(endedAt.formatted(date: .abbreviated, time: .omitted))"
        }

        if let lv = state.lastValidatedAt, isUnlocked {
            entitlementsDetail += entitlementsDetail.isEmpty ? "" : "  "
            entitlementsDetail += "Validated \(lv.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// Fired after a dictation-state change (rows deleted or lifetime counters reset)
    /// so other VMs (e.g. the history view) can reload their derived data.
    public var onDictationStateChanged: (() -> Void)?
    public var onTransformHistoryChanged: (() -> Void)?

    public func clearAllDictations() {
        guard let repo = dictationRepo else { return }
        // `deleteAll()` only removes visible (hidden = 0) rows; `deleteHidden()`
        // covers the metric-only entries created when "Save dictation history" was
        // off. Together they truly clear all dictation rows. Each runs in its own
        // GRDB write transaction; partial failure is logged but never silently
        // corrupts state because the row counts are independent.
        do {
            try repo.deleteAll()
            try repo.deleteHidden()
        } catch {
            logger.error("Failed to clear dictations error=\(error.localizedDescription, privacy: .public)")
        }
        // Also remove any saved audio files (best effort).
        let dir = AppPaths.dictationsDir
        if FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        refreshStats()
        onDictationStateChanged?()
    }

    /// Zero the lifetime stats counters. Symmetric to `clearAllDictations()` —
    /// dictation rows are preserved; only the lifetime totals (total words,
    /// total time, total count, longest dictation) are reset.
    public func resetLifetimeStats() {
        guard let repo = dictationRepo else { return }
        do {
            try repo.resetLifetimeStats()
        } catch {
            logger.error("Failed to reset lifetime stats error=\(error.localizedDescription, privacy: .public)")
        }
        refreshStats()
        onDictationStateChanged?()
    }

    public func clearTransformHistory() {
        guard let repo = transformHistoryRepo else { return }
        Task { @MainActor [repo, weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repo.deleteAll()
                }.value
                self?.onTransformHistoryChanged?()
            } catch {
                self?.logger.error("Failed to clear transform history error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func clearDownloadedYouTubeAudio() {
        let dir = youtubeDownloadsDirPath()
        let fm = FileManager.default
        storageCleanupError = nil

        if fm.fileExists(atPath: dir) {
            do {
                try fm.removeItem(atPath: dir)
            } catch {
                logger.error("Failed to remove downloaded audio directory error=\(error.localizedDescription, privacy: .public)")
                storageCleanupError = "Could not clear downloaded video audio: \(error.localizedDescription)"
                refreshStats()
                return
            }
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to recreate downloaded audio directory error=\(error.localizedDescription, privacy: .public)")
            storageCleanupError = "Could not recreate the downloaded audio folder: \(error.localizedDescription)"
            refreshStats()
            return
        }

        do {
            try transcriptionRepo?.clearStoredAudioPathsForURLTranscriptions()
        } catch {
            logger.error("Failed to clear stored audio paths error=\(error.localizedDescription, privacy: .public)")
            storageCleanupError = "Could not detach downloaded audio from transcriptions: \(error.localizedDescription)"
        }
        refreshStats()
    }

    public func clearMeetingAudio() {
        storageCleanupError = nil

        // A live meeting session writes into this same directory
        // (meeting-recordings/{sessionID}/). Wiping it mid-recording would
        // delete the active writer's folder and lose the in-progress meeting,
        // so refuse while a recording is active rather than clobber it.
        guard !isMeetingRecordingActive else {
            storageCleanupError = "Stop the active meeting recording before clearing meeting audio."
            return
        }

        let dir = meetingRecordingsDirPath()
        let fm = FileManager.default
        do {
            let protectedSessions = try MeetingRecordingLockFileStore().discoverAnySessions(
                meetingsRoot: URL(fileURLWithPath: dir, isDirectory: true)
            )
            guard protectedSessions.isEmpty else {
                storageCleanupError = "Finish or discard pending meeting recording recovery before clearing meeting audio."
                refreshStats()
                refreshPendingMeetingRecoveries()
                return
            }
        } catch {
            logger.error("Failed to inspect meeting recording locks error=\(error.localizedDescription, privacy: .public)")
            storageCleanupError = "Could not verify pending meeting recordings: \(error.localizedDescription)"
            refreshStats()
            refreshPendingMeetingRecoveries()
            return
        }

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try TranscriptionAssetCleanup.removeManagedMeetingAudioFiles(under: dir, fileManager: fm)
        } catch {
            logger.error("Failed to clear meeting audio files error=\(error.localizedDescription, privacy: .public)")
            storageCleanupError = "Could not clear meeting audio: \(error.localizedDescription)"
            refreshStats()
            refreshPendingMeetingRecoveries()
            return
        }

        do {
            try transcriptionRepo?.clearStoredAudioPathsForMeetingTranscriptions(under: dir)
        } catch {
            logger.error("Failed to clear stored meeting audio paths error=\(error.localizedDescription, privacy: .public)")
            storageCleanupError = "Could not detach meeting audio from transcripts: \(error.localizedDescription)"
        }
        refreshStats()
        refreshPendingMeetingRecoveries()
    }

    private func refreshStorageStats() {
        storageStatsRefreshGeneration += 1
        let generation = storageStatsRefreshGeneration
        let youtubeDownloadsDir = youtubeDownloadsDirPath()
        let meetingRecordingsDir = meetingRecordingsDirPath()

        storageStatsTask?.cancel()
        storageStatsTask = Task { @MainActor [weak self, generation, youtubeDownloadsDir, meetingRecordingsDir] in
            let stats = await Task.detached(priority: .utility) {
                StorageStatsSnapshot(
                    youtubeDownloads: Self.youtubeDownloadStats(in: youtubeDownloadsDir),
                    meetingAudio: Self.meetingAudioStats(in: meetingRecordingsDir)
                )
            }.value

            guard
                !Task.isCancelled,
                let self,
                self.storageStatsRefreshGeneration == generation
            else { return }

            self.youtubeDownloadCount = stats.youtubeDownloads.count
            self.youtubeDownloadStorageMB = Double(stats.youtubeDownloads.sizeBytes) / (1024.0 * 1024.0)
            self.meetingAudioRecordingCount = stats.meetingAudio.count
            self.meetingAudioStorageMB = Double(stats.meetingAudio.sizeBytes) / (1024.0 * 1024.0)
        }
    }

    private struct StorageDirectoryStats: Sendable {
        var count: Int
        var sizeBytes: Int64
    }

    private struct StorageStatsSnapshot: Sendable {
        var youtubeDownloads: StorageDirectoryStats
        var meetingAudio: StorageDirectoryStats
    }

    nonisolated private static func youtubeDownloadStats(in dirPath: String) -> StorageDirectoryStats {
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageDirectoryStats(count: 0, sizeBytes: 0)
        }

        var count = 0
        var sizeBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }

            count += 1
            sizeBytes += Int64(values.fileSize ?? 0)
        }

        return StorageDirectoryStats(count: count, sizeBytes: sizeBytes)
    }

    nonisolated private static func meetingAudioStats(in dirPath: String) -> StorageDirectoryStats {
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageDirectoryStats(count: 0, sizeBytes: 0)
        }

        var count = 0
        var sizeBytes: Int64 = 0

        for sessionURL in contents {
            guard
                let sessionValues = try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]),
                sessionValues.isDirectory == true,
                let files = try? fm.contentsOfDirectory(
                    at: sessionURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            var sessionHasAudio = false
            for fileURL in files {
                guard
                    TranscriptionAssetCleanup.isStandardMeetingAudioFileName(fileURL.lastPathComponent),
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true
                else { continue }

                sessionHasAudio = true
                sizeBytes += Int64(values.fileSize ?? 0)
            }

            if sessionHasAudio {
                count += 1
            }
        }

        return StorageDirectoryStats(count: count, sizeBytes: sizeBytes)
    }

    private static func normalizedProcessingMode(_ rawValue: String?) -> String {
        guard let rawValue, Dictation.ProcessingMode(rawValue: rawValue) != nil else {
            return Dictation.ProcessingMode.raw.rawValue
        }
        return rawValue
    }

    private func applyLaunchAtLoginChange(_ enabled: Bool) {
        defaults.set(enabled, forKey: "launchAtLogin")
        launchAtLoginError = nil
        Telemetry.send(.settingChanged(setting: .launchAtLogin))

        guard let service = launchAtLoginService else { return }

        do {
            let updatedStatus = try service.setEnabled(enabled)
            applyLaunchAtLoginStatus(updatedStatus)
        } catch {
            let fallbackStatus = service.currentStatus()
            applyLaunchAtLoginStatus(fallbackStatus)
            launchAtLoginError = error.localizedDescription
        }
    }

    private func applyLaunchAtLoginStatus(_ status: LaunchAtLoginStatus) {
        isApplyingLaunchAtLoginState = true
        launchAtLogin = status.isEnabled
        defaults.set(status.isEnabled, forKey: "launchAtLogin")
        isApplyingLaunchAtLoginState = false
        launchAtLoginDetail = status.detailText
    }

}

private final class MicrophoneLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestValue: Float = 0
    private var peakValue: Float = 0

    var latestLevel: Float {
        lock.withLock { latestValue }
    }

    var maxLevel: Float {
        lock.withLock { peakValue }
    }

    func record(_ level: Float) {
        lock.withLock {
            latestValue = level
            peakValue = max(peakValue, level)
        }
    }
}
