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
    /// about my flight` stays in the mail app. Only the current request of an
    /// amended goal counts (`VoiceControlGoalText.currentRequest`): a correction
    /// that names no site abandons the earlier one, and a clarification answers
    /// a question rather than restating the request.
    public static func matchingGoal(_ lower: String) -> VoiceControlWebDestination? {
        guard let request = VoiceControlGoalText.currentRequest(lower) else { return nil }
        let padded = " " + VoiceControlSessionGrammar.normalize(request) + " "
        guard padded.count > 2, !isControlCommand(padded) else { return nil }
        return all.first { $0.isRequested(by: padded) }
    }

    private func isRequested(by padded: String) -> Bool {
        // Explicit navigation always routes: `open YouTube`, `go to Gmail`, `Wikipedia …`.
        for name in names {
            if padded.hasPrefix(" \(name) ") { return true }
            let navigation = ["open", "go to", "switch to", "launch", "use"]
            if navigation.contains(where: { padded.contains(" \($0) \(name) ") }) { return true }
        }
        // Below, the site is mentioned in passing or inferred. A sentence about
        // a message (`forward the video on YouTube to Sarah`, `reply to Sarah
        // with directions to the office`) is work in the current app, unless it
        // leads with a search verb (`find flights …`, `directions to …`). Mail
        // words are the subject matter of Gmail itself, so they never veto it.
        if id != "web:gmail", Self.isAboutAMessage(padded) { return false }
        for name in names {
            if padded.contains(" \(name) for ") { return true }
            if ["on", "in", "search"].contains(where: { padded.contains(" \($0) \(name) ") }) { return true }
        }
        // A flight search is the one destination named by its subject.
        if id == "web:google-flights", Self.leadsWithFlightSearch(padded) { return true }
        return intentPhrases.contains(where: { padded.contains(" \($0) ") })
    }

    /// `… in Chrome`, `… in Safari`: the person names the browser to use. A
    /// sentence about a message (`reply that the login fails in Chrome`) does not.
    public static func namesBrowser(_ lower: String) -> Bool {
        guard let request = VoiceControlGoalText.currentRequest(lower) else { return false }
        let padded = " " + VoiceControlSessionGrammar.normalize(request) + " "
        guard !isControlCommand(padded), !isAboutAMessage(padded) else { return false }
        return ["chrome", "safari", "firefox", "brave", "edge"].contains { padded.contains(" in \($0) ") }
    }

    private static func isAboutAMessage(_ padded: String) -> Bool {
        let leadsWithSearch = searchLeads.contains { padded.hasPrefix(" \($0) ") }
        return !leadsWithSearch && messageWords.contains { padded.contains(" \($0) ") }
    }

    /// `find cheap one way flights …`: flights are the object of the search verb,
    /// with only articles and fare modifiers in between.
    private static func leadsWithFlightSearch(_ padded: String) -> Bool {
        let words = padded.split(separator: " ").map(String.init)
        return searchVerbs.contains { verb in
            let verbWords = verb.split(separator: " ").map(String.init)
            guard words.starts(with: verbWords) else { return false }
            let object = words.dropFirst(verbWords.count).drop { flightModifiers.contains($0) }
            return object.first == "flight" || object.first == "flights"
        }
    }

    private static let searchVerbs = ["find", "search", "search for", "look for", "book", "compare"]
    private static let flightModifiers: Set<String> = [
        "a", "an", "the", "some", "cheap", "cheapest", "one", "way", "round", "trip", "nonstop", "non", "stop",
        "direct", "return",
    ]
    private static let messageWords = [
        "email", "emails", "mail", "message", "messages", "confirmation", "booking reference", "itinerary",
        "reply", "forward", "send", "text", "tell", "share", "invite",
    ]
    private static let searchLeads = [
        "find", "search", "look", "book", "compare", "google", "directions", "get", "play", "watch",
    ]

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
