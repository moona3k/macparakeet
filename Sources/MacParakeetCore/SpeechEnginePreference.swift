import Foundation

public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case nemotron
    case whisper

    public static let defaultsKey = "speechRecognitionEngine"
    public static let parakeetModelVariantKey = "parakeetModelVariant"
    public static let nemotronDefaultLanguageKey = "nemotronDefaultLanguage"
    public static let whisperDefaultLanguageKey = "whisperDefaultLanguage"
    public static let whisperModelVariantKey = "whisperModelVariant"

    /// New users stay on the multilingual `v3` build — it "works for everyone".
    /// `v2` (English-only) is surfaced as a clearly-labeled opt-in.
    public static let defaultParakeetModelVariant: ParakeetModelVariant = .v3

    /// Variants whose one-time CoreML compile/ANE specialization has already
    /// completed on this Mac. The first load of a Whisper variant pays a
    /// multi-minute optimize (`WhisperKitConfig(load: true)`); subsequent loads
    /// reuse the on-disk compiled artifacts and are fast. We persist which
    /// variants are warm so the UI can distinguish a cold first switch
    /// ("Setup needed", minutes) from a warm one ("Downloaded", seconds).
    public static let whisperOptimizedVariantsKey = "whisperOptimizedVariants"

    public static let defaultWhisperModelVariant = "large-v3-v20240930_turbo_632MB"
    public static let defaultNemotronModelVariant: NemotronModelVariant = .multilingual1120

    public var displayName: String {
        switch self {
        case .parakeet:
            "Parakeet"
        case .nemotron:
            "Nemotron"
        case .whisper:
            "Whisper"
        }
    }

    public var alternative: SpeechEnginePreference {
        switch self {
        case .parakeet:
            .nemotron
        case .nemotron:
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

    public static func nemotronDefaultLanguage(defaults: UserDefaults = .standard) -> String? {
        normalizeNemotronLanguage(defaults.string(forKey: nemotronDefaultLanguageKey))
    }

    public static func saveNemotronDefaultLanguage(_ language: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeNemotronLanguage(language) else {
            defaults.removeObject(forKey: nemotronDefaultLanguageKey)
            return
        }
        defaults.set(normalized, forKey: nemotronDefaultLanguageKey)
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

    /// The persisted Parakeet model variant, defaulting to multilingual `v3`.
    /// Backed by a validated enum so the stored value can never drift to an
    /// unsupported model id.
    public static func parakeetModelVariant(defaults: UserDefaults = .standard) -> ParakeetModelVariant {
        guard let raw = defaults.string(forKey: parakeetModelVariantKey),
              let variant = ParakeetModelVariant(rawValue: raw) else {
            return defaultParakeetModelVariant
        }
        return variant
    }

    public static func saveParakeetModelVariant(_ variant: ParakeetModelVariant, defaults: UserDefaults = .standard) {
        defaults.set(variant.rawValue, forKey: parakeetModelVariantKey)
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

    /// Forgets that `variant` was optimized. Call after deleting the model from
    /// disk so a later re-download honestly reports the cold "first switch takes
    /// a few minutes" state instead of promising an instant load. Idempotent.
    public static func clearWhisperOptimized(variant: String, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeModelVariant(variant) else { return }
        let optimized = defaults.stringArray(forKey: whisperOptimizedVariantsKey) ?? []
        guard optimized.contains(normalized) else { return }
        let remaining = optimized.filter { $0 != normalized }
        if remaining.isEmpty {
            defaults.removeObject(forKey: whisperOptimizedVariantsKey)
        } else {
            defaults.set(remaining, forKey: whisperOptimizedVariantsKey)
        }
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

    public static func normalizeNemotronLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: "-")
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

/// Which Parakeet TDT 0.6B build powers on-device transcription.
///
/// FluidAudio ships two peer Parakeet TDT 0.6B bundles. `v3` is multilingual
/// (English + 24 other European languages) and is the default; `v2` is an
/// English-only build that runs a touch faster on English and — crucially —
/// cannot mis-detect English speech as another language, which `v3`'s
/// auto-detection occasionally does (issues #311, #398).
///
/// The FluidAudio `AsrModelVersion` bridge lives in the STT layer
/// (`ParakeetModelVariant+ASR.swift`) so this preference type stays
/// Foundation-only and decoupled from CoreML.
public enum ParakeetModelVariant: String, CaseIterable, Codable, Sendable {
    case v3
    case v2

    /// Short label for the variant's language posture.
    public var displayName: String {
        switch self {
        case .v3: "Multilingual"
        case .v2: "English only"
        }
    }

    /// Marketing-grade model identifier (Local Models row, `models list`).
    public var modelName: String {
        switch self {
        case .v3: "Parakeet TDT 0.6B v3"
        case .v2: "Parakeet TDT 0.6B v2"
        }
    }

    /// One-line description of what the variant is best for.
    public var coverageSummary: String {
        switch self {
        case .v3:
            "English plus 24 European languages. Best for mixed or non-English speech."
        case .v2:
            "English only. A touch faster, and never mis-hears English as another language."
        }
    }

    /// Approximate on-disk download footprint. Both builds land near ~465 MB
    /// (v3 int8 encoder ≈ 461 MB measured; v2 ≈ 465 MB). Kept deliberately
    /// rounded so the copy doesn't read as falsely precise.
    public var approximateDownloadSize: String { "~465 MB" }

    public var isEnglishOnly: Bool { self == .v2 }

    public var alternative: ParakeetModelVariant {
        switch self {
        case .v3: .v2
        case .v2: .v3
        }
    }
}

/// The Nemotron 3.5 CoreML build surfaced by MacParakeet.
///
/// FluidAudio exposes several chunk-size tiers. MacParakeet starts with the
/// multilingual 1120 ms tier because it keeps the Beta product surface simple
/// while preserving the balanced quality/latency posture expected for
/// dictation, meetings, and file transcription.
public enum NemotronModelVariant: String, CaseIterable, Codable, Sendable {
    case multilingual1120 = "multilingual-1120ms"

    public var displayName: String {
        switch self {
        case .multilingual1120:
            "Multilingual Beta"
        }
    }

    public var modelName: String {
        switch self {
        case .multilingual1120:
            "Nemotron 3.5 ASR Streaming 0.6B"
        }
    }

    public var coverageSummary: String {
        switch self {
        case .multilingual1120:
            "Fast multilingual streaming model. Beta while MacParakeet benchmarks quality and edge cases."
        }
    }

    public var approximateDownloadSize: String { "~1.5 GB" }

    public var chunkMilliseconds: Int {
        switch self {
        case .multilingual1120:
            1120
        }
    }
}

public struct SpeechEngineSelection: Codable, Equatable, Sendable {
    public let engine: SpeechEnginePreference
    public let language: String?

    public init(engine: SpeechEnginePreference, language: String? = nil) {
        self.engine = engine
        self.language = switch engine {
        case .parakeet:
            nil
        case .nemotron:
            SpeechEnginePreference.normalizeNemotronLanguage(language)
        case .whisper:
            SpeechEnginePreference.normalizeLanguage(language)
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> SpeechEngineSelection {
        let engine = SpeechEnginePreference.current(defaults: defaults)
        let language: String? = switch engine {
        case .parakeet:
            nil
        case .nemotron:
            SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        case .whisper:
            SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)
        }
        return SpeechEngineSelection(engine: engine, language: language)
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
