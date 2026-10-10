import AppKit
import MacParakeetCore
import SwiftUI

/// Draws what Voice Control is about to touch: an outline on the control it
/// acts on or asks to confirm, and number badges on the choices of a pick, so
/// "say the number" has something to look at. One click-through window per
/// display, excluded from screen capture so screen-text reading never sees it.
@MainActor
final class VoiceControlOverlayController {
    private var windows: [NSWindow] = []
    private let model = OverlayModel()
    private var fade: Task<Void, Never>?

    func show(_ highlight: VoiceControlHighlight) {
        let marks = highlight.marks.filter { mark in
            guard let frame = mark.frame else { return false }
            return frame.width >= 2 && frame.height >= 2 && frame.width.isFinite && frame.height.isFinite
        }
        fade?.cancel()
        guard !marks.isEmpty else { clear(); return }
        ensureWindows()
        model.style = highlight.style
        model.marks = marks
        model.visible = true
        windows.forEach { $0.orderFrontRegardless() }
        // An acting outline is a flash that confirms the target as it is
        // pressed; confirmations and picks stay until the next step.
        if highlight.style == .acting {
            fade = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        }
    }

    /// Ends a confirmation outline or pick badges; a press flash finishes on its own.
    func dismissPersistent() {
        guard model.style != .acting || !model.visible else { return }
        clear()
    }

    func clear() {
        fade?.cancel(); fade = nil
        model.visible = false
        model.marks = []
        windows.forEach { $0.orderOut(nil) }
    }

    private func ensureWindows() {
        let screens = NSScreen.screens
        guard windows.count != screens.count
            || zip(windows, screens).contains(where: { $0.frame != $1.frame })
        else { return }
        windows.forEach { $0.orderOut(nil) }
        let primaryHeight = screens.first?.frame.maxY ?? 0
        windows = screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.sharingType = .none
            window.isReleasedWhenClosed = false
            // AX frames are global with a top-left origin on the primary display.
            let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
            window.contentView = NSHostingView(rootView: OverlayView(model: model, origin: origin))
            window.setFrame(screen.frame, display: false)
            return window
        }
    }
}

@MainActor @Observable
private final class OverlayModel {
    var style: VoiceControlHighlight.Style = .acting
    var marks: [VoiceControlHighlight.Mark] = []
    var visible = false
}

private struct OverlayView: View {
    let model: OverlayModel
    /// This display's top-left corner in global top-left coordinates.
    let origin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(model.marks.enumerated()), id: \.offset) { _, mark in
                if let frame = mark.frame {
                    let local = frame.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(model.style == .numbered ? 0.06 : 0.12))
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tint, lineWidth: model.style == .confirming ? 3 : 2.5)
                        if let number = mark.number {
                            Text("\(number)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Circle().fill(tint))
                                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                .offset(x: -11, y: -11)
                        }
                    }
                    .frame(width: local.width, height: local.height)
                    .offset(x: local.minX, y: local.minY)
                    .shadow(color: tint.opacity(0.45), radius: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: model.visible)
        .allowsHitTesting(false)
    }

    private var tint: Color {
        model.style == .confirming ? DesignSystem.Colors.warningAmber : DesignSystem.Colors.accent
    }
}
