import MacParakeetCore
import SwiftUI

/// Single row in the Meetings list. Apple-minimal layout: title + snippet on
/// the left, time-of-day + duration trailing right. Conditional decorators
/// (recovered dot, speaker count) appear only when they carry signal.
struct MeetingRowCard<MenuContent: View>: View {
    let transcription: Transcription
    var searchText: String = ""
    var onTap: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                contentColumn
                trailingColumn
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, 12)
            .frame(minHeight: 64, alignment: .top)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .help(hoverTooltip)
        .onHover { hovered = $0 }
        .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        .contextMenu { menuContent() }
    }

    // MARK: - Backgrounds

    @ViewBuilder
    private var rowBackground: some View {
        if hovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignSystem.Colors.rowHoverBackground)
        } else {
            Color.clear
        }
    }

    // MARK: - Content

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            snippetRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if transcription.recoveredFromCrash {
                Circle()
                    .fill(DesignSystem.Colors.warningAmber)
                    .frame(width: 6, height: 6)
                    .help("Recovered from a crash")
                    .accessibilityLabel("Recovered from a crash")
            }

            highlightedTitle
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)

            speakerInline
                .layoutPriority(0)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var speakerInline: some View {
        if let count = displayedSpeakerCount {
            Text("· \(count) speakers")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var snippetRow: some View {
        if let snippet = displayedSnippet {
            highlightedText(snippet)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if transcription.status == .processing {
            Text("Transcribing…")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .lineLimit(1)
        } else if transcription.status == .error {
            Text("Transcription failed")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.errorRed.opacity(0.85))
                .lineLimit(1)
        }
    }

    // MARK: - Trailing

    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let durationMs = transcription.durationMs {
                Text(durationMs.formattedDurationCompact)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(timeOfDayString)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: - Derived display values

    private var displayedTitle: String {
        if let derived = transcription.derivedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !derived.isEmpty {
            return derived
        }
        if transcription.status == .processing { return "Transcribing…" }
        return transcription.fileName
    }

    private var displayedSnippet: String? {
        if let derived = transcription.derivedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !derived.isEmpty {
            return derived
        }
        return legacySnippet
    }

    private var legacySnippet: String? {
        guard let text = transcription.cleanTranscript ?? transcription.rawTranscript, !text.isEmpty else {
            return nil
        }
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(140))
    }

    private var displayedSpeakerCount: Int? {
        let count = transcription.speakerCount ?? transcription.speakers?.count ?? 0
        return count >= 2 ? count : nil
    }

    private var timeOfDayString: String {
        transcription.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private var hoverTooltip: String {
        let absolute = transcription.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let engineLabel = engineLabel {
            return "\(absolute) · \(engineLabel)"
        }
        return absolute
    }

    private var engineLabel: String? {
        guard let raw = transcription.engine?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "parakeet": return "Parakeet"
        case "whisper": return "Whisper"
        default: return raw.capitalized
        }
    }

    // MARK: - Search highlighting

    private var highlightedTitle: Text {
        highlightedText(displayedTitle)
    }

    @MainActor
    private func highlightedText(_ text: String) -> Text {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(text) }

        var result = Text("")
        var remainder = text[...]
        while let range = remainder.range(of: query, options: .caseInsensitive) {
            let prefix = String(remainder[..<range.lowerBound])
            if !prefix.isEmpty {
                result = result + Text(prefix)
            }
            let match = String(remainder[range])
            result = result + Text(match).bold()
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty {
            result = result + Text(String(remainder))
        }
        return result
    }
}

// MARK: - Compact duration

fileprivate extension Int {
    /// Formats milliseconds as compact duration: "3s", "47s", "15m", "1h 2m".
    var formattedDurationCompact: String {
        let totalSeconds = self / 1000
        guard totalSeconds > 0 else { return "0s" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }
}
