import ArgumentParser
import Foundation
import MacParakeetCore

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show voice stats dashboard."
    )

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let stats = try dictationRepo.stats()
        let transcriptionCount = try transcriptionRepo.count()
        let favoriteCount = try transcriptionRepo.fetchFavorites().count

        if stats.visibleCount == 0 && transcriptionCount == 0 {
            print("No voice activity yet.")
            return
        }

        print("=== Voice Stats ===")
        print()

        // Dictation stats
        print("Dictations")
        print("  Total:            \(stats.visibleCount)")
        print("  Total words:      \(stats.totalWords)")
        if stats.totalDurationMs > 0 {
            let totalSec = stats.totalDurationMs / 1000
            let min = totalSec / 60
            let sec = totalSec % 60
            print("  Total duration:   \(min)m \(sec)s")
        }
        if stats.averageDurationMs > 0 {
            let avgSec = stats.averageDurationMs / 1000
            print("  Avg duration:     \(avgSec)s")
        }
        if stats.averageWPM > 0 {
            print("  Avg WPM:          \(Int(stats.averageWPM))")
        }
        if stats.longestDurationMs > 0 {
            let longestSec = stats.longestDurationMs / 1000
            let min = longestSec / 60
            let sec = longestSec % 60
            print("  Longest:          \(min)m \(sec)s")
        }
        if stats.weeklyStreak > 0 {
            print("  Weekly streak:    \(stats.weeklyStreak) week(s)")
        }
        if stats.dictationsThisWeek > 0 {
            print("  This week:        \(stats.dictationsThisWeek)")
        }

        // Equivalents
        if stats.totalWords > 0 {
            let timeSavedMin = stats.timeSavedMs / 60_000
            if timeSavedMin > 0 {
                print("  Time saved:       ~\(timeSavedMin) min (vs typing)")
            }
            if stats.booksEquivalent >= 0.1 {
                print("  Books equivalent: \(String(format: "%.1f", stats.booksEquivalent))")
            }
            if stats.emailsEquivalent >= 1.0 {
                print("  Emails equivalent: \(Int(stats.emailsEquivalent))")
            }
        }

        // Transcription stats
        print()
        print("Transcriptions")
        print("  Total:            \(transcriptionCount)")
        if favoriteCount > 0 {
            print("  Favorites:        \(favoriteCount)")
        }
    }
}
