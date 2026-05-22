import SwiftUI
import AppKit

// Shared building blocks for the Vocabulary surfaces (the Vocabulary tab and
// the Custom Words / Text Snippets sheets). These replace the old "every
// subsection is its own icon-tiled card" pattern with lighter, list-native
// primitives: one grouped surface per collection, plain section headers, and
// fields whose focus reads coral instead of the system blue ring.

// MARK: - Layout metrics

/// Layout metrics shared across the Vocabulary management sheets.
enum VocabMetrics {
    /// Leading inset for in-group row dividers so they begin under the row's
    /// text — clearing the small toggle plus the row's leading padding + gap.
    static let rowDividerInset: CGFloat = 52
}

// MARK: - Styled text field

/// A text field with a coral focus ring instead of the system blue one, an
/// optional leading glyph (for search), and an optional clear button.
///
/// Focus can be driven internally (default) or bound to an external
/// `@FocusState` so callers can focus it programmatically — e.g. an empty
/// state's "Add your first…" button focusing the add form.
struct ParakeetTextField: View {
    let placeholder: String
    @Binding var text: String
    var leadingSystemImage: String? = nil
    var showsClearButton: Bool = false
    var onSubmit: (() -> Void)? = nil
    var externalFocus: FocusState<Bool>.Binding? = nil

    @FocusState private var localFocus: Bool

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $localFocus
    }

    private var isFocused: Bool {
        externalFocus?.wrappedValue ?? localFocus
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .tint(DesignSystem.Colors.accent)
                .focused(focusBinding)
                .onSubmit { onSubmit?() }

            if showsClearButton && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(
                    isFocused
                        ? DesignSystem.Colors.accent.opacity(0.7)
                        : DesignSystem.Colors.border.opacity(0.7),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        )
        .animation(DesignSystem.Animation.hoverTransition, value: isFocused)
    }
}

// MARK: - Section header

/// A plain section header — uppercase label with an optional trailing accessory
/// (typically a contextual count) and an optional one-line subtitle. Replaces
/// the heavy icon-tile card header for content that doesn't warrant a card.
struct VocabSectionHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: DesignSystem.Spacing.sm)
                trailing
            }
            if let subtitle {
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension VocabSectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Grouped collection surface

extension View {
    /// Wraps a vertical stack of rows in one grouped "collection" surface —
    /// subtle fill, hairline border, rounded and clipped so per-row hover fills
    /// stay inside the corners. One surface per collection, instead of one card
    /// per row or a card around everything.
    func vocabGroup() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
            )
    }
}

// MARK: - Sheet header

/// Title + subtitle on the left, a neutral Done button on the right. Gives the
/// management sheets a real header bar so Done is sheet-level chrome rather than
/// a second coral button buried mid-content.
struct VocabSheetHeader: View {
    let title: String
    let subtitle: String
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.pageTitle)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Button("Done", action: onDone)
                .parakeetAction(.secondary)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}

// MARK: - Delete icon button

/// A trash button that rests in the secondary color and warms to red on hover,
/// giving the destructive affordance a clear, contained signal.
struct DeleteIconButton: View {
    let helpText: String
    let accessibilityName: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? DesignSystem.Colors.errorRed : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityName)
    }
}

// MARK: - Sheet auto-focus suppressor

/// Stops a freshly presented `.sheet` from auto-focusing its first text field.
/// macOS makes the first text field the window's initial first responder;
/// pointing `initialFirstResponder` at a non-editable view instead means the
/// sheet opens with nothing focused — no caret, no flash. Drop a zero-size
/// instance inside the sheet's content.
struct SheetAutoFocusSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockerView: NSView {
        override var acceptsFirstResponder: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }
}
