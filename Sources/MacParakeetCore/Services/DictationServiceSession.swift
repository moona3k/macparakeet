import Foundation

/// Wraps DictationService with monotonic session ownership so callers do not
/// need to thread session IDs through every lifecycle operation.
public actor DictationServiceSession {
    private let service: DictationService
    private var activeSessionID: Int = 0

    public init(service: DictationService) {
        self.service = service
    }

    public var currentSessionID: Int {
        activeSessionID
    }

    public var state: DictationState {
        get async { await service.state }
    }

    public var audioLevel: Float {
        get async { await service.audioLevel }
    }

    @discardableResult
    public func startRecording(context: DictationTelemetryContext) async throws -> Int {
        activeSessionID += 1
        let sessionID = activeSessionID
        try await service.startRecording(context: context, sessionID: sessionID)
        return sessionID
    }

    public func stopRecording() async throws -> DictationResult {
        try await service.stopRecording(sessionID: activeSessionID)
    }

    public func cancelRecording(reason: TelemetryDictationCancelReason?) async {
        await service.cancelRecording(reason: reason, sessionID: activeSessionID)
    }

    public func confirmCancel() async {
        await service.confirmCancel(sessionID: activeSessionID)
    }

    public func undoCancel() async throws -> DictationResult {
        try await service.undoCancel()
    }
}
