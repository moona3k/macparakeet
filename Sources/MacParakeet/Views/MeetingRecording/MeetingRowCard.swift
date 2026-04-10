import MacParakeetCore
import SwiftUI

/// Row-based card for displaying a meeting recording in a list layout.
/// Shows duration, title, metadata (speakers, word count), transcript snippet,
/// and relative time — optimized for scanning a timeline of meetings.
struct MeetingRowCard<MenuContent: View>: View {
    let transcription: Transcription
    var searchText: String = ""
    var onTap: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var hovered = false
    @State private var moreHovered = false

    private var transcript: String? {
        transcription.cleanTranscript ?? transcription.rawTranscript
    }

    private var wordCount: Int {
        guard let text = transcript, !text.isEmpty else { return 0 }
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private var speakerCount: Int {
        transcription.speakerCount ?? transcription.speakers?.count ?? 0
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                durationColumn
                Divider()
                    .frame(height: 48)
                    .opacity(0.4)
                contentColumn
            }
            .padding(.vertical, 12)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(hovered
                          ? DesignSystem.Colors.rowHoverBackground
                          : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        hovered
                            ? DesignSystem.Colors.border.opacity(0.6)
                            : DesignSystem.Colors.border.opacity(0.25),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        .onHover { hovered = $0 }
        .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        .contextMenu { menuContent() }
    }

    // MARK: - Duration Column

    private var durationColumn: some View {
        VStack(spacing: 2) {
            if let durationMs = transcription.durationMs {
                Text(durationMs.formattedDurationCompact)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            } else {
                Text("--:--")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .frame(width: 64)
    }

    // MARK: - Content Column

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Title + relative time
            HStack(alignment: .firstTextBaseline) {
                highlightedText(transcription.fileName)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DesignSystem.Spacing.sm)

                if hovered {
                    moreButton
                } else {
                    Text(transcription.createdAt.relativeFormatted)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .layoutPriority(1)
                }
            }

            // Row 2: Metadata chips
            HStack(spacing: DesignSystem.Spacing.sm) {
                if speakerCount > 0 {
                    metadataLabel(
                        icon: "person.2",
                        text: speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers"
                    )
                }

                if wordCount > 0 {
                    metadataLabel(
                        icon: "text.word.spacing",
                        text: wordCount.formatted() + " words"
                    )
                }

                statusIndicator
            }

            // Row 3: Transcript snippet
            if let snippet = transcriptSnippet {
                highlightedText(snippet)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 12)
    }

    // MARK: - Metadata Label

    private func metadataLabel(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(DesignSystem.Typography.caption)
        }
        .foregroundStyle(DesignSystem.Colors.textTertiary)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch transcription.status {
        case .processing:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
        case .error:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Error")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(DesignSystem.Colors.errorRed)
        case .completed, .cancelled:
            EmptyView()
        }
    }

    // MARK: - Transcript Snippet

    private var transcriptSnippet: String? {
        guard let text = transcript, !text.isEmpty else { return nil }
        let snippet = String(text.prefix(200))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }
        return String(snippet.prefix(120))
    }

    // MARK: - More Button

    private var moreButton: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(moreHovered ? 1 : 0.8))
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onHover { moreHovered = $0 }
        )
    }

    // MARK: - Search Highlighting

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
            result = result + Text(match)
                .bold()

            remainder = remainder[range.upperBound...]
        }

        if !remainder.isEmpty {
            result = result + Text(String(remainder))
        }

        return result
    }
}

// MARK: - Compact Duration Formatter

fileprivate extension Int {
    /// Formats milliseconds as compact duration: "3s", "47s", "15m", "1h 2m".
    /// Optimized for meeting list scanning — shorter than `formattedDuration`.
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
