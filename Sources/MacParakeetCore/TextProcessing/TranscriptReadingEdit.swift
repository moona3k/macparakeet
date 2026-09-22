import Foundation

/// One passage in the reading editor, before it is saved.
public struct TranscriptReadingDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: SpeakerCorrectionTarget
    public let originalText: String
    public var text: String
    public var removed: Bool

    public init(
        target: SpeakerCorrectionTarget,
        originalText: String,
        text: String,
        removed: Bool = false,
        id: UUID = UUID()
    ) {
        self.id = id
        self.target = target
        self.originalText = originalText
        self.text = text
        self.removed = removed
    }
}

/// Turns a reading session into one correction command.
public enum TranscriptReadingEdit {
    public static func changes(in drafts: [TranscriptReadingDraft]) -> [TranscriptTextChange] {
        drafts.compactMap { draft in
            if draft.removed || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .omit(target: draft.target)
            }
            let revised = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard revised != original else { return nil }
            return .replace(target: draft.target, text: revised)
        }
    }

    public static func command(for drafts: [TranscriptReadingDraft]) -> SpeakerCorrectionCommand? {
        let changes = changes(in: drafts)
        guard !changes.isEmpty else { return nil }
        return .reviseText(changes: changes)
    }
}
