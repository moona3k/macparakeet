import SwiftUI
import Foundation
import MacParakeetCore

private struct TranscriptSegmentRowIdentity: Hashable {
    let startMs: Int
    let text: String
    let speakerId: String?
    let duplicateOrdinal: Int
}

private struct TranscriptSegmentRowIdentityBase: Hashable {
    let startMs: Int
    let text: String
    let speakerId: String?
}

private struct IndexedTranscriptSegment: Identifiable {
    let index: Int
    let segment: TranscriptSegment
    let identity: TranscriptSegmentRowIdentity

    var id: TranscriptSegmentRowIdentity {
        identity
    }
}

private func indexedSegments(_ segments: [TranscriptSegment]) -> [IndexedTranscriptSegment] {
    var duplicateCounts: [TranscriptSegmentRowIdentityBase: Int] = [:]
    return segments.enumerated().map { index, segment in
        let base = TranscriptSegmentRowIdentityBase(
            startMs: segment.startMs,
            text: segment.text,
            speakerId: segment.speakerId
        )
        let ordinal = duplicateCounts[base, default: 0]
        duplicateCounts[base] = ordinal + 1
        return IndexedTranscriptSegment(
            index: index,
            segment: segment,
            identity: TranscriptSegmentRowIdentity(
                startMs: segment.startMs,
                text: segment.text,
                speakerId: segment.speakerId,
                duplicateOrdinal: ordinal
            )
        )
    }
}

struct SpeakerTurnIdentity: Hashable {
    let speakerId: String
    let firstStartMs: Int?
    let duplicateOrdinal: Int
}

private struct SpeakerTurnIdentityBase: Hashable {
    let speakerId: String
    let firstStartMs: Int?
}

struct IdentifiedSpeakerTurn: Identifiable {
    let turn: SpeakerTurn
    let identity: SpeakerTurnIdentity

    var id: SpeakerTurnIdentity {
        identity
    }
}

/// Keep each lazy speaker card to a small, predictable amount of view work.
/// Twenty-four transcript segments is typically a few minutes of speech: large
/// enough to preserve the visual rhythm of speaker turns, but small enough that
/// a single-speaker recording cannot become one unbounded SwiftUI subtree.
let maximumSpeakerTurnSegmentsPerCard = 24

func identifiedSpeakerTurnCards(_ turns: [SpeakerTurn]) -> [IdentifiedSpeakerTurn] {
    let cardTurns = turns.flatMap { turn -> [SpeakerTurn] in
        guard turn.segments.count > maximumSpeakerTurnSegmentsPerCard else {
            return [turn]
        }

        return stride(
            from: 0,
            to: turn.segments.count,
            by: maximumSpeakerTurnSegmentsPerCard
        ).map { startIndex in
            let endIndex = min(
                startIndex + maximumSpeakerTurnSegmentsPerCard,
                turn.segments.count
            )
            return SpeakerTurn(
                speakerId: turn.speakerId,
                speakerLabel: turn.speakerLabel,
                segments: Array(turn.segments[startIndex..<endIndex])
            )
        }
    }

    return identifySpeakerTurns(cardTurns)
}

func speakerTurnCardScrollTarget(
    for currentMs: Int,
    in cards: [IdentifiedSpeakerTurn]
) -> Int? {
    for card in cards.reversed() {
        if let firstStartMs = card.turn.segments.first?.startMs,
            firstStartMs <= currentMs
        {
            return firstStartMs
        }
    }
    return nil
}

struct IdentifiedEffectiveSpeakerTurn: Identifiable {
    let id: SpeakerEditableSegmentID
    let assignment: SpeakerAssignment
    let speakerLabel: String
    let segments: [SpeakerEditableSegment]
    let logicalTurnSegments: [SpeakerEditableSegment]
}

func identifiedEffectiveSpeakerTurnCards(
    _ turns: [EffectiveSpeakerTurn]
) -> [IdentifiedEffectiveSpeakerTurn] {
    turns.flatMap { turn -> [IdentifiedEffectiveSpeakerTurn] in
        guard !turn.segments.isEmpty else { return [] }
        return stride(from: 0, to: turn.segments.count, by: maximumSpeakerTurnSegmentsPerCard).map { start in
            let end = min(start + maximumSpeakerTurnSegmentsPerCard, turn.segments.count)
            let segments = Array(turn.segments[start..<end])
            return IdentifiedEffectiveSpeakerTurn(
                id: segments[0].id,
                assignment: turn.assignment,
                speakerLabel: turn.speakerLabel,
                segments: segments,
                logicalTurnSegments: turn.segments
            )
        }
    }
}

func effectiveSpeakerTurnCardScrollTarget(
    for currentMs: Int,
    in cards: [IdentifiedEffectiveSpeakerTurn]
) -> SpeakerEditableSegmentID? {
    cards.reversed().first {
        ($0.segments.first?.startMs ?? .max) <= currentMs
    }?.id
}

func effectiveTranscriptScrollTarget(
    for currentMs: Int,
    attribution: EffectiveSpeakerAttribution
) -> SpeakerEditableSegmentID? {
    if attribution.speakers.isEmpty {
        return attribution.editableSegments.last { $0.startMs <= currentMs }?.id
    }
    return effectiveSpeakerTurnCardScrollTarget(
        for: currentMs,
        in: identifiedEffectiveSpeakerTurnCards(attribution.turns)
    )
}

private func identifySpeakerTurns(_ turns: [SpeakerTurn]) -> [IdentifiedSpeakerTurn] {
    var duplicateCounts: [SpeakerTurnIdentityBase: Int] = [:]
    return turns.map { turn in
        let base = SpeakerTurnIdentityBase(
            speakerId: turn.speakerId,
            firstStartMs: turn.segments.first?.startMs
        )
        let ordinal = duplicateCounts[base, default: 0]
        duplicateCounts[base] = ordinal + 1
        return IdentifiedSpeakerTurn(
            turn: turn,
            identity: SpeakerTurnIdentity(
                speakerId: turn.speakerId,
                firstStartMs: base.firstStartMs,
                duplicateOrdinal: ordinal
            )
        )
    }
}

struct TranscriptTimestampedContentView<SpeakerLabelContent: View>: View {
    let hasSpeakers: Bool
    let identifiedTurnCards: [IdentifiedSpeakerTurn]
    let segments: [TranscriptSegment]
    let speakerColorMap: [String: Color]
    let speakerLabelForID: (String) -> String
    let speakerLabelContent: (String, String, Color, String, Bool) -> SpeakerLabelContent
    let isSegmentActive: (Int) -> Bool
    let timestampLabel: (Int) -> String
    let isTimestampSeekable: Bool
    let onTimestampTap: (Int) -> Void
    /// Long transcripts put the `ForEach` directly inside this lazy stack.
    /// Callers must not wrap this view in another lazy transcript container:
    /// that would make the entire transcript one eager child again.
    var usesLazyStack: Bool = false
    /// User-adjustable reading size for the transcript body (U4). Defaults to the
    /// design-system `bodyLarge` so existing call sites are unaffected.
    var bodyFont: Font = DesignSystem.Typography.bodyLarge
    /// In-transcript find highlights (U2), keyed by a row's `startMs`.
    var highlightRangesByStartMs: [Int: [NSRange]] = [:]
    /// The single emphasized ("current") match, identified by its row `startMs`.
    var currentHighlight: (id: Int, range: NSRange)?
    /// Per-row `.textSelection(.enabled)`. Each selectable `Text` is an AppKit
    /// platform overlay; `TranscriptBodyLayout.rowTextSelectionEnabled` lets a
    /// DEBUG launch turn them off to bisect the transcript freeze.
    var textSelectionEnabled: Bool = true
    /// Observes realized direct children in layout smoke tests. Production uses
    /// the no-op default, so it does not own a second loading or layout path.
    var onRenderedChildAppear: () -> Void = {}
    /// Effective correction projection. `false` preserves the legacy rendering
    /// path until the owning result view has loaded its database-backed snapshot.
    var usesEffectiveAttribution = false
    var editableSegments: [SpeakerEditableSegment] = []
    var effectiveTurnCards: [IdentifiedEffectiveSpeakerTurn] = []
    var availableSpeakers: [SpeakerInfo] = []
    var isSpeakerEditing = false
    var isSpeakerActionDisabled = false
    var selectedSegmentIDs: Set<SpeakerEditableSegmentID> = []
    var effectiveIsSegmentActive: (SpeakerEditableSegment) -> Bool = { _ in false }
    var effectiveHighlightRanges: [SpeakerEditableSegmentID: [NSRange]] = [:]
    var effectiveCurrentHighlight: (id: SpeakerEditableSegmentID, range: NSRange)? = nil
    var onSelectSegment: (SpeakerEditableSegmentID) -> Void = { _ in }
    var onToggleTurnSelection: ([SpeakerEditableSegmentID]) -> Void = { _ in }
    var onBeginSpeakerEditing: () -> Void = {}
    var onAssignSegment: (SpeakerEditableSegment, SpeakerAssignment) -> Void = { _, _ in }
    var onCreateSpeakerForSegment: (SpeakerEditableSegment) -> Void = { _ in }
    var onSplitSegment: (SpeakerEditableSegment) -> Void = { _ in }
    var onAssignTurn: ([SpeakerEditableSegment], SpeakerAssignment) -> Void = { _, _ in }
    var onCreateSpeakerForTurn: ([SpeakerEditableSegment]) -> Void = { _ in }

    @ViewBuilder
    var body: some View {
        if usesLazyStack {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if usesEffectiveAttribution {
                    if !effectiveTurnCards.isEmpty {
                        ForEach(effectiveTurnCards) { identified in
                            effectiveSpeakerTurnCard(identified)
                        }
                    } else {
                        ForEach(editableSegments) { segment in
                            effectiveSegmentRow(segment)
                        }
                    }
                } else if hasSpeakers {
                    ForEach(identifiedTurnCards) { identified in
                        speakerTurnCard(identified)
                    }
                } else {
                    ForEach(indexedSegments(segments)) { indexed in
                        segmentRow(indexed)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if usesEffectiveAttribution {
                    if !effectiveTurnCards.isEmpty {
                        ForEach(effectiveTurnCards) { identified in
                            effectiveSpeakerTurnCard(identified)
                        }
                    } else {
                        ForEach(editableSegments) { segment in
                            effectiveSegmentRow(segment)
                        }
                    }
                } else if hasSpeakers {
                    ForEach(identifiedTurnCards) { identified in
                        speakerTurnCard(identified)
                    }
                } else {
                    ForEach(indexedSegments(segments)) { indexed in
                        segmentRow(indexed)
                    }
                }
            }
        }
    }

    private func speakerTurnCard(_ identified: IdentifiedSpeakerTurn) -> some View {
        let turn = identified.turn
        let speakerLabel = speakerLabelForID(turn.speakerId)
        let speakerColor = speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary
        let renameContextID = SpeakerRenameAccessibility.turnRenameContextIdentifier(
            speakerID: turn.speakerId,
            firstStartMs: identified.identity.firstStartMs,
            duplicateOrdinal: identified.identity.duplicateOrdinal
        )
        return TranscriptTurnCardView(
            speakerID: turn.speakerId,
            speakerLabel: speakerLabel,
            renameContextID: renameContextID,
            speakerLabelContent: speakerLabelContent,
            speakerColor: speakerColor,
            segments: turn.segments,
            timestampLabel: timestampLabel,
            isTimestampSeekable: isTimestampSeekable,
            bodyFont: bodyFont,
            highlightRangesByStartMs: highlightRangesByStartMs,
            currentHighlight: currentHighlight,
            onTimestampTap: onTimestampTap,
            textSelectionEnabled: textSelectionEnabled
        )
        // Preserve the existing first-segment/card scroll target while later
        // rows expose their own anchors for mid-turn find results.
        .id(turn.segments.first?.startMs ?? 0)
        .onAppear(perform: onRenderedChildAppear)
    }

    private func segmentRow(_ indexed: IndexedTranscriptSegment) -> some View {
        let index = indexed.index
        let segment = indexed.segment
        return ZStack(alignment: .topLeading) {
            timestampScrollAnchor(startMs: segment.startMs)
            TranscriptSegmentRow(
                startMs: segment.startMs,
                text: segment.text,
                timestampText: timestampLabel(segment.startMs),
                isActive: isSegmentActive(index),
                isSeekable: isTimestampSeekable,
                bodyFont: bodyFont,
                showRowBackground: true,
                highlightRanges: highlightRangesByStartMs[segment.startMs] ?? [],
                currentRange: currentHighlight?.id == segment.startMs ? currentHighlight?.range : nil,
                onPlayFromHere: { onTimestampTap(segment.startMs) },
                textSelectionEnabled: textSelectionEnabled
            )
        }
        .onAppear(perform: onRenderedChildAppear)
    }

    private func effectiveSpeakerTurnCard(_ identified: IdentifiedEffectiveSpeakerTurn) -> some View {
        EditableTranscriptTurnCardView(
            turn: identified,
            availableSpeakers: availableSpeakers,
            speakerColorMap: speakerColorMap,
            speakerLabelContent: speakerLabelContent,
            isSpeakerEditing: isSpeakerEditing,
            isSpeakerActionDisabled: isSpeakerActionDisabled,
            selectedSegmentIDs: selectedSegmentIDs,
            timestampLabel: timestampLabel,
            isTimestampSeekable: isTimestampSeekable,
            bodyFont: bodyFont,
            textSelectionEnabled: textSelectionEnabled,
            highlightRanges: effectiveHighlightRanges,
            currentHighlight: effectiveCurrentHighlight,
            onTimestampTap: onTimestampTap,
            onSelectSegment: onSelectSegment,
            onToggleTurnSelection: onToggleTurnSelection,
            onBeginSpeakerEditing: onBeginSpeakerEditing,
            onAssignSegment: onAssignSegment,
            onCreateSpeakerForSegment: onCreateSpeakerForSegment,
            onSplitSegment: onSplitSegment,
            onAssignTurn: onAssignTurn,
            onCreateSpeakerForTurn: onCreateSpeakerForTurn
        )
        .id(identified.id)
        .onAppear(perform: onRenderedChildAppear)
    }

    private func effectiveSegmentRow(_ segment: SpeakerEditableSegment) -> some View {
        ZStack(alignment: .topLeading) {
            effectiveTimestampScrollAnchor(id: segment.id)
            TranscriptSegmentRow(
                startMs: segment.startMs,
                text: segment.text,
                timestampText: timestampLabel(segment.startMs),
                isActive: effectiveIsSegmentActive(segment),
                isSeekable: isTimestampSeekable,
                bodyFont: bodyFont,
                showRowBackground: true,
                highlightRanges: effectiveHighlightRanges[segment.id] ?? [],
                currentRange: effectiveCurrentHighlight?.id == segment.id
                    ? effectiveCurrentHighlight?.range : nil,
                onPlayFromHere: { onTimestampTap(segment.startMs) },
                textSelectionEnabled: textSelectionEnabled,
                editableSegment: segment,
                availableSpeakers: availableSpeakers,
                isSpeakerEditing: isSpeakerEditing,
                isSpeakerActionDisabled: isSpeakerActionDisabled,
                isSelectedForSpeakerEditing: selectedSegmentIDs.contains(segment.id),
                onSelectForSpeakerEditing: { onSelectSegment(segment.id) },
                onBeginSpeakerEditing: onBeginSpeakerEditing,
                onAssignSpeaker: { onAssignSegment(segment, $0) },
                onCreateSpeaker: { onCreateSpeakerForSegment(segment) },
                onSplit: { onSplitSegment(segment) }
            )
        }
        .onAppear(perform: onRenderedChildAppear)
    }

}

private func timestampScrollAnchor(startMs: Int) -> some View {
    Color.clear
        .frame(width: 1, height: 1)
        .id(startMs)
        .accessibilityHidden(true)
}

private func effectiveTimestampScrollAnchor(id: SpeakerEditableSegmentID) -> some View {
    Color.clear
        .frame(width: 1, height: 1)
        .id(id)
        .accessibilityHidden(true)
}

private struct EditableTranscriptTurnCardView<SpeakerLabelContent: View>: View {
    let turn: IdentifiedEffectiveSpeakerTurn
    let availableSpeakers: [SpeakerInfo]
    let speakerColorMap: [String: Color]
    let speakerLabelContent: (String, String, Color, String, Bool) -> SpeakerLabelContent
    let isSpeakerEditing: Bool
    let isSpeakerActionDisabled: Bool
    let selectedSegmentIDs: Set<SpeakerEditableSegmentID>
    let timestampLabel: (Int) -> String
    let isTimestampSeekable: Bool
    var bodyFont: Font
    var textSelectionEnabled: Bool
    let highlightRanges: [SpeakerEditableSegmentID: [NSRange]]
    let currentHighlight: (id: SpeakerEditableSegmentID, range: NSRange)?
    let onTimestampTap: (Int) -> Void
    let onSelectSegment: (SpeakerEditableSegmentID) -> Void
    let onToggleTurnSelection: ([SpeakerEditableSegmentID]) -> Void
    let onBeginSpeakerEditing: () -> Void
    let onAssignSegment: (SpeakerEditableSegment, SpeakerAssignment) -> Void
    let onCreateSpeakerForSegment: (SpeakerEditableSegment) -> Void
    let onSplitSegment: (SpeakerEditableSegment) -> Void
    let onAssignTurn: ([SpeakerEditableSegment], SpeakerAssignment) -> Void
    let onCreateSpeakerForTurn: ([SpeakerEditableSegment]) -> Void

    @State private var isHovering = false

    private var speakerID: String? {
        guard case .speaker(let id) = turn.assignment else { return nil }
        return id
    }

    private var speakerColor: Color {
        speakerID.flatMap { speakerColorMap[$0] } ?? DesignSystem.Colors.textTertiary
    }

    private var segmentIDs: [SpeakerEditableSegmentID] {
        turn.logicalTurnSegments.map(\.id)
    }

    private var selectedSegmentCount: Int {
        segmentIDs.lazy.filter(selectedSegmentIDs.contains).count
    }

    private var allSegmentsSelected: Bool {
        !segmentIDs.isEmpty && selectedSegmentCount == segmentIDs.count
    }

    private var someSegmentsSelected: Bool {
        selectedSegmentCount > 0 && !allSegmentsSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)

                if let speakerID {
                    speakerLabelContent(
                        speakerID,
                        turn.speakerLabel,
                        speakerColor,
                        SpeakerRenameAccessibility.turnRenameContextIdentifier(
                            speakerID: speakerID,
                            firstStartMs: turn.segments.first?.startMs,
                            duplicateOrdinal: 0
                        ),
                        isHovering
                    )
                    .contextMenu {
                        turnSpeakerAssignmentMenu
                            .disabled(isSpeakerActionDisabled)
                    }
                } else {
                    Text("Unassigned")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .contextMenu {
                            turnSpeakerAssignmentMenu
                                .disabled(isSpeakerActionDisabled)
                        }
                }

                if let firstStart = turn.segments.first?.startMs {
                    transcriptMetadataChip(icon: "clock", text: timestampLabel(firstStart))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(turn.segments) { segment in
                    ZStack(alignment: .topLeading) {
                        // The card owns its first segment's scroll identity.
                        if segment.id != turn.id {
                            effectiveTimestampScrollAnchor(id: segment.id)
                        }
                        TranscriptSegmentRow(
                            startMs: segment.startMs,
                            text: segment.text,
                            timestampText: timestampLabel(segment.startMs),
                            isActive: false,
                            isSeekable: isTimestampSeekable,
                            bodyFont: bodyFont,
                            showRowBackground: false,
                            highlightRanges: highlightRanges[segment.id] ?? [],
                            currentRange: currentHighlight?.id == segment.id
                                ? currentHighlight?.range : nil,
                            onPlayFromHere: { onTimestampTap(segment.startMs) },
                            textSelectionEnabled: textSelectionEnabled,
                            editableSegment: segment,
                            availableSpeakers: availableSpeakers,
                            isSpeakerEditing: isSpeakerEditing,
                            isSpeakerActionDisabled: isSpeakerActionDisabled,
                            isSelectedForSpeakerEditing: selectedSegmentIDs.contains(segment.id),
                            onSelectForSpeakerEditing: { onSelectSegment(segment.id) },
                            onBeginSpeakerEditing: onBeginSpeakerEditing,
                            onAssignSpeaker: { onAssignSegment(segment, $0) },
                            onCreateSpeaker: { onCreateSpeakerForSegment(segment) },
                            onSplit: { onSplitSegment(segment) }
                        )
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(
                    allSegmentsSelected
                        ? DesignSystem.Colors.accent.opacity(0.13)
                        : someSegmentsSelected
                        ? DesignSystem.Colors.accent.opacity(0.09)
                        : speakerColor.opacity(0.08)
                )
                .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                .onTapGesture(count: 2) {
                    guard isSpeakerEditing, !isSpeakerActionDisabled else { return }
                    onToggleTurnSelection(segmentIDs)
                }
                .allowsHitTesting(isSpeakerEditing && !isSpeakerActionDisabled)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(
                    allSegmentsSelected || someSegmentsSelected
                        ? DesignSystem.Colors.accent.opacity(allSegmentsSelected ? 0.70 : 0.40)
                        : speakerColor.opacity(0.18),
                    lineWidth: allSegmentsSelected ? 1.25 : 0.75
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovering = hovering
            }
        }
        .accessibilityAction(
            named: Text(allSegmentsSelected ? "Deselect all segments in this turn" : "Select all segments in this turn")
        ) {
            guard isSpeakerEditing, !isSpeakerActionDisabled else { return }
            onToggleTurnSelection(segmentIDs)
        }
    }

    @ViewBuilder
    private var turnSpeakerAssignmentMenu: some View {
        Menu("Assign this turn to…") {
            ForEach(availableSpeakers.filter { $0.id != speakerID }, id: \.id) { speaker in
                Button(speaker.label) {
                    onAssignTurn(turn.logicalTurnSegments, .speaker(id: speaker.id))
                }
            }
            if speakerID != nil {
                Divider()
                Button("Unassigned") {
                    onAssignTurn(turn.logicalTurnSegments, .unassigned)
                }
            }
        }
        Button("New speaker…") {
            onCreateSpeakerForTurn(turn.logicalTurnSegments)
        }
    }

    private func transcriptMetadataChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(DesignSystem.Typography.timestamp)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
    }
}

private struct TranscriptTurnCardView<SpeakerLabelContent: View>: View {
    let speakerID: String
    let speakerLabel: String
    let renameContextID: String
    let speakerLabelContent: (String, String, Color, String, Bool) -> SpeakerLabelContent
    let speakerColor: Color
    let segments: [TranscriptSegment]
    let timestampLabel: (Int) -> String
    let isTimestampSeekable: Bool
    var bodyFont: Font
    var highlightRangesByStartMs: [Int: [NSRange]] = [:]
    var currentHighlight: (id: Int, range: NSRange)?
    let onTimestampTap: (Int) -> Void
    var textSelectionEnabled: Bool = true

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)

                speakerLabelContent(speakerID, speakerLabel, speakerColor, renameContextID, isHovering)

                if let firstStart = segments.first?.startMs {
                    transcriptMetadataChip(icon: "clock", text: timestampLabel(firstStart))
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(indexedSegments(segments)) { indexed in
                    let index = indexed.index
                    let segment = indexed.segment
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
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovering = hovering
            }
        }
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
            highlightRanges: highlightRangesByStartMs[segment.startMs] ?? [],
            currentRange: currentHighlight?.id == segment.startMs ? currentHighlight?.range : nil,
            onPlayFromHere: { onTimestampTap(segment.startMs) },
            textSelectionEnabled: textSelectionEnabled
        )
        if index == 0 {
            row
        } else {
            // Non-first rows get their own anchors so find navigation can land
            // inside a speaker turn without shifting the first-line/card target.
            ZStack(alignment: .topLeading) {
                timestampScrollAnchor(startMs: segment.startMs)
                row
            }
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
    var textSelectionEnabled: Bool = true
    var editableSegment: SpeakerEditableSegment? = nil
    var availableSpeakers: [SpeakerInfo] = []
    var isSpeakerEditing = false
    var isSpeakerActionDisabled = false
    var isSelectedForSpeakerEditing = false
    var onSelectForSpeakerEditing: () -> Void = {}
    var onBeginSpeakerEditing: () -> Void = {}
    var onAssignSpeaker: (SpeakerAssignment) -> Void = { _ in }
    var onCreateSpeaker: () -> Void = {}
    var onSplit: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            if isSpeakerEditing {
                Button(action: onSelectForSpeakerEditing) {
                    Image(systemName: isSelectedForSpeakerEditing ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            isSelectedForSpeakerEditing
                                ? DesignSystem.Colors.accent
                                : DesignSystem.Colors.textTertiary
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSpeakerActionDisabled)
                .accessibilityLabel(
                    isSelectedForSpeakerEditing ? "Deselect transcript segment" : "Select transcript segment"
                )
                .accessibilityValue(isSelectedForSpeakerEditing ? "Selected" : "Not selected")
            }

            TranscriptTimestampChip(
                startMs: startMs,
                label: timestampText,
                isSeekable: isSeekable,
                onTap: { _ in onPlayFromHere() }
            )

            bodyText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(showRowBackground ? DesignSystem.Spacing.md : 0)
        // Keep the hover capsule inside the row's actual hit-test bounds even
        // when the transcript text is only one short line.
        .frame(minHeight: 30, alignment: .top)
        .contentShape(Rectangle())
        .background {
            if showRowBackground {
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isActive
                          ? DesignSystem.Colors.accent.opacity(0.12)
                          : isSelectedForSpeakerEditing
                          ? DesignSystem.Colors.accent.opacity(0.10)
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
        .contextMenu {
            if editableSegment != nil {
                segmentSpeakerMenu
                    .disabled(isSpeakerActionDisabled)
            }
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        let styled =
            bodyTextCore
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .lineSpacing(5)
        if textSelectionEnabled {
            styled.textSelection(.enabled)
        } else {
            styled.textSelection(.disabled)
        }
    }

    /// Plain `Text` on the idle fast path; an attributed, highlighted `Text`
    /// only when this row carries find matches.
    private var bodyTextCore: Text {
        guard !highlightRanges.isEmpty else {
            return Text(text).font(bodyFont)
        }
        return Text(
            TranscriptFindHighlight.attributed(
                text,
                ranges: highlightRanges,
                current: currentRange,
                baseFont: bodyFont
            ))
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if editableSegment != nil {
                Menu {
                    segmentSpeakerMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Speaker actions")
                .accessibilityLabel("Speaker actions")
                .disabled(isSpeakerActionDisabled)
            }
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

    @ViewBuilder
    private var segmentSpeakerMenu: some View {
        if isSpeakerEditing {
            speakerEditingMenu
        } else {
            Button("Edit speakers", action: onBeginSpeakerEditing)
        }
    }

    @ViewBuilder
    private var speakerEditingMenu: some View {
        Menu("Assign to…") {
            ForEach(availableSpeakers, id: \.id) { speaker in
                Button(speaker.label) {
                    onAssignSpeaker(.speaker(id: speaker.id))
                }
            }
            if !availableSpeakers.isEmpty {
                Divider()
            }
            Button("Unassigned") {
                onAssignSpeaker(.unassigned)
            }
        }
        Button("New speaker…", action: onCreateSpeaker)
        Button("Split…", action: onSplit)
            .disabled(!canSplitEditableSegment)
    }

    private var canSplitEditableSegment: Bool {
        guard let range = editableSegment?.wordRange else { return false }
        return range.endIndexExclusive - range.startIndex > 1
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
