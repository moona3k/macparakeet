import Foundation
import GRDB

/// One billable-style unit of AI or online-speech use, kept locally so the
/// Usage panel can total it. Metadata only: no prompt, transcript, or audio
/// content is stored.
public struct UsageEvent: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A chat-completion request to an AI provider (summary, chat,
        /// translation, cleanup, transform, …).
        case llm
        /// Audio uploaded to the online speech service.
        case cloudSpeech = "cloud_speech"
    }

    public var id: UUID
    public var kind: Kind
    public var provider: String
    public var model: String
    public var isLocal: Bool
    public var promptTokens: Int
    public var completionTokens: Int
    /// True when the provider reported no token counts and they were
    /// estimated from text length.
    public var tokensEstimated: Bool
    public var audioMs: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        provider: String,
        model: String,
        isLocal: Bool = false,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        tokensEstimated: Bool = false,
        audioMs: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.model = model
        self.isLocal = isLocal
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.tokensEstimated = tokensEstimated
        self.audioMs = audioMs
        self.createdAt = createdAt
    }
}

extension UsageEvent: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage_events"
}

/// Totals for one kind, provider, model, and locality over a period.
public struct UsageSummaryRow: Sendable, Equatable, Identifiable {
    public var kind: UsageEvent.Kind
    public var provider: String
    public var model: String
    public var isLocal: Bool
    public var requests: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var tokensEstimated: Bool
    public var audioMs: Int

    public var id: String {
        [kind.rawValue, provider, model, isLocal ? "local" : "remote"]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    public init(
        kind: UsageEvent.Kind,
        provider: String,
        model: String,
        isLocal: Bool,
        requests: Int,
        promptTokens: Int,
        completionTokens: Int,
        tokensEstimated: Bool,
        audioMs: Int
    ) {
        self.kind = kind
        self.provider = provider
        self.model = model
        self.isLocal = isLocal
        self.requests = requests
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.tokensEstimated = tokensEstimated
        self.audioMs = audioMs
    }
}

/// Local speech-engine use, derived from saved transcriptions and dictations.
public struct SpeechEngineUsageRow: Sendable, Equatable, Identifiable {
    public var engine: String
    public var variant: String?
    public var items: Int
    public var audioMs: Int

    public var id: String { "\(engine)|\(variant ?? "")" }

    public init(engine: String, variant: String?, items: Int, audioMs: Int) {
        self.engine = engine
        self.variant = variant
        self.items = items
        self.audioMs = audioMs
    }
}

/// Price used for an estimate. Provider prices change and this app cannot
/// look them up, so every figure derived from these is an estimate.
public struct UsagePrice: Codable, Sendable, Equatable {
    /// US dollars per one million input tokens.
    public var inputPerMillion: Double
    /// US dollars per one million output tokens.
    public var outputPerMillion: Double
    /// US dollars per minute of uploaded audio.
    public var audioPerMinute: Double

    public init(inputPerMillion: Double = 0, outputPerMillion: Double = 0, audioPerMinute: Double = 0) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.audioPerMinute = audioPerMinute
    }

    public var isValid: Bool {
        [inputPerMillion, outputPerMillion, audioPerMinute].allSatisfy { $0.isFinite && $0 >= 0 }
    }

    public func cost(for row: UsageSummaryRow) -> Double {
        Double(row.promptTokens) / 1_000_000 * inputPerMillion
            + Double(row.completionTokens) / 1_000_000 * outputPerMillion
            + Double(row.audioMs) / 60_000 * audioPerMinute
    }
}

/// Built-in starting prices plus the user's own overrides.
public struct UsagePriceBook: Sendable {
    /// Legacy model-only values remain stored until the user confirms which
    /// provider they belong to. They are never silently applied to a row.
    public static let overridesKey = "usagePriceOverrides"
    public static let scopedOverridesKey = "usagePriceOverridesByProviderV1"

    /// List prices in US dollars as known when this was written. They are a
    /// starting point only; the user can correct any of them in the panel.
    /// Matched by model-name prefix, longest prefix first.
    static let builtIn: [(prefix: String, price: UsagePrice)] = [
        ("gpt-4o-mini-transcribe", UsagePrice(audioPerMinute: 0.003)),
        ("gpt-4o-transcribe", UsagePrice(audioPerMinute: 0.006)),
        ("whisper-large-v3-turbo", UsagePrice(audioPerMinute: 0.000667)),
        ("whisper-large-v3", UsagePrice(audioPerMinute: 0.00185)),
        ("whisper-1", UsagePrice(audioPerMinute: 0.006)),
        ("gpt-4o-mini", UsagePrice(inputPerMillion: 0.15, outputPerMillion: 0.60)),
        ("gpt-4o", UsagePrice(inputPerMillion: 2.50, outputPerMillion: 10.00)),
        ("gpt-4.1-nano", UsagePrice(inputPerMillion: 0.10, outputPerMillion: 0.40)),
        ("gpt-4.1-mini", UsagePrice(inputPerMillion: 0.40, outputPerMillion: 1.60)),
        ("gpt-4.1", UsagePrice(inputPerMillion: 2.00, outputPerMillion: 8.00)),
        ("claude-3-5-haiku", UsagePrice(inputPerMillion: 0.80, outputPerMillion: 4.00)),
        ("claude-haiku", UsagePrice(inputPerMillion: 1.00, outputPerMillion: 5.00)),
        ("claude-sonnet", UsagePrice(inputPerMillion: 3.00, outputPerMillion: 15.00)),
        ("claude-3-5-sonnet", UsagePrice(inputPerMillion: 3.00, outputPerMillion: 15.00)),
        ("claude-3-7-sonnet", UsagePrice(inputPerMillion: 3.00, outputPerMillion: 15.00)),
        ("gemini-2.5-flash-lite", UsagePrice(inputPerMillion: 0.10, outputPerMillion: 0.40)),
        ("gemini-2.5-flash", UsagePrice(inputPerMillion: 0.30, outputPerMillion: 2.50)),
        ("gemini-2.5-pro", UsagePrice(inputPerMillion: 1.25, outputPerMillion: 10.00)),
    ]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func overrides() -> [String: UsagePrice] {
        prices(forKey: Self.overridesKey)
    }

    private func prices(forKey key: String) -> [String: UsagePrice] {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: UsagePrice].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Legacy API retained for callers with model-only data. A saved value
    /// still requires explicit provider confirmation before it affects costs.
    public func setOverride(_ price: UsagePrice?, forModel model: String) {
        guard price?.isValid != false else { return }
        var all = overrides()
        all[Self.key(model)] = price
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.overridesKey)
        }
    }

    public func hasOverride(forModel model: String) -> Bool {
        overrides()[Self.key(model)] != nil
    }

    /// A candidate for the editor, not an automatically usable provider price.
    public func legacyOverride(forModel model: String) -> UsagePrice? {
        guard let price = overrides()[Self.key(model)], price.isValid else { return nil }
        return price
    }

    @discardableResult
    public func setOverride(_ price: UsagePrice?, for row: UsageSummaryRow) -> Bool {
        guard !row.isLocal, price?.isValid != false else { return false }
        var all = prices(forKey: Self.scopedOverridesKey)
        all[row.id] = price
        guard let data = try? JSONEncoder().encode(all) else { return false }
        defaults.set(data, forKey: Self.scopedOverridesKey)
        return true
    }

    public func hasOverride(for row: UsageSummaryRow) -> Bool {
        prices(forKey: Self.scopedOverridesKey)[row.id]?.isValid == true
    }

    /// The price to use for a row: free for local models, then the user's
    /// override, then the built-in table. `nil` means unknown.
    public func price(for row: UsageSummaryRow) -> UsagePrice? {
        if row.isLocal { return UsagePrice() }
        if let override = prices(forKey: Self.scopedOverridesKey)[row.id] {
            return override.isValid ? override : nil
        }
        // A legacy correction must not silently become either another
        // provider's price or the built-in price it previously replaced.
        guard !hasOverride(forModel: row.model) else { return nil }
        return Self.builtInPrice(for: row)
    }

    static func builtInPrice(for row: UsageSummaryRow) -> UsagePrice? {
        let name = Self.key(row.model)
        let provider = Self.key(row.provider)
        let vendorMatches: Bool
        switch (row.kind, provider) {
        case (.llm, "openai"): vendorMatches = name.hasPrefix("gpt-")
        case (.llm, "anthropic"): vendorMatches = name.hasPrefix("claude-")
        case (.llm, "gemini"): vendorMatches = name.hasPrefix("gemini-")
        case (.cloudSpeech, "api.openai.com"):
            vendorMatches =
                name == "whisper-1" || name.hasPrefix("gpt-4o-transcribe")
                || name.hasPrefix("gpt-4o-mini-transcribe")
        case (.cloudSpeech, "api.groq.com"): vendorMatches = name.hasPrefix("whisper-large-v3")
        default: vendorMatches = false
        }
        guard vendorMatches else { return nil }
        guard
            let price =
                builtIn
                .filter({ name == $0.prefix || name.hasPrefix($0.prefix + "-") })
                .max(by: { $0.prefix.count < $1.prefix.count })?
                .price
        else { return nil }
        guard row.kind == .cloudSpeech ? price.audioPerMinute > 0 : price.audioPerMinute == 0 else { return nil }
        return price
    }

    private static func key(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
