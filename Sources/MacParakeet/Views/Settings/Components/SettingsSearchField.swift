import SwiftUI
import AppKit

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
                    // Empty query: yield focus rather than sit lit with a
                    // caret. (Previously returned `.ignored` and stayed
                    // focused — contradicting this field's own doc comment.)
                    isFocused = false
                    return .handled
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
        // The bare `TextField` only takes focus when its (potentially tiny)
        // text area is clicked. Make the whole capsule — icon and padding
        // included — a focus target so the control is never a dead pill.
        .contentShape(Capsule())
        .onTapGesture {
            isFocused = true
        }
        // Keep the field from auto-grabbing focus when Settings appears, so
        // the panel opens calm instead of with a lit search box + caret.
        .background(InitialFocusBlocker())
        .animation(DesignSystem.Animation.hoverTransition, value: isFocused)
    }
}

/// Stops the enclosing window from auto-selecting this search field as its
/// initial first responder, so Settings opens with nothing focused. Covers two
/// cases:
/// - **Window not yet key:** pointing `initialFirstResponder` at a non-editable
///   view means the field isn't chosen when the window first becomes key.
/// - **Window already key (e.g. switching tabs):** AppKit may have already made
///   the shared field editor first responder, so clear it once on appear.
///
/// Only fires at mount, so it never fights a later, user-initiated focus
/// (clicking the field or ⌘F).
private struct InitialFocusBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockerView: NSView {
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                // The field editor backing a focused NSTextField is an
                // NSTextView; if it grabbed focus on mount, release it.
                if window.firstResponder is NSTextView {
                    window.makeFirstResponder(nil)
                }
            }
        }
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
