import SwiftUI

/// Hover-driven tooltip with a 300ms reveal delay and DesignSystem-tuned
/// content. Uses `.popover` so positioning escapes parent clipping (the
/// AskPromptsSheet rows live inside a `.clipShape`-bounded card group, where
/// a plain `.overlay`-based tooltip would clip at the card edge).
///
/// Pair with `.accessibilityLabel(...)` for VoiceOver — this modifier does
/// not set accessibility hints itself, since `.help(...)` (which it
/// replaces) had that side effect and we want callers to remain explicit.
struct PolishedTooltip: ViewModifier {
    let text: String

    @State private var isHovering = false
    @State private var isShowing = false
    @State private var revealTask: Task<Void, Never>?

    /// 300ms feels quick without being jumpy. macOS system tooltips delay
    /// closer to 1500ms; the polished version exists to feel faster.
    private static let revealDelay: UInt64 = 300_000_000

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                revealTask?.cancel()
                if hovering {
                    revealTask = Task {
                        try? await Task.sleep(nanoseconds: Self.revealDelay)
                        guard !Task.isCancelled, isHovering else { return }
                        isShowing = true
                    }
                } else {
                    isShowing = false
                }
            }
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .fixedSize(horizontal: true, vertical: false)
            }
    }
}

extension View {
    /// Drop-in replacement for `.help(...)` with a faster reveal (~300ms vs
    /// macOS default ~1500ms) and DesignSystem-styled content. Pair with
    /// `.accessibilityLabel(...)` for VoiceOver.
    func polishedTooltip(_ text: String) -> some View {
        modifier(PolishedTooltip(text: text))
    }
}
