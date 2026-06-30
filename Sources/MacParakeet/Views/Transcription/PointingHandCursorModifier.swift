import AppKit
import SwiftUI

extension View {
    func pointingHandCursor(isActive: Bool) -> some View {
        modifier(PointingHandCursorModifier(isActive: isActive))
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isActive: Bool

    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, isActive in
                updateCursor(isActive: isActive)
            }
            .onDisappear {
                releaseCursorIfNeeded()
            }
    }

    private func updateCursor(isActive: Bool) {
        if isActive, !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
            return
        }

        if !isActive {
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
