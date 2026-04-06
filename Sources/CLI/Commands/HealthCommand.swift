import ArgumentParser
import Foundation
import MacParakeetCore

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check system health: database, local speech stack, and helper binaries."
    )

    @Flag(name: .long, help: "Attempt to repair/warm the local speech stack.")
    var repairModels: Bool = false

    @Option(name: .long, help: "Maximum repair attempts when --repair-models is set.")
    var repairAttempts: Int = 3

    func run() async throws {
        let validatedRepairAttempts: Int?
        if repairModels {
            validatedRepairAttempts = try validatedAttempts(repairAttempts)
        } else {
            validatedRepairAttempts = nil
        }

        print("MacParakeet Health Check")
        print("========================")
        print()

        // 1. Paths
        print("Paths:")
        print("  App Support: \(AppPaths.appSupportDir)")
        print("  Database:    \(AppPaths.databasePath)")
        print("  Temp:        \(AppPaths.tempDir)")
        print("  Bin:         \(AppPaths.binDir)")
        print("  yt-dlp:      \(AppPaths.ytDlpBinaryPath)")
        print()

        // 2. Directories
        print("Directories:")
        do {
            try AppPaths.ensureDirectories()
            print("  All directories exist or created.")
        } catch {
            print("  ERROR: \(error.localizedDescription)")
        }
        print()

        // 3. Database
        print("Database:")
        let dbExists = FileManager.default.fileExists(atPath: AppPaths.databasePath)
        if dbExists {
            do {
                let dbManager = try DatabaseManager(path: AppPaths.databasePath)
                let dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

                let dictStats = try dictationRepo.stats()
                let transcriptions = try transcriptionRepo.fetchAll(limit: nil)

                print("  Status: OK")
                print("  Dictations: \(dictStats.totalCount)")
                print("  Transcriptions: \(transcriptions.count)")
            } catch {
                print("  Status: ERROR — \(error.localizedDescription)")
            }
        } else {
            print("  Status: Not created yet (will be created on first use)")
        }
        print()

        // 4. Local speech stack
        print("Local Speech Stack:")
        let sttClient = STTClient()
        let diarizationService = DiarizationService()
        let status = await loadSpeechStackStatus(
            sttClient: sttClient,
            diarizationService: diarizationService
        )
        printSpeechStackStatus(status, includeHeader: false)

        if let repairAttempts = validatedRepairAttempts {
            print()
            print("Speech-stack repair requested...")
            do {
                try await prepareSpeechStack(
                    attempts: repairAttempts,
                    sttClient: sttClient,
                    diarizationService: diarizationService,
                    log: { message in print("  \(message)") }
                )
                print("Speech-stack repair completed.")
            } catch {
                print("Speech-stack repair failed — \(error.localizedDescription)")
            }
        }
        await sttClient.shutdown()
        print()

        // 5. Bundled FFmpeg
        print("FFmpeg:")
        if let ffmpegPath = BinaryBootstrap.resolveRuntimeFFmpegPath() {
            if ffmpegPath == AppPaths.bundledFFmpegPath() {
                print("  Status: Found bundled binary at \(ffmpegPath)")
            } else {
                print("  Status: Found development fallback at \(ffmpegPath)")
            }
        } else {
            print("  Status: Missing (bundle + development fallback)")
        }
        print()

        // 6. yt-dlp managed binary
        print("yt-dlp:")
        let bootstrap = BinaryBootstrap()
        do {
            let path = try await bootstrap.ensureYtDlpAvailable()
            print("  Status: Ready at \(path)")
        } catch {
            print("  Status: Not available — \(error.localizedDescription)")
        }
        print()

        print("Done.")
    }
}
