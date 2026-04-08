import Foundation
import MacParakeetCore

@MainActor
final class AppStartupBootstrapper {
    func bootstrapEnvironment() async throws -> AppEnvironment {
        let databaseManager = try await Task.detached(priority: .userInitiated) {
            try AppPaths.ensureDirectories()
            let manager = try DatabaseManager(path: AppPaths.databasePath)

            // Keep one-time launch cleanup off the main actor.
            let dictationRepo = DictationRepository(dbQueue: manager.dbQueue)
            _ = try? dictationRepo.deleteEmpty()
            try? dictationRepo.clearMissingAudioPaths()

            return manager
        }.value

        return try AppEnvironment(databaseManager: databaseManager)
    }
}
