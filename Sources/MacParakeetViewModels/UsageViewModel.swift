import Foundation
import MacParakeetCore

/// Totals for the Usage panel: AI requests and online-speech uploads from the
/// local usage ledger, local speech-engine use from saved recordings, and
/// cost estimates from the editable price book.
@MainActor
@Observable
public final class UsageViewModel {
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        case all

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            case .all: return "All time"
            }
        }

        func startDate(now: Date) -> Date? {
            switch self {
            case .week: return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .all: return nil
            }
        }
    }

    public var period: Period = .month {
        didSet {
            if period != oldValue {
                Task { await reload() }
            }
        }
    }

    public private(set) var aiRows: [UsageSummaryRow] = []
    public private(set) var onlineSpeechRows: [UsageSummaryRow] = []
    public private(set) var localSpeechRows: [SpeechEngineUsageRow] = []
    public private(set) var loadError: String?
    public private(set) var isLoading = false
    /// Bumped when a price changes so cost cells recompute.
    public private(set) var priceRevision = 0

    private let readerProvider: @MainActor () -> UsageEventRepositoryProtocol?
    private let priceBook: UsagePriceBook
    private let now: @MainActor () -> Date
    private var loadGeneration = UUID()

    public init(
        readerProvider: @escaping @MainActor () -> UsageEventRepositoryProtocol? = { UsageLedger.shared.reader },
        priceBook: UsagePriceBook = UsagePriceBook(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.readerProvider = readerProvider
        self.priceBook = priceBook
        self.now = now
    }

    public func reload() async {
        let generation = UUID()
        loadGeneration = generation
        loadError = nil
        guard let reader = readerProvider() else {
            aiRows = []
            onlineSpeechRows = []
            localSpeechRows = []
            isLoading = false
            return
        }
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        let since = period.startDate(now: now())
        do {
            let (rows, speechRows) = try await Task.detached(priority: .utility) {
                let rows = try reader.summary(since: since)
                let speechRows = try reader.speechEngineUsage(since: since)
                return (rows, speechRows)
            }.value
            guard loadGeneration == generation, !Task.isCancelled else { return }
            aiRows = rows.filter { $0.kind == .llm }
            onlineSpeechRows = rows.filter { $0.kind == .cloudSpeech }
            // Online speech is listed from the ledger (it includes live
            // preview uploads), so drop it from the saved-recordings view.
            localSpeechRows = speechRows.filter { $0.engine != SpeechEnginePreference.cloud.rawValue }
            loadError = nil
        } catch {
            guard loadGeneration == generation, !Task.isCancelled else { return }
            aiRows = []
            onlineSpeechRows = []
            localSpeechRows = []
            loadError = "Could not load usage."
        }
    }

    // MARK: - Prices

    /// Price in effect for a row; `nil` when the model has no known price.
    public func price(for row: UsageSummaryRow) -> UsagePrice? {
        _ = priceRevision
        return priceBook.price(for: row)
    }

    public func hasCustomPrice(for row: UsageSummaryRow) -> Bool {
        _ = priceRevision
        return priceBook.hasOverride(for: row)
    }

    public func legacyPrice(for row: UsageSummaryRow) -> UsagePrice? {
        _ = priceRevision
        guard !hasCustomPrice(for: row) else { return nil }
        return priceBook.legacyOverride(forModel: row.model)
    }

    /// Estimated cost in US dollars; `nil` when the price is unknown.
    public func estimatedCost(for row: UsageSummaryRow) -> Double? {
        guard let cost = price(for: row)?.cost(for: row), cost.isFinite, cost >= 0 else { return nil }
        return cost
    }

    @discardableResult
    public func setPrice(_ price: UsagePrice?, for row: UsageSummaryRow) -> Bool {
        guard priceBook.setOverride(price, for: row) else { return false }
        priceRevision += 1
        return true
    }

    /// Sum of every row with a known price.
    public var estimatedTotal: Double {
        (aiRows + onlineSpeechRows).compactMap { estimatedCost(for: $0) }.reduce(0, +)
    }

    /// Keep arithmetic overflow distinct from models whose prices are unknown.
    public var hasCostOverflow: Bool {
        !estimatedTotal.isFinite
            || (aiRows + onlineSpeechRows).contains { row in
                guard let price = price(for: row) else { return false }
                return !price.cost(for: row).isFinite
            }
    }

    public var estimatedTotalText: String {
        hasCostOverflow ? "Amount too large" : Self.formatCost(estimatedTotal)
    }

    /// Paid models that have usage but no price yet, so the total omits them.
    public var modelsMissingPrice: [String] {
        (aiRows + onlineSpeechRows).filter { price(for: $0) == nil }
            .map { "\($0.provider) · \($0.model)" }
    }

    public var isEmpty: Bool {
        aiRows.isEmpty && onlineSpeechRows.isEmpty && localSpeechRows.isEmpty
    }

    public func clearHistory() async {
        guard let reader = readerProvider() else { await reload(); return }
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        do {
            try await Task.detached(priority: .utility) { try reader.deleteAll() }.value
            await reload()
        } catch {
            guard loadGeneration == generation else { return }
            isLoading = false
            loadError = "Could not clear usage."
        }
    }

    /// Decimal editor input must be explicit: blank, unfinished, negative,
    /// nonfinite, and malformed values are not zero-dollar prices.
    public static func parsePrice(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let last = parts.last, !last.isEmpty,
            parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
            let value = Double(normalized), value.isFinite, value >= 0
        else { return nil }
        return value
    }

    /// Expand Double's round-trippable spelling without rounding or exponent
    /// notation, so every saved price can be edited by the decimal-only parser.
    public static func priceEditorText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        if value == 0 { return "0" }
        let text = String(value)
        let parts = text.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].split(separator: ".")
        let digits = mantissa.joined()
        let decimalPosition = mantissa[0].count + exponent
        if decimalPosition <= 0 {
            return "0." + String(repeating: "0", count: -decimalPosition) + digits
        }
        if decimalPosition >= digits.count {
            return digits + String(repeating: "0", count: decimalPosition - digits.count)
        }
        let point = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return String(digits[..<point]) + "." + String(digits[point...])
    }

    // MARK: - Formatting

    public static func formatCost(_ dollars: Double?) -> String {
        guard let dollars, dollars.isFinite, dollars >= 0 else { return "—" }
        if dollars == 0 { return "$0" }
        if dollars < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", dollars)
    }

    public static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        default: return String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    public static func formatDuration(ms: Int) -> String {
        let totalMinutes = Double(ms) / 60_000
        if totalMinutes < 1 { return "\(max(0, ms / 1000)) sec" }
        if totalMinutes < 60 { return String(format: "%.1f min", totalMinutes) }
        return String(format: "%.1f hr", totalMinutes / 60)
    }
}
