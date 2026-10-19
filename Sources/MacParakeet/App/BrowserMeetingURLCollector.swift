import AppKit
import ApplicationServices
import Foundation
import MacParakeetCore

struct BrowserMeetingObservation: Sendable, Equatable {
    var urls: [String: [URL]] = [:]
    var inCallURLs: [String: [URL]] = [:]
    var preJoinURLs: [String: [URL]] = [:]
    var runningBrowserBundleIDs: Set<String> = []
}

/// Reads browser document metadata using the Accessibility permission already
/// used by dictation. It never requests browser Automation access, activates a
/// tab, or reads transcript/page text. Accessible button names identify known
/// prejoin controls and Google Meet's in-call leave control. Some browsers expose
/// only the selected tab; unknown observations do not establish a live call.
actor BrowserMeetingURLCollector {
    struct BrowserProcess: Sendable, Equatable {
        let bundleID: String
        let pid: Int32
    }

    typealias ProcessProvider = @MainActor @Sendable () -> [BrowserProcess]
    typealias SnapshotReader = @Sendable ([BrowserProcess]) -> BrowserMeetingObservation

    private let isTrusted: @Sendable () -> Bool
    private let processes: ProcessProvider
    private let readSnapshot: SnapshotReader
    private let isMeetingURL: @Sendable (URL) -> Bool

    init(
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        processes: @escaping ProcessProvider = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                    MeetingAppRegistry.isBrowser(bundleID: bundleID)
                else { return nil }
                return BrowserProcess(bundleID: bundleID, pid: app.processIdentifier)
            }
        },
        readSnapshot: @escaping SnapshotReader = { BrowserMeetingURLCollector.readBrowserDocuments($0) },
        isMeetingURL: @escaping @Sendable (URL) -> Bool = { MeetingPromptCandidateResolver.isMeetingURL($0) }
    ) {
        self.isTrusted = isTrusted
        self.processes = processes
        self.readSnapshot = readSnapshot
        self.isMeetingURL = isMeetingURL
    }

    func snapshot(bundleIDs: Set<String>? = nil) async -> [String: [URL]] {
        await snapshotDetailed(bundleIDs: bundleIDs).urls
    }

    func snapshotDetailed(bundleIDs: Set<String>? = nil) async -> BrowserMeetingObservation {
        // Process presence does not require AX permission and lets the runtime
        // preserve an existing dismissal during an unknown background-tab scan.
        let candidates = await processes().filter {
            MeetingAppRegistry.isBrowser(bundleID: $0.bundleID)
                && (bundleIDs?.contains($0.bundleID) ?? true)
        }
        let running = Set(candidates.map(\.bundleID))
        // Never prompt for AX permission from a background poll.
        guard isTrusted(), !candidates.isEmpty else {
            return BrowserMeetingObservation(runningBrowserBundleIDs: running)
        }
        let reader = readSnapshot
        let observations = await Task.detached(priority: .utility) {
            reader(candidates)
        }.value
        let allowed = Set(candidates.map(\.bundleID))
        var result = BrowserMeetingObservation(runningBrowserBundleIDs: running)
        for (bundleID, urls) in observations.urls where allowed.contains(bundleID) {
            var seen = Set<URL>()
            let rooms = urls.filter { isMeetingURL($0) && seen.insert($0).inserted }
            if !rooms.isEmpty { result.urls[bundleID] = rooms }
            let confirmed = Set(
                (observations.inCallURLs[bundleID] ?? [])
                    .filter(Self.isGoogleMeetRoom)
                    .compactMap { MeetingPromptCandidateResolver.normalizedMeetingRoomID(for: $0) })
            let inCall = rooms.filter {
                MeetingPromptCandidateResolver.normalizedMeetingRoomID(for: $0).map(confirmed.contains) ?? false
            }
            if !inCall.isEmpty { result.inCallURLs[bundleID] = inCall }
            let preJoin = Set(
                (observations.preJoinURLs[bundleID] ?? [])
                    .compactMap { MeetingPromptCandidateResolver.normalizedMeetingRoomID(for: $0) })
            let waiting = rooms.filter {
                guard let roomID = MeetingPromptCandidateResolver.normalizedMeetingRoomID(for: $0) else { return false }
                return preJoin.contains(roomID) && !confirmed.contains(roomID)
            }
            if !waiting.isEmpty { result.preJoinURLs[bundleID] = waiting }
        }
        return result
    }

    private nonisolated static func readBrowserDocuments(_ processes: [BrowserProcess]) -> BrowserMeetingObservation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var result = BrowserMeetingObservation()
        for process in processes {
            guard ContinuousClock.now < deadline else { break }
            let application = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let windows = children(of: application, attribute: kAXWindowsAttribute as CFString, limit: 24)
            var queue: [(AXUIElement, Int, URL?, Bool)] = windows.map { ($0, 0, nil, false) }
            var offset = 0
            // Breadth-first traversal reaches all windows before nested chrome.
            // Within a known meeting document we inspect roles and button names only;
            // static text, editable fields and link subtrees are never read.
            while offset < queue.count, offset < 320, ContinuousClock.now < deadline {
                let (element, depth, inheritedURL, wasInDocument) = queue[offset]
                offset += 1
                AXUIElementSetMessagingTimeout(element, 0.05)
                let metadata = documentMetadata(of: element)
                let documentURL = metadata.url ?? inheritedURL
                let inDocument = wasInDocument || metadata.role == "AXWebArea"
                if let url = metadata.url {
                    result.urls[process.bundleID, default: []].append(url)
                }
                if inDocument, let documentURL, MeetingPromptCandidateResolver.isMeetingURL(documentURL),
                    metadata.role == kAXButtonRole
                {
                    let labels = buttonLabels(of: element)
                    if isGoogleMeetRoom(documentURL), isMeetLeaveControl(role: metadata.role, labels: labels) {
                        result.inCallURLs[process.bundleID, default: []].append(documentURL)
                    } else if isPreJoinControl(documentURL: documentURL, role: metadata.role, labels: labels) {
                        result.preJoinURLs[process.bundleID, default: []].append(documentURL)
                    }
                }
                guard depth < 18, ContinuousClock.now < deadline else { continue }
                if inDocument {
                    guard let documentURL, MeetingPromptCandidateResolver.isMeetingURL(documentURL),
                        ![kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXButtonRole, "AXLink"].contains(
                            metadata.role ?? "")
                    else { continue }
                }
                let remaining = min(64, 320 - queue.count)
                guard remaining > 0 else { continue }
                queue.append(
                    contentsOf: children(of: element, attribute: kAXChildrenAttribute as CFString, limit: remaining)
                        .map { ($0, depth + 1, documentURL, inDocument) })
            }
        }
        return result
    }

    private nonisolated static func documentMetadata(of element: AXUIElement) -> (role: String?, url: URL?) {
        documentMetadata { attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }
    }

    /// Role is read before document attributes so link destinations, control
    /// URLs and other page-node metadata never enter the collection path.
    nonisolated static func documentMetadata(readAttribute: (String) -> Any?) -> (role: String?, url: URL?) {
        let role = readAttribute(kAXRoleAttribute) as? String
        guard role == kAXWindowRole || role == "AXWebArea" else { return (role, nil) }
        return (
            role,
            readAttribute(kAXDocumentAttribute).flatMap(documentURL)
                ?? readAttribute("AXURL").flatMap(documentURL)
        )
    }

    private nonisolated static func isGoogleMeetRoom(_ url: URL) -> Bool {
        url.host?.lowercased() == "meet.google.com" && MeetingPromptCandidateResolver.isMeetingURL(url)
    }

    /// These are public UI label fixtures, not provider internals. Unknown
    /// locales yield no in-call evidence and can still use the audio+URL path.
    nonisolated static func isMeetLeaveControl(role: String?, labels: [String]) -> Bool {
        guard role == kAXButtonRole else { return false }
        let names = ["leave call", "opuść rozmowę", "opuść połączenie"]
        return labels.contains { label in
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return names.contains { name in
                normalized == name || (normalized.hasPrefix(name + " (") && normalized.hasSuffix(")"))
            }
        }
    }

    nonisolated static func isMeetPreJoinControl(role: String?, labels: [String]) -> Bool {
        guard role == kAXButtonRole else { return false }
        let names = ["join now", "ask to join", "rejoin", "dołącz teraz", "poproś o dołączenie"]
        return labels.contains { names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    /// Negative evidence is scoped to a validated provider room. In particular,
    /// generic “Join” labels can belong to unrelated meeting controls and are
    /// not enough. These English/Polish fixtures need no page text extraction.
    nonisolated static func isPreJoinControl(documentURL: URL, role: String?, labels: [String]) -> Bool {
        guard MeetingPromptCandidateResolver.isMeetingURL(documentURL), role == kAXButtonRole else { return false }
        if isGoogleMeetRoom(documentURL) {
            return isMeetPreJoinControl(role: role, labels: labels)
        }
        let host = documentURL.host?.lowercased() ?? ""
        let names: Set<String>
        if ["zoom.us", "zoomgov.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            names = ["join meeting"]
        } else {
            names = ["join now", "dołącz teraz"]
        }
        return labels.contains { names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    private nonisolated static func buttonLabels(of element: AXUIElement) -> [String] {
        var values: CFArray?
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXHidden"] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
            let metadata = values as? [Any], metadata.count == 4,
            (metadata[3] as? Bool) != true
        else { return [] }
        return metadata.prefix(3).compactMap { $0 as? String }
    }

    nonisolated static func documentURL(_ value: Any) -> URL? {
        let url: URL?
        if let native = value as? URL {
            url = native
        } else if let string = value as? String {
            url = URL(string: string)
        } else {
            return nil
        }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host != nil
        else { return nil }
        return url
    }

    private nonisolated static func children(of element: AXUIElement, attribute: CFString, limit: Int) -> [AXUIElement]
    {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute, 0, limit, &values) == .success,
            let values = values as? [AnyObject]
        else { return [] }
        return values.compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast($0, to: AXUIElement.self)
        }
    }
}
