import XCTest
@testable import MacParakeetCore

final class TextRefinementServiceTests: XCTestCase {
    func testCleanModeReturnsDeterministicText() async {
        let service = TextRefinementService()
        let result = await service.refine(
            rawText: "um hello world",
            mode: .clean,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.path, .deterministic)
    }

    func testRawModeReturnsNilText() async {
        let service = TextRefinementService()
        let result = await service.refine(
            rawText: "um hello world",
            mode: .raw,
            customWords: [],
            snippets: []
        )

        XCTAssertNil(result.text, "Raw mode returns nil (no processing applied)")
        XCTAssertEqual(result.path, .raw)
    }
}
