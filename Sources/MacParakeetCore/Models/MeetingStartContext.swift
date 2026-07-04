import Foundation

public struct MeetingStartContext: Codable, Sendable, Equatable {
    public enum TriggerKind: String, Codable, Sendable, Equatable, CaseIterable {
        case manual
        case hotkey
        case calendarAutoStart = "calendar_auto_start"
    }

    public struct FrontmostApplication: Codable, Sendable, Equatable {
        public let bundleIdentifier: String?
        public let localizedName: String?

        public init(bundleIdentifier: String?, localizedName: String?) {
            self.bundleIdentifier = AppPromptContext.normalizedBundleIdentifier(bundleIdentifier)
            self.localizedName = AppPromptContext.normalizedDisplayName(localizedName)
        }
    }

    public let triggerKind: TriggerKind
    public let frontmostApplication: FrontmostApplication?
    public let sourceMode: MeetingAudioSourceMode

    public init(
        triggerKind: TriggerKind,
        frontmostApplication: FrontmostApplication?,
        sourceMode: MeetingAudioSourceMode
    ) {
        self.triggerKind = triggerKind
        self.frontmostApplication = frontmostApplication
        self.sourceMode = sourceMode
    }
}

public extension MeetingStartContext.TriggerKind {
    init(_ trigger: TelemetryMeetingRecordingTrigger) {
        switch trigger {
        case .manual:
            self = .manual
        case .hotkey:
            self = .hotkey
        case .calendarAutoStart:
            self = .calendarAutoStart
        }
    }
}
