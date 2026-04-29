import SwiftUI

/// Persistent top-of-panel search field used to find any setting.
///
/// Behavior:
/// - `⌘F` from anywhere in the Settings panel focuses the field.
/// - Typing filters results live (results-as-you-type — no Enter required).
/// - The clear button (`xmark.circle.fill`) appears once the query is
///   non-empty, blanks the field, and returns focus to it.
/// - `Esc` while focused with a non-empty query clears the query; with an
///   empty query, it yields focus and is treated as a no-op by the parent
///   (the panel itself does not dismiss).
///
/// Wiring is intentionally minimal in this primitive — it owns no search
/// index. The parent (`SettingsRootViewModel`) owns the query string and
/// reacts to changes.
struct SettingsSearchField: View {
    @Binding var query: String
    @FocusState.Binding var isFocused: Bool

    /// Mirrors `SettingsRootViewModel.isSearching` so the clear-button
    /// affordance and the flat-results UI activate on the same predicate.
    /// Trims `.whitespacesAndNewlines` to match both the root VM and
    /// `SettingsSearchIndex.matches` — without this, pasted whitespace
    /// or newline-only queries would show an X but nothing else would
    /// react.
    private var hasActiveQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($isFocused)
                .onKeyPress(.escape) {
                    if !query.isEmpty {
                        query = ""
                        return .handled
                    }
                    return .ignored
                }

            if hasActiveQuery {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isFocused ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border.opacity(0.4),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .animation(DesignSystem.Animation.hoverTransition, value: isFocused)
    }
}

#Preview("Light", traits: .fixedLayout(width: 480, height: 100)) {
    @Previewable @State var query = ""
    @FocusState var focus: Bool

    return SettingsSearchField(query: $query, isFocused: $focus)
        .padding()
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 480, height: 100)) {
    @Previewable @State var query = "hotkey"
    @FocusState var focus: Bool

    return SettingsSearchField(query: $query, isFocused: $focus)
        .padding()
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.dark)
}
