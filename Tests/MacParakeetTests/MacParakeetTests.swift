import XCTest
@testable import MacParakeetCore

final class MacParakeetTests: XCTestCase {

    func testVersionExists() {
        XCTAssertFalse(macParakeetCoreVersion.isEmpty)
    }

    func testTranscriptionServiceInitializes() {
        let service = TranscriptionService()
        XCTAssertNotNil(service)
    }
}
