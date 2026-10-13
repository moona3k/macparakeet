import XCTest

@testable import MacParakeet

final class MarkdownMeasureWidthTests: XCTestCase {
    func testFiniteProposalIsKept() {
        XCTAssertEqual(MarkdownMeasureWidth.resolve(720), 720)
    }

    func testMissingOrUnboundedProposalStaysAReadingWidth() {
        XCTAssertEqual(MarkdownMeasureWidth.resolve(nil), MarkdownMeasureWidth.unspecifiedFallback)
        XCTAssertEqual(MarkdownMeasureWidth.resolve(.infinity), MarkdownMeasureWidth.unspecifiedFallback)
        XCTAssertEqual(MarkdownMeasureWidth.resolve(0), MarkdownMeasureWidth.unspecifiedFallback)
        XCTAssertEqual(MarkdownMeasureWidth.resolve(-8), MarkdownMeasureWidth.unspecifiedFallback)
        XCTAssertTrue(MarkdownMeasureWidth.resolve(nil).isFinite)
        XCTAssertLessThan(MarkdownMeasureWidth.resolve(nil), 1_000)
    }
}
