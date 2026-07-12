import MacParakeetCore
import SwiftUI

/// Single row in the Meetings list. Apple-minimal layout: title + snippet on
/// the left, time-of-day + duration trailing right. Conditional decorators
/// (recovered dot, speaker count) appear only when they carry signal.
struct MeetingRowCard<MenuContent: View>: View {
    let transcription: Transcription
    let audioState: MeetingAudioFile.State
    var searchText: String = ""
    var isSelected: Bool = false
    var showsSelectionControls: Bool = false
    var isRetrying: Bool = false
    var onTap: () -> Void
    var onRetry: (() -> Void)? = nil
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var hovered = false
    @State private var showsErrorDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                rowActivationButton

                if showsRetryButton {
                    retryButton
                        .padding(.top, 4)
                }
            }

            errorDetailDisclosure
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, 12)
        .frame(minHeight: 64, alignment: .top)
        .background(rowBackground)
        .help(hoverTooltip)
        .onHover { hovered = $0 }
        .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        .contextMenu { menuContent() }
    }

    // MARK: - Backgrounds

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignSystem.Colors.accentLight)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DesignSystem.Colors.accent.opacity(0.38), lineWidth: 0.8)
                }
        } else if hovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignSystem.Colors.rowHoverBackground)
        } else {
            Color.clear
        }
    }

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DesignSystem.Colors.accent : Color.clear)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary.opacity(0.7),
                            lineWidth: 1.2
                        )
                }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.onAccent)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Content

    private var rowActivationButton: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                if showsSelectionControls {
                    selectionBadge
                        .padding(.top, 1)
                }
                contentColumn
                metadataColumn
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(showsSelectionControls ? (isSelected ? "Selected" : "Not selected") : "")
        .accessibilityHint(showsSelectionControls ? "Toggles selection" : hoverTooltip)
    }

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
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .layoutPriority(1)

            speakerInline
                .layoutPriority(0)

            audioInline
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
    private var audioInline: some View {
        if showsAudioInline {
            MeetingAudioStateChip(state: audioState)
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
            HStack(spacing: 5) {
                ParakeetSpinner(.inline)
                    .scaleEffect(0.85)
                    .frame(width: 12, height: 12)
                Text(statusLine("Transcribing"))
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }
        } else if transcription.status == .error {
            failedHeadlineRow
        } else if transcription.status == .cancelled {
            // Keep-Audio outcome of the stop-transcription flow (issue #487):
            // the audio is intact and retranscribable from the detail view.
            Text(statusLine("Transcription stopped"))
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var failedHeadlineRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(failedHeadline)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var errorDetailDisclosure: some View {
        if transcription.status == .error, let detail = errorDetail {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                if showsSelectionControls {
                    Color.clear
                        .frame(width: 18, height: 1)
                }
                DisclosureGroup(isExpanded: $showsErrorDetail) {
                    Text(detail)
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.top, 1)
                } label: {
                    Text("Details")
                        .font(DesignSystem.Typography.micro.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .disclosureGroupStyle(.automatic)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Trailing

    private var metadataColumn: some View {
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

    private var retryButton: some View {
        Button {
            onRetry?()
        } label: {
            HStack(spacing: 5) {
                if isRetrying {
                    ParakeetSpinner(.inline)
                        .scaleEffect(0.85)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isRetrying ? "Retrying" : "Retry")
                    .font(DesignSystem.Typography.micro.weight(.semibold))
            }
            .foregroundStyle(retryButtonForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.72))
                    .overlay(
                        Capsule()
                            .strokeBorder(DesignSystem.Colors.border.opacity(0.8), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isRetrying || onRetry == nil || audioState != .saved)
        .help(retryHelp)
        .accessibilityLabel(isRetrying ? "Retrying transcription" : "Retry transcription")
    }

    // MARK: - Derived display values

    private var displayedTitle: String {
        let title = transcription.effectiveDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if transcription.status == .processing { return "Transcribing…" }
        return transcription.fileName
    }

    private var displayedSnippet: String? {
        if let derived = transcription.derivedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !derived.isEmpty
        {
            return derived
        }
        return legacySnippet
    }

    private var legacySnippet: String? {
        guard let text = transcription.cleanTranscript ?? transcription.rawTranscript, !text.isEmpty else {
            return nil
        }
        let cleaned =
            text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(140))
    }

    private var displayedSpeakerCount: Int? {
        let count = transcription.speakerCount ?? transcription.speakers?.count ?? 0
        return count >= 2 ? count : nil
    }

    private var errorDetail: String? {
        guard let detail = transcription.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty
        else {
            return nil
        }
        return detail
    }

    private var failedHeadline: String {
        switch audioState {
        case .saved:
            return "Transcription failed — audio is saved"
        case .removed:
            return "Transcription failed — audio removed"
        case .missing:
            return "Transcription failed — audio missing"
        case .notMeeting:
            return "Transcription failed"
        }
    }

    private var showsRetryButton: Bool {
        transcription.sourceType == .meeting
            && (transcription.status == .error || transcription.status == .cancelled)
    }

    private var retryButtonForeground: Color {
        if isRetrying || onRetry == nil || audioState != .saved {
            return DesignSystem.Colors.textTertiary
        }
        return DesignSystem.Colors.accent
    }

    private var retryHelp: String {
        if isRetrying {
            return "Retry is already in progress"
        }
        guard onRetry != nil else {
            return "Retry is not available"
        }
        return audioState == .saved
            ? "Retry transcription from saved meeting audio"
            : "Saved meeting audio is required before retrying transcription"
    }

    private var showsAudioInline: Bool {
        guard audioState != .notMeeting else { return false }
        return transcription.status != .error && transcription.status != .cancelled
    }

    private func statusLine(_ prefix: String) -> String {
        guard let suffix = audioStateSuffix else { return prefix }
        return "\(prefix) · \(suffix)"
    }

    private var audioStateSuffix: String? {
        switch audioState {
        case .saved:
            return "audio saved"
        case .removed:
            return "audio removed"
        case .missing:
            return "audio missing"
        case .notMeeting:
            return nil
        }
    }

    private var timeOfDayString: String {
        transcription.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private var hoverTooltip: String {
        let absolute = transcription.createdAt.formatted(date: .abbreviated, time: .shortened)
        var parts = [absolute]
        if let engineLabel {
            parts.append(engineLabel)
        }
        if let audioStateSuffix {
            parts.append(audioStateSuffix)
        }
        return parts.joined(separator: " · ")
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
