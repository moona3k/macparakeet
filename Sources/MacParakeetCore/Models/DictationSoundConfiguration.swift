import Foundation

/// Only microphone-open/closed cues are configurable; completion/error sounds
/// deliberately keep their existing behavior.
public enum DictationSoundCue: String, CaseIterable, Codable, Sendable {
    case start
    case stop

    public var title: String { self == .start ? "Start sound" : "Stop sound" }
    public var systemSoundName: String { self == .start ? "Tink" : "Pop" }
}

public enum DictationSoundStyle: String, CaseIterable, Codable, Sendable {
    case system
    case bloom
    case gong
    case custom
    case silent

    public var title: String {
        switch self {
        case .system: "macOS default"
        case .bloom: "Bloom"
        case .gong: "Gong"
        case .custom: "Custom file"
        case .silent: "None"
        }
    }

    public func resourceName(for cue: DictationSoundCue) -> String? {
        switch self {
        case .bloom, .gong: "macparakeet_\(rawValue)_\(cue.rawValue)"
        case .system, .custom, .silent: nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Retired Handy presets and the unreleased Pebble choice become Bloom
        // without resetting volume or retained custom-file metadata.
        switch value {
        case "handyPop", "handyMarimba", "pebble": self = .bloom
        default:
            guard let style = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown dictation sound style")
            }
            self = style
        }
    }
}

public struct DictationSoundConfiguration: Codable, Equatable, Sendable {
    public var style: DictationSoundStyle
    public var volume: Double
    /// An app-generated basename, never an external path or bookmark.
    public var customFileName: String?
    public var customDisplayName: String?

    public init(
        style: DictationSoundStyle = .system,
        volume: Double = 0.4,
        customFileName: String? = nil,
        customDisplayName: String? = nil
    ) {
        self.style = style
        self.volume = volume
        self.customFileName = customFileName
        self.customDisplayName = customDisplayName
    }

    public static let supportedExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "caf"]

    public static func isManagedFileName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2
            && UUID(uuidString: String(parts[0])) != nil
            && supportedExtensions.contains(String(parts[1]))
    }

    public var normalized: Self {
        var result = self
        result.volume = volume.isFinite ? min(1, max(0, volume)) : 0.4
        if let name = result.customFileName, !Self.isManagedFileName(name) {
            result.customFileName = nil
            result.customDisplayName = nil
        }
        if result.customFileName == nil {
            result.customDisplayName = nil
            if result.style == .custom { result.style = .system }
        }
        return result
    }

    public static func preferenceKey(for cue: DictationSoundCue) -> String {
        "dictationSound.\(cue.rawValue).v1"
    }

    public static func load(for cue: DictationSoundCue, defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey(for: cue)),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value.normalized
    }

    public func save(for cue: DictationSoundCue, defaults: UserDefaults) {
        // Normalization makes nonfinite doubles encodable; all remaining fields
        // are strings/enums. Keep one atomic preference value per cue.
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.preferenceKey(for: cue))
    }
}
