import SwiftUI
import Foundation
import MacParakeetCore

struct TranscriptTimestampedContentView: View {
    let hasSpeakers: Bool
    let turns: [SpeakerTurn]
    let segments: [TranscriptSegment]
    let speakerColorMap: [String: Color]
    let speakerLabelForID: (String) -> String
    let isSegmentActive: (Int) -> Bool
    let timestampLabel: (Int) -> String
    let isTimestampSeekable: Bool
    let onTimestampTap: (Int) -> Void
    /// User-adjustable reading size for the transcript body (U4). Defaults to the
    /// design-system `bodyLarge` so existing call sites are unaffected.
    var bodyFont: Font = DesignSystem.Typography.bodyLarge
    /// In-transcript find highlights (U2), looked up by a row's `startMs`.
    /// Returns the match ranges to wash inside that row; empty when find is idle.
    var highlightRanges: (Int) -> [NSRange] = { _ in [] }
    /// The single emphasized ("current") match, identified by its row `startMs`.
    var currentHighlight: (id: Int, range: NSRange)?

    var body: some View {
        if hasSpeakers {
            ForEach(turns, id: \.segments.first?.startMs) { turn in
                TranscriptTurnCardView(
                    speakerLabel: speakerLabelForID(turn.speakerId),
                    speakerColor: speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary,
                    segments: turn.segments,
                    timestampLabel: timestampLabel,
                    isTimestampSeekable: isTimestampSeekable,
                    bodyFont: bodyFont,
                    highlightRanges: highlightRanges,
                    currentHighlight: currentHighlight,
                    onTimestampTap: onTimestampTap
                )
                // Preserve the existing first-segment/card scroll target while
                // later rows expose their own anchors for mid-turn find results.
                .id(turn.segments.first?.startMs ?? 0)
            }
        } else {
            ForEach(Array(segments.enumerated()), id: \.element.startMs) { index, segment in
                TranscriptSegmentRow(
                    startMs: segment.startMs,
                    text: segment.text,
                    timestampText: timestampLabel(segment.startMs),
                    isActive: isSegmentActive(index),
                    isSeekable: isTimestampSeekable,
                    bodyFont: bodyFont,
                    showRowBackground: true,
                    highlightRanges: highlightRanges(segment.startMs),
                    currentRange: currentHighlight?.id == segment.startMs ? currentHighlight?.range : nil,
                    onPlayFromHere: { onTimestampTap(segment.startMs) }
                )
                .id(segment.startMs)
            }
        }
    }
}

private struct TranscriptTurnCardView: View {
    let speakerLabel: String
    let speakerColor: Color
    let segments: [TranscriptSegment]
    let timestampLabel: (Int) -> String
    let isTimestampSeekable: Bool
    var bodyFont: Font
    var highlightRanges: (Int) -> [NSRange] = { _ in [] }
    var currentHighlight: (id: Int, range: NSRange)?
    let onTimestampTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)

                Text(speakerLabel)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(speakerColor)

                if let firstStart = segments.first?.startMs {
                    transcriptMetadataChip(icon: "clock", text: timestampLabel(firstStart))
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    turnSegmentRow(index: index, segment: segment)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(speakerColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(speakerColor.opacity(0.18), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func turnSegmentRow(index: Int, segment: TranscriptSegment) -> some View {
        let row = TranscriptSegmentRow(
            startMs: segment.startMs,
            text: segment.text,
            timestampText: timestampLabel(segment.startMs),
            // Per-segment active highlight is a flat-mode affordance
            // today; turn cards keep their own surface unchanged.
            isActive: false,
            isSeekable: isTimestampSeekable,
            bodyFont: bodyFont,
            showRowBackground: false,
            highlightRanges: highlightRanges(segment.startMs),
            currentRange: currentHighlight?.id == segment.startMs ? currentHighlight?.range : nil,
            onPlayFromHere: { onTimestampTap(segment.startMs) }
        )
        if index == 0 {
            row
        } else {
            // Non-first rows get their own anchors so find navigation can land
            // inside a speaker turn without shifting the first-line/card target.
            row.id(segment.startMs)
        }
    }

    @ViewBuilder
    private func transcriptMetadataChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(DesignSystem.Typography.timestamp)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }
}

/// One transcript line: a seekable timestamp chip, the segment text, and
/// hover-revealed actions (play-from-here, copy, copy-with-timestamp). Shared by
/// both the flat segment list and the speaker-turn cards so the affordances stay
/// identical across modes.
private struct TranscriptSegmentRow: View {
    let startMs: Int
    let text: String
    let timestampText: String
    let isActive: Bool
    let isSeekable: Bool
    var bodyFont: Font
    /// Flat list rows draw their own active/inactive surface; turn-card rows sit
    /// inside the card and pass `false`.
    var showRowBackground: Bool
    /// In-transcript find matches inside this row's text (U2). Empty on the
    /// fast path keeps the row a plain `Text`.
    var highlightRanges: [NSRange] = []
    /// The emphasized match within this row, if the find cursor is on it.
    var currentRange: NSRange?
    let onPlayFromHere: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            TranscriptTimestampChip(
                startMs: startMs,
                label: timestampText,
                isSeekable: isSeekable,
                onTap: { _ in onPlayFromHere() }
            )

            bodyTextCore
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(showRowBackground ? DesignSystem.Spacing.md : 0)
        .background {
            if showRowBackground {
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isActive
                          ? DesignSystem.Colors.accent.opacity(0.12)
                          : DesignSystem.Colors.surfaceElevated.opacity(0.45))
            }
        }
        .overlay(alignment: .topTrailing) {
            hoverActions
                .padding(showRowBackground ? DesignSystem.Spacing.sm : 0)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovering = hovering
            }
        }
    }

    /// Plain `Text` on the idle fast path; an attributed, highlighted `Text`
    /// only when this row carries find matches.
    private var bodyTextCore: Text {
        guard !highlightRanges.isEmpty else {
            return Text(text).font(bodyFont)
        }
        return Text(TranscriptFindHighlight.attributed(
            text,
            ranges: highlightRanges,
            current: currentRange,
            baseFont: bodyFont
        ))
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            // Play-from-here mirrors the timestamp chip's ready-state guard: when
            // playback isn't seekable the chip is inert, so don't expose a live
            // play action that would bypass it. Copy actions stay available.
            if isSeekable {
                rowActionButton(icon: "play.fill", help: "Play from here", action: onPlayFromHere)
            }
            rowActionButton(icon: "doc.on.doc", help: "Copy text") {
                TranscriptResultActions.copyText(text)
            }
            rowActionButton(icon: "clock", help: "Copy with timestamp") {
                TranscriptResultActions.copyText(
                    TranscriptSegmentClipboard.text(timestampLabel: timestampText, body: text)
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(DesignSystem.Colors.surface)
        )
        .overlay(
            Capsule().strokeBorder(DesignSystem.Colors.textTertiary.opacity(0.20), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private func rowActionButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TranscriptTimestampChip: View {
    let startMs: Int
    let label: String
    let isSeekable: Bool
    let onTap: (Int) -> Void
    @State private var isHovering = false
    @State private var didPushCursor = false

    var body: some View {
        Text(label)
            .font(DesignSystem.Typography.timestamp)
            .foregroundStyle(isSeekable ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surface)
            )
            .frame(width: 72, alignment: .leading)
            .contentShape(Capsule())
            .onTapGesture {
                guard isSeekable else { return }
                onTap(startMs)
            }
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
            }
            .onChange(of: isSeekable) { _, _ in
                updateCursor()
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
    }

    private func updateCursor() {
        let shouldShowPointer = isHovering && isSeekable
        if shouldShowPointer, !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
            return
        }
        if !shouldShowPointer, didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}
