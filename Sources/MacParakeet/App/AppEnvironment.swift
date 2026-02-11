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
    let clipboardService: ClipboardService
    let exportService: ExportService
    let permissionService: PermissionService
    let entitlementsService: EntitlementsService
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

        // Licensing / entitlements (basic guards: 7-day trial + license unlock).
        // TODO: Set these before release:
        // - checkoutURL: your Lemon Squeezy checkout link
        // - expectedVariantID: the Lemon Squeezy Variant ID for MacParakeet
        checkoutURL = URL(string: ProcessInfo.processInfo.environment["MACPARAKEET_CHECKOUT_URL"] ?? "")
        let expectedVariantID = Int(ProcessInfo.processInfo.environment["MACPARAKEET_LS_VARIANT_ID"] ?? "")
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
            return Dictation.ProcessingMode(rawValue: raw ?? "clean") ?? .clean
        }

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
            processingMode: processingModeClosure
        )
    }
}
