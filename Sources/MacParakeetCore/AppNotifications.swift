import Foundation

public extension Notification.Name {
    static let macParakeetOpenOnboarding = Notification.Name("macparakeet.openOnboarding")
    static let macParakeetOpenSettings = Notification.Name("macparakeet.openSettings")
    static let macParakeetHotkeyTriggerDidChange = Notification.Name("macparakeet.hotkeyTriggerDidChange")
    static let macParakeetMeetingHotkeyTriggerDidChange = Notification.Name("macparakeet.meetingHotkeyTriggerDidChange")
    static let macParakeetMenuBarOnlyModeDidChange = Notification.Name("macparakeet.menuBarOnlyModeDidChange")
    static let macParakeetShowIdlePillDidChange = Notification.Name("macparakeet.showIdlePillDidChange")
    static let macParakeetAIFormatterWarning = Notification.Name("macparakeet.aiFormatterWarning")
    /// Posted by `DictationService`/`TranscriptionService` just before the AI
    /// formatter begins running on a transcript. Observed by the dictation
    /// flow coordinator to promote the overlay pill into the `.formatting`
    /// beat (visually distinct from `.processing`).
    ///
    /// `userInfo["source"]` is "dictation" or "transcription".
    static let macParakeetAIFormatterDidStart = Notification.Name("macparakeet.aiFormatterDidStart")
    /// Posted immediately after the formatter returns (success, fallback, or
    /// cancellation). Observers should not rely on this alone for terminal
    /// state — the regular `.showSuccess` / `.showError` flow will fire next.
    /// This exists mainly so observers can clear any formatter-scoped UI if
    /// the higher-level flow has already moved on.
    static let macParakeetAIFormatterDidFinish = Notification.Name("macparakeet.aiFormatterDidFinish")
}
