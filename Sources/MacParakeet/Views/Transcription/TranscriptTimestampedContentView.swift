import SwiftUI
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

    var body: some View {
        if hasSpeakers {
            ForEach(turns, id: \.segments.first?.startMs) { turn in
                TranscriptTurnCardView(
                    speakerLabel: speakerLabelForID(turn.speakerId),
                    speakerColor: speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary,
                    segments: turn.segments,
                    timestampLabel: timestampLabel,
                    isTimestampSeekable: isTimestampSeekable,
                    onTimestampTap: onTimestampTap
                )
                .id(turn.segments.first?.startMs ?? 0)
            }
        } else {
            ForEach(Array(segments.enumerated()), id: \.element.startMs) { index, segment in
                let isActive = isSegmentActive(index)
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    TranscriptTimestampChip(
                        startMs: segment.startMs,
                        label: timestampLabel(segment.startMs),
                        isSeekable: isTimestampSeekable,
                        onTap: onTimestampTap
                    )

                    Text(segment.text)
                        .font(DesignSystem.Typography.bodyLarge)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(isActive
                              ? DesignSystem.Colors.accent.opacity(0.12)
                              : DesignSystem.Colors.surfaceElevated.opacity(0.45))
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
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        TranscriptTimestampChip(
                            startMs: segment.startMs,
                            label: timestampLabel(segment.startMs),
                            isSeekable: isTimestampSeekable,
                            onTap: onTimestampTap
                        )

                        Text(segment.text)
                            .font(DesignSystem.Typography.bodyLarge)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
