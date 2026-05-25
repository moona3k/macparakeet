import Foundation

/// One feature's engine choice: either follow the global default, or
/// override with a specific engine. Used in `SpeechEnginePreferences`.
public enum FeatureEngineSelection: Codable, Sendable, Equatable, Hashable {
    case global
    case specific(SpeechEnginePreference)
}

/// User's persisted speech-engine configuration. One global default plus
/// per-feature overrides for dictation, file transcription, and meeting
/// recording. Replaces the pre-Phase-2.2 single `SpeechEnginePreference`
/// persistence.
public struct SpeechEnginePreferences: Codable, Sendable, Equatable {
    public var global: SpeechEnginePreference
    public var dictation: FeatureEngineSelection
    public var fileTranscription: FeatureEngineSelection
    public var meetingRecording: FeatureEngineSelection

    public init(
        global: SpeechEnginePreference = .parakeet,
        dictation: FeatureEngineSelection = .global,
        fileTranscription: FeatureEngineSelection = .global,
        meetingRecording: FeatureEngineSelection = .global
    ) {
        self.global = global
        self.dictation = dictation
        self.fileTranscription = fileTranscription
        self.meetingRecording = meetingRecording
    }

    /// Resolves the engine for a given job kind. Per-feature overrides win;
    /// `.global` falls through to `global`.
    public func engine(for jobKind: STTJobKind) -> SpeechEnginePreference {
        switch jobKind {
        case .dictation:           return resolve(dictation)
        case .fileTranscription:   return resolve(fileTranscription)
        case .meetingFinalize, .meetingLiveChunk:
            return resolve(meetingRecording)
        }
    }

    private func resolve(_ selection: FeatureEngineSelection) -> SpeechEnginePreference {
        switch selection {
        case .global:           return global
        case .specific(let e):  return e
        }
    }

    // MARK: - Persistence

    /// UserDefaults key where the JSON-encoded `SpeechEnginePreferences` blob
    /// is stored. Distinct from `SpeechEnginePreference.defaultsKey` which
    /// is the pre-Phase-2.2 single-engine key, kept around for migration.
    public static let defaultsKey = "speechEnginePreferences"

    /// Loads the current preferences. If the new key isn't present, migrates
    /// from the legacy `SpeechEnginePreference` single key. If neither is
    /// present, returns defaults (all-Parakeet).
    public static func current(defaults: UserDefaults = .standard) -> SpeechEnginePreferences {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SpeechEnginePreferences.self, from: data) {
            return decoded
        }
        // Migration from pre-Phase-2.2: the only persisted value was the
        // legacy single-engine key. Promote it to `global` and leave every
        // per-feature override at `.global`.
        let legacy = SpeechEnginePreference.current(defaults: defaults)
        return SpeechEnginePreferences(
            global: legacy,
            dictation: .global,
            fileTranscription: .global,
            meetingRecording: .global
        )
    }

    /// Persists the preferences. Does not delete the legacy
    /// `SpeechEnginePreference.defaultsKey` — readers that still use it
    /// (until they're migrated) keep working off the old value.
    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
