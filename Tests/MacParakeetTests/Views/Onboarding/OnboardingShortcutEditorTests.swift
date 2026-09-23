import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class OnboardingShortcutEditorTests: XCTestCase {
    private func snapshot(
        meeting: HotkeyTrigger = .disabled,
        dictationClipboard: HotkeyTrigger = .disabled,
        meetingRecordingEnabled: Bool = true
    ) -> HotkeyConflictPolicy.SettingsSnapshot {
        HotkeyConflictPolicy.SettingsSnapshot(
            handsFree: .disabled,
            pushToTalk: .disabled,
            meeting: meeting,
            fileTranscription: .disabled,
            youtubeTranscription: .disabled,
            dictationAIPolish: .disabled,
            dictationClipboard: dictationClipboard,
            transformHotkeys: [],
            meetingRecordingEnabled: meetingRecordingEnabled
        )
    }

    func testDefaultPairIsAllowedWhenOtherShortcutsDoNotConflict() {
        XCTAssertNil(OnboardingShortcutEditor.defaultResetConflict(in: snapshot()))
        XCTAssertNil(
            OnboardingShortcutEditor.defaultResetConflict(
                in: snapshot(meeting: .fn, meetingRecordingEnabled: false)
            ))
    }

    func testDefaultPairIsBlockedWhenAnotherActionUsesFn() {
        XCTAssertTrue(
            OnboardingShortcutEditor.defaultResetConflict(in: snapshot(dictationClipboard: .fn))?
                .contains("clipboard-only dictation") == true
        )
    }
}
