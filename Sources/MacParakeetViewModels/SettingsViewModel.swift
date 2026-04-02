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
            NotificationCenter.default.post(name: Notification.Name("macparakeet.menuBarOnlyModeDidChange"), object: nil)
            Telemetry.send(.settingChanged(setting: .menuBarOnly))
        }
    }
    public var showIdlePill: Bool {
        didSet {
            defaults.set(showIdlePill, forKey: "showIdlePill")
            NotificationCenter.default.post(name: Notification.Name("macparakeet.showIdlePillDidChange"), object: nil)
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
            NotificationCenter.default.post(name: Notification.Name("macparakeet.hotkeyTriggerDidChange"), object: nil)
            Telemetry.send(.hotkeyCustomized)
        }
    }
    public var silenceAutoStop: Bool {
        didSet { defaults.set(silenceAutoStop, forKey: "silenceAutoStop") }
    }
    public var silenceDelay: Double {
        didSet { defaults.set(silenceDelay, forKey: "silenceDelay") }
    }

    // Voice Return
    public var voiceReturnEnabled: Bool {
        didSet { defaults.set(voiceReturnEnabled, forKey: "voiceReturnEnabled") }
    }
    public var voiceReturnTrigger: String {
        didSet { defaults.set(voiceReturnTrigger, forKey: "voiceReturnTrigger") }
    }

    // Processing
    public var processingMode: String {
        didSet {
            guard Dictation.ProcessingMode(rawValue: processingMode) != nil else {
                // didSet doesn't re-trigger when assigning within itself,
                // so execute side effects explicitly for the fallback.
                let fallback = Dictation.ProcessingMode.raw.rawValue
                processingMode = fallback
                defaults.set(fallback, forKey: "processingMode")
                return
            }
            defaults.set(processingMode, forKey: "processingMode")
            Telemetry.send(.processingModeChanged(mode: processingMode))
        }
    }
    public var customWordCount: Int = 0
    public var snippetCount: Int = 0

    // Storage
    public var saveDictationHistory: Bool {
        didSet {
            defaults.set(saveDictationHistory, forKey: "saveDictationHistory")
            Telemetry.send(.settingChanged(setting: .saveHistory))
        }
    }
    public var saveAudioRecordings: Bool {
        didSet {
            defaults.set(saveAudioRecordings, forKey: "saveAudioRecordings")
            Telemetry.send(.settingChanged(setting: .audioRetention))
        }
    }
    public var saveTranscriptionAudio: Bool {
        didSet {
            defaults.set(saveTranscriptionAudio, forKey: "saveTranscriptionAudio")
            Telemetry.send(.settingChanged(setting: .saveTranscriptionAudio))
        }
    }

    // Permission status
    public var microphoneGranted = false
    public var accessibilityGranted = false

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
    private var isApplyingLaunchAtLoginState = false
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "SettingsViewModel")

    public init(
        defaults: UserDefaults = .standard,
        youtubeDownloadsDirPath: @escaping @Sendable () -> String = { AppPaths.youtubeDownloadsDir },
        isSpeechModelCached: @escaping @Sendable () -> Bool = { STTClient.isModelCached() }
    ) {
        self.defaults = defaults
        self.youtubeDownloadsDirPath = youtubeDownloadsDirPath
        self.isSpeechModelCached = isSpeechModelCached
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        menuBarOnlyMode = AppPreferences.isMenuBarOnlyModeEnabled(defaults: defaults)
        showIdlePill = defaults.object(forKey: "showIdlePill") as? Bool ?? true
        telemetryEnabled = AppPreferences.isTelemetryEnabled(defaults: defaults)
        hotkeyTrigger = HotkeyTrigger.current(defaults: defaults)
        silenceAutoStop = defaults.bool(forKey: "silenceAutoStop")
        let delay = defaults.double(forKey: "silenceDelay")
        silenceDelay = delay == 0 ? 2.0 : delay
        voiceReturnEnabled = defaults.bool(forKey: "voiceReturnEnabled")
        voiceReturnTrigger = defaults.string(forKey: "voiceReturnTrigger") ?? "press return"
        processingMode = Self.normalizedProcessingMode(defaults.string(forKey: "processingMode"))
        saveDictationHistory = defaults.object(forKey: "saveDictationHistory") as? Bool ?? true
        saveAudioRecordings = defaults.object(forKey: "saveAudioRecordings") as? Bool ?? true
        saveTranscriptionAudio = defaults.object(forKey: "saveTranscriptionAudio") as? Bool ?? true
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
                microphoneGranted = micStatus == .granted
                accessibilityGranted = accStatus
            }
        }
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

    /// Called after dictations are cleared so other VMs (e.g. history) can reload.
    public var onDictationsCleared: (() -> Void)?

    public func clearAllDictations() {
        guard let repo = dictationRepo else { return }
        do {
            try repo.deleteAll()
        } catch {
            logger.error("Failed to delete all dictations error=\(error.localizedDescription, privacy: .public)")
        }
        // Also remove any saved audio files (best effort).
        let dir = AppPaths.dictationsDir
        if FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        refreshStats()
        onDictationsCleared?()
    }

    public func resetPrivateStatistics() {
        guard let repo = dictationRepo else { return }
        do {
            try repo.deleteHidden()
        } catch {
            logger.error("Failed to delete hidden dictations error=\(error.localizedDescription, privacy: .public)")
        }
        refreshStats()
        onDictationsCleared?()
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
