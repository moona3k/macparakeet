import AppKit
import MacParakeetCore
import SwiftUI

/// Trigger button + popover wrapper used inline in settings rows.
///
/// The button shows the current selection's English label and a chevron.
/// Tapping opens the popover; commit dismisses it. Disabled state matches the
/// segmented engine picker so the row visually mutes when Whisper is inactive.
struct LanguagePickerButton: View {
    @Binding var selection: String
    var isDisabled: Bool

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(WhisperLanguageCatalog.displayLabel(for: selection))
                    .font(DesignSystem.Typography.bodySmall)
                    .lineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(width: LanguagePickerLayout.buttonWidth)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .accessibilityLabel("Whisper language: \(WhisperLanguageCatalog.displayLabel(for: selection))")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            LanguagePickerPopover(selection: $selection) {
                isShowing = false
            }
        }
    }
}

/// Searchable popover for the full Whisper language list.
///
/// Layout: search field (autofocused) → divider → scrollable list with
/// "Auto-detect" pinned at top, separated from the alphabetical full list.
/// Selection commits and dismisses on click or ⏎; Esc dismisses (handled by
/// the popover itself). Keyboard nav: ↑↓ moves the highlight, hover syncs it
/// to whichever row the cursor is over so the two input modes don't fight.
struct LanguagePickerPopover: View {
    @Binding var selection: String
    var onCommit: () -> Void

    @State private var query = ""
    @State private var highlightedCode: String
    @FocusState private var searchFocused: Bool

    init(selection: Binding<String>, onCommit: @escaping () -> Void) {
        self._selection = selection
        self.onCommit = onCommit
        // Seed highlight with the current selection so opening the popover
        // immediately points at the active language.
        self._highlightedCode = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        .frame(width: LanguagePickerLayout.popoverWidth)
        .onAppear { searchFocused = true }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("Search languages", text: $query)
                .font(DesignSystem.Typography.bodySmall)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    // MARK: - List

    /// Visible rows after applying `query`. `auto` is included whenever the
    /// query is empty or the typed text plausibly matches "auto".
    private var visibleRows: [WhisperLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let results = WhisperLanguageCatalog.search(query)
        let includesAuto = trimmed.isEmpty
            || "auto".contains(trimmed)
            || "auto-detect".contains(trimmed)
        return includesAuto ? [WhisperLanguageCatalog.auto] + results : results
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = visibleRows
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.code) { index, language in
                            row(for: language)
                                .id(language.code)
                            if index == 0 && language.code == WhisperLanguageCatalog.autoCode && rows.count > 1 {
                                Divider().padding(.horizontal, DesignSystem.Spacing.sm)
                            }
                        }
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
            .frame(maxHeight: LanguagePickerLayout.listMaxHeight)
            .background(KeyEventCatcher(
                onUp: { moveHighlight(by: -1, proxy: proxy) },
                onDown: { moveHighlight(by: 1, proxy: proxy) },
                onReturn: { commitHighlighted() }
            ))
            .onAppear {
                proxy.scrollTo(highlightedCode, anchor: .center)
            }
            .onChange(of: query) { _, _ in
                if let first = visibleRows.first {
                    highlightedCode = first.code
                    proxy.scrollTo(first.code, anchor: .top)
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No matches")
            .font(DesignSystem.Typography.bodySmall)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.lg)
    }

    // MARK: - Row

    private func row(for language: WhisperLanguage) -> some View {
        let isSelected = language.code == selection
        let isHighlighted = language.code == highlightedCode

        return Button {
            commit(language.code)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .clear)
                    .frame(width: LanguagePickerLayout.checkmarkWidth)
                    .accessibilityHidden(true)
                Text(language.englishName)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                if !language.nativeName.isEmpty
                    && language.nativeName != language.englishName {
                    Text(language.nativeName)
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius, style: .continuous)
                    .fill(isHighlighted ? DesignSystem.Colors.accent.opacity(LanguagePickerLayout.highlightOpacity) : Color.clear)
            )
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            if hovering {
                highlightedCode = language.code
            }
        }
    }

    // MARK: - Keyboard nav

    private func moveHighlight(by delta: Int, proxy: ScrollViewProxy) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(where: { $0.code == highlightedCode }) ?? 0
        let newIndex = max(0, min(rows.count - 1, currentIndex + delta))
        let code = rows[newIndex].code
        highlightedCode = code
        proxy.scrollTo(code, anchor: nil)
    }

    private func commitHighlighted() {
        if visibleRows.contains(where: { $0.code == highlightedCode }) {
            commit(highlightedCode)
        } else if let first = visibleRows.first {
            commit(first.code)
        }
    }

    private func commit(_ code: String) {
        selection = code
        onCommit()
    }

    private func accessibilityLabel(for language: WhisperLanguage) -> String {
        if language.nativeName.isEmpty || language.nativeName == language.englishName {
            return language.englishName
        }
        return "\(language.englishName), \(language.nativeName)"
    }
}

private enum LanguagePickerLayout {
    static let buttonWidth: CGFloat = 160
    static let popoverWidth: CGFloat = 280
    static let listMaxHeight: CGFloat = 320
    static let checkmarkWidth: CGFloat = 12
    static let highlightOpacity = 0.18
}

// MARK: - Key event catcher
//
// `.onKeyPress` only fires on the focused responder, which is the search
// `TextField`. Plumbing arrow keys through the text field is unreliable —
// arrows move the caret instead — so we drop a tiny `NSView` that lives
// alongside the list and intercepts ↑/↓/↩ at the AppKit responder chain. It
// never takes first responder away from the search field.

private struct KeyEventCatcher: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
    }

    final class CatcherView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onReturn: (() -> Void)?

        // `deinit` is nonisolated; the AppKit monitor is installed and removed
        // on the main thread during the view's lifetime.
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    guard !self.shouldPassThrough(event, in: window) else {
                        return event
                    }
                    switch event.keyCode {
                    case KeyCode.arrowDown:
                        self.onDown?()
                        return nil
                    case KeyCode.arrowUp:
                        self.onUp?()
                        return nil
                    case KeyCode.returnKey, KeyCode.keypadEnter:
                        self.onReturn?()
                        return nil
                    default:
                        return event
                    }
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldPassThrough(_ event: NSEvent, in window: NSWindow) -> Bool {
            if !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                return true
            }
            if let textView = window.firstResponder as? NSTextView, textView.hasMarkedText() {
                return true
            }
            if let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView, fieldEditor.hasMarkedText() {
                return true
            }
            return false
        }

        private enum KeyCode {
            static let arrowDown: UInt16 = 125
            static let arrowUp: UInt16 = 126
            static let returnKey: UInt16 = 36
            static let keypadEnter: UInt16 = 76
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
