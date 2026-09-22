import Foundation

/// Local search-box filling for ordinary web destinations that are already open.
/// Site-specific flight forms stay in `VoiceControlFlightPlan`.
public struct VoiceControlWebQuery: Equatable, Sendable {
    public let destinationID: String
    public let query: String

    public static func parse(_ goal: String) -> VoiceControlWebQuery? {
        let lower = goal.lowercased()
        guard let destination = VoiceControlWebDestination.matchingGoal(lower),
            destination.id != "web:google-flights"
        else { return nil }
        guard let query = extractQuery(from: goal, destinationID: destination.id), !query.isEmpty else {
            return nil
        }
        return VoiceControlWebQuery(destinationID: destination.id, query: query)
    }

    public func nextAction(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> VoiceControlAction? {
        if let option = uniqueSuggestion(in: snapshot, history: history) {
            return ordinary(.press, option.id)
        }
        if let field = searchField(in: snapshot), needs(field, history: history),
            field.operations.contains(.setValue)
        {
            return ordinary(.setValue, field.id, query)
        }
        if let search = snapshot.targets.first(where: Self.isSearchControl),
            !history.contains(where: {
                $0.referring(to: search)
                    && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
            })
        {
            return ordinary(.press, search.id)
        }
        return nil
    }

    static func extractQuery(from goal: String, destinationID: String) -> String? {
        var text = goal
        switch destinationID {
        case "web:youtube":
            text = strip(text, suffixes: [" on youtube", " on you tube", " youtube"])
            text = strip(text, prefixes: ["play ", "watch ", "search youtube for ", "youtube ", "open youtube "])
        case "web:google-maps":
            text = strip(text, prefixes: ["directions to ", "navigate to ", "google maps to ", "maps to "])
            text = strip(text, suffixes: [" on google maps", " in google maps"])
        case "web:wikipedia":
            text = strip(text, suffixes: [" on wikipedia", " in wikipedia", " wikipedia"])
            text = strip(text, prefixes: ["search wikipedia for ", "look up ", "wikipedia "])
        case "web:google-search":
            text = strip(text, prefixes: ["search the web for ", "google for ", "google ", "search google for ", "search for "])
        case "web:gmail":
            return nil
        default:
            return nil
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let residual = query.lowercased()
        if query.isEmpty || ["youtube", "gmail", "maps", "google", "open", "wikipedia"].contains(residual) {
            return nil
        }
        return query
    }

    private static func strip(_ value: String, prefixes: [String] = [], suffixes: [String] = []) -> String {
        var text = value
        for suffix in suffixes {
            if let range = text.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                text = String(text[..<range.lowerBound])
            } else if let range = text.range(of: suffix, options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
            }
        }
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text
    }

    private func searchField(in snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        let labeled = snapshot.targets.first { target in
            target.operations.contains(.setValue) && target.role != "url" && target.role != "application"
                && ["search", "find a video", "search google maps"].contains {
                    target.label.lowercased().contains($0)
                }
        }
        if let labeled { return labeled }
        return nil
    }

    private func ordinary(_ operation: VoiceControlOperation, _ targetID: String, _ value: String? = nil)
        -> VoiceControlAction
    {
        VoiceControlAction(operation: operation, targetID: targetID, value: value, consequence: .ordinary)
    }

    private func needs(_ target: VoiceControlTarget, history: [VoiceControlAction]) -> Bool {
        if history.contains(where: {
            $0.referring(to: target) && $0.value == query
                && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
        }) {
            return false
        }
        let current = (target.value ?? "").lowercased()
        return current.isEmpty || !current.contains(query.lowercased())
    }

    private func uniqueSuggestion(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> VoiceControlTarget?
    {
        guard let last = history.last, last.operation == .setValue, last.value == query, query.count >= 3,
            last.receiptStatus == .verified || last.receiptStatus == .transitionObserved
        else { return nil }
        let matches = snapshot.targets.filter {
            $0.operations.contains(.press) && $0.role != "url" && $0.role != "application"
                && $0.label.localizedStandardContains(query)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isSearchControl(_ target: VoiceControlTarget) -> Bool {
        let label = target.label.lowercased()
        return target.operations.contains(.press) && target.role != "url" && target.role != "application"
            && ["search", "google search"].contains { label == $0 || label.hasPrefix($0 + " ") }
    }
}
