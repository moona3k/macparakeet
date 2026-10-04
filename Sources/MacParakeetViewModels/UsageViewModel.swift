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
        didSet { if period != oldValue { reload() } }
    }

    public private(set) var aiRows: [UsageSummaryRow] = []
    public private(set) var onlineSpeechRows: [UsageSummaryRow] = []
    public private(set) var localSpeechRows: [SpeechEngineUsageRow] = []
    public private(set) var loadError: String?
    /// Bumped when a price changes so cost cells recompute.
    public private(set) var priceRevision = 0

    private let readerProvider: @MainActor () -> UsageEventRepositoryProtocol?
    private let priceBook: UsagePriceBook
    private let now: @MainActor () -> Date

    public init(
        readerProvider: @escaping @MainActor () -> UsageEventRepositoryProtocol? = { UsageLedger.shared.reader },
        priceBook: UsagePriceBook = UsagePriceBook(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.readerProvider = readerProvider
        self.priceBook = priceBook
        self.now = now
    }

    public func reload() {
        guard let reader = readerProvider() else {
            aiRows = []
            onlineSpeechRows = []
            localSpeechRows = []
            return
        }
        do {
            let since = period.startDate(now: now())
            let rows = try reader.summary(since: since)
            aiRows = rows.filter { $0.kind == .llm }
            onlineSpeechRows = rows.filter { $0.kind == .cloudSpeech }
            // Online speech is listed from the ledger (it includes live
            // preview uploads), so drop it from the saved-recordings view.
            localSpeechRows = try reader.speechEngineUsage(since: since)
                .filter { $0.engine != SpeechEnginePreference.cloud.rawValue }
            loadError = nil
        } catch {
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
        return priceBook.hasOverride(forModel: row.model)
    }

    /// Estimated cost in US dollars; `nil` when the price is unknown.
    public func estimatedCost(for row: UsageSummaryRow) -> Double? {
        price(for: row)?.cost(for: row)
    }

    public func setPrice(_ price: UsagePrice?, for row: UsageSummaryRow) {
        priceBook.setOverride(price, forModel: row.model)
        priceRevision += 1
    }

    /// Sum of every row with a known price.
    public var estimatedTotal: Double {
        (aiRows + onlineSpeechRows).compactMap(estimatedCost(for:)).reduce(0, +)
    }

    /// Paid models that have usage but no price yet, so the total omits them.
    public var modelsMissingPrice: [String] {
        (aiRows + onlineSpeechRows).filter { price(for: $0) == nil }.map(\.model)
    }

    public var isEmpty: Bool {
        aiRows.isEmpty && onlineSpeechRows.isEmpty && localSpeechRows.isEmpty
    }

    public func clearHistory() {
        try? readerProvider()?.deleteAll()
        reload()
    }

    // MARK: - Formatting

    public static func formatCost(_ dollars: Double?) -> String {
        guard let dollars else { return "—" }
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
