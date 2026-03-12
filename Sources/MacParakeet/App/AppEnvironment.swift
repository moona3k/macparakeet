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
    let sttClient: STTClient
    let audioProcessor: AudioProcessor
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

    init() throws {
        // Ensure required runtime directories exist (db, dictations, temp).
        try AppPaths.ensureDirectories()

        // Database
        let dbPath = AppPaths.databasePath
        databaseManager = try DatabaseManager(path: dbPath)

        // Repositories
        dictationRepo = DictationRepository(dbQueue: databaseManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: databaseManager.dbQueue)
        customWordRepo = CustomWordRepository(dbQueue: databaseManager.dbQueue)
        snippetRepo = TextSnippetRepository(dbQueue: databaseManager.dbQueue)

        // One-time cleanup on launch
        _ = try? dictationRepo.deleteEmpty()
        try? dictationRepo.clearMissingAudioPaths()

        // Services
        sttClient = STTClient()
        audioProcessor = AudioProcessor()
        clipboardService = ClipboardService()
        exportService = ExportService()
        permissionService = PermissionService()
        accessibilityService = AccessibilityService()
        launchAtLoginService = LaunchAtLoginService()

        // Licensing / entitlements (basic guards: 7-day trial + license unlock).
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

        let processingModeClosure: @Sendable () -> Dictation.ProcessingMode = {
            let raw = UserDefaults.standard.string(forKey: "processingMode")
            return Dictation.ProcessingMode(rawValue: raw ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw
        }

        youtubeDownloader = YouTubeDownloader()
        diarizationService = DiarizationService()

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            dictationRepo: dictationRepo,
            clipboardService: clipboardService,
            shouldSaveAudio: {
                // Defaults to true if unset (matches Settings UI default).
                UserDefaults.standard.object(forKey: "saveAudioRecordings") as? Bool ?? true
            },
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: processingModeClosure
        )

        transcriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            transcriptionRepo: transcriptionRepo,
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: processingModeClosure,
            shouldKeepDownloadedAudio: {
                // Defaults to true if unset (matches Settings UI default).
                UserDefaults.standard.object(forKey: "saveTranscriptionAudio") as? Bool ?? true
            },
            youtubeDownloader: youtubeDownloader,
            diarizationService: diarizationService
        )
    }
}
