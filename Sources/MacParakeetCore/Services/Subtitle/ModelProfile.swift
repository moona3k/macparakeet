import Foundation

// MARK: - ModelProfile

/// Describes the behavioural characteristics of an LLM as they apply to
/// subtitle refinement. Structural fields (parameterCount, contextWindow)
/// come from Ollama /api/show; behavioural fields (promptHint, leniency,
/// quirks) come from the remote profile catalog or its bundled fallback.
public struct ModelProfile: Sendable, Equatable {

    // MARK: - Types

    public enum SizeClass: String, Sendable, Equatable, Codable {
        case small    // <10B parameters
        case medium   // 10–35B
        case large    // >35B
        case unknown

        public init(parameterCount: Int?) {
            guard let p = parameterCount else { self = .unknown; return }
            if p < 10_000_000_000 { self = .small }
            else if p < 35_000_000_000 { self = .medium }
            else { self = .large }
        }
    }

    /// Controls which prompt template variant the layout planner and reviewer use.
    public enum PromptHint: String, Codable, Sendable, Equatable {
        /// Standard prompts — good for instruction-tuned models.
        case standard
        /// Adds a concrete JSON example to the system prompt — helps models
        /// that drift from the required schema (Gemma 4, some small Qwen models).
        case explicitJSON
        /// Shorter system prompt — better for <7B models whose effective
        /// context is smaller than their advertised window suggests.
        case minimal
    }

    /// How aggressively the LayoutPlanParser auto-repairs index gaps in the
    /// LLM's JSON output before falling back to the deterministic builder.
    public enum ParserLeniency: String, Codable, Sendable, Equatable {
        case strict    // maxGapToRepair = 1
        case normal    // maxGapToRepair = 3  (current default for all models)
        case lenient   // maxGapToRepair = 5  (for models that drop indices often)
    }

    public enum ModelQuirk: String, Codable, Sendable, Hashable {
        /// Model appends `// comment` annotations after JSON values.
        case addsLineComments
        /// Model occasionally skips word indices in the cue ranges.
        case skipsWordIndices
    }

    // MARK: - Fields

    public let displayName: String
    public let architectureFamily: String?
    public let parameterCount: Int?
    public let contextWindow: Int?
    public let sizeClass: SizeClass
    public let suggestedBatchSize: Int
    public let promptHint: PromptHint
    public let parserLeniency: ParserLeniency
    public let quirks: Set<ModelQuirk>

    // MARK: - Init

    public init(
        displayName: String,
        architectureFamily: String?,
        parameterCount: Int?,
        contextWindow: Int?,
        sizeClass: SizeClass,
        suggestedBatchSize: Int,
        promptHint: PromptHint,
        parserLeniency: ParserLeniency,
        quirks: Set<ModelQuirk>
    ) {
        self.displayName = displayName
        self.architectureFamily = architectureFamily
        self.parameterCount = parameterCount
        self.contextWindow = contextWindow
        self.sizeClass = sizeClass
        self.suggestedBatchSize = min(10, max(1, suggestedBatchSize))
        self.promptHint = promptHint
        self.parserLeniency = parserLeniency
        self.quirks = quirks
    }

    // MARK: - Helpers

    /// Formatted string for UI display, e.g. "Gemma (27B)".
    public var badge: String {
        if let size = parameterSizeString { return "\(displayName) (\(size))" }
        return displayName
    }

    public var parameterSizeString: String? {
        guard let p = parameterCount else { return nil }
        let b = Double(p) / 1_000_000_000.0
        if b >= 1 { return String(format: "%.0fB", b) }
        let m = Double(p) / 1_000_000.0
        return String(format: "%.0fM", m)
    }

    // MARK: - Fallback

    public static let generic = ModelProfile(
        displayName: "Unknown model",
        architectureFamily: nil,
        parameterCount: nil,
        contextWindow: nil,
        sizeClass: .unknown,
        suggestedBatchSize: 5,
        promptHint: .standard,
        parserLeniency: .normal,
        quirks: []
    )
}

// MARK: - Remote catalog types (shared by service + disk cache)

public struct RemoteProfileCatalog: Codable, Sendable, Equatable {
    public let version: Int
    public let updated: String?
    public let profiles: [RemoteProfile]

    public struct RemoteProfile: Codable, Sendable, Equatable {
        public let patterns: [String]
        public let displayName: String
        public let architectureHint: String?
        public let promptHint: ModelProfile.PromptHint
        public let parserLeniency: ModelProfile.ParserLeniency
        public let quirks: [ModelProfile.ModelQuirk]
        /// Batch sizes keyed by SizeClass.rawValue: "small", "medium", "large", "unknown"
        public let batchSizes: [String: Int]
    }
}

// MARK: - Ollama model metadata

/// Parsed from Ollama's POST /api/show response.
struct OllamaModelMetadata: Sendable {
    let architecture: String?
    let parameterCount: Int?
    let contextWindow: Int?
    let quantization: String?

    init?(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let details = json["details"] as? [String: Any]
        let modelInfo = json["model_info"] as? [String: Any]

        // Prefer the canonical key from model_info — details.family
        // happens to match for the common architectures (gemma3, llama,
        // qwen2) but is not guaranteed for custom Modelfiles.
        let archFromModelInfo = modelInfo?["general.architecture"] as? String
        let archFromDetails = details?["family"] as? String
        architecture = (archFromModelInfo ?? archFromDetails)?.lowercased()
        quantization = details?["quantization_level"] as? String

        if let raw = modelInfo?["general.parameter_count"] {
            if let i = raw as? Int { parameterCount = i }
            else if let d = raw as? Double { parameterCount = Int(d) }
            else { parameterCount = nil }
        } else {
            parameterCount = nil
        }

        // Context window key varies by architecture: "{arch}.context_length"
        if let arch = architecture, let info = modelInfo {
            if let ctx = info["\(arch).context_length"] as? Int { contextWindow = ctx }
            else if let ctx = info["\(arch).context_length"] as? Double { contextWindow = Int(ctx) }
            else { contextWindow = nil }
        } else {
            contextWindow = nil
        }
    }
}
