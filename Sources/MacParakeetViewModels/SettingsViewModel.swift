import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class SettingsViewModel {
    // General
    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    // Dictation
    public var silenceAutoStop: Bool {
        didSet { defaults.set(silenceAutoStop, forKey: "silenceAutoStop") }
    }
    public var silenceDelay: Double {
        didSet { defaults.set(silenceDelay, forKey: "silenceDelay") }
    }

    // Processing
    public var processingMode: String {
        didSet { defaults.set(processingMode, forKey: "processingMode") }
    }
    public var customWordCount: Int = 0
    public var snippetCount: Int = 0

    // Storage
    public var saveAudioRecordings: Bool {
        didSet { defaults.set(saveAudioRecordings, forKey: "saveAudioRecordings") }
    }
    public var saveTranscriptionAudio: Bool {
        didSet { defaults.set(saveTranscriptionAudio, forKey: "saveTranscriptionAudio") }
    }

    // Permission status
    public var microphoneGranted = false
    public var accessibilityGranted = false

    // Stats
    public var dictationCount = 0
    public var youtubeDownloadCount = 0
    public var youtubeDownloadStorageMB: Double = 0

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
    private let defaults: UserDefaults
    private let youtubeDownloadsDirPath: @Sendable () -> String

    public init(
        defaults: UserDefaults = .standard,
        youtubeDownloadsDirPath: @escaping @Sendable () -> String = { AppPaths.youtubeDownloadsDir }
    ) {
        self.defaults = defaults
        self.youtubeDownloadsDirPath = youtubeDownloadsDirPath
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        silenceAutoStop = defaults.bool(forKey: "silenceAutoStop")
        let delay = defaults.double(forKey: "silenceDelay")
        silenceDelay = delay == 0 ? 2.0 : delay
        processingMode = defaults.string(forKey: "processingMode") ?? "clean"
        saveAudioRecordings = defaults.object(forKey: "saveAudioRecordings") as? Bool ?? true
        saveTranscriptionAudio = defaults.object(forKey: "saveTranscriptionAudio") as? Bool ?? true
    }

    public func configure(
        permissionService: PermissionServiceProtocol,
        dictationRepo: DictationRepositoryProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        entitlementsService: EntitlementsService,
        checkoutURL: URL?,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil
    ) {
        self.permissionService = permissionService
        self.dictationRepo = dictationRepo
        self.transcriptionRepo = transcriptionRepo
        self.entitlementsService = entitlementsService
        self.checkoutURL = checkoutURL
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        refreshPermissions()
        refreshStats()
        refreshEntitlements()
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
        if let stats = try? repo.stats() {
            dictationCount = stats.totalCount
        }
        customWordCount = (try? customWordRepo?.fetchAll().count) ?? 0
        snippetCount = (try? snippetRepo?.fetchAll().count) ?? 0

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
                }
            } catch {
                await MainActor.run {
                    self.licensingBusy = false
                    self.licensingError = error.localizedDescription
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

    public func clearAllDictations() {
        guard let repo = dictationRepo else { return }
        try? repo.deleteAll()
        // Also remove any saved audio files (best effort).
        let dir = AppPaths.dictationsDir
        if FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        refreshStats()
    }

    public func clearDownloadedYouTubeAudio() {
        let dir = youtubeDownloadsDirPath()
        let fm = FileManager.default

        if fm.fileExists(atPath: dir) {
            try? fm.removeItem(atPath: dir)
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try? transcriptionRepo?.clearStoredAudioPathsForURLTranscriptions()
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
}
