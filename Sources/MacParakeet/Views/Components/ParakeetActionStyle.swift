import SwiftUI

/// Semantic role for an actionable control. Apply via `.parakeetAction(_:)`.
///
/// Replaces ad-hoc `.buttonStyle(.bordered) + .tint(...)` composition with a
/// single intent-carrying modifier. The role drives visual treatment so
/// callsites carry meaning, not styling primitives.
enum ParakeetActionRole {
    /// Primary action. Brand coral.
    case primary
    /// The single highest-priority primary CTA on a surface. Brand coral.
    case primaryProminent
    /// Default action weight. System label color, neutral chrome.
    case secondary
    /// Irreversible action. System destructive red.
    /// Pair with `Button(role: .destructive)` to also carry VoiceOver semantics.
    case destructive
    /// Highest-priority irreversible action. System destructive red.
    /// Pair with `Button(role: .destructive)` to also carry VoiceOver semantics.
    case destructiveProminent
    /// Lower visual weight than `.secondary`. Borderless, secondary label
    /// color. For non-essential actions in dense rows or as inline links.
    case subtle
}

extension View {
    /// Apply a semantic action role to a control.
    @ViewBuilder
    func parakeetAction(_ role: ParakeetActionRole) -> some View {
        switch role {
        case .primary:
            self.buttonStyle(.bordered)
                .tint(DesignSystem.Colors.accent)
        case .primaryProminent:
            self.buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
        case .secondary:
            self.buttonStyle(.bordered)
                .tint(DesignSystem.Colors.tintNeutral)
        case .destructive:
            self.buttonStyle(.bordered)
                .tint(DesignSystem.Colors.errorRed)
        case .destructiveProminent:
            self.buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.errorRed)
        case .subtle:
            self.buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    /// Brand-consistent switch styling. Use for every `Toggle` styled as a
    /// switch so on-state reads coral app-wide rather than the system blue that
    /// an untinted `.switch` falls back to. Keeps sibling toggles consistent.
    func parakeetSwitch() -> some View {
        self.toggleStyle(.switch)
            .tint(DesignSystem.Colors.accent)
    }
}
