import XCTest
import ApplicationServices
@testable import MacParakeetCore

final class NativeVoiceControlAdapterTests: XCTestCase {
    func testPressableStaticTextUsesVisibleValueAsItsName() {
        XCTAssertEqual(NativeVoiceControlAdapter.actionLabel("", value: "One way", role: kAXStaticTextRole, pressable: true), "One way")
        XCTAssertEqual(NativeVoiceControlAdapter.actionLabel("Ticket type", value: "One way", role: kAXStaticTextRole, pressable: true), "Ticket type")
        XCTAssertEqual(NativeVoiceControlAdapter.actionLabel("", value: "Private text", role: kAXStaticTextRole, pressable: false), "")
        XCTAssertEqual(NativeVoiceControlAdapter.actionLabel("", value: "One way", role: kAXMenuItemRole, pressable: true), "One way")
    }

    func testAccountBadgeIdentityIsNotNeededForControl() {
        XCTAssertEqual(NativeVoiceControlAdapter.contextLabel("Google Account: Example Person (person@example.test)", role: kAXButtonRole), "Account menu")
        XCTAssertEqual(NativeVoiceControlAdapter.contextLabel("Profile: Example Person", role: kAXPopUpButtonRole), "Browser profile menu")
        XCTAssertEqual(NativeVoiceControlAdapter.contextLabel("Where from?", role: kAXComboBoxRole), "Where from?")
    }
    func testRichTextRequiresSelectionSetterAndNeverOffersWholeValueRewrite() {
        XCTAssertEqual(NativeVoiceControlAdapter.textOperations(role: kAXTextAreaRole, readableValue: true,
            valueSettable: true, selectionSettable: true), [.insertText])
        XCTAssertEqual(NativeVoiceControlAdapter.textOperations(role: kAXTextAreaRole, readableValue: true,
            valueSettable: true, selectionSettable: false), [])
    }
    func testUnreadableTextCannotAuthorizeDestructiveReplacement() {
        XCTAssertEqual(NativeVoiceControlAdapter.textOperations(role: kAXTextFieldRole, readableValue: false,
            valueSettable: true, selectionSettable: true), [])
    }
    func testPlainFieldSupportsKnownValueReplacement() {
        XCTAssertEqual(NativeVoiceControlAdapter.textOperations(role: kAXTextFieldRole, readableValue: true,
            valueSettable: true, selectionSettable: false), [.setValue, .insertText])
    }
    func testListOptionsAreOrdinaryNavigation() {
        XCTAssertTrue(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXStaticTextRole, pressable: true))
        XCTAssertFalse(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXStaticTextRole, pressable: false))
        XCTAssertTrue(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXMenuItemRole, pressable: true))
        XCTAssertTrue(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXComboBoxRole, pressable: true))
        XCTAssertTrue(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXRadioButtonRole, pressable: true))
        XCTAssertFalse(NativeVoiceControlAdapter.isOrdinaryControl(role: kAXButtonRole, pressable: true))
    }
    func testBrowserChromeNoiseIsDroppedWhenThePageHasControls() {
        XCTAssertTrue(NativeVoiceControlAdapter.isBrowserBundle("com.google.Chrome"))
        XCTAssertFalse(NativeVoiceControlAdapter.isBrowserBundle("com.apple.Notes"))
        XCTAssertTrue(
            NativeVoiceControlAdapter.isBrowserShellNoise(
                label: "Find Cheap Flights Worldwide & Book Your Ticket - Google Flights - Memory usage - 305 MB",
                role: kAXStaticTextRole))
        XCTAssertTrue(
            NativeVoiceControlAdapter.isBrowserShellNoise(label: "Address and search bar", role: kAXTextFieldRole))
        XCTAssertTrue(NativeVoiceControlAdapter.isBrowserShellNoise(label: "Tab search", role: kAXPopUpButtonRole))
        XCTAssertFalse(NativeVoiceControlAdapter.isBrowserShellNoise(label: "Where from?", role: kAXComboBoxRole))
        XCTAssertTrue(
            NativeVoiceControlAdapter.keepOfferedControl(
                isBrowser: true, inWebArea: true, hasWebContent: true, label: "Where from?", role: kAXComboBoxRole))
        XCTAssertFalse(
            NativeVoiceControlAdapter.keepOfferedControl(
                isBrowser: true, inWebArea: false, hasWebContent: true, label: "Address and search bar",
                role: kAXTextFieldRole))
        XCTAssertTrue(
            NativeVoiceControlAdapter.keepOfferedControl(
                isBrowser: false, inWebArea: false, hasWebContent: false, label: "New Note", role: kAXButtonRole))
    }
}
