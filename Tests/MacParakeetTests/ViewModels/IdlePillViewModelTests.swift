import XCTest
@testable import MacParakeetViewModels

@MainActor
final class IdlePillViewModelTests: XCTestCase {
    func testInitialState() {
        let vm = IdlePillViewModel()
        XCTAssertFalse(vm.isHovered)
        XCTAssertNil(vm.onStartDictation)
    }

    func testHoverToggle() {
        let vm = IdlePillViewModel()
        vm.isHovered = true
        XCTAssertTrue(vm.isHovered)
        vm.isHovered = false
        XCTAssertFalse(vm.isHovered)
    }

    func testCallbackFires() {
        let vm = IdlePillViewModel()
        var fired = false
        vm.onStartDictation = { fired = true }
        vm.onStartDictation?()
        XCTAssertTrue(fired)
    }
}
