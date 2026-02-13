import ArgumentParser
import Foundation
import MacParakeetCore

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check system health: database, speech engine, and helper binaries."
    )

    func run() async throws {
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

        // 4. Speech engine
        print("Speech Engine:")
        let sttClient = STTClient()
        do {
            try await sttClient.warmUp()
            let ready = await sttClient.isReady()
            print("  Status: \(ready ? "Ready" : "Not ready")")
        } catch {
            print("  Status: Not available — \(error.localizedDescription)")
        }
        await sttClient.shutdown()
        print()

        // 5. Bundled FFmpeg
        print("Bundled FFmpeg:")
        if let ffmpegPath = AppPaths.bundledFFmpegPath() {
            print("  Status: Found at \(ffmpegPath)")
        } else {
            print("  Status: Missing from app resources")
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
