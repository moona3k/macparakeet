import Foundation

/// Local allowlisted websites for ordinary spoken goals. Jev never receives
/// these targets; the command router opens them only when the current page
/// does not already look like the destination.
public struct VoiceControlWebDestination: Sendable, Equatable {
    public let id: String
    public let label: String
    public let url: URL
    /// Names that route only in a navigation or search frame (`open YouTube`,
    /// `… on YouTube`, `search Wikipedia for …`). A bare mention is page content.
    public let names: [String]
    /// Whole phrases that are themselves a request for this destination.
    public let intentPhrases: [String]
    public let pageHints: [String]

    public static let all: [VoiceControlWebDestination] = [
        VoiceControlWebDestination(
            id: "web:google-flights", label: "Google Flights",
            url: URL(string: "https://www.google.com/travel/flights?gl=US&hl=en-US")!,
            names: ["google flights"],
            intentPhrases: ["flights from", "flight from", "flights to", "flight to"],
            pageHints: ["where from", "where to", "search flights"]),
        VoiceControlWebDestination(
            id: "web:youtube", label: "YouTube",
            url: URL(string: "https://www.youtube.com/")!,
            names: ["youtube", "you tube"], intentPhrases: [],
            pageHints: ["youtube"]),
        VoiceControlWebDestination(
            id: "web:gmail", label: "Gmail",
            url: URL(string: "https://mail.google.com/")!,
            names: ["gmail"], intentPhrases: [],
            pageHints: ["gmail"]),
        VoiceControlWebDestination(
            id: "web:google-maps", label: "Google Maps",
            url: URL(string: "https://www.google.com/maps")!,
            names: ["google maps"], intentPhrases: ["directions to"],
            pageHints: ["directions", "google maps"]),
        VoiceControlWebDestination(
            id: "web:wikipedia", label: "Wikipedia",
            url: URL(string: "https://en.wikipedia.org/")!,
            names: ["wikipedia"], intentPhrases: [],
            pageHints: ["wikipedia"]),
        VoiceControlWebDestination(
            id: "web:google-search", label: "Google Search",
            url: URL(string: "https://www.google.com/")!,
            names: [], intentPhrases: ["search the web", "google search", "google for", "search google"],
            pageHints: ["google search", "search google"]),
    ]

    public static func named(_ id: String) -> VoiceControlWebDestination? {
        all.first { $0.id == id }
    }

    /// The destination a goal explicitly asks for, if any. Matching is anchored
    /// at word boundaries and on a navigation or search frame, because this route
    /// runs before the page's own controls: `search for headphones` searches the
    /// open shop, `click the YouTube link` presses a link, and `reply to the email
    /// about my flight` stays in the mail app.
    public static func matchingGoal(_ lower: String) -> VoiceControlWebDestination? {
        let padded = " " + VoiceControlSessionGrammar.normalize(lower) + " "
        guard padded.count > 2, !isControlCommand(padded) else { return nil }
        return all.first { $0.isRequested(by: padded) }
    }

    private func isRequested(by padded: String) -> Bool {
        if intentPhrases.contains(where: { padded.contains(" \($0) ") }) { return true }
        for name in names {
            if padded.hasPrefix(" \(name) ") || padded.contains(" \(name) for ") { return true }
            let frames = ["open", "go to", "switch to", "launch", "on", "in", "search", "use"]
            if frames.contains(where: { padded.contains(" \($0) \(name) ") }) { return true }
        }
        // A flight search is the one destination named by its subject.
        if id == "web:google-flights", padded.contains(" flight ") || padded.contains(" flights ") {
            return Self.searchVerbs.contains { padded.hasPrefix(" \($0) ") }
        }
        return false
    }

    private static let searchVerbs = ["find", "search", "search for", "look for", "book", "compare"]

    /// `click …` / `press …` / `select …` name a control on the current page.
    private static func isControlCommand(_ padded: String) -> Bool {
        ["click", "press", "tap", "select", "choose"].contains { padded.hasPrefix(" \($0) ") }
    }

    public static func pageMatches(_ snapshot: VoiceControlSnapshot, destination: VoiceControlWebDestination) -> Bool {
        let pageTargets = snapshot.targets.filter { $0.role != "url" && $0.role != "application" }
        let haystack = (
            [snapshot.summary] + pageTargets.map(\.label) + pageTargets.compactMap(\.value)
        )
        .joined(separator: "\n")
        .lowercased()
        return destination.pageHints.contains { haystack.contains($0) }
    }

    public static func wasOpened(_ destination: VoiceControlWebDestination, history: [VoiceControlAction]) -> Bool {
        history.contains {
            $0.targetID == destination.id
                && ($0.receiptStatus == .transitionObserved || $0.receiptStatus == .verified)
        }
    }

    public static func isCurrent(
        _ destination: VoiceControlWebDestination, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]
    ) -> Bool {
        pageMatches(snapshot, destination: destination) || wasOpened(destination, history: history)
    }
}
