import Foundation

public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case nemotron
    case whisper
    /// Cohere Transcribe (03-2026) via FluidAudio's `CoherePipeline`, on-device
    /// Core ML. A batch, dictation-oriented engine (no live partials, no word
    /// timestamps); see ``CohereTranscribeEngine``.
    case cohere

    public static let defaultsKey = "speechRecognitionEngine"
    public static let parakeetModelVariantKey = "parakeetModelVariant"
    public static let nemotronModelVariantKey = "nemotronModelVariant"
    public static let nemotronDefaultLanguageKey = "nemotronDefaultLanguage"
    public static let whisperDefaultLanguageKey = "whisperDefaultLanguage"
    public static let whisperModelVariantKey = "whisperModelVariant"
    /// Cohere has no auto language detection — the user picks one of its 14
    /// supported languages (default English). Stored as a primary subtag ("en",
    /// "fr", …); the engine maps it to `CohereAsrConfig.Language`.
    public static let cohereDefaultLanguageKey = "cohereDefaultLanguage"

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
        case .cohere:
            "Cohere"
        }
    }

    public var alternative: SpeechEnginePreference {
        switch self {
        case .parakeet:
            .whisper
        case .nemotron:
            .whisper
        case .whisper:
            .parakeet
        case .cohere:
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

    /// The persisted Cohere dictation language, as a primary subtag ("en",
    /// "fr", …). `nil` means none chosen yet → the engine defaults to English.
    public static func cohereDefaultLanguage(defaults: UserDefaults = .standard) -> String? {
        normalizeCohereLanguage(defaults.string(forKey: cohereDefaultLanguageKey))
    }

    public static func saveCohereDefaultLanguage(_ language: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeCohereLanguage(language) else {
            defaults.removeObject(forKey: cohereDefaultLanguageKey)
            return
        }
        defaults.set(normalized, forKey: cohereDefaultLanguageKey)
    }

    /// Cohere language codes are simple supported primary subtags ("en", "zh").
    /// Fold any BCP-47-ish input down to its lowercased primary subtag and drop
    /// unsupported values so manual defaults edits cannot leak stale picker
    /// state into the runtime.
    public static func normalizeCohereLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "auto" else { return nil }
        let primary = trimmed.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? trimmed
        guard primary.count == 2, primary.allSatisfy(\.isLetter) else { return nil }
        guard CohereTranscribeEngine.supportedLanguages.contains(where: { $0.code == primary }) else {
            return nil
        }
        return primary
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

    /// The persisted Nemotron build, defaulting to the multilingual `1120ms`
    /// tier. Backed by a validated enum so the stored value can never drift to
    /// an unsupported model id.
    public static func nemotronModelVariant(defaults: UserDefaults = .standard) -> NemotronModelVariant {
        guard let raw = defaults.string(forKey: nemotronModelVariantKey),
              let variant = NemotronModelVariant(rawValue: raw) else {
            return defaultNemotronModelVariant
        }
        return variant
    }

    public static func saveNemotronModelVariant(_ variant: NemotronModelVariant, defaults: UserDefaults = .standard) {
        defaults.set(variant.rawValue, forKey: nemotronModelVariantKey)
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
        let parts = trimmed.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let primary = parts.first,
              (2...3).contains(primary.count),
              primary.allSatisfy(\.isLetter) else {
            return nil
        }

        var canonicalParts = [primary.lowercased()]
        var index = 1
        if parts.indices.contains(index),
           parts[index].count == 4,
           parts[index].allSatisfy(\.isLetter) {
            let script = parts[index].lowercased()
            canonicalParts.append(script.prefix(1).uppercased() + String(script.dropFirst()))
            index += 1
        }
        if parts.indices.contains(index) {
            let region = parts[index]
            if region.count == 2, region.allSatisfy(\.isLetter) {
                canonicalParts.append(region.uppercased())
                index += 1
            } else if region.count == 3, region.allSatisfy(\.isNumber) {
                canonicalParts.append(region)
                index += 1
            } else {
                return nil
            }
        }
        guard index == parts.count else { return nil }
        return canonicalParts.joined(separator: "-")
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

/// Which Parakeet build powers on-device transcription.
///
/// FluidAudio ships two peer Parakeet TDT 0.6B bundles plus the newer Parakeet
/// Unified build. `v3` is multilingual (English + 24 other European languages)
/// and is the default; `v2` is an English-only TDT build that runs a touch
/// faster on English and — crucially — cannot mis-detect English speech as
/// another language, which `v3`'s auto-detection occasionally does (issues
/// #311, #398). `unified` is English-only NVIDIA Parakeet Unified EN 0.6B,
/// a *different* runtime (its own CoreML chain, no `AsrModelVersion`) with
/// strong English offline accuracy plus punctuation/capitalization (issue #520).
///
/// The FluidAudio `AsrModelVersion` bridge lives in the STT layer
/// (`ParakeetModelVariant+ASR.swift`) so this preference type stays
/// Foundation-only and decoupled from CoreML. `unified` has no `AsrModelVersion`
/// — see ``usesUnifiedEngine``.
public enum ParakeetModelVariant: String, CaseIterable, Codable, Sendable {
    case v3
    case v2
    /// NVIDIA Parakeet Unified EN 0.6B (`parakeet-unified-en-0.6b`). English-only
    /// Unified-FastConformer-RNNT — a *different* FluidAudio runtime from the TDT
    /// v2/v3 builds (its own preprocessor/encoder/decoder chain, no
    /// `AsrModelVersion`), so it is routed to ``ParakeetUnifiedEngine`` instead
    /// of the shared `AsrManager`. The offline batch path is competitive with
    /// v2 on English and adds punctuation/capitalization (issue #520).
    case unified

    /// Short label for the variant's language posture.
    public var displayName: String {
        switch self {
        case .v3: "Multilingual"
        case .v2: "English only"
        case .unified: "English (Unified)"
        }
    }

    /// Marketing-grade model identifier (Local Models row, `models list`).
    public var modelName: String {
        switch self {
        case .v3: "Parakeet TDT 0.6B v3"
        case .v2: "Parakeet TDT 0.6B v2"
        case .unified: "Parakeet Unified 0.6B"
        }
    }

    /// One-line description of what the variant is best for.
    public var coverageSummary: String {
        switch self {
        case .v3:
            "English plus 24 European languages. Best for mixed or non-English speech."
        case .v2:
            "English only. A touch faster, and never mis-hears English as another language."
        case .unified:
            "English only. Excellent accuracy and speed, but no word-level timestamps."
        }
    }

    /// Approximate on-disk download footprint. The TDT builds land near ~465 MB
    /// (v3 int8 encoder ≈ 461 MB measured; v2 ≈ 465 MB); Unified's int8 offline
    /// bundle is ~565 MB. Kept deliberately rounded so the copy doesn't read as
    /// falsely precise.
    public var approximateDownloadSize: String {
        switch self {
        case .v3, .v2: "~465 MB"
        case .unified: "~565 MB"
        }
    }

    public var isEnglishOnly: Bool { self == .v2 || self == .unified }

    /// Whether this variant is served by ``ParakeetUnifiedEngine`` (its own
    /// FluidAudio runtime) rather than the shared TDT `AsrManager`. The STT
    /// runtime branches on this before touching the `AsrModelVersion`-keyed
    /// path; it is the single predicate every TDT-only site guards on.
    public var usesUnifiedEngine: Bool { self == .unified }

    public var alternative: ParakeetModelVariant {
        switch self {
        case .v3: .v2
        case .v2: .v3
        case .unified: .v2
        }
    }
}

/// The Nemotron CoreML builds surfaced by MacParakeet.
///
/// FluidAudio exposes several chunk-size tiers per Nemotron family. MacParakeet
/// surfaces the 1120 ms tier of each because it keeps the Beta product surface
/// simple while preserving the balanced quality/latency posture expected for
/// dictation, meetings, and file transcription. The multilingual build is the
/// Nemotron 3.5 model; the English build is the smaller English-only
/// Nemotron Speech Streaming EN 0.6B model
/// (research: `docs/research/stt-models-and-voice-personalization-2026-06.md` §2.1).
public enum NemotronModelVariant: String, CaseIterable, Codable, Sendable {
    case multilingual1120 = "multilingual-1120ms"
    case english1120 = "english-1120ms"

    public var displayName: String {
        switch self {
        case .multilingual1120:
            "Multilingual Beta"
        case .english1120:
            "English Beta"
        }
    }

    public var modelName: String {
        switch self {
        case .multilingual1120:
            "Nemotron 3.5 ASR Streaming 0.6B"
        case .english1120:
            "Nemotron Speech Streaming EN 0.6B"
        }
    }

    public var coverageSummary: String {
        switch self {
        case .multilingual1120:
            "Fast multilingual streaming model."
        case .english1120:
            "English only. Strong research-benchmarked accuracy."
        }
    }

    public var approximateDownloadSize: String {
        switch self {
        case .multilingual1120:
            "~1.5 GB"
        case .english1120:
            "~600 MB"
        }
    }

    public var chunkMilliseconds: Int {
        switch self {
        case .multilingual1120, .english1120:
            1120
        }
    }

    public var isEnglishOnly: Bool { self == .english1120 }

    public var alternative: NemotronModelVariant {
        switch self {
        case .multilingual1120: .english1120
        case .english1120: .multilingual1120
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
        case .cohere:
            // Cohere uses simple language subtags ("en", "fr", …); the engine
            // maps the primary subtag to a supported language (English default).
            SpeechEnginePreference.normalizeCohereLanguage(language)
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
        case .cohere:
            SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults)
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
