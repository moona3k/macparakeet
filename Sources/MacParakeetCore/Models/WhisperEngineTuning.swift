import Foundation

/// Tunable parameters for the WhisperKit STT engine.
///
/// These map to WhisperKit `DecodingOptions` fields that affect
/// transcription accuracy vs. speed trade-offs. All values have sensible
/// defaults so the engine works out-of-the-box.
public struct WhisperEngineTuning: Codable, Equatable, Sendable {
    // MARK: - Search / Sampling

    /// Temperature for sampling. 0.0 = deterministic (best for transcription).
    /// Higher values increase diversity but can introduce hallucinations.
    public var temperature: Double

    /// Top-k sampling cutoff. Lower = more conservative.
    public var topK: Int

    /// Maximum number of tokens to sample per chunk.
    public var sampleLength: Int

    /// Temperature increment when falling back after a low-confidence result.
    public var temperatureIncrementOnFallback: Double

    /// How many times to retry with increased temperature before giving up.
    public var temperatureFallbackCount: Int

    // MARK: - Thresholds / Filtering

    /// Log-probability threshold below which segments are considered garbage.
    /// -1.0 = permissive. Raising to -0.5 filters more aggressively.
    public var logProbThreshold: Double

    /// No-speech threshold. Segments below this are treated as silence.
    public var noSpeechThreshold: Double

    /// Compression ratio threshold. Used to detect repetitive/garbled output.
    public var compressionRatioThreshold: Double

    // MARK: - Init

    public init(
        temperature: Double = 0.0,
        topK: Int = 5,
        sampleLength: Int = 224,
        temperatureIncrementOnFallback: Double = 0.2,
        temperatureFallbackCount: Int = 5,
        logProbThreshold: Double = -1.0,
        noSpeechThreshold: Double = 0.6,
        compressionRatioThreshold: Double = 2.4
    ) {
        self.temperature = temperature
        self.topK = max(1, topK)
        self.sampleLength = max(1, sampleLength)
        self.temperatureIncrementOnFallback = temperatureIncrementOnFallback
        self.temperatureFallbackCount = max(0, temperatureFallbackCount)
        self.logProbThreshold = logProbThreshold
        self.noSpeechThreshold = noSpeechThreshold
        self.compressionRatioThreshold = compressionRatioThreshold
    }
}

// MARK: - Presets

/// Named presets for the common Whisper tuning use-cases. Each one
/// resolves to a fixed `WhisperEngineTuning` value the user can pick
/// without having to understand the individual knobs. Picking
/// `.custom` lets the user surface the raw sliders and edit values
/// freely; any edit to a slider while a non-custom preset is selected
/// automatically flips the selection to `.custom`.
public enum WhisperTuningPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// WhisperKit's stock defaults. Safe for any audio quality.
    case `default`
    /// Tighter filtering for podcasts, voiceovers, recorded videos.
    /// Catches more hallucinations (random foreign-language phrases
    /// at the tail of audio, repeated phrases) at the cost of being
    /// slightly more likely to drop quiet speech.
    case cleanStudio
    /// Loosened filtering for noisy or quiet recordings — phone
    /// calls, field recordings, ambient classroom audio. Captures
    /// more borderline speech but lets through more questionable
    /// text too.
    case noisy
    /// Balanced for multi-speaker meetings and conversations with
    /// varied volume. Sits between Default and Clean Studio.
    case conversation
    /// User-tuned. The sliders are surfaced so values can be set
    /// directly. Picked automatically when the user edits any
    /// slider from a different preset.
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default:      return "Default"
        case .cleanStudio:  return "Clean Studio"
        case .noisy:        return "Noisy / Quiet Audio"
        case .conversation: return "Conversation / Meeting"
        case .custom:       return "Custom"
        }
    }

    /// One-line description shown under the preset name in the picker.
    public var summary: String {
        switch self {
        case .default:
            return "WhisperKit defaults. Works for most audio."
        case .cleanStudio:
            return "Tightest filtering. Best for podcasts, voiceovers, and clean studio recordings."
        case .noisy:
            return "Most permissive. Catches more speech in noisy or quiet recordings."
        case .conversation:
            return "Balanced for meetings and conversations with varied volume."
        case .custom:
            return "Adjust each setting manually."
        }
    }

    /// Resolve the preset to concrete tuning values. `.custom`
    /// returns the WhisperKit defaults; the actual user values are
    /// kept in the stored `WhisperEngineTuning` and edited directly.
    public var tuning: WhisperEngineTuning {
        switch self {
        case .default:
            return WhisperEngineTuning()
        case .cleanStudio:
            // Stricter log-prob and tighter compression-ratio kill
            // end-of-audio hallucinations and repetition glitches
            // like "I hope I hope" without over-aggressive silence
            // detection that would drop legitimate quiet speech.
            return WhisperEngineTuning(
                temperature: 0.0,
                topK: 5,
                sampleLength: 224,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.7,
                compressionRatioThreshold: 2.0
            )
        case .noisy:
            // Permissive so Whisper keeps trying on low-signal input
            // instead of treating it as silence and skipping it.
            return WhisperEngineTuning(
                temperature: 0.0,
                topK: 5,
                sampleLength: 224,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                logProbThreshold: -1.5,
                noSpeechThreshold: 0.5,
                compressionRatioThreshold: 2.8
            )
        case .conversation:
            // Between default and clean-studio. Reasonable filtering
            // without losing soft-spoken participants.
            return WhisperEngineTuning(
                temperature: 0.0,
                topK: 5,
                sampleLength: 224,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                logProbThreshold: -0.8,
                noSpeechThreshold: 0.6,
                compressionRatioThreshold: 2.2
            )
        case .custom:
            return WhisperEngineTuning()
        }
    }

    /// Reverse-lookup: which preset (if any) does this tuning match?
    /// Returns `.custom` when the values don't match any named preset
    /// exactly. Used by the UI to surface the right picker selection
    /// when settings load.
    public static func matching(_ tuning: WhisperEngineTuning) -> WhisperTuningPreset {
        for preset in WhisperTuningPreset.allCases where preset != .custom {
            if preset.tuning == tuning { return preset }
        }
        return .custom
    }
}

// MARK: - UserDefaults Persistence

extension WhisperEngineTuning {
    public static let defaultsKey = "whisperEngineTuning"

    public static let `default` = WhisperEngineTuning()

    public static func current(defaults: UserDefaults = .standard) -> WhisperEngineTuning {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let tuning = try? JSONDecoder().decode(WhisperEngineTuning.self, from: data)
        else {
            return .default
        }
        return tuning
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: WhisperEngineTuning.defaultsKey)
        }
    }

    public static func reset(to defaults: UserDefaults = .standard) {
        Self.default.save(to: defaults)
    }
}
