import Foundation

enum SpeakerRenameAccessibility {
    static let overviewToggleIdentifier = "transcript.speakerOverview.toggle"
    static let overviewToggleHint = "Shows speaker labels and rename controls."
    static let speakerNameFieldLabel = "Speaker name"
    static let speakerNameFieldHint = "Press Return or move focus away to save. Press Escape to cancel."
    static let renameButtonHint = "Edits this speaker label for this meeting only."

    static func overviewToggleLabel(isExpanded: Bool) -> String {
        isExpanded ? "Collapse speaker overview" : "Expand speaker overview"
    }

    static func renameButtonLabel(for speakerLabel: String) -> String {
        "Rename \(speakerLabel)"
    }

    static func renameButtonIdentifier(contextID: String) -> String {
        "transcript.speaker.rename.\(contextID)"
    }

    static func speakerNameFieldIdentifier(contextID: String) -> String {
        "transcript.speaker.name.\(contextID)"
    }

    static func renameButtonOpacity(isVisuallyRevealed: Bool) -> Double {
        isVisuallyRevealed ? 1 : 0
    }

    static func overviewRenameContextIdentifier(for speakerID: String) -> String {
        "overview:\(speakerID)"
    }

    static func turnRenameContextIdentifier(
        speakerID: String,
        firstStartMs: Int?,
        duplicateOrdinal: Int
    ) -> String {
        let start = firstStartMs.map(String.init) ?? "none"
        return "turn:\(speakerID):\(start):\(duplicateOrdinal)"
    }
}
