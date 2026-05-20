import XCTest
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
}
