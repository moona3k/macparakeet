import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class MainWindowStateTests: XCTestCase {
    func testNavigateToSettingsSelectsSettingsAndRecordsRequestedTab() {
        let state = MainWindowState()

        state.navigateToSettings(tab: .ai)

        XCTAssertEqual(state.selectedItem, .settings)
        XCTAssertEqual(state.requestedSettingsTab, .ai)
        XCTAssertEqual(state.requestedSettingsTabRevision, 1)
    }

    func testRepeatedSettingsTabNavigationAdvancesRevision() {
        let state = MainWindowState()

        state.navigateToSettings(tab: .ai)
        state.navigateToSettings(tab: .ai)

        XCTAssertEqual(state.requestedSettingsTab, .ai)
        XCTAssertEqual(state.requestedSettingsTabRevision, 2)
    }

    func testConsumeRequestedSettingsTabClearsTabWithoutChangingRevision() {
        let state = MainWindowState()
        state.navigateToSettings(tab: .ai)

        state.consumeRequestedSettingsTab()

        XCTAssertNil(state.requestedSettingsTab)
        XCTAssertEqual(state.requestedSettingsTabRevision, 1)
        XCTAssertEqual(state.selectedItem, .settings)
    }

    func testNavigateSelectsRequestedSidebarItem() {
        let state = MainWindowState()

        state.navigate(to: .library)

        XCTAssertEqual(state.selectedItem, .library)
    }

    func testNavigateCanSelectMeetingsWorkspace() {
        let state = MainWindowState()

        state.navigate(to: .meetings)

        XCTAssertEqual(state.selectedItem, .meetings)
    }

    func testPrimarySidebarOrdersMeetingsAfterDictations() {
        XCTAssertEqual(
            SidebarItem.primaryItems,
            [.transcribe, .library, .dictations, .meetings]
        )
    }

    func testStartNewTranscriptionReturnsToTranscribeAndHidesProgressDetail() {
        let state = MainWindowState()
        state.selectedItem = .library
        state.showingProgressDetail = true

        state.startNewTranscription()

        XCTAssertEqual(state.selectedItem, .transcribe)
        XCTAssertFalse(state.showingProgressDetail)
    }

    func testBeginCreatingTransformSelectsTransformsAndClearsEditTarget() {
        let state = MainWindowState()
        state.selectedItem = .settings
        state.editingTransform = Prompt.builtInPrompts().first { $0.category == .transform }
        XCTAssertNotNil(state.editingTransform)

        state.beginCreatingTransform()

        XCTAssertEqual(state.selectedItem, .transforms)
        XCTAssertNil(state.editingTransform)
        XCTAssertTrue(state.isCreatingTransform)
    }
}
