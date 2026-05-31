import AppKit
import MacParakeetCore
import MacParakeetViewModels
import OSLog
import UserNotifications

/// Turns a `TranscriptionCompletionNotifier.Content` into user-facing output:
/// always an audible chime via `SoundManager` (which plays while backgrounded
/// and respects the system "Play sound effects" preference), plus — only when
/// MacParakeet is in the background — a silent local-notification banner.
///
/// The ViewModel produces a `Content` only when the user's
/// completion-notification setting is on, so this presenter unconditionally
/// acts on whatever it is handed. The banner is silent (`content.sound = nil`)
/// because `SoundManager` already owns the audible cue — that also lets us
/// reuse the shared `.alert`-only authorization helper without dragging in the
/// `.sound` authorization nuance.
@MainActor
enum TranscriptionCompletionPresenter {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "TranscriptionNotifications")

    static func present(_ content: TranscriptionCompletionNotifier.Content) {
        SoundManager.shared.play(.transcriptionComplete)
        guard !NSApp.isActive else { return }
        postBanner(content)
    }

    private static func postBanner(_ content: TranscriptionCompletionNotifier.Content) {
        Task {
            guard await CalendarNotificationAuthorization.requestIfNeeded() else {
                logger.info("Completion banner skipped — notifications not authorized")
                return
            }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            notification.sound = nil  // SoundManager owns the audible cue
            let request = UNNotificationRequest(
                identifier: "macparakeet.transcription.\(UUID().uuidString)",
                content: notification,
                trigger: nil  // Deliver immediately
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Completion banner failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
