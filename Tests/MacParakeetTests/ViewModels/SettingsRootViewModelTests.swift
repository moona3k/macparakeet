import XCTest
@testable import MacParakeetViewModels

@MainActor
final class SettingsRootViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Each test gets an isolated UserDefaults suite so tab persistence
        // assertions don't leak across cases or interfere with the user's
        // real preferences during local runs.
        suiteName = "SettingsRootViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToCaptureTabOnFirstLaunch() {
        let vm = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(vm.activeTab, .capture)
        XCTAssertEqual(vm.activeCaptureWorkflow, .dictation)
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertFalse(vm.isSearching)
    }

    func testActiveTabPersistsAcrossInstances() {
        let first = SettingsRootViewModel(defaults: defaults)
        first.activeTab = .system

        let second = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(second.activeTab, .system)
    }

    func testInitialTabOverridesPersistedTabAndPersists() {
        defaults.set(SettingsTab.system.rawValue, forKey: SettingsRootViewModel.lastViewedTabKey)

        let first = SettingsRootViewModel(defaults: defaults, initialTab: .ai)
        XCTAssertEqual(first.activeTab, .ai)

        let second = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(second.activeTab, .ai)
    }

    func testEachTabRoundTripsThroughPersistence() {
        for tab in SettingsTab.allCases {
            let writer = SettingsRootViewModel(defaults: defaults)
            writer.activeTab = tab

            let reader = SettingsRootViewModel(defaults: defaults)
            XCTAssertEqual(reader.activeTab, tab, "Tab \(tab.rawValue) should round-trip")
        }
    }

    func testActiveCaptureWorkflowPersistsAcrossInstances() {
        let first = SettingsRootViewModel(defaults: defaults)
        first.activeCaptureWorkflow = .meetings

        let second = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(second.activeCaptureWorkflow, .meetings)
    }

    func testEachCaptureWorkflowRoundTripsThroughPersistence() {
        for workflow in SettingsCaptureWorkflow.allCases {
            let writer = SettingsRootViewModel(defaults: defaults)
            writer.activeCaptureWorkflow = workflow

            let reader = SettingsRootViewModel(defaults: defaults)
            XCTAssertEqual(reader.activeCaptureWorkflow, workflow, "Workflow \(workflow.rawValue) should round-trip")
        }
    }

    func testCorruptedPersistedCaptureWorkflowFallsBackToDefault() {
        defaults.set("not-a-real-workflow", forKey: SettingsRootViewModel.lastCaptureWorkflowKey)
        let vm = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(vm.activeCaptureWorkflow, .default)
    }

    func testCorruptedPersistedTabFallsBackToDefault() {
        defaults.set("not-a-real-tab", forKey: SettingsRootViewModel.lastViewedTabKey)
        let vm = SettingsRootViewModel(defaults: defaults)
        XCTAssertEqual(vm.activeTab, .default)
    }

    func testIsSearchingTracksTrimmedQuery() {
        let vm = SettingsRootViewModel(defaults: defaults)
        XCTAssertFalse(vm.isSearching)

        vm.searchQuery = "   "
        XCTAssertFalse(vm.isSearching, "Whitespace-only query should not count as searching")

        // `.whitespacesAndNewlines` matters here: the index trims newlines
        // before matching, so if `isSearching` only trimmed `.whitespaces`
        // a pasted newline would put the UI into search mode while the
        // index returned zero results — a confusing "No matches" state
        // for an effectively empty query.
        vm.searchQuery = "\n\t"
        XCTAssertFalse(vm.isSearching, "Newline / tab-only query should not count as searching")

        vm.searchQuery = "hotkey"
        XCTAssertTrue(vm.isSearching)
    }

    func testClearSearchEmptiesQuery() {
        let vm = SettingsRootViewModel(defaults: defaults)
        vm.searchQuery = "hotkey"
        XCTAssertTrue(vm.isSearching)

        vm.clearSearch()
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertFalse(vm.isSearching)
    }

    func testOpenTabClearsSearchAndPersistsTab() {
        let vm = SettingsRootViewModel(defaults: defaults)
        vm.searchQuery = "ai"

        vm.open(tab: .ai)

        XCTAssertEqual(vm.activeTab, .ai)
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertFalse(vm.isSearching)
        XCTAssertEqual(defaults.string(forKey: SettingsRootViewModel.lastViewedTabKey), SettingsTab.ai.rawValue)
    }

    func testWritingSameTabDoesNotChurnDefaults() {
        // The didSet only writes when the new value differs. We can't observe
        // UserDefaults writes directly, but we can confirm setting the same
        // value doesn't somehow change behavior.
        let vm = SettingsRootViewModel(defaults: defaults)
        vm.activeTab = .capture
        XCTAssertEqual(vm.activeTab, .capture)

        vm.activeTab = .capture
        XCTAssertEqual(vm.activeTab, .capture)
    }

    func testLegacyModesRawValueRestoresCaptureTab() {
        defaults.set("modes", forKey: SettingsRootViewModel.lastViewedTabKey)

        let vm = SettingsRootViewModel(defaults: defaults)

        XCTAssertEqual(vm.activeTab, .capture)
    }
}
