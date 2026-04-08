import Foundation
import MacParakeetCore

@MainActor
final class AppStartupBootstrapper {
    func bootstrapEnvironment() async throws -> AppEnvironment {
        let bootstrapTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try AppPaths.ensureDirectories()
            try Task.checkCancellation()

            let manager = try DatabaseManager(path: AppPaths.databasePath)
            try Task.checkCancellation()

            // Keep one-time launch cleanup off the main actor.
            let dictationRepo = DictationRepository(dbQueue: manager.dbQueue)
            _ = try? dictationRepo.deleteEmpty()
            try? dictationRepo.clearMissingAudioPaths()

            try Task.checkCancellation()
            return manager
        }

        let databaseManager = try await withTaskCancellationHandler {
            try await bootstrapTask.value
        } onCancel: {
            bootstrapTask.cancel()
        }

        try Task.checkCancellation()
        return try AppEnvironment(databaseManager: databaseManager)
    }
}
