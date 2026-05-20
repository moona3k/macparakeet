import Foundation
import OSLog

public struct LLMRunRecorder: Sendable {
    private let repository: LLMRunRepositoryProtocol?
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "LLMRunRecorder")

    public init(repository: LLMRunRepositoryProtocol?) {
        self.repository = repository
    }

    public func record(_ run: LLMRun?) async {
        guard let repository, let run else { return }
        do {
            try await repository.save(run)
        } catch {
            logger.error("llm_run_record_failed feature=\(run.feature.rawValue, privacy: .public) status=\(run.status.rawValue, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }
}
