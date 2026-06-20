import SwiftUI

struct BulkTranscriptionSelectionBar: View {
    let selectedCount: Int
    let selectedMeetingAudioCount: Int
    let isMeetingContext: Bool
    let areAllLoadedSelected: Bool
    let isPerformingOperation: Bool
    let onSelectLoaded: () -> Void
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
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPerformingOperation ? "Deleting selected items" : "\(selectedCount) selected")
    }

    private var horizontalBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            selectionSummary

            Spacer(minLength: DesignSystem.Spacing.md)

            utilityActions
            destructiveActions
        }
    }

    private var wrappedBar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            selectionSummary
            HStack(spacing: DesignSystem.Spacing.sm) {
                utilityActions
                destructiveActions
            }
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: 7) {
            if isPerformingOperation {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }

            Text(isPerformingOperation ? "Deleting..." : "\(selectedCount) selected")
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .accessibilityHidden(true)
    }

    private var utilityActions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Cancel", action: onCancel)
                .parakeetAction(.subtle)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(isPerformingOperation)

            Button {
                onSelectLoaded()
            } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            .disabled(areAllLoadedSelected || isPerformingOperation)
            .parakeetAction(.secondary)

            Button {
                onClear()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(selectedCount == 0 || isPerformingOperation)
            .parakeetAction(.secondary)
        }
    }

    private var destructiveActions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if showsAudioAction {
                Button(role: .destructive) {
                    onDeleteAudioOnly()
                } label: {
                    Label(deleteAudioTitle, systemImage: "waveform.slash")
                }
                .disabled(selectedMeetingAudioCount == 0 || isPerformingOperation)
                .parakeetAction(.destructive)
            }

            Button(role: .destructive) {
                onDeleteItems()
            } label: {
                Label(deleteItemsTitle, systemImage: "trash")
            }
            .disabled(selectedCount == 0 || isPerformingOperation)
            .parakeetAction(.destructive)
        }
    }
}
