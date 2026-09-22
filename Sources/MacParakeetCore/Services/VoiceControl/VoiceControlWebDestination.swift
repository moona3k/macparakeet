import Foundation

/// Local allowlisted websites for ordinary spoken goals. Jev never receives
/// these targets; the command router opens them only when the current page
/// does not already look like the destination.
public struct VoiceControlWebDestination: Sendable, Equatable {
    public let id: String
    public let label: String
    public let url: URL
    public let goalHints: [String]
    public let pageHints: [String]

    public static let all: [VoiceControlWebDestination] = [
        VoiceControlWebDestination(
            id: "web:google-flights", label: "Google Flights",
            url: URL(string: "https://www.google.com/travel/flights?gl=US&hl=en-US")!,
            goalHints: ["flight", "flights"],
            pageHints: ["where from", "where to", "search flights"]),
        VoiceControlWebDestination(
            id: "web:youtube", label: "YouTube",
            url: URL(string: "https://www.youtube.com/")!,
            goalHints: ["youtube"],
            pageHints: ["youtube"]),
        VoiceControlWebDestination(
            id: "web:gmail", label: "Gmail",
            url: URL(string: "https://mail.google.com/")!,
            goalHints: ["gmail"],
            pageHints: ["gmail"]),
        VoiceControlWebDestination(
            id: "web:google-maps", label: "Google Maps",
            url: URL(string: "https://www.google.com/maps")!,
            goalHints: ["google maps", "directions to", "navigate to"],
            pageHints: ["directions", "google maps"]),
        VoiceControlWebDestination(
            id: "web:wikipedia", label: "Wikipedia",
            url: URL(string: "https://en.wikipedia.org/")!,
            goalHints: ["wikipedia"],
            pageHints: ["wikipedia"]),
        VoiceControlWebDestination(
            id: "web:google-search", label: "Google Search",
            url: URL(string: "https://www.google.com/")!,
            goalHints: ["search the web", "google search", "google for", "search google", "search for"],
            pageHints: ["google search", "search google"]),
    ]

    public static func named(_ id: String) -> VoiceControlWebDestination? {
        all.first { $0.id == id }
    }

    public static func matchingGoal(_ lower: String) -> VoiceControlWebDestination? {
        all.first { destination in
            destination.goalHints.contains { lower.contains($0) }
        }
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
