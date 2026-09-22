import MacParakeetViewModels
import SwiftUI

struct MeetingSourceHealthChips: View {
    let chips: [MeetingSourceHealthChip]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    MeetingSourceHealthChipView(chip: chip, showsText: true)
                }
            }

            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    MeetingSourceHealthChipView(chip: chip, showsText: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeetingSourceHealthGlyph: View {
    let chip: MeetingSourceHealthChip

    var body: some View {
        Image(systemName: chip.symbolName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(healthForegroundColor(for: chip.severity))
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(healthBackgroundColor(for: chip.severity))
            )
            .overlay(
                Circle()
                    .strokeBorder(healthForegroundColor(for: chip.severity).opacity(0.35), lineWidth: 0.7)
            )
            .help(chip.label)
            .accessibilityLabel(chip.label)
    }
}

struct MeetingSourceHealthInlineBadge: View {
    let chip: MeetingSourceHealthChip

    var body: some View {
        MeetingSourceHealthChipView(chip: chip, showsText: true)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MeetingSourceHealthChipView: View {
    let chip: MeetingSourceHealthChip
    let showsText: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.symbolName)
                .font(.system(size: 10, weight: .semibold))

            if showsText {
                Text(chip.label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .foregroundStyle(healthForegroundColor(for: chip.severity))
        .padding(.horizontal, showsText ? 8 : 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(healthBackgroundColor(for: chip.severity))
        )
        .overlay(
            Capsule()
                .strokeBorder(healthForegroundColor(for: chip.severity).opacity(0.25), lineWidth: 0.6)
        )
        .help(chip.label)
        .accessibilityLabel(chip.label)
    }
}

private func healthForegroundColor(for severity: MeetingSourceHealthSeverity) -> Color {
    switch severity {
    case .neutral:
        return DesignSystem.Colors.textTertiary
    case .good:
        return DesignSystem.Colors.successGreen
    case .warning:
        return DesignSystem.Colors.warningAmber
    case .critical:
        return DesignSystem.Colors.errorRed
    }
}

private func healthBackgroundColor(for severity: MeetingSourceHealthSeverity) -> Color {
    healthForegroundColor(for: severity).opacity(severity == .neutral ? 0.10 : 0.13)
}
