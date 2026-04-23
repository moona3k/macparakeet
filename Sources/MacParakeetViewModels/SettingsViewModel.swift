import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class SettingsViewModel {
    public enum LocalModelStatus: Equatable {
        case unknown
        case checking
        case ready
        case notLoaded
        case notDownloaded
        case repairing
        case failed
    }

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
                Telemetry.send(.telemetryOptedOut)
                Task { await Telemetry.flush() }
            }
        }
    }

    // Dictation
    public var hotkeyTrigger: HotkeyTrigger {
        didSet {
            hotkeyTrigger.save(to: defaults)
            NotificationCenter.default.post(name: .macParakeetHotkeyTriggerDidChange, object: nil)
            Telemetry.send(.hotkeyCustomized)
        }
    }
    public var meetingHotkeyTrigger: HotkeyTrigger {
        didSet {
            meetingHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.meetingDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetMeetingHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(.settingChanged(setting: .meetingHotkey))
        }
    }
    public var fileTranscriptionHotkeyTrigger: HotkeyTrigger {
        didSet {
            fileTranscriptionHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetFileTranscriptionHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(.settingChanged(setting: .fileTranscriptionHotkey))
        }
    }
    public var youtubeTranscriptionHotkeyTrigger: HotkeyTrigger {
        didSet {
            youtubeTranscriptionHotkeyTrigger.save(to: defaults, defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey)
            NotificationCenter.default.post(
                name: .macParakeetYouTubeTranscriptionHotkeyTriggerDidChange,
                object: nil
            )
            Telemetry.send(.settingChanged(setting: .youtubeTranscriptionHotkey))
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

    // Transcription
    public var speakerDiarization: Bool {
        didSet {
            defaults.set(speakerDiarization, forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey)
            Telemetry.send(.settingChanged(setting: .speakerDiarization))
        }
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

    // Permission status
    public var microphoneGranted = false
    public var accessibilityGranted = false
    public var screenRecordingGranted = false

    // Stats
    public var dictationCount = 0
    public var youtubeDownloadCount = 0
    public var youtubeDownloadStorageMB: Double = 0
    public var formattedYouTubeStorage: String {
        let mb = youtubeDownloadStorageMB
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    // Local model status / repair
    public var parakeetStatus: LocalModelStatus = .unknown
    public var parakeetStatusDetail: String = "Not checked yet."
    public var parakeetRepairing = false

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
    private var customWordRepo: CustomWordRepositoryProtocol?
    private var snippetRepo: TextSnippetRepositoryProtocol?
    private var entitlementsService: EntitlementsService?
    private var launchAtLoginService: LaunchAtLoginControlling?
    private var sttClient: STTClientProtocol?
    private let defaults: UserDefaults
    private let youtubeDownloadsDirPath: @Sendable () -> String
    private let isSpeechModelCached: @Sendable () -> Bool
    private let permissionPollingInterval: Duration
    private var isApplyingLaunchAtLoginState = false
    private var permissionPollingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "SettingsViewModel")

    public init(
        defaults: UserDefaults = .standard,
        youtubeDownloadsDirPath: @escaping @Sendable () -> String = { AppPaths.youtubeDownloadsDir },
        isSpeechModelCached: @escaping @Sendable () -> Bool = { STTRuntime.isModelCached() },
        permissionPollingInterval: Duration = .seconds(2)
    ) {
        AutoSaveService.migrateLegacyMeetingSettingsIfNeeded(defaults: defaults)
        self.defaults = defaults
        self.youtubeDownloadsDirPath = youtubeDownloadsDirPath
        self.isSpeechModelCached = isSpeechModelCached
        self.permissionPollingInterval = permissionPollingInterval
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        menuBarOnlyMode = AppPreferences.isMenuBarOnlyModeEnabled(defaults: defaults)
        showIdlePill = defaults.object(forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey) as? Bool ?? true
        telemetryEnabled = AppPreferences.isTelemetryEnabled(defaults: defaults)
        hotkeyTrigger = HotkeyTrigger.current(defaults: defaults)
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
        voiceReturnEnabled = defaults.bool(forKey: UserDefaultsAppRuntimePreferences.voiceReturnEnabledKey)
        voiceReturnTrigger = defaults.string(forKey: UserDefaultsAppRuntimePreferences.voiceReturnTriggerKey) ?? "press return"
        processingMode = Self.normalizedProcessingMode(defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey))
        saveDictationHistory = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveDictationHistoryKey) as? Bool ?? true
        saveAudioRecordings = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveAudioRecordingsKey) as? Bool ?? true
        saveTranscriptionAudio = defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool ?? true
        speakerDiarization = defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool ?? true
        autoSaveTranscripts = defaults.bool(forKey: AutoSaveService.enabledKey)
        autoSaveFormat = AutoSaveFormat(rawValue: defaults.string(forKey: AutoSaveService.formatKey) ?? "md") ?? .md
        autoSaveFolderPath = Self.resolveAutoSaveFolderPath(defaults: defaults, scope: .transcription)
        meetingAutoSave = defaults.bool(forKey: AutoSaveScope.meeting.enabledKey)
        meetingAutoSaveFormat = AutoSaveFormat(rawValue: defaults.string(forKey: AutoSaveScope.meeting.formatKey) ?? "md") ?? .md
        meetingAutoSaveFolderPath = Self.resolveAutoSaveFolderPath(defaults: defaults, scope: .meeting)
    }

    /// Resolve the stored bookmark to a display path.
    private static func resolveAutoSaveFolderPath(defaults: UserDefaults, scope: AutoSaveScope = .transcription) -> String? {
        let service = AutoSaveService(defaults: defaults)
        return service.resolveFolder(scope: scope)?.path
    }

    public func chooseAutoSaveFolder(url: URL) {
        if let path = AutoSaveService.storeFolder(url, scope: .transcription, defaults: defaults) {
            autoSaveFolderPath = path
        }
    }

    public func clearAutoSaveFolder() {
        AutoSaveService.clearFolder(scope: .transcription, defaults: defaults)
        autoSaveFolderPath = nil
    }

    public func chooseMeetingAutoSaveFolder(url: URL) {
        if let path = AutoSaveService.storeFolder(url, scope: .meeting, defaults: defaults) {
            meetingAutoSaveFolderPath = path
        }
    }

    public func clearMeetingAutoSaveFolder() {
        AutoSaveService.clearFolder(scope: .meeting, defaults: defaults)
        meetingAutoSaveFolderPath = nil
    }

    private static func resolveMeetingHotkeyTrigger(defaults: UserDefaults) -> HotkeyTrigger {
        HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.meetingDefaultsKey,
            fallback: .defaultMeetingRecording
        )
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
        entitlementsService: EntitlementsService,
        launchAtLoginService: LaunchAtLoginControlling? = nil,
        checkoutURL: URL?,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        sttClient: STTClientProtocol? = nil
    ) {
        self.permissionService = permissionService
        self.dictationRepo = dictationRepo
        self.transcriptionRepo = transcriptionRepo
        self.entitlementsService = entitlementsService
        self.launchAtLoginService = launchAtLoginService
        self.checkoutURL = checkoutURL
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.sttClient = sttClient
        refreshLaunchAtLoginStatus()
        refreshPermissions()
        refreshStats()
        refreshEntitlements()
        refreshModelStatus()
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
        Task {
            if let service = permissionService {
                let micStatus = await service.checkMicrophonePermission()
                let accStatus = service.checkAccessibilityPermission()
                let screenRecordingStatus = service.checkScreenRecordingPermission()
                microphoneGranted = micStatus == .granted
                accessibilityGranted = accStatus
                screenRecordingGranted = screenRecordingStatus
            }
        }
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

    public func startPermissionPolling() {
        guard permissionPollingTask == nil else { return }
        refreshPermissions()
        permissionPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.permissionPollingInterval)
                guard !Task.isCancelled else { break }
                self.refreshPermissions()
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

        let (count, sizeBytes) = youtubeDownloadStats()
        youtubeDownloadCount = count
        youtubeDownloadStorageMB = Double(sizeBytes) / (1024.0 * 1024.0)
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

    public func refreshModelStatus() {
        guard let sttClient else {
            parakeetStatus = .unknown
            parakeetStatusDetail = "Unavailable in this runtime."
            return
        }

        parakeetStatus = .checking
        parakeetStatusDetail = "Checking model state..."

        Task {
            let parakeetReady = await sttClient.isReady()
            let parakeetCached = isSpeechModelCached()

            await MainActor.run {
                if parakeetReady {
                    self.parakeetStatus = .ready
                    self.parakeetStatusDetail = "Loaded in memory and ready."
                } else if parakeetCached {
                    self.parakeetStatus = .notLoaded
                    self.parakeetStatusDetail = "Downloaded. Loads automatically when needed."
                } else {
                    self.parakeetStatus = .notDownloaded
                    self.parakeetStatusDetail = "Not downloaded yet."
                }

            }
        }
    }

    public func repairParakeetModel() {
        guard let sttClient else { return }
        guard !parakeetRepairing else { return }
        parakeetRepairing = true
        parakeetStatus = .repairing
        parakeetStatusDetail = "Preparing speech model..."

        Task {
            do {
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

                await MainActor.run {
                    self.parakeetRepairing = false
                    self.refreshModelStatus()
                }
            } catch {
                await MainActor.run {
                    self.parakeetRepairing = false
                    self.parakeetStatus = .failed
                    self.parakeetStatusDetail = error.localizedDescription
                }
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

    public func clearDownloadedYouTubeAudio() {
        let dir = youtubeDownloadsDirPath()
        let fm = FileManager.default

        if fm.fileExists(atPath: dir) {
            try? fm.removeItem(atPath: dir)
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        do {
            try transcriptionRepo?.clearStoredAudioPathsForURLTranscriptions()
        } catch {
            logger.error("Failed to clear stored audio paths error=\(error.localizedDescription, privacy: .public)")
        }
        refreshStats()
    }

    private func youtubeDownloadStats() -> (count: Int, sizeBytes: Int64) {
        let dirURL = URL(fileURLWithPath: youtubeDownloadsDirPath(), isDirectory: true)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
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

        return (count, sizeBytes)
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
