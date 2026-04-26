import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Notes tab inside the live meeting panel — the primary "active" surface
/// during a recording (ADR-020 §1, §2). Plain-text scratchpad that auto-saves
/// onto the lock file via a 250 ms idle debounce; on finalize, the notes are
/// persisted onto the Transcription's `userNotes` column where the
/// "Memo-Steered Notes" prompt can pull them in to shape the summary.
///
/// "Notes are user-authored only" (ADR-020 §11): the only mutator wired up
/// here is the user's own keystrokes. There is intentionally no /ask insertion
/// path or "drop assistant reply into notes" affordance — that invariant is
/// what lets the summary template treat `{{userNotes}}` as a trustable signal
/// of what the user actually cares about.
struct LiveNotesPaneView: View {
    @Bindable var viewModel: MeetingNotesViewModel
    /// Elapsed meeting time, supplied by the parent panel. Used by the
    /// `/now` slash command to format the inserted timestamp. Defaults to
    /// 0 so previews and unit tests don't need to plumb it.
    var elapsedSeconds: Int = 0

    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            editor
            if viewModel.isApproachingSoftCap {
                Divider()
                softCapFooter
            }
        }
        .background(DesignSystem.Colors.background)
        .task {
            // Cursor lands in the editor the moment you switch to Notes — same
            // pattern as LiveAskPaneView. The tiny await lets the focus binding
            // wire up before we set it.
            try? await Task.sleep(for: .milliseconds(100))
            editorFocused = true
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: viewModel.notesBinding)
                .font(DesignSystem.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .focused($editorFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Slash-menu key handling — onKeyPress fires before TextEditor
                // sees the key, which is what lets us hijack ↑/↓/Return/Esc
                // while the menu is open without owning first responder
                // (ADR-020 §7 NSPanel pitfalls). Returns `.handled` only when
                // the menu is open and we acted on the key; otherwise falls
                // through so normal editing keys still work.
                .onKeyPress(.upArrow) {
                    guard viewModel.isSlashMenuActive else { return .ignored }
                    viewModel.moveSlashSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard viewModel.isSlashMenuActive else { return .ignored }
                    viewModel.moveSlashSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard viewModel.isSlashMenuActive else { return .ignored }
                    viewModel.acceptSlashCommand(elapsedSeconds: elapsedSeconds)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard viewModel.isSlashMenuActive else { return .ignored }
                    viewModel.dismissSlashMenu()
                    return .handled
                }

            if viewModel.notesText.isEmpty {
                placeholder
                    .padding(.horizontal, DesignSystem.Spacing.md + 5)
                    .padding(.vertical, DesignSystem.Spacing.sm + 8)
                    .allowsHitTesting(false)
            }

            // In-view ZStack overlay anchored to the editor frame
            // (ADR-020 §7) — never a SwiftUI .popover, since popovers
            // hosted inside KeylessPanel can clip, steal first responder,
            // and route arrow keys unpredictably.
            if viewModel.isSlashMenuActive {
                SlashMenuOverlay(viewModel: viewModel, elapsedSeconds: elapsedSeconds)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    // Honor System Settings → Accessibility → Display →
                    // Reduce Motion: opacity-only transition with no slide
                    // and no easing curve.
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15),
                               value: viewModel.matchingCommands)
                    .allowsHitTesting(true)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Take notes to shape the summary…")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.7))
            Text("Anything you type here steers the post-meeting summary. Headings, bullets, scratch — all welcome.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Anchored at the bottom of the editor frame, NOT a SwiftUI popover
    /// (ADR-020 §7 NSPanel pitfalls). Renders the matching commands as
    /// rows; the highlighted row tracks `viewModel.slashSelection` (driven
    /// by the editor's `.onKeyPress` handlers above). Click-to-select is
    /// also wired up so mouse users get the same affordance.
    private struct SlashMenuOverlay: View {
        @Bindable var viewModel: MeetingNotesViewModel
        var elapsedSeconds: Int

        var body: some View {
            let matches = viewModel.matchingCommands
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.trigger) { index, command in
                    SlashCommandRow(
                        command: command,
                        isHighlighted: index == viewModel.slashSelection,
                        onTap: {
                            viewModel.selectSlashCommand(at: index)
                            viewModel.acceptSlashCommand(elapsedSeconds: elapsedSeconds)
                        }
                    )
                    if index < matches.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignSystem.Colors.surfaceElevated)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
            )
            .frame(maxWidth: 260)
        }
    }

    private struct SlashCommandRow: View {
        let command: SlashCommand
        let isHighlighted: Bool
        let onTap: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(command.trigger)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(isHighlighted
                            ? DesignSystem.Colors.accent
                            : DesignSystem.Colors.textSecondary)
                    Text(command.label)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 8)
                    Text(command.description)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted
                            ? DesignSystem.Colors.accent.opacity(0.12)
                            : (isHovered ? DesignSystem.Colors.background.opacity(0.5) : .clear))
                )
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }

    /// Surfaces near the soft cap so users know summary generation will start
    /// trimming around 8,000 words (ADR-020 §3). Notes themselves are never
    /// truncated — the cap only applies to the prompt-assembly step.
    private var softCapFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .accessibilityHidden(true)
            Text("Summary will start trimming notes past ~8,000 words.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Spacer(minLength: 0)
            Text("\(viewModel.wordCount) words")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.8))
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .background(DesignSystem.Colors.cardBackground)
        // Combine into a single VoiceOver element so the warning + word
        // count are announced together when the footer appears (otherwise
        // VoiceOver users get no signal that the soft cap is active).
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notes approaching soft cap: \(viewModel.wordCount) words. Summary will start trimming past 8,000 words.")
    }
}
