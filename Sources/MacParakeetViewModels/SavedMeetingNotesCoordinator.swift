import Foundation

/// Owns unsaved meeting drafts beyond the lifetime of their detail views.
/// Each editor is permanently associated with one meeting, so a delayed or
/// failed save cannot leave another meeting's editor bound to the old row.
@MainActor
public final class SavedMeetingNotesCoordinator {
    public static let shared = SavedMeetingNotesCoordinator()

    private var drafts: [UUID: SavedMeetingNotesViewModel] = [:]
    private var quitTask: Task<Void, Never>?

    public init() {}

    /// Includes durable notes whose derived files still need a flush.
    public var hasUnsavedChanges: Bool { !drafts.isEmpty }

    /// One pending AppKit termination decision owns the eventual reply.
    public var isPreparingToQuit: Bool { quitTask != nil }

    public func editor(
        meetingID: UUID,
        text: String?,
        isMeetingDeleted: (() async throws -> Bool)? = nil,
        onFlush: (() async -> Void)? = nil,
        persist: @escaping (String) async -> Bool
    ) -> SavedMeetingNotesViewModel {
        if let draft = drafts[meetingID] {
            return draft
        }
        let editor = SavedMeetingNotesViewModel()
        editor.configure(
            meetingID: meetingID,
            text: text,
            isMeetingDeleted: isMeetingDeleted,
            onFlush: onFlush,
            persist: persist
        )
        editor.onUnsavedChangesChange = { [weak self, weak editor] in
            guard let self, let editor else { return }
            if editor.hasPendingFlush {
                self.drafts[meetingID] = editor
            } else if self.drafts[meetingID] === editor {
                self.drafts[meetingID] = nil
            }
        }
        return editor
    }

    /// Recheck after suspension: users can edit an existing draft or open a
    /// different meeting while an earlier write is completing.
    @discardableResult
    public func flushAll() async -> Bool {
        while !drafts.isEmpty {
            let pending = Array(drafts.values)
            var succeeded = true
            for draft in pending {
                if !(await draft.flush()) {
                    succeeded = false
                }
            }
            // Another concurrent flush may have retired the same deleted
            // draft while this pass was suspended in its existence check.
            if !succeeded { return drafts.isEmpty }
        }
        return true
    }

    /// Returns true when the application must defer its termination reply.
    /// The completion runs once, after every pending draft has been attempted.
    /// A failed save leaves the draft available to retry after cancelling quit.
    public func prepareToQuit(completion: @escaping (Bool) -> Void) -> Bool {
        guard quitTask == nil else { return true }
        guard hasUnsavedChanges else { return false }
        quitTask = Task { @MainActor in
            let saved = await flushAll()
            quitTask = nil
            completion(saved)
        }
        return true
    }
}
