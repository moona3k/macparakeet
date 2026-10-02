import Foundation

/// The app's deliberately small, fire-and-forget recording automation surface.
/// Never log incoming URLs: the query can contain a private meeting title.
enum MeetingURLCommand: Equatable {
    case start(title: String?)
    case stop
    case pause
    case resume

    init?(url: URL, scheme: String = "macparakeet") {
        guard url.absoluteString.utf8.count <= 8_192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme,
              parts.host?.lowercased() == "meeting",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil
        else { return nil }
        let query = parts.queryItems ?? []
        switch parts.percentEncodedPath {
        case "/start":
            guard query.count <= 1, query.allSatisfy({ $0.name == "title" && $0.value != nil }) else { return nil }
            let title = query.first?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title else { self = .start(title: nil); return }
            guard title.count <= 500,
                  !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            self = .start(title: title.isEmpty ? nil : title)
        case "/stop" where query.isEmpty: self = .stop
        case "/pause" where query.isEmpty: self = .pause
        case "/resume" where query.isEmpty: self = .resume
        default: return nil
        }
    }
}

/// Holds cold-launch deliveries until the app has installed its recording
/// coordinator. Consent is checked both at receipt and before dispatch.
@MainActor
final class MeetingURLCommandRouter {
    private let scheme: String
    private let isEnabled: () -> Bool
    private let execute: (MeetingURLCommand) -> Void
    private var pending: [MeetingURLCommand] = []
    private var isReady = false

    init(scheme: String, isEnabled: @escaping () -> Bool, execute: @escaping (MeetingURLCommand) -> Void) {
        self.scheme = scheme
        self.isEnabled = isEnabled
        self.execute = execute
    }

    func open(_ urls: [URL]) {
        guard isEnabled() else { return }
        for url in urls {
            guard let command = MeetingURLCommand(url: url, scheme: scheme) else { continue }
            if isReady {
                execute(command)
            } else if pending.count < 16 {
                pending.append(command)
            }
        }
    }

    func finishLaunching() {
        isReady = true
        let commands = pending
        pending.removeAll()
        for command in commands where isEnabled() {
            execute(command)
        }
    }

    func discardPending() {
        pending.removeAll()
    }
}
