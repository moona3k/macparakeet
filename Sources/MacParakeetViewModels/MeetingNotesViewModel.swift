import Foundation
import OSLog
import SwiftUI

/// View model for the live meeting notepad pane (ADR-020 §1, §8, §11).
///
/// Owns the user-typed notes during a meeting recording and routes every
/// change through a 250 ms idle debounce to the `persist` callback (which
/// the flow coordinator wires to `MeetingRecordingService.updateNotes(_:)`).
///
/// "Notes are user-authored only" is enforced at the type level: `notesText`
/// is `private(set)`, the only mutator the SwiftUI view sees is `notesBinding`
/// (which routes through `applyEdit(_:)`), and the only other write paths are
/// `restore(_:)` (called from recovery at launch) and `reset()` (called when
/// the panel is disposed). Adding a programmatic insertion path (e.g. for an
/// "insert AI response into notes" affordance) would require a new public
/// mutator — visible in code review and a deliberate violation of the
/// memo→summary invariant.
@MainActor
@Observable
public final class MeetingNotesViewModel {
    /// Idle window before persisting a change. ADR-020 §8.
    public static let debounceInterval: Duration = .milliseconds(250)

    /// Soft cap that triggers the inline footer warning in the editor view.
    /// ADR-020 §3 — notes themselves are not truncated; the warning lets the
    /// user know summary generation will start trimming around 8,000 words.
    public static let softCapWarningWordCount = 7_500

    /// User-typed notes. Read-only externally; mutated only by the editor
    /// binding, `restore(_:)`, `reset()`, and the slash-command insertion
    /// path (which is itself user-driven — no AI in the loop, ADR-020 §11).
    public private(set) var notesText: String = ""

    // MARK: - Slash menu state (ADR-020 §7)

    /// `true` while the user is typing a slash-command token at the end
    /// of `notesText`. The view watches this to render the in-view overlay.
    public private(set) var isSlashMenuActive: Bool = false

    /// The query the user has typed after the leading `/`. Empty string
    /// means the menu was just opened by typing `/` alone.
    public private(set) var slashQuery: String = ""

    /// Currently highlighted command in the menu — driven by ↑/↓ key
    /// handling on the editor (the overlay never owns first responder
    /// per ADR-020 §7 NSPanel pitfalls). Always a valid index into
    /// `matchingCommands` while the menu is active.
    public private(set) var slashSelection: Int = 0

    /// Filtered command list for the current `slashQuery`. Empty when
    /// no command's trigger starts with the typed query (which auto-
    /// dismisses the menu in `updateSlashMenuState`).
    public var matchingCommands: [SlashCommand] {
        guard isSlashMenuActive else { return [] }
        if slashQuery.isEmpty { return Self.allCommands }
        let q = slashQuery.lowercased()
        return Self.allCommands.filter { $0.trigger.dropFirst().lowercased().hasPrefix(q) }
    }

    /// `true` once the user has crossed the soft-cap warning threshold. The
    /// view uses this to surface a small footer notice without blocking input.
    public var isApproachingSoftCap: Bool {
        wordCount >= Self.softCapWarningWordCount
    }

    /// Word count derived from `notesText`. Cached as a stored property
    /// and refreshed whenever `notesText` changes (via `applyEdit`,
    /// `restore`, `reset`, or slash-command acceptance) — used by the
    /// tab-state-bearing label (`Notes · 24w`) per panel render and by
    /// `isApproachingSoftCap` per keystroke. With notes that can grow to
    /// 8,000+ words and SwiftUI re-rendering on every observable change,
    /// re-walking the string on every read would be real main-thread cost.
    public private(set) var wordCount: Int = 0

    /// SwiftUI `TextEditor` binds to this. The setter both applies the new
    /// value and queues a debounced persist task.
    public var notesBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.notesText ?? "" },
            set: { [weak self] newValue in self?.applyEdit(newValue) }
        )
    }

    private var persist: ((String) async -> Void)?
    private var debounceTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "MeetingNotesViewModel")

    public init() {}

    /// Wire the persistence target. Called once per recording session by the
    /// flow coordinator. Subsequent calls replace the target (used when a
    /// session ends and a new one begins on the same VM instance, though in
    /// practice the panel VM tree is recreated per session). Cancels any
    /// in-flight debounce so a queued write from the previous session can't
    /// fire against the new persist target.
    public func bindPersist(_ persist: @escaping (String) async -> Void) {
        debounceTask?.cancel()
        debounceTask = nil
        self.persist = persist
    }

    /// Restore notes into a live VM. Reserved for a future mid-session-resume
    /// path; the v0.6 hard-crash recovery path writes notes directly to
    /// `Transcription.userNotes` via `MeetingRecordingRecoveryService` and
    /// never touches the live VM, so no production caller invokes this today.
    /// Kept for symmetry with `reset()` and to give the future resume feature
    /// a documented entry point.
    public func restore(_ notes: String?) {
        notesText = notes ?? ""
        wordCount = Self.wordCount(for: notesText)
    }

    /// Cancel any pending debounce and persist whatever was last typed
    /// immediately. Called at finalize so notes typed in the last < 250 ms
    /// before stop are not lost.
    public func commit() async {
        debounceTask?.cancel()
        debounceTask = nil
        await persist?(notesText)
    }

    /// Drop any pending writes and clear local state. Called when the panel
    /// is disposed (no recording active).
    public func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        notesText = ""
        wordCount = 0
        dismissSlashMenu()
    }

    // MARK: - Slash commands (ADR-020 §7)

    /// Move the highlighted command in the slash menu by `delta` positions.
    /// Wraps via clamping (no rotational wrap-around — typing past the ends
    /// quietly stops at the bounds, matching native macOS menu behavior).
    public func moveSlashSelection(by delta: Int) {
        let count = matchingCommands.count
        guard count > 0 else { return }
        let next = slashSelection + delta
        slashSelection = max(0, min(count - 1, next))
    }

    /// Mouse-driven selection. The view layer calls this when a row is
    /// clicked; the index is clamped against the current `matchingCommands`
    /// so a stale tap can't push the selection out of bounds.
    public func selectSlashCommand(at index: Int) {
        let count = matchingCommands.count
        guard count > 0 else { return }
        slashSelection = max(0, min(count - 1, index))
    }

    /// Accept the currently-highlighted command. Replaces the trailing
    /// `/word` token in `notesText` with the command's expanded insertion
    /// (literal text or formatted timestamp), dismisses the menu, and
    /// schedules a persist debounce so the new text lands on the lock file.
    /// `elapsedSeconds` is the meeting's current elapsed time, supplied by
    /// the view layer which has access to `MeetingRecordingPanelViewModel`.
    public func acceptSlashCommand(elapsedSeconds: Int) {
        guard isSlashMenuActive else { return }
        let matches = matchingCommands
        guard slashSelection >= 0, slashSelection < matches.count else { return }
        let command = matches[slashSelection]

        // Strip the trailing slash-token from notesText.
        let trailingTokenLength = Self.trailingSlashToken(in: notesText)?.count ?? 0
        guard trailingTokenLength > 0 else {
            // Defensive: token disappeared between the user pressing Return
            // and us reaching here. Just dismiss; don't insert.
            dismissSlashMenu()
            return
        }
        let prefix = notesText.dropLast(trailingTokenLength)
        let insertion = command.expandedInsertion(elapsedSeconds: elapsedSeconds)

        // Direct write — bypasses the binding setter on purpose so the
        // view's TextEditor binding observes the final post-substitution
        // text in one tick (no flicker of the typed `/word`).
        notesText = String(prefix) + insertion
        wordCount = Self.wordCount(for: notesText)
        dismissSlashMenu()
        scheduleDebounce()
    }

    /// Close the slash menu without inserting anything (Esc, click-outside,
    /// space/whitespace, or the user backspacing past the leading `/`).
    public func dismissSlashMenu() {
        isSlashMenuActive = false
        slashQuery = ""
        slashSelection = 0
    }

    private func applyEdit(_ newValue: String) {
        notesText = newValue
        wordCount = Self.wordCount(for: newValue)
        updateSlashMenuState(for: newValue)
        scheduleDebounce()
    }

    /// Re-evaluate the slash menu state against the current text. Detection
    /// is purely text-based — the SwiftUI `TextEditor` doesn't expose the
    /// caret position via its binding, so we read the trailing token (the
    /// substring from the end back to the most recent whitespace) and treat
    /// "user is typing at the end of the text" as the supported case.
    /// Mid-text slash insertion is intentionally not supported in v0.6 —
    /// the ADR §7 calls out an `NSTextView` wrapper as the fallback if
    /// users actually need it.
    private func updateSlashMenuState(for text: String) {
        guard let token = Self.trailingSlashToken(in: text) else {
            if isSlashMenuActive { dismissSlashMenu() }
            return
        }
        // The "/" must be at the start of the text or preceded by whitespace
        // (newline counts as whitespace). Otherwise this is a mid-word slash
        // (URL fragment, math, regex…) and shouldn't trigger the menu.
        let slashIndex = text.index(text.endIndex, offsetBy: -token.count)
        if slashIndex > text.startIndex {
            let prev = text[text.index(before: slashIndex)]
            if !prev.isWhitespace {
                if isSlashMenuActive { dismissSlashMenu() }
                return
            }
        }

        let query = String(token.dropFirst())
        // If the query no longer matches any command, dismiss — typing
        // gibberish past the end of "/decision" shouldn't keep an empty
        // menu open just because the leading "/" is still there.
        let candidateMatches = Self.allCommands.filter {
            query.isEmpty || $0.trigger.dropFirst().lowercased().hasPrefix(query.lowercased())
        }
        if candidateMatches.isEmpty {
            if isSlashMenuActive { dismissSlashMenu() }
            return
        }

        isSlashMenuActive = true
        slashQuery = query
        if slashSelection >= candidateMatches.count {
            slashSelection = max(0, candidateMatches.count - 1)
        }
    }

    /// Returns the trailing slash-prefixed token (e.g., `/act`), or `nil`
    /// if the text doesn't end with one. Token boundary is whitespace.
    /// Visible to tests via `@testable`.
    static func trailingSlashToken(in text: String) -> String? {
        let trailing = String(text.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        return trailing.hasPrefix("/") ? trailing : nil
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let snapshot = notesText
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            await self.persist?(snapshot)
        }
    }

    /// Counts whitespace-delimited words without allocating a Substring array.
    /// Called on every keystroke from `applyEdit`; a `split(whereSeparator:)`
    /// implementation materializes one Substring per word — at 8,000 words
    /// that is 8,000 heap allocations per keystroke on `@MainActor`, which
    /// produces visible input latency on slower Macs.
    private static func wordCount(for text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// The full slash-command catalog, in display order. ADR-020 §7 locks
    /// the v0.6 set to exactly three; expansion is Future Work.
    public static let allCommands: [SlashCommand] = [
        SlashCommand(
            trigger: "/action",
            label: "Action item",
            description: "Insert **Action:** marker",
            insertion: .literal("**Action:** ")
        ),
        SlashCommand(
            trigger: "/decision",
            label: "Decision",
            description: "Insert **Decision:** marker",
            insertion: .literal("**Decision:** ")
        ),
        SlashCommand(
            trigger: "/now",
            label: "Timestamp",
            description: "Insert current meeting time",
            insertion: .timestamp
        ),
    ]
}

/// One entry in the slash menu (ADR-020 §7). Bold-asterisk markers are
/// plaintext during the meeting; post-meeting markdown rendering (Future
/// Work) will surface them as headings/labels.
public struct SlashCommand: Equatable, Sendable {
    public let trigger: String       // "/action"
    public let label: String         // "Action item"
    public let description: String   // tooltip / secondary text
    public let insertion: SlashInsertion

    public init(trigger: String, label: String, description: String, insertion: SlashInsertion) {
        self.trigger = trigger
        self.label = label
        self.description = description
        self.insertion = insertion
    }

    /// The literal text that replaces the typed `/word` token. For the
    /// `.timestamp` insertion the elapsed-seconds is formatted as `[M:SS]`
    /// to match the timestamp shape used in the live transcript preview
    /// (`MeetingRecordingFlowCoordinator.format(milliseconds:)`).
    public func expandedInsertion(elapsedSeconds: Int) -> String {
        switch insertion {
        case .literal(let s):
            return s
        case .timestamp:
            let safe = max(0, elapsedSeconds)
            let m = safe / 60
            let s = safe % 60
            return String(format: "[%d:%02d] ", m, s)
        }
    }
}

public enum SlashInsertion: Equatable, Sendable {
    case literal(String)
    case timestamp
}
