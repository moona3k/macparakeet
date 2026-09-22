import CoreGraphics
import XCTest

@testable import MacParakeetCore

final class ScreenTextSourceTests: XCTestCase {
    private func block(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 100, h: CGFloat = 16) -> ScreenTextBlock {
        ScreenTextBlock(text: text, confidence: 0.9, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testReadingOrderSortsRowsThenColumns() {
        let ordered = ScreenTextMerge.readingOrder([
            block("row2-right", x: 300, y: 100), block("row1-right", x: 300, y: 10),
            block("row2-left", x: 10, y: 103), block("row1-left", x: 10, y: 12),
        ])
        XCTAssertEqual(ordered.map(\.text), ["row1-left", "row1-right", "row2-left", "row2-right"])
    }

    func testMergeLinesJoinsAlignedNeighboursAndLeavesDistantOnes() {
        let merged = ScreenTextMerge.mergeLines([
            block("Flight departs", x: 10, y: 10), block("at 9:40 tomorrow", x: 12, y: 30),
            block("Far away", x: 10, y: 200),
        ])
        XCTAssertEqual(merged.map(\.text), ["Flight departs at 9:40 tomorrow", "Far away"])
        XCTAssertEqual(merged[0].frame, CGRect(x: 10, y: 10, width: 102, height: 36))
    }

    func testMatchesRequiresOverlapAndText() {
        let searched = block("Search flights", x: 10, y: 10)
        XCTAssertTrue(
            ScreenTextMerge.matches(
                searched, controlLabel: "search  FLIGHTS", controlFrame: CGRect(x: 0, y: 5, width: 130, height: 30)))
        XCTAssertFalse(
            ScreenTextMerge.matches(
                searched, controlLabel: "Search flights", controlFrame: CGRect(x: 500, y: 500, width: 100, height: 20)))
        XCTAssertFalse(
            ScreenTextMerge.matches(
                searched, controlLabel: "Book now", controlFrame: CGRect(x: 0, y: 5, width: 130, height: 30)))
    }

    func testUnexplainedDropsExplainedExcludedAndSecureLines() {
        let blocks = [
            block("Search flights", x: 10, y: 10), block("$412 round trip", x: 10, y: 50),
            block("hunter2", x: 10, y: 100), block("Enter your password", x: 10, y: 150),
        ]
        let result = ScreenTextMerge.unexplained(
            blocks, controls: [("Search flights", CGRect(x: 8, y: 8, width: 110, height: 20))],
            excludedFrames: [CGRect(x: 0, y: 95, width: 200, height: 26)])
        XCTAssertEqual(result.map(\.text), ["$412 round trip"])
    }

    func testTextTargetsPipelineShapesTargetsAndSummary() {
        var blocks = [
            block("Search flights", x: 10, y: 10), block("$412 round trip", x: 10, y: 50),
            block("Enter your password", x: 10, y: 150), block("Already in tree", x: 10, y: 200),
        ]
        for index in 0..<100 { blocks.append(block("Row \(index)", x: 400, y: CGFloat(index) * 40)) }
        let result = NativeVoiceControlAdapter.textTargets(
            from: blocks, controls: [("Search flights", CGRect(x: 8, y: 8, width: 110, height: 20))],
            excludedFrames: [], existingText: ["already  IN tree"])
        XCTAssertFalse(result.targets.contains { $0.label == "Search flights" })
        let price = result.targets.first { $0.label == "$412 round trip" }
        XCTAssertEqual(price?.role, "text")
        XCTAssertEqual(price?.operations, [.press])
        XCTAssertEqual(price?.isNavigation, false)
        XCTAssertTrue(result.summaryLines.contains("$412 round trip"))
        XCTAssertFalse(result.summaryLines.contains { $0.lowercased().contains("password") })
        XCTAssertFalse(result.targets.contains { $0.label.lowercased().contains("password") })
        XCTAssertFalse(result.summaryLines.contains("Already in tree"))
        XCTAssertEqual(result.targets.count, 80)
        XCTAssertEqual(result.blocks.count, 80)
    }

    func testLegalityKeepsTextTargetsOutOfPickersAndInPlain() {
        let textTarget = VoiceControlTarget(id: "n:9", label: "Zurich, Switzerland", role: "text", operations: [.press])
        let picker = VoiceControlSnapshot(
            contextID: "c", applicationName: "Chrome",
            targets: [
                VoiceControlTarget(
                    id: "city", label: "Zurich, Switzerland", role: "AXStaticText", operations: [.press],
                    isFocused: true),
                VoiceControlTarget(id: "search", label: "Search flights", role: "AXButton", operations: [.press]),
                VoiceControlTarget(
                    id: "else", label: "Where else?", role: "AXComboBox", operations: [.setValue, .press]),
                textTarget,
            ])
        XCTAssertEqual(VoiceControlSituation.classify(picker), .suggestionPicker)
        XCTAssertFalse(VoiceControlLegality.offeredTargets(in: picker).contains { $0.role == "text" })

        let onlyText = VoiceControlSnapshot(
            contextID: "c", applicationName: "Chrome",
            targets: [
                VoiceControlTarget(
                    id: "t", label: "Zurich, Switzerland", role: "text", operations: [.press], isFocused: true)
            ])
        XCTAssertEqual(VoiceControlSituation.classify(onlyText), .plain)

        let plain = VoiceControlSnapshot(
            contextID: "c", applicationName: "Notes",
            targets: [VoiceControlTarget(id: "b", label: "Save", role: "AXButton", operations: [.press]), textTarget])
        XCTAssertTrue(VoiceControlLegality.offeredTargets(in: plain).contains { $0.role == "text" })
    }

    func testSingleGlyphsAndSymbolRunsAreNotAddressable() {
        for glyph in ["f", "#", "•", "→", "• C"] { XCTAssertFalse(ScreenTextMerge.isAddressable(glyph), glyph) }
        for word in ["OK", "Ask Gemini", "$412", "9:41"] { XCTAssertTrue(ScreenTextMerge.isAddressable(word), word) }
        let blocks = [
            ScreenTextBlock(text: "#", confidence: 0.9, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            ScreenTextBlock(text: "Compose", confidence: 0.9, frame: CGRect(x: 0, y: 20, width: 60, height: 10)),
        ]
        XCTAssertEqual(ScreenTextMerge.unexplained(blocks, controls: [], excludedFrames: []).map(\.text), ["Compose"])
    }

    func testCapturePlanFailsClosedOnAmbiguousWindowsAndRecordsOccluders() {
        let window = CGRect(x: 10, y: 20, width: 400, height: 300)
        let owner = ScreenTextCaptureWindow(id: 7, processID: 42, frame: window, layer: 0)
        let twin = ScreenTextCaptureWindow(id: 8, processID: 42, frame: window, layer: 0)
        XCTAssertNil(ScreenTextCapturePlan.resolve(window: window, processID: 42, windows: [owner, twin]))
        let overlay = ScreenTextCaptureWindow(
            id: 3, processID: 99, frame: CGRect(x: 40, y: 40, width: 80, height: 40), layer: 0)
        let plan = ScreenTextCapturePlan.resolve(window: window, processID: 42, windows: [overlay, owner])
        XCTAssertEqual(plan?.windowID, 7)
        XCTAssertEqual(plan?.exclusions, [overlay.frame])
        XCTAssertNil(ScreenTextCapturePlan.resolve(window: .infinite, processID: 42, windows: [owner]))
    }
}
