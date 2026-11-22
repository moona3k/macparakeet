import XCTest

@testable import MacParakeet

@MainActor
final class NotchOccupancyTests: XCTestCase {
    func testReleaseByOwnerFreesTheNotch() {
        let occupancy = NotchOccupancy()
        let owner = NSObject()
        occupancy.claim(by: owner)
        XCTAssertTrue(occupancy.dictationActive)
        occupancy.release(by: owner)
        XCTAssertFalse(occupancy.dictationActive)
    }

    func testOlderSessionCannotReleaseANewerClaim() {
        let occupancy = NotchOccupancy()
        let older = NSObject()
        let newer = NSObject()
        occupancy.claim(by: older)
        occupancy.claim(by: newer)
        occupancy.release(by: older)
        XCTAssertTrue(occupancy.dictationActive)
        occupancy.release(by: newer)
        XCTAssertFalse(occupancy.dictationActive)
    }
}
