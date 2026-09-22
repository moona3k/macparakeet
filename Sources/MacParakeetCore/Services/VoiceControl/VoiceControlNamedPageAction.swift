import Foundation

/// Unique labeled page clicks that do not send, pay, or delete.
enum VoiceControlNamedPageAction {
    static func next(
        command: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]
    ) -> VoiceControlAction? {
        composeGmail(command: command, snapshot: snapshot, history: history)
    }

    private static func composeGmail(
        command: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]
    ) -> VoiceControlAction? {
        let lower = command.lowercased()
        guard VoiceControlWebDestination.matchingGoal(lower)?.id == "web:gmail" else { return nil }
        let wantsCompose = ["compose", "new email", "new mail", "write an email", "write a mail"].contains {
            lower.contains($0)
        }
        guard wantsCompose else { return nil }
        let gmail = VoiceControlWebDestination.named("web:gmail")
        guard let gmail, VoiceControlWebDestination.isCurrent(gmail, snapshot: snapshot, history: history) else {
            return nil
        }
        let matches = snapshot.targets.filter {
            $0.operations.contains(.press) && $0.role != "url" && $0.role != "application"
                && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Compose") == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        if history.contains(where: {
            $0.referring(to: matches[0])
                && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
        }) {
            return nil
        }
        return VoiceControlAction(operation: .press, targetID: matches[0].id, consequence: .ordinary)
    }
}
