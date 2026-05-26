import SwiftUI
import MacParakeetCore

/// Inline pill-bar for selecting a per-feature engine override. Renders
/// "Use default" plus one pill per engine; the selected pill is highlighted.
/// Used by `SpeechEngineCard`'s per-feature overrides section.
struct EnginePillBar: View {
    let label: String
    @Binding var selection: FeatureEngineSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            HStack(spacing: 6) {
                pill(label: "Use default", isSelected: selection == .global) {
                    selection = .global
                }
                ForEach(SpeechEnginePreference.allCases, id: \.self) { engine in
                    pill(label: engine.displayName, isSelected: selection == .specific(engine)) {
                        selection = .specific(engine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(isSelected
                      ? DesignSystem.Typography.caption.weight(.semibold)
                      : DesignSystem.Typography.caption)
                .foregroundStyle(isSelected
                                 ? DesignSystem.Colors.onAccent
                                 : DesignSystem.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? DesignSystem.Colors.accent
                              : DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.clear : DesignSystem.Colors.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
