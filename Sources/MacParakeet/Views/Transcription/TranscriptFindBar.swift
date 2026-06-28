import SwiftUI

/// In-transcript find bar (Transcript Detail Refresh / U2). A compact capsule
/// that floats over the transcript reading pane: type to highlight matches,
/// step through them with the chevrons (or ⌘G / ⇧⌘G), and dismiss with Esc or
/// the close button.
///
/// Mirrors `SettingsSearchField`'s capsule styling and Esc/clear conventions
/// but adds match navigation and an "X of Y" counter. It owns no search index —
/// the parent feeds blocks to a `TranscriptFindModel` and reacts to the cursor.
struct TranscriptFindBar: View {
    @Binding var query: String
    @FocusState.Binding var isFocused: Bool
    /// 1-based "current of total"; `nil` while the query is empty or unmatched.
    let position: (current: Int, total: Int)?
    /// True when the query is non-empty but matched nothing.
    let hasQueryButNoMatches: Bool
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void

    private var canNavigate: Bool { position != nil }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($isFocused)
                .frame(minWidth: 130, maxWidth: 200)
                // Enter steps to the next match, like a browser find bar.
                .onSubmit(onNext)
                .onKeyPress(.escape) {
                    if !query.isEmpty {
                        query = ""
                        return .handled
                    }
                    onClose()
                    return .handled
                }

            counter

            Divider().frame(height: 16)

            navButton(icon: "chevron.up", label: "Previous match", help: "Previous match (⇧⌘G)", action: onPrev)
            navButton(icon: "chevron.down", label: "Next match", help: "Next match (⌘G)", action: onNext)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 8)
        .background(Capsule().fill(DesignSystem.Colors.surface))
        .overlay(
            Capsule().strokeBorder(
                isFocused ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border.opacity(0.5),
                lineWidth: isFocused ? 1 : 0.5
            )
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .animation(DesignSystem.Animation.hoverTransition, value: isFocused)
    }

    @ViewBuilder
    private var counter: some View {
        Group {
            if let position {
                Text("\(position.current) of \(position.total)")
            } else if hasQueryButNoMatches {
                Text("No results")
            } else {
                EmptyView()
            }
        }
        .font(DesignSystem.Typography.caption.monospacedDigit())
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .fixedSize()
    }

    private func navButton(icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(canNavigate ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .help(help)
        .accessibilityLabel(label)
    }
}
