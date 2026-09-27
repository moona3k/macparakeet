import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class OnboardingShortcutEditorTests: XCTestCase {
    private func snapshot(
        meeting: HotkeyTrigger = .disabled,
        dictationAIPolish: HotkeyTrigger = .disabled,
        meetingRecordingEnabled: Bool = true
    ) -> HotkeyConflictPolicy.SettingsSnapshot {
        HotkeyConflictPolicy.SettingsSnapshot(
            handsFree: .disabled,
            pushToTalk: .disabled,
            meeting: meeting,
            fileTranscription: .disabled,
            youtubeTranscription: .disabled,
            dictationAIPolish: dictationAIPolish,
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
            OnboardingShortcutEditor.defaultResetConflict(in: snapshot(dictationAIPolish: .fn))?
                .contains("AI-polished dictation") == true
        )
    }
}
