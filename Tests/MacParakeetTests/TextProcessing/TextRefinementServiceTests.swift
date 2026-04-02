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

    func testRawModeExtractsActionButSkipsOtherProcessing() async {
        let service = TextRefinementService()
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = await service.refine(
            rawText: "hello return",
            mode: .raw,
            customWords: [],
            snippets: snippets
        )
        // Raw mode strips trigger but does NOT apply filler removal, custom words, etc.
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.postPasteAction, .returnKey)
        XCTAssertEqual(result.path, .raw)
    }

    func testRawModeNoActionWhenNoTrigger() async {
        let service = TextRefinementService()
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = await service.refine(
            rawText: "hello world",
            mode: .raw,
            customWords: [],
            snippets: snippets
        )
        XCTAssertNil(result.text, "Raw mode returns nil when no action trigger")
        XCTAssertNil(result.postPasteAction)
    }

    func testRawModeSkipsTextSnippets() async {
        let service = TextRefinementService()
        let snippets = [
            TextSnippet(trigger: "my sig", expansion: "Best regards")
        ]
        let result = await service.refine(
            rawText: "hello my sig",
            mode: .raw,
            customWords: [],
            snippets: snippets
        )
        // Text snippets are NOT expanded in raw mode
        XCTAssertNil(result.text)
        XCTAssertNil(result.postPasteAction)
    }

    func testDeterministicModeReturnsAction() async {
        let service = TextRefinementService()
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = await service.refine(
            rawText: "hello return",
            mode: .clean,
            customWords: [],
            snippets: snippets
        )
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }
}
