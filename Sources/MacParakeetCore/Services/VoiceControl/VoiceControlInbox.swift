import Foundation

public struct VoiceControlInboxCommand: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case submit, revise, confirm, stop, cancel
        case continueTask = "continue"
    }
    public var action: Action
    public var text: String
    public var activate: String? = nil
    /// Observe, route and decide, then report the compiled action without executing it.
    public var dryRun: Bool = false

    public static func parse(_ raw: String) -> VoiceControlInboxCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let actionName = (json["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "submit"
            guard let action = Action(rawValue: actionName) else { return nil }
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if (action == .submit || action == .revise) && text.isEmpty { return nil }
            let activate = (json["activate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return VoiceControlInboxCommand(
                action: action, text: text, activate: activate?.isEmpty == false ? activate : nil,
                dryRun: json["dryRun"] as? Bool ?? false)
        }
        return VoiceControlInboxCommand(action: .submit, text: trimmed, activate: nil)
    }
}
