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
    /// binding, `restore(_:)`, and `reset()`.
    public private(set) var notesText: String = ""

    /// `true` once the user has crossed the soft-cap warning threshold. The
    /// view uses this to surface a small footer notice without blocking input.
    public var isApproachingSoftCap: Bool {
        wordCount >= Self.softCapWarningWordCount
    }

    /// Word count derived from `notesText`. Used by the tab-state-bearing
    /// label in Phase 3 (`Notes · 24w`).
    public var wordCount: Int {
        Self.wordCount(for: notesText)
    }

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
    /// practice the panel VM tree is recreated per session).
    public func bindPersist(_ persist: @escaping (String) async -> Void) {
        self.persist = persist
    }

    /// Restore notes recovered from a crash (ADR-020 §9). Called at launch
    /// when `MeetingRecordingRecoveryService` finds notes in the lock file.
    /// Does not trigger the debounce — the recovery path persists notes
    /// onto the row directly via `Transcription.userNotes`.
    public func restore(_ notes: String?) {
        notesText = notes ?? ""
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
    }

    private func applyEdit(_ newValue: String) {
        notesText = newValue
        scheduleDebounce()
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

    private static func wordCount(for text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
