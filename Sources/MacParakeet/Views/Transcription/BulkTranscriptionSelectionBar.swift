import SwiftUI

struct BulkTranscriptionSelectionBar: View {
    let selectedCount: Int
    let selectedMeetingAudioCount: Int
    let isMeetingContext: Bool
    let areAllVisibleSelected: Bool
    let isPerformingOperation: Bool
    let onSelectVisible: () -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    let onDeleteAudioOnly: () -> Void
    let onDeleteItems: () -> Void

    private var showsAudioAction: Bool {
        isMeetingContext || selectedMeetingAudioCount > 0
    }

    private var deleteAudioTitle: String {
        if isMeetingContext {
            return "Remove Audio Only..."
        }
        return "Remove Audio for \(selectedMeetingAudioCount) \(selectedMeetingAudioCount == 1 ? "Meeting" : "Meetings")..."
    }

    private var deleteItemsTitle: String {
        isMeetingContext ? "Delete Meetings..." : "Delete Items..."
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalBar
            wrappedBar
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceElevated)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.35)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.55)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPerformingOperation ? "Deleting selected items" : "\(selectedCount) selected")
    }

    private var horizontalBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            selectionSummary

            Spacer(minLength: DesignSystem.Spacing.md)

            actionCluster
        }
        .frame(minHeight: 34)
    }

    private var wrappedBar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            selectionSummary
            actionFlow
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: 8) {
            if isPerformingOperation {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }

            Text(isPerformingOperation ? "Deleting..." : "\(selectedCount) selected")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.accentLight)
        )
        .accessibilityHidden(true)
    }

    private var actionCluster: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                utilityActions
                destructiveActions
            }

            VStack(alignment: .leading, spacing: 6) {
                utilityActions
                destructiveActions
            }
        }
    }

    private var utilityActions: some View {
        HStack(spacing: 6) {
            cancelAction
            selectVisibleAction
            clearAction
        }
    }

    private var destructiveActions: some View {
        HStack(spacing: 6) {
            if showsAudioAction {
                deleteAudioAction
            }
            deleteItemsAction
        }
    }

    private var actionFlow: some View {
        FlowLayout(spacing: 6) {
            cancelAction
            selectVisibleAction
            clearAction
            if showsAudioAction {
                deleteAudioAction
            }
            deleteItemsAction
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cancelAction: some View {
        SelectionBarActionButton(
            title: "Cancel",
            systemImage: "xmark",
            tone: .subtle,
            isDisabled: isPerformingOperation,
            usesEscapeShortcut: true,
            action: onCancel
        )
    }

    // Labeled "Select All" but scoped to the loaded rows by design: selection
    // (and therefore deletion) never reaches rows that aren't loaded yet. The
    // selected-count chip and the delete confirmation always state the exact
    // number, so the scope is explicit at the moment of action.
    private var selectVisibleAction: some View {
        SelectionBarActionButton(
            title: "Select All",
            systemImage: "checkmark.circle",
            tone: .utility,
            isDisabled: areAllVisibleSelected || isPerformingOperation,
            action: onSelectVisible
        )
    }

    private var clearAction: some View {
        SelectionBarActionButton(
            title: "Clear",
            systemImage: "xmark.circle",
            tone: .utility,
            isDisabled: selectedCount == 0 || isPerformingOperation,
            action: onClear
        )
    }

    private var deleteAudioAction: some View {
        SelectionBarActionButton(
            title: deleteAudioTitle,
            systemImage: "waveform.slash",
            tone: .destructive,
            isDisabled: selectedMeetingAudioCount == 0 || isPerformingOperation,
            role: .destructive,
            action: onDeleteAudioOnly
        )
    }

    private var deleteItemsAction: some View {
        SelectionBarActionButton(
            title: deleteItemsTitle,
            systemImage: "trash",
            tone: .destructive,
            isDisabled: selectedCount == 0 || isPerformingOperation,
            role: .destructive,
            action: onDeleteItems
        )
    }
}

private enum SelectionBarActionTone {
    case utility
    case destructive
    case subtle

    func foreground(isHovered: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return DesignSystem.Colors.textTertiary }
        switch self {
        case .utility:
            return isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
        case .destructive:
            return DesignSystem.Colors.errorRed
        case .subtle:
            return isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
        }
    }

    func fill(isHovered: Bool) -> Color {
        switch self {
        case .utility:
            return isHovered
                ? DesignSystem.Colors.textPrimary.opacity(0.08)
                : DesignSystem.Colors.surface.opacity(0.72)
        case .destructive:
            return DesignSystem.Colors.errorRed.opacity(isHovered ? 0.16 : 0.09)
        case .subtle:
            return isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : .clear
        }
    }

    var stroke: Color {
        switch self {
        case .utility:
            return DesignSystem.Colors.border.opacity(0.7)
        case .destructive:
            return DesignSystem.Colors.errorRed.opacity(0.24)
        case .subtle:
            return .clear
        }
    }
}

private struct SelectionBarActionButton: View {
    let title: String
    let systemImage: String
    let tone: SelectionBarActionTone
    var isDisabled: Bool = false
    var usesEscapeShortcut: Bool = false
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovered = false
    @State private var didPushCursor = false

    var body: some View {
        Group {
            if usesEscapeShortcut {
                baseButton
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                baseButton
            }
        }
    }

    private var baseButton: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            .foregroundStyle(tone.foreground(isHovered: isHovered, isDisabled: isDisabled))
            .padding(.horizontal, tone == .subtle ? 8 : 11)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(tone.fill(isHovered: isHovered))
            )
            .overlay {
                Capsule()
                    .strokeBorder(tone.stroke, lineWidth: tone == .subtle ? 0 : 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .onHover { hovering in
            isHovered = hovering && !isDisabled
            updateCursor(isHovering: hovering)
        }
        .onChange(of: isDisabled) { _, _ in
            if isDisabled {
                isHovered = false
            }
            updateCursor(isHovering: isHovered)
        }
        .onDisappear {
            releaseCursorIfNeeded()
        }
        .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
        .animation(DesignSystem.Animation.hoverTransition, value: isDisabled)
    }

    private func updateCursor(isHovering: Bool) {
        let shouldShowPointer = isHovering && !isDisabled
        if shouldShowPointer, !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
            return
        }
        if !shouldShowPointer, didPushCursor {
            releaseCursorIfNeeded()
        }
    }

    private func releaseCursorIfNeeded() {
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}
