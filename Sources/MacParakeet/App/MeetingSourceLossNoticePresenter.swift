import MacParakeetCore
import MacParakeetViewModels
import OSLog
import UserNotifications

/// Posts the one-time "this meeting may be missing a side" banner. The caller
/// posts it only while MacParakeet is in the background and the live panel is
/// closed; the system does not display a banner for a frontmost app.
/// Authorization can wait on a system prompt, so `isStillRelevant` is checked
/// again before posting: the meeting may have ended or the source recovered.
enum MeetingSourceLossNoticePresenter {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "MeetingSourceLossNotice")

    static func present(
        _ notice: MeetingSourceLossNotice,
        isStillRelevant: @escaping @MainActor @Sendable () -> Bool
    ) {
        Task {
            guard await CalendarNotificationAuthorization.requestIfNeeded() else {
                logger.info("Source-loss banner skipped: notifications not authorized")
                return
            }
            guard await isStillRelevant() else {
                logger.info("Source-loss banner skipped: no longer relevant")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            let request = UNNotificationRequest(
                identifier: "macparakeet.meeting.source-loss.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Source-loss banner failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
