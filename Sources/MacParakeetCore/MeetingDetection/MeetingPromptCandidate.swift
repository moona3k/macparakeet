import Foundation

/// An on-device call identity. Browser identities contain a normalized room
/// identifier, never URL credentials, query parameters, or fragments.
public struct MeetingPromptCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let app: MeetingApp
    public let bundleID: String
    public let displayName: String

    public init(id: String, app: MeetingApp, bundleID: String, displayName: String) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

public enum MeetingPromptCandidateResolver {
    public static func isMeetingURL(_ url: URL) -> Bool {
        meetingRoom(url) != nil
    }

    public static func normalizedMeetingRoomID(for url: URL) -> String? {
        meetingRoom(url)?.identity
    }

    public static func browserCandidate(bundleID: String, meetingURL: URL) -> MeetingPromptCandidate? {
        guard MeetingAppRegistry.browserBundleIDs.contains(bundleID), let room = meetingRoom(meetingURL) else {
            return nil
        }
        return MeetingPromptCandidate(
            id: "browser:\(bundleID):\(room.identity)",
            app: .browser, bundleID: bundleID, displayName: room.displayName
        )
    }

    public static func resolve(
        audio: ProcessAudioSnapshot,
        meetingURLsByBundleID: [String: [URL]],
        confirmedInCallURLsByBundleID: [String: [URL]] = [:],
        excludedPreJoinURLsByBundleID: [String: [URL]] = [:]
    ) -> [MeetingPromptCandidate] {
        var candidates: [String: MeetingPromptCandidate] = [:]
        for process in audio.inputHolders {
            guard let bundleID = process.bundleID else { continue }
            if let browserID = MeetingAppRegistry.normalizedBrowserBundleID(for: bundleID) {
                let preJoinRooms = Set(
                    (excludedPreJoinURLsByBundleID[browserID] ?? []).compactMap { meetingRoom($0)?.identity })
                for url in meetingURLsByBundleID[browserID] ?? [] {
                    guard let room = meetingRoom(url) else { continue }
                    guard !preJoinRooms.contains(room.identity) else { continue }
                    let candidate = MeetingPromptCandidate(
                        id: "browser:\(browserID):\(room.identity)",
                        app: .browser,
                        bundleID: browserID,
                        displayName: room.displayName
                    )
                    candidates[candidate.id] = candidate
                }
                continue
            }
            guard let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                descriptor.trustTier != .browser
            else { continue }
            if descriptor.trustTier == .chat {
                // Slack can keep its input device open outside a huddle. Its
                // audio may be attributed across processes of the same app.
                guard audio.outputHolders.contains(where: { $0.bundleID == bundleID }) else { continue }
            }
            let candidate = MeetingPromptCandidate(
                id: "app:\(bundleID)",
                app: descriptor.app,
                bundleID: bundleID,
                displayName: displayName(for: descriptor.app)
            )
            candidates[candidate.id] = candidate
        }
        // Google Meet releases microphone ownership when joining muted. An
        // explicit in-call control observation (from that room's web area)
        // supplies positive evidence in that case. A URL alone never does.
        for browserID in MeetingAppRegistry.browserBundleIDs {
            let visibleRooms = Set((meetingURLsByBundleID[browserID] ?? []).compactMap { meetingRoom($0)?.identity })
            for url in confirmedInCallURLsByBundleID[browserID] ?? [] {
                guard let room = meetingRoom(url), room.identity.hasPrefix("meet:"),
                    visibleRooms.contains(room.identity)
                else { continue }
                let candidate = MeetingPromptCandidate(
                    id: "browser:\(browserID):\(room.identity)",
                    app: .browser, bundleID: browserID, displayName: room.displayName
                )
                candidates[candidate.id] = candidate
            }
        }
        return candidates.values.sorted { $0.id < $1.id }
    }

    private static func displayName(for app: MeetingApp) -> String {
        switch app {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .facetime: return "FaceTime"
        case .browser: return "Browser meeting"
        }
    }

    private static func meetingRoom(_ url: URL) -> (identity: String, displayName: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
            components.user == nil, components.password == nil,
            components.port == nil || components.port == (scheme == "https" ? 443 : 80),
            let host = components.host?.lowercased()
        else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        if host == "meet.google.com", path.count == 1,
            path[0].range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        {
            return ("meet:\(path[0].lowercased())", "Google Meet")
        }
        if ["zoom.us", "zoomgov.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            let route = path.first?.lowercased()
            if path.count == 2, ["j", "w"].contains(route ?? ""),
                path[1].range(of: #"^[0-9]{9,11}$"#, options: .regularExpression) != nil
            {
                return ("zoom:\(path[1])", "Zoom")
            }
            if path.count == 3, route == "wc", path[2].lowercased() == "join",
                path[1].range(of: #"^[0-9]{9,11}$"#, options: .regularExpression) != nil
            {
                return ("zoom:\(path[1])", "Zoom")
            }
            if path.count == 2, route == "my",
                path[1].range(of: #"^[a-z0-9][a-z0-9.@_-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            {
                return ("zoom-my:\(path[1].lowercased())", "Zoom")
            }
        }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) {
            if path.count >= 3, path[0] == "l", path[1] == "meetup-join",
                path[2].hasPrefix("19:"), path[2].contains("@thread.v2")
            {
                return ("teams:\(path[2])", "Microsoft Teams")
            }
            if path.count == 2, path[0] == "meet",
                path[1].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
            {
                return ("teams:\(path[1])", "Microsoft Teams")
            }
        }
        return nil
    }
}
