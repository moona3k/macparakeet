import Foundation
import MacParakeetCore

public enum MeetingSourceHealthSeverity: Sendable, Equatable {
    case neutral
    case good
    case warning
    case critical
}

public struct MeetingSourceHealthChip: Identifiable, Sendable, Equatable {
    public let source: MeetingSourceHealth.Source
    public let status: MeetingSourceHealth.Status
    public let label: String
    public let symbolName: String
    public let severity: MeetingSourceHealthSeverity
    public let isDegraded: Bool

    public var id: String {
        source.rawValue
    }

    public init(_ health: MeetingSourceHealth) {
        self.source = health.source
        self.status = health.status
        self.label = health.label
        self.symbolName = Self.symbolName(source: health.source, status: health.status)
        self.severity = Self.severity(for: health.status)
        self.isDegraded = health.status.isDegraded
    }

    public static func chips(
        for summary: MeetingCaptureHealthSummary,
        includeNotSelected: Bool
    ) -> [MeetingSourceHealthChip] {
        [summary.microphone, summary.system]
            .filter { includeNotSelected || $0.status != .notSelected }
            .map(MeetingSourceHealthChip.init)
    }

    public static func primaryDegraded(
        for summary: MeetingCaptureHealthSummary
    ) -> MeetingSourceHealthChip? {
        summary.primaryDegradedSource.map(MeetingSourceHealthChip.init)
    }

    public static func actionableWarnings(
        for summary: MeetingCaptureHealthSummary
    ) -> [MeetingSourceHealthChip] {
        [summary.microphone, summary.system]
            .filter { $0.status.isActionableWarning }
            .map(MeetingSourceHealthChip.init)
    }

    public static func primaryActionableWarning(
        for summary: MeetingCaptureHealthSummary
    ) -> MeetingSourceHealthChip? {
        summary.primaryActionableSource.map(MeetingSourceHealthChip.init)
    }

    private static func severity(for status: MeetingSourceHealth.Status) -> MeetingSourceHealthSeverity {
        switch status {
        case .live:
            return .good
        case .muted, .silent, .stalled, .recovering:
            return .warning
        case .interrupted, .unavailable:
            return .critical
        case .notSelected, .starting:
            return .neutral
        }
    }

    private static func symbolName(
        source: MeetingSourceHealth.Source,
        status: MeetingSourceHealth.Status
    ) -> String {
        switch (source, status) {
        case (.microphone, .live):
            return "mic.fill"
        case (.microphone, .muted), (.microphone, .notSelected):
            return "mic.slash.fill"
        case (.microphone, .silent), (.microphone, .stalled), (.microphone, .interrupted), (.microphone, .unavailable):
            return "exclamationmark.triangle.fill"
        case (.microphone, .recovering):
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case (.microphone, .starting):
            return "mic"
        case (.system, .live):
            return "speaker.wave.2.fill"
        case (.system, .notSelected):
            return "speaker.slash.fill"
        case (.system, .silent), (.system, .stalled), (.system, .interrupted), (.system, .unavailable):
            return "exclamationmark.triangle.fill"
        case (.system, .recovering):
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case (.system, .starting), (.system, .muted):
            return "speaker.wave.2"
        }
    }
}
