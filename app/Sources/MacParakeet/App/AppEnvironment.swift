import Foundation
import MacParakeetCore

/// Service container: creates and wires up all dependencies.
@MainActor
final class AppEnvironment {
    let databaseManager: DatabaseManager
    let dictationRepo: DictationRepository
    let transcriptionRepo: TranscriptionRepository
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
        // Database
        let dbPath = AppPaths.databasePath
        try FileManager.default.createDirectory(
            atPath: AppPaths.appSupportDir,
            withIntermediateDirectories: true
        )
        databaseManager = try DatabaseManager(path: dbPath)

        // Repositories
        dictationRepo = DictationRepository(dbQueue: databaseManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: databaseManager.dbQueue)

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

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            dictationRepo: dictationRepo,
            clipboardService: clipboardService,
            entitlements: entitlementsService
        )

        transcriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            transcriptionRepo: transcriptionRepo,
            entitlements: entitlementsService
        )
    }
}
