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
