import XCTest
@testable import MacParakeetCore

final class TextSnippetModelTests: XCTestCase {
    func testDefaultValues() {
        let snippet = TextSnippet(trigger: "my signature", expansion: "Best regards, David")

        XCTAssertEqual(snippet.trigger, "my signature")
        XCTAssertEqual(snippet.expansion, "Best regards, David")
        XCTAssertTrue(snippet.isEnabled)
        XCTAssertEqual(snippet.useCount, 0)
    }

    func testDisabledSnippet() {
        let snippet = TextSnippet(trigger: "test", expansion: "Test expansion", isEnabled: false)

        XCTAssertFalse(snippet.isEnabled)
    }

    func testUseCountTracking() {
        var snippet = TextSnippet(trigger: "my address", expansion: "123 Main St")
        snippet.useCount = 5

        XCTAssertEqual(snippet.useCount, 5)
    }
}
