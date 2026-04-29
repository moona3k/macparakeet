import Foundation
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Section header above a group of meeting rows. Apple Notes / Mail pattern:
/// small, all-caps, tertiary color, generous top padding.
struct MeetingDateGroupHeader: View {
    let group: TranscriptionDateGroup
    var calendar: Calendar = .autoupdatingCurrent

    private static let monthFormatterCurrentYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "LLLL"
        return f
    }()

    private static let monthFormatterWithYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        switch group {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case .month(let year, let month):
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = 1
            guard let date = calendar.date(from: comps) else { return "" }
            let nowYear = calendar.component(.year, from: Date())
            let formatter = (year == nowYear)
                ? Self.monthFormatterCurrentYear
                : Self.monthFormatterWithYear
            return formatter.string(from: date)
        }
    }
}

/// Hairline divider used between meeting rows inside a date group. 1px, low
/// opacity — readable but never visually heavy.
struct MeetingRowHairline: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.divider.opacity(0.25))
            .frame(height: 0.5)
            .padding(.leading, DesignSystem.Spacing.lg)
    }
}
