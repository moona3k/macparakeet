import AppKit
import SwiftUI

private final class MeetingActivityPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingActivityPromptController {
    private var panel: NSPanel?
    private var onOutcome: (@MainActor (MeetingActivityPromptOutcome) -> Void)?

    func show(displayName: String, onOutcome: @escaping @MainActor (MeetingActivityPromptOutcome) -> Void) {
        close()
        self.onOutcome = onOutcome

        let view = MeetingActivityPromptView(
            displayName: displayName,
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

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        onOutcome = nil
    }

    private func finish(_ outcome: MeetingActivityPromptOutcome) {
        let callback = onOutcome
        panel?.orderOut(nil)
        panel = nil
        onOutcome = nil
        callback?(outcome)
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

            HStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                Button("Not now", action: onDecline)
                    .parakeetAction(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                Button {
                    onRecord()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.return, modifiers: [])
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
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        )
        .accessibilityElement(children: .combine)
    }
}
