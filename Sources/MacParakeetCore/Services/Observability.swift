import Foundation

public enum ObservabilityOutcome: String, Sendable {
    case success
    case failure
    case cancelled
    case empty
    case unavailable
}

public enum ObservabilityInputKind: String, Sendable {
    case audio
    case video
    case youtube
    case meeting
    case unknown
}

public struct ObservabilityOperationContext: Sendable, Equatable {
    public let operationID: String
    public let workflowID: String
    public let parentOperationID: String?
    public let startedAt: Date

    public init(
        operationID: String = Observability.operationID(),
        workflowID: String? = nil,
        parentOperationID: String? = nil,
        startedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.workflowID = workflowID ?? operationID
        self.parentOperationID = parentOperationID
        self.startedAt = startedAt
    }

    public func child(startedAt: Date = Date()) -> ObservabilityOperationContext {
        ObservabilityOperationContext(
            workflowID: workflowID,
            parentOperationID: operationID,
            startedAt: startedAt
        )
    }
}

public enum Observability {
    @TaskLocal public static var currentOperationContext: ObservabilityOperationContext?

    public static func withOperationContext<T>(
        _ context: ObservabilityOperationContext,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentOperationContext.withValue(context, operation: operation, isolation: isolation)
    }

    public static func childOperationContext(startedAt: Date = Date()) -> ObservabilityOperationContext {
        if let currentOperationContext {
            return currentOperationContext.child(startedAt: startedAt)
        }
        return ObservabilityOperationContext(startedAt: startedAt)
    }

    public static func operationContext(operationID: String, startedAt: Date) -> ObservabilityOperationContext {
        if let currentOperationContext {
            return ObservabilityOperationContext(
                operationID: operationID,
                workflowID: currentOperationContext.workflowID,
                parentOperationID: currentOperationContext.operationID == operationID
                    ? currentOperationContext.parentOperationID
                    : currentOperationContext.operationID,
                startedAt: startedAt
            )
        }
        return ObservabilityOperationContext(operationID: operationID, startedAt: startedAt)
    }

    public static func operationID() -> String {
        UUID().uuidString
    }

    public static func durationSeconds(since startedAt: Date) -> Double {
        max(0, Date().timeIntervalSince(startedAt))
    }

    public static func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    public static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    public static func mediaExtension(for url: URL?) -> String? {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            return nil
        }
        return ext
    }

    public static func inputKind(for url: URL?) -> ObservabilityInputKind? {
        guard let ext = mediaExtension(for: url) else { return nil }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return .unknown
    }

    public static func fileSizeBucket(bytes: Int?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        switch bytes {
        case 0..<1_000_000:
            return "lt_1mb"
        case 1_000_000..<10_000_000:
            return "1_10mb"
        case 10_000_000..<100_000_000:
            return "10_100mb"
        case 100_000_000..<1_000_000_000:
            return "100mb_1gb"
        default:
            return "gte_1gb"
        }
    }

    public static func textLengthBucket(_ text: String?) -> String {
        let count = text?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        switch count {
        case 0:
            return "none"
        case 1...200:
            return "1_200"
        case 201...1_000:
            return "201_1000"
        case 1_001...5_000:
            return "1001_5000"
        default:
            return "gt_5000"
        }
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma"
    ]

    private static let videoExtensions: Set<String> = [
        "avi", "flv", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv"
    ]
}
