import XCTest
@testable import MacParakeetCore

final class MenuBarTransformCatalogTests: XCTestCase {
    func testListingsSkipHiddenAndInvisiblePromptsAndKeepSortOrder() {
        let polish = Prompt(
            id: UUID(),
            name: "Polish",
            content: "polish",
            category: .transform,
            isBuiltIn: true,
            sortOrder: 0
        )
        let distill = Prompt(
            id: UUID(),
            name: "Distill",
            content: "distill",
            category: .transform,
            isBuiltIn: true,
            sortOrder: 1
        )
        let hidden = Prompt(
            id: UUID(),
            name: "Decide",
            content: "decide",
            category: .transform,
            isBuiltIn: true,
            sortOrder: 2
        )
        let summary = Prompt(
            name: "Summary",
            content: "summarize",
            category: .result,
            sortOrder: 0
        )
        let invisible = Prompt(
            name: "Old",
            content: "old",
            category: .transform,
            isVisible: false,
            sortOrder: 0
        )

        let listings = MenuBarTransformCatalog.listings(
            from: [distill, summary, invisible, hidden, polish],
            hiddenIDs: [hidden.id]
        )

        XCTAssertEqual(listings.map(\.name), ["Polish", "Distill"])
        XCTAssertEqual(listings.map(\.id), [polish.id, distill.id])
    }

    func testMissingHiddenSetShowsEveryVisibleTransform() {
        let prompt = Prompt(name: "Polish", content: "x", category: .transform)
        let listings = MenuBarTransformCatalog.listings(from: [prompt], hiddenIDs: [])
        XCTAssertEqual(listings.map(\.name), ["Polish"])
    }
}
