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

    @FocusState private var editorFocused: Bool

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

            if viewModel.notesText.isEmpty {
                placeholder
                    .padding(.horizontal, DesignSystem.Spacing.md + 5)
                    .padding(.vertical, DesignSystem.Spacing.sm + 8)
                    .allowsHitTesting(false)
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
    }
}
