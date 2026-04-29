import Foundation

public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper

    public static let defaultsKey = "speechRecognitionEngine"
    public static let whisperDefaultLanguageKey = "whisperDefaultLanguage"
    public static let whisperModelVariantKey = "whisperModelVariant"

    public static let defaultWhisperModelVariant = "large-v3-v20240930_turbo_632MB"

    public var displayName: String {
        switch self {
        case .parakeet:
            "Parakeet"
        case .whisper:
            "Whisper"
        }
    }

    public var alternative: SpeechEnginePreference {
        switch self {
        case .parakeet:
            .whisper
        case .whisper:
            .parakeet
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> SpeechEnginePreference {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let preference = SpeechEnginePreference(rawValue: rawValue) else {
            return .parakeet
        }
        return preference
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public static func whisperDefaultLanguage(defaults: UserDefaults = .standard) -> String? {
        normalizeLanguage(defaults.string(forKey: whisperDefaultLanguageKey))
    }

    public static func saveWhisperDefaultLanguage(_ language: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeLanguage(language) else {
            defaults.removeObject(forKey: whisperDefaultLanguageKey)
            return
        }
        defaults.set(normalized, forKey: whisperDefaultLanguageKey)
    }

    public static func whisperModelVariant(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: whisperModelVariantKey)
        return normalizeModelVariant(stored) ?? defaultWhisperModelVariant
    }

    public static func saveWhisperModelVariant(_ variant: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeModelVariant(variant) else {
            defaults.removeObject(forKey: whisperModelVariantKey)
            return
        }
        defaults.set(normalized, forKey: whisperModelVariantKey)
    }

    public static func normalizeLanguage(_ language: String?) -> String? {
        WhisperLanguageCatalog.canonicalCode(for: language)
    }

    public static func normalizeModelVariant(_ variant: String?) -> String? {
        guard let variant else { return nil }
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("whisper-") ? String(trimmed.dropFirst("whisper-".count)) : trimmed
    }

    /// Maps an internal Whisper variant id to a short, user-friendly label.
    /// Falls back to the raw variant if the shape is unrecognized so unknown
    /// future variants degrade to something readable rather than empty.
    public static func friendlyVariantName(_ rawVariant: String) -> String {
        let normalized = normalizeModelVariant(rawVariant) ?? rawVariant
        let lowered = normalized.lowercased()

        let sizeOrder: [(token: String, label: String)] = [
            ("large-v3", "Large v3"),
            ("large-v2", "Large v2"),
            ("large", "Large"),
            ("medium", "Medium"),
            ("small", "Small"),
            ("base", "Base"),
            ("tiny", "Tiny")
        ]
        let size = sizeOrder.first { variantPrefixMatches(lowered, token: $0.token) }?.label

        let isTurbo = lowered.contains("turbo")

        if let size {
            return isTurbo ? "\(size) Turbo" : size
        }
        return rawVariant
    }

    private static func variantPrefixMatches(_ normalized: String, token: String) -> Bool {
        guard normalized.hasPrefix(token) else { return false }
        let remainder = normalized.dropFirst(token.count)
        guard let separator = remainder.first else { return true }
        guard separator == "-" || separator == "_" || separator == "." else { return false }

        if !token.contains("-v"), separator == "-" {
            let suffix = remainder.dropFirst()
            if suffix.first == "v",
               suffix.dropFirst().first?.isNumber == true {
                return false
            }
        }

        return true
    }
}

public struct SpeechEngineSelection: Codable, Equatable, Sendable {
    public let engine: SpeechEnginePreference
    public let language: String?

    public init(engine: SpeechEnginePreference, language: String? = nil) {
        self.engine = engine
        self.language = engine == .whisper ? SpeechEnginePreference.normalizeLanguage(language) : nil
    }

    public static func current(defaults: UserDefaults = .standard) -> SpeechEngineSelection {
        let engine = SpeechEnginePreference.current(defaults: defaults)
        return SpeechEngineSelection(
            engine: engine,
            language: engine == .whisper ? SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults) : nil
        )
    }
}

public struct SpeechEngineLease: Equatable, Sendable {
    public let id: UUID
    public let selection: SpeechEngineSelection

    public init(id: UUID = UUID(), selection: SpeechEngineSelection) {
        self.id = id
        self.selection = selection
    }
}
