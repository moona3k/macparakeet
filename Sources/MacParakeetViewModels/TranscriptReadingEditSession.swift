import Foundation
import MacParakeetCore
import Observation

/// Owns drafts independently of the lifetime of lazily realized editor rows.
@MainActor
@Observable
public final class TranscriptReadingEditSession {
    public let passages: [TranscriptReadingPassage]
    public private(set) var hasChanges: Bool
    @ObservationIgnored private var changedPassageCount: Int

    public init(drafts: [TranscriptReadingDraft]) {
        passages = drafts.map(TranscriptReadingPassage.init)
        changedPassageCount = passages.filter(\.hasChanges).count
        hasChanges = changedPassageCount > 0
        for passage in passages {
            passage.onChangeStatus = { [weak self] changed in
                guard let self else { return }
                changedPassageCount += changed ? 1 : -1
                let next = changedPassageCount > 0
                if hasChanges != next { hasChanges = next }
            }
        }
    }

    /// Build the full, ordered correction once, when the user saves.
    public func command() -> SpeakerCorrectionCommand? {
        TranscriptReadingEdit.command(for: passages.map(\.draft))
    }
}

/// Observation stops at the passage being typed into. Only clean/dirty
/// transitions reach the session, so Done does not rescan the transcript.
@MainActor
@Observable
public final class TranscriptReadingPassage: Identifiable {
    public let id: UUID
    public var text: String { didSet { updateChangeStatus() } }
    public var removed: Bool { didSet { updateChangeStatus() } }
    private let original: TranscriptReadingDraft
    @ObservationIgnored fileprivate var hasChanges: Bool
    @ObservationIgnored fileprivate var onChangeStatus: ((Bool) -> Void)?

    fileprivate init(_ draft: TranscriptReadingDraft) {
        id = draft.id
        original = draft
        text = draft.text
        removed = draft.removed
        hasChanges = TranscriptReadingEdit.command(for: [draft]) != nil
    }

    public var draft: TranscriptReadingDraft {
        var result = original
        result.text = text
        result.removed = removed
        return result
    }

    private func updateChangeStatus() {
        let next = TranscriptReadingEdit.command(for: [draft]) != nil
        guard next != hasChanges else { return }
        hasChanges = next
        onChangeStatus?(next)
    }
}
