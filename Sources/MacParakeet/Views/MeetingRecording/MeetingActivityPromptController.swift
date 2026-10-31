import AppKit
import Observation
import SwiftUI

private final class MeetingActivityPromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
private final class MeetingActivityPromptState {
    var recordingAvailable = true
}

@MainActor
final class MeetingActivityPromptController {
    private var panel: NSPanel?
    private var onOutcome: (@MainActor (MeetingActivityPromptOutcome) -> Void)?
    private let state = MeetingActivityPromptState()

    func show(displayName: String, onOutcome: @escaping @MainActor (MeetingActivityPromptOutcome) -> Void) {
        close()
        self.onOutcome = onOutcome
        state.recordingAvailable = true

        let view = MeetingActivityPromptView(
            displayName: displayName,
            state: state,
            onRecord: { [weak self] in self?.finish(.accepted) },
            onDecline: { [weak self] in self?.finish(.declined) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 118)

        let panel = MeetingActivityPromptPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        if let screen = Self.screenForPrompt() {
            let size =
                hosting.fittingSize.width > 0
                ? hosting.fittingSize
                : NSSize(width: 340, height: 118)
            let frame = screen.visibleFrame
            let margin: CGFloat = 16
            panel.setFrame(
                NSRect(
                    x: frame.maxX - size.width - margin,
                    y: frame.maxY - size.height - margin,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }

        // Keep keyboard focus in the meeting app. Actions are available by
        // pointer or Accessibility, without intercepting Return or Escape.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func setRecordingAvailable(_ available: Bool) {
        state.recordingAvailable = available
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        onOutcome = nil
    }

    private func finish(_ outcome: MeetingActivityPromptOutcome) {
        if case .accepted = outcome, !state.recordingAvailable { return }
        // The coordinator owns dismissal after validating the action. A stale
        // Record action must not silently remove a still-useful reminder.
        onOutcome?(outcome)
    }

    private static func screenForPrompt() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

private struct MeetingActivityPromptView: View {
    let displayName: String
    let state: MeetingActivityPromptState
    let onRecord: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "record.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record this meeting?")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Meeting activity in \(displayName).")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                Button("Not now", action: onDecline)
                    .parakeetAction(.secondary)
                Button {
                    onRecord()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .parakeetAction(.primaryProminent)
                .disabled(!state.recordingAvailable)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )
        )
    }
}
