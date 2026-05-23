import Foundation

public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper

    public static let defaultsKey = "speechRecognitionEngine"
    public static let whisperDefaultLanguageKey = "whisperDefaultLanguage"
    public static let whisperModelVariantKey = "whisperModelVariant"

    /// Variants whose one-time CoreML compile/ANE specialization has already
    /// completed on this Mac. The first load of a Whisper variant pays a
    /// multi-minute optimize (`WhisperKitConfig(load: true)`); subsequent loads
    /// reuse the on-disk compiled artifacts and are fast. We persist which
    /// variants are warm so the UI can distinguish a cold first switch
    /// ("Setup needed", minutes) from a warm one ("Downloaded", seconds).
    public static let whisperOptimizedVariantsKey = "whisperOptimizedVariants"

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

    /// Whether `variant` has already paid its one-time on-device optimize, so
    /// the next load will be fast. Compares on the normalized variant id.
    public static func hasOptimizedWhisper(variant: String, defaults: UserDefaults = .standard) -> Bool {
        guard let normalized = normalizeModelVariant(variant) else { return false }
        let optimized = defaults.stringArray(forKey: whisperOptimizedVariantsKey) ?? []
        return optimized.contains(normalized)
    }

    public static func isColdSwitch(to preference: SpeechEnginePreference, defaults: UserDefaults = .standard) -> Bool {
        guard preference == .whisper else { return false }
        return !hasOptimizedWhisper(variant: whisperModelVariant(defaults: defaults), defaults: defaults)
    }

    /// Records that `variant` finished its one-time optimize on this Mac.
    /// Idempotent; call after a successful `WhisperEngine.prepare()`.
    public static func markWhisperOptimized(variant: String, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeModelVariant(variant) else { return }
        var optimized = defaults.stringArray(forKey: whisperOptimizedVariantsKey) ?? []
        guard !optimized.contains(normalized) else { return }
        optimized.append(normalized)
        defaults.set(optimized, forKey: whisperOptimizedVariantsKey)
    }

    public static func normalizeLanguage(_ language: String?) -> String? {
        WhisperLanguageCatalog.canonicalCode(for: language)
    }

    public static func normalizeKnownLanguage(_ language: String?) -> String? {
        guard let normalized = normalizeLanguage(language),
              WhisperLanguageCatalog.language(forCode: normalized) != nil else {
            return nil
        }
        return normalized
    }

    public static func normalizeModelVariant(_ variant: String?) -> String? {
        guard let variant else { return nil }
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutPrefix = trimmed.hasPrefix("whisper-")
            ? String(trimmed.dropFirst("whisper-".count))
            : trimmed
        return canonicalizeTurboSuffix(withoutPrefix)
    }

    /// Whisper "turbo" variants ship with both hyphen and underscore spellings
    /// (`large-v3-turbo`, `large-v3_turbo`). Fold them to the underscore form so
    /// one model resolves to a single id everywhere — on-disk folder lookup, the
    /// stored preference, and optimized-flag tracking — instead of the mark-side
    /// (engine) and query-side (UI) ids drifting apart.
    private static func canonicalizeTurboSuffix(_ variant: String) -> String {
        if variant.hasSuffix("-turbo") {
            return String(variant.dropLast("-turbo".count)) + "_turbo"
        }
        if variant.contains("-turbo_") {
            return variant.replacingOccurrences(of: "-turbo_", with: "_turbo_")
        }
        if variant.contains("-turbo-") {
            return variant.replacingOccurrences(of: "-turbo-", with: "_turbo_")
        }
        return variant
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
