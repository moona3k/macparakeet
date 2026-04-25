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

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    func run() async throws {
        let validatedRepairAttempts: Int?
        if repairModels {
            validatedRepairAttempts = try validatedAttempts(repairAttempts)
        } else {
            validatedRepairAttempts = nil
        }

        // Operations are run unconditionally; printing is gated on `!json` so the
        // final JSON dump is the only thing on stdout in --json mode.
        var report = HealthReport()

        if !json {
            print("MacParakeet Health Check")
            print("========================")
            print()
        }

        // 1. Paths
        report.paths = HealthReport.Paths(
            appSupport: AppPaths.appSupportDir,
            database: AppPaths.databasePath,
            temp: AppPaths.tempDir,
            bin: AppPaths.binDir,
            ytDlp: AppPaths.ytDlpBinaryPath
        )
        if !json {
            print("Paths:")
            print("  App Support: \(report.paths.appSupport)")
            print("  Database:    \(report.paths.database)")
            print("  Temp:        \(report.paths.temp)")
            print("  Bin:         \(report.paths.bin)")
            print("  yt-dlp:      \(report.paths.ytDlp)")
            print()
        }

        // 2. Directories
        do {
            try AppPaths.ensureDirectories()
            report.directoriesOK = true
        } catch {
            report.directoriesOK = false
            report.directoriesError = error.localizedDescription
        }
        if !json {
            print("Directories:")
            if report.directoriesOK {
                print("  All directories exist or created.")
            } else {
                print("  ERROR: \(report.directoriesError ?? "unknown")")
            }
            print()
        }

        // 3. Database
        let database: HealthReport.Database
        if FileManager.default.fileExists(atPath: AppPaths.databasePath) {
            do {
                let dbManager = try DatabaseManager(path: AppPaths.databasePath)
                let dictStats = try DictationRepository(dbQueue: dbManager.dbQueue).stats()
                let transcriptions = try TranscriptionRepository(dbQueue: dbManager.dbQueue).fetchAll(limit: nil)
                database = .init(status: "ok", dictations: dictStats.totalCount, transcriptions: transcriptions.count, error: nil)
            } catch {
                database = .init(status: "error", dictations: nil, transcriptions: nil, error: error.localizedDescription)
            }
        } else {
            database = .init(status: "missing", dictations: nil, transcriptions: nil, error: nil)
        }
        report.database = database
        if !json {
            print("Database:")
            switch database.status {
            case "ok":
                print("  Status: OK")
                print("  Dictations: \(database.dictations ?? 0)")
                print("  Transcriptions: \(database.transcriptions ?? 0)")
            case "missing":
                print("  Status: Not created yet (will be created on first use)")
            default:
                print("  Status: ERROR — \(database.error ?? "unknown")")
            }
            print()
        }

        // 4. Audio input
        let audio = loadAudioInputDiagnostics()
        report.audioInput = HealthReport.AudioInput(
            deviceCount: audio.devices.count,
            selectedUID: audio.storedSelectedUID,
            defaultDeviceName: audio.defaultDevice?.name,
            builtInDeviceName: audio.builtInDevice?.name
        )
        if !json {
            print("Audio Input:")
            printAudioInputDiagnostics(audio)
            print()
        }

        // 5. Local speech stack
        let sttClient = STTClient()
        // CLI is about to exit anyway, but `defer` guarantees shutdown runs
        // even if a future change adds a throw between init and the explicit
        // shutdown below. Detached because defer can't await.
        defer { Task { await sttClient.shutdown() } }
        let diarizationService = DiarizationService()
        let status = await loadSpeechStackStatus(
            sttClient: sttClient,
            diarizationService: diarizationService
        )
        report.speechStack = SpeechStackPayload(status: status)
        if !json {
            print("Local Speech Stack:")
            printSpeechStackStatus(status, includeHeader: false)
        }

        if let repairAttempts = validatedRepairAttempts {
            if !json { print(); print("Speech-stack repair requested...") }
            do {
                try await prepareSpeechStack(
                    attempts: repairAttempts,
                    sttClient: sttClient,
                    diarizationService: diarizationService,
                    log: { message in if !self.json { print("  \(message)") } }
                )
                report.repair = HealthReport.Repair(attempted: true, completed: true, error: nil)
                if !json { print("Speech-stack repair completed.") }
            } catch {
                report.repair = HealthReport.Repair(attempted: true, completed: false, error: error.localizedDescription)
                if !json { print("Speech-stack repair failed — \(error.localizedDescription)") }
            }
        }
        if !json { print() }

        // 6. Bundled FFmpeg
        let ffmpeg: HealthReport.Binary
        if let ffmpegPath = BinaryBootstrap.resolveRuntimeFFmpegPath() {
            let isBundled = ffmpegPath == AppPaths.bundledFFmpegPath()
            ffmpeg = .init(status: isBundled ? "bundled" : "fallback", path: ffmpegPath, error: nil)
        } else {
            ffmpeg = .init(status: "missing", path: nil, error: nil)
        }
        report.ffmpeg = ffmpeg
        if !json {
            print("FFmpeg:")
            switch ffmpeg.status {
            case "bundled": print("  Status: Found bundled binary at \(ffmpeg.path ?? "")")
            case "fallback": print("  Status: Found development fallback at \(ffmpeg.path ?? "")")
            default: print("  Status: Missing (bundle + development fallback)")
            }
            print()
        }

        // 7. yt-dlp
        let ytDlp: HealthReport.Binary
        do {
            let path = try await BinaryBootstrap().ensureYtDlpAvailable()
            ytDlp = .init(status: "ready", path: path, error: nil)
        } catch {
            ytDlp = .init(status: "missing", path: nil, error: error.localizedDescription)
        }
        report.ytDlp = ytDlp
        if !json {
            print("yt-dlp:")
            switch ytDlp.status {
            case "ready": print("  Status: Ready at \(ytDlp.path ?? "")")
            default:      print("  Status: Not available — \(ytDlp.error ?? "unknown")")
            }
            print()
        }

        // 8. Calendar
        let permission = CalendarService.shared.permissionStatus
        let calendarStatus: String
        switch permission {
        case .granted: calendarStatus = "granted"
        case .denied: calendarStatus = "denied"
        case .notDetermined: calendarStatus = "notDetermined"
        }
        var calendarsVisible: Int?
        if permission == .granted {
            calendarsVisible = await CalendarService.shared.availableCalendars().count
        }
        report.calendar = HealthReport.Calendar(permission: calendarStatus, calendarsVisible: calendarsVisible)
        if !json {
            print("Calendar (EventKit):")
            switch permission {
            case .granted:
                print("  Status: Granted")
                if let n = calendarsVisible { print("  Calendars visible: \(n)") }
            case .denied:
                print("  Status: Denied (open System Settings → Privacy & Security → Calendars)")
            case .notDetermined:
                print("  Status: Not requested (run the app once and grant access)")
            }
            print()
            print("Done.")
        } else {
            try printJSON(report)
        }
    }
}

// Health JSON payload. Local to the CLI so adding diagnostic fields here
// doesn't require touching the Core layer.
private struct HealthReport: Encodable {
    var paths: Paths = .empty
    var directoriesOK: Bool = false
    var directoriesError: String?
    var database: Database?
    var audioInput: AudioInput?
    var speechStack: SpeechStackPayload?
    var repair: Repair?
    var ffmpeg: Binary?
    var ytDlp: Binary?
    var calendar: Calendar?

    struct Paths: Encodable {
        let appSupport: String
        let database: String
        let temp: String
        let bin: String
        let ytDlp: String
        static let empty = Paths(appSupport: "", database: "", temp: "", bin: "", ytDlp: "")
    }

    struct Database: Encodable {
        let status: String  // "ok" | "missing" | "error"
        let dictations: Int?
        let transcriptions: Int?
        let error: String?
    }

    struct AudioInput: Encodable {
        let deviceCount: Int
        let selectedUID: String?
        let defaultDeviceName: String?
        let builtInDeviceName: String?
    }

    struct Repair: Encodable {
        let attempted: Bool
        let completed: Bool
        let error: String?
    }

    struct Binary: Encodable {
        let status: String
        let path: String?
        let error: String?
    }

    struct Calendar: Encodable {
        let permission: String  // "granted" | "denied" | "notDetermined"
        let calendarsVisible: Int?
    }
}
