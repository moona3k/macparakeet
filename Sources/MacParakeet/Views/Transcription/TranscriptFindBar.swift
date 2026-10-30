import SwiftUI

/// Replace controls for `TranscriptFindBar`. The parent passes `nil` when the
/// transcript cannot be edited segment by segment; the bar then shows no
/// replace affordance at all.
struct TranscriptFindReplaceControls {
    var text: Binding<String>
    var isExpanded: Binding<Bool>
    /// True while a replacement is being saved.
    var isBusy: Bool
    /// Outcome of the last replacement, such as "Replaced 12". Shown in the
    /// counter once no matches remain.
    var status: String?
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    /// Undoes the last replacement while it is still the latest edit.
    var onUndo: (() -> Void)?
}

/// In-transcript find bar (Transcript Detail Refresh / U2). A compact capsule
/// that floats over the transcript reading pane: type to highlight matches,
/// step through them with Return / ⇧Return, the chevrons, or ⌘G / ⇧⌘G, and
/// dismiss with Esc or the close button. Where the transcript is editable, a
/// disclosure reveals a replace row (⌥⌘F opens the bar with it shown).
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
    var replace: TranscriptFindReplaceControls?
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void

    @FocusState private var isReplaceFocused: Bool

    private var canNavigate: Bool { position != nil }
    private var isReplaceExpanded: Bool { replace?.isExpanded.wrappedValue ?? false }
    private var isAnyFieldFocused: Bool { isFocused || isReplaceFocused }

    private static let disclosureWidth: CGFloat = 14
    private static let leadingIconWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            findRow
            if let replace, isReplaceExpanded {
                replaceRow(replace)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 8)
        .background(barShape.fill(DesignSystem.Colors.surface))
        .overlay(
            barShape.strokeBorder(
                isAnyFieldFocused ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border.opacity(0.5),
                lineWidth: isAnyFieldFocused ? 1 : 0.5
            )
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .contentShape(barShape)
        .onTapGesture { if !isAnyFieldFocused { isFocused = true } }
        .animation(DesignSystem.Animation.hoverTransition, value: isAnyFieldFocused)
    }

    /// A capsule while collapsed; the same radius reads as a rounded panel
    /// once the replace row is shown.
    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var findRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let replace {
                disclosure(replace)
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.leadingIconWidth)
                .accessibilityHidden(true)

            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($isFocused)
                .frame(minWidth: 130, maxWidth: 200)
                // Enter steps to the next match and Shift-Enter to the
                // previous one, like a browser find bar.
                .onSubmit(onNext)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift),
                        press.modifiers.isDisjoint(with: [.command, .option, .control])
                    else { return .ignored }
                    onPrev()
                    return .handled
                }
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
            .help("Close find (Esc)")
            .accessibilityLabel("Close find")
        }
    }

    private func disclosure(_ replace: TranscriptFindReplaceControls) -> some View {
        Button {
            replace.isExpanded.wrappedValue.toggle()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .rotationEffect(.degrees(isReplaceExpanded ? 90 : 0))
                .frame(width: Self.disclosureWidth, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isReplaceExpanded ? "Hide replace" : "Replace (⌥⌘F)")
        .accessibilityLabel(isReplaceExpanded ? "Hide replace" : "Show replace")
    }

    private func replaceRow(_ replace: TranscriptFindReplaceControls) -> some View {
        let canReplace = canNavigate && !replace.isBusy
        return HStack(spacing: DesignSystem.Spacing.sm) {
            // Line the replace field up under the find field.
            Color.clear.frame(width: Self.disclosureWidth + DesignSystem.Spacing.sm + Self.leadingIconWidth, height: 1)

            TextField("Replace with", text: replace.text)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($isReplaceFocused)
                .frame(minWidth: 130, maxWidth: 200)
                // Enter replaces the current match and moves to the next one.
                .onSubmit { if canReplace { replace.onReplace() } }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            Button("Replace", action: replace.onReplace)
                .parakeetAction(.secondary)
                .controlSize(.small)
                .disabled(!canReplace)
                .help("Replace this match and go to the next one")

            Button("Replace All", action: replace.onReplaceAll)
                .parakeetAction(.secondary)
                .controlSize(.small)
                .disabled(!canReplace)
                .help("Replace every match in this transcript")

            if replace.isBusy {
                ProgressView().controlSize(.small)
            } else if let onUndo = replace.onUndo {
                Button("Undo", action: onUndo)
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                    .help("Undo the last replacement")
            }
        }
    }

    @ViewBuilder
    private var counter: some View {
        ZStack(alignment: .trailing) {
            Text("No results")
                .hidden()
            Text("00000 of 00000")
                .hidden()

            if let position {
                Text("\(position.current) of \(position.total)")
            } else if let status = replace?.status {
                Text(status)
            } else if hasQueryButNoMatches {
                Text("No results")
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
