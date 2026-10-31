import Foundation
import MacParakeetCore

/// Explicit commands for the GUI dictation flow. Never log incoming URLs.
enum DictationURLCommand: String, CaseIterable {
    case start
    case stop
    case toggle

    init?(url: URL, scheme: String = "macparakeet") {
        guard url.absoluteString.utf8.count <= 8_192,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == scheme,
            parts.host?.lowercased() == "dictation",
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        switch parts.percentEncodedPath {
        case "/start": self = .start
        case "/stop": self = .stop
        case "/toggle": self = .toggle
        default: return nil
        }
    }

    /// URL starts must not use the hotkey's rapid-restart behavior: that can
    /// discard a recording or an undo window. Finishing can still own a paste.
    enum Action: Equatable { case start, stop }

    func action(for state: DictationFlowState) -> Action? {
        switch (self, state) {
        case (.start, .idle), (.start, .ready), (.toggle, .idle), (.toggle, .ready):
            return .start
        case (.stop, .checkingEntitlements), (.stop, .startingService), (.stop, .recording),
            (.toggle, .checkingEntitlements), (.toggle, .startingService), (.toggle, .recording):
            return .stop
        default:
            return nil
        }
    }
}

/// Mirrors meeting URL delivery: bounded cold-launch buffering, consent at
/// receipt and each dispatch, and no replay after failed setup or revocation.
@MainActor
final class DictationURLCommandRouter {
    private let scheme: String
    private let isEnabled: () -> Bool
    private let execute: (DictationURLCommand) -> Void
    private var pending: [DictationURLCommand] = []
    private var isReady = false

    init(scheme: String, isEnabled: @escaping () -> Bool, execute: @escaping (DictationURLCommand) -> Void) {
        self.scheme = scheme
        self.isEnabled = isEnabled
        self.execute = execute
    }

    func open(_ urls: [URL]) {
        guard isEnabled() else { return }
        for url in urls {
            guard let command = DictationURLCommand(url: url, scheme: scheme) else { continue }
            if isReady {
                guard isEnabled() else { return }
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
