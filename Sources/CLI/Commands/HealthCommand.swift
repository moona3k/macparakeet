import ArgumentParser
import Foundation
import MacParakeetCore

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check system health: database, STT daemon, paths."
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
        print("  Python:      \(AppPaths.pythonVenvDir)")
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

        // 4. STT Daemon
        print("STT Daemon:")
        let sttClient = STTClient()
        let bootstrap = PythonBootstrap()
        let env = bootstrap.daemonEnvironment()
        if let pythonPath = env["PYTHONPATH"] {
            print("  PYTHONPATH: \(pythonPath)")
            let marker = URL(fileURLWithPath: pythonPath, isDirectory: true)
                .appendingPathComponent("macparakeet_stt", isDirectory: true)
                .appendingPathComponent("requirements.txt", isDirectory: false)
                .path
            print("  Source: \(FileManager.default.fileExists(atPath: marker) ? "Found" : "Missing")")
        } else {
            print("  PYTHONPATH: (not set)")
        }
        do {
            try await sttClient.warmUp()
            let ready = await sttClient.isReady()
            print("  Status: \(ready ? "Ready" : "Not ready")")
        } catch {
            print("  Status: Not available — \(error.localizedDescription)")
        }
        await sttClient.shutdown()
        print()

        // 5. FFmpeg
        print("FFmpeg:")
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        let foundFFmpeg = ffmpegPaths.first { FileManager.default.fileExists(atPath: $0) }
        if let path = foundFFmpeg {
            print("  Status: Found at \(path)")
        } else {
            print("  Status: Not found (install via: brew install ffmpeg)")
        }
        print()

        print("Done.")
    }
}
