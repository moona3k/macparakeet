import MacParakeetCore
import MacParakeetViewModels
import OSLog
import UserNotifications

/// Posts the one-time "this meeting may be missing a side" banner. It is
/// delivered even while MacParakeet is frontmost: the live panel, the only
/// in-app surface with full source detail, may be closed.
enum MeetingSourceLossNoticePresenter {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "MeetingSourceLossNotice")

    static func present(_ notice: MeetingSourceLossNotice) {
        Task {
            guard await CalendarNotificationAuthorization.requestIfNeeded() else {
                logger.info("Source-loss banner skipped: notifications not authorized")
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
