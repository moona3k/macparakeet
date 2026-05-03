import SwiftUI

/// Tooltip wrapper for buttons in the AskPromptsSheet (and friends).
///
/// **History:** initially backed by a custom 300ms-reveal `.popover` so we
/// could control visual styling. Reverted to `.help(...)` because
/// SwiftUI's `.popover` dismissal swallows the first click on the
/// underlying button (NSPopover semantics) — every tooltip-decorated
/// button needed two clicks to fire. `.help(...)` doesn't have that
/// failure mode.
///
/// Trade-off accepted: ~1500ms native delay (vs the prior 300ms) and
/// system styling (vs DesignSystem-tuned chrome). The polished *copy*
/// (e.g. "Already at the top" when reorder is disabled) is preserved —
/// only the chrome reverts. First-click response matters more than
/// reveal speed.
///
/// Pair with `.accessibilityLabel(...)` so VoiceOver gets a specific
/// label even though `.help` seeds an accessibility hint of its own.
struct PolishedTooltip: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.help(text)
    }
}

extension View {
    /// Tooltip helper. See `PolishedTooltip` for context. Pair with
    /// `.accessibilityLabel(...)` to stay explicit about VoiceOver.
    func polishedTooltip(_ text: String) -> some View {
        modifier(PolishedTooltip(text: text))
    }
}
