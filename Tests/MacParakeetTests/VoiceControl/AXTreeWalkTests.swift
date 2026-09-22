import CoreGraphics
import Foundation
import XCTest

@testable import MacParakeetCore

/// The pruning rules against a plain dictionary tree. No live app, no AX.
final class AXTreeWalkTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let window = CGRect(x: 100, y: 50, width: 1200, height: 900)

    final class FakeNode: Hashable {
        var facts: AXWalkFacts
        var children: [FakeNode]
        init(_ facts: AXWalkFacts, children: [FakeNode] = []) { self.facts = facts; self.children = children }
        static func == (lhs: FakeNode, rhs: FakeNode) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }
    struct FakeSource: AXTreeSource {
        var reads = 0
        func children(of node: FakeNode) -> [FakeNode] { node.children }
        func facts(of node: FakeNode) -> AXWalkFacts { node.facts }
    }

    private func node(
        _ role: String, _ label: String = "", frame: CGRect? = CGRect(x: 200, y: 100, width: 100, height: 20),
        press: Bool = false, hidden: Bool = false, menuOpen: Bool = false, text: String? = nil,
        children: [FakeNode] = []
    ) -> FakeNode {
        FakeNode(
            AXWalkFacts(
                role: role, label: label, frame: frame, hidden: hidden, pressable: press, menuOpen: menuOpen, text: text
            ),
            children: children)
    }
    private func app(_ children: FakeNode...) -> FakeNode {
        // An application element reports a zero-size frame; that is a container, not off-screen evidence.
        node("AXApplication", "Finder", frame: CGRect(x: 0, y: 1117, width: 0, height: 0), children: children)
    }
    private func walk(
        _ root: FakeNode, focused: FakeNode? = nil, caps: AXWalkCaps = AXWalkCaps(), window: CGRect? = nil
    )
        -> AXWalkResult<FakeNode>
    {
        AXTreeWalk.run(
            roots: [root], source: FakeSource(), display: display, window: window ?? self.window, focused: focused,
            caps: caps)
    }
    private func labels(_ result: AXWalkResult<FakeNode>) -> [String] { result.candidates.map(\.facts.label) }

    func testKeepsLabelledControlsInTraversalOrderAndReportsComplete() {
        let result = walk(
            app(
                node("AXButton", "Share", press: true),
                node("AXLink", "Pricing", frame: CGRect(x: 200, y: 140, width: 60, height: 16), press: true)))
        XCTAssertEqual(labels(result), ["Share", "Pricing"])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.visited, 3)
    }

    func testFramelessRootDoesNotPruneTheTree() {
        let root = node("AXApplication", "Finder", frame: nil, children: [node("AXButton", "Share", press: true)])
        XCTAssertEqual(labels(walk(root)), ["Share"])
    }

    func testUnlabelledPressOnlyControlsAreDroppedButEditableAndFocusedStay() {
        let field = node("AXTextField", "")
        let icon = node("AXButton", "", press: true)
        let focusedGroup = node("AXGroup", "Toolbar")
        let result = walk(app(icon, field, focusedGroup), focused: focusedGroup)
        XCTAssertEqual(result.candidates.map(\.facts.role), ["AXTextField", "AXGroup"])
        XCTAssertTrue(result.candidates[1].isFocused)
    }

    func testNamelessGroupIsNeverACandidateEvenWhenPressable() {
        let result = walk(app(node("AXGroup", "", press: true), node("AXGroup", "Toolbar", press: true)))
        XCTAssertEqual(labels(result), ["Toolbar"])
    }

    func testPressActionMakesStaticTextACandidateWithoutALabel() {
        let result = walk(
            app(
                node("AXStaticText", "", press: true, text: "Zürich, Switzerland"),
                node("AXStaticText", "", text: "Just words")))
        XCTAssertEqual(result.candidates.map { $0.facts.text }, ["Zürich, Switzerland"])
        XCTAssertEqual(result.staticText, ["Just words"])
    }

    func testStaticTextIsCollectedForTheSummaryOnlyWhenVisible() {
        let offscreen = node(
            "AXStaticText", "", frame: CGRect(x: 200, y: 40_000, width: 100, height: 20), text: "far below")
        let result = walk(app(node("AXStaticText", "Heading"), offscreen))
        XCTAssertEqual(result.staticText, ["Heading"])
    }

    func testSliversAndOffDisplayFramesAreNotVisible() {
        let tree = app(
            node("AXLink", "clamped", frame: CGRect(x: 200, y: 125, width: 72, height: 1), press: true),
            node("AXLink", "narrow", frame: CGRect(x: 200, y: 125, width: 2, height: 30), press: true),
            node("AXLink", "below the display", frame: CGRect(x: 200, y: 40_000, width: 200, height: 30), press: true),
            node("AXLink", "above the display", frame: CGRect(x: 200, y: -300, width: 200, height: 30), press: true),
            node("AXLink", "on screen", frame: CGRect(x: 200, y: 125, width: 72, height: 30), press: true))
        let result = walk(tree)
        XCTAssertEqual(labels(result), ["on screen"])
        XCTAssertEqual(
            Set(result.offscreen.map(\.facts.label)), ["clamped", "narrow", "below the display", "above the display"],
            "AXPress does not need visibility; labelled pressables are kept as off-screen controls")
    }

    func testOffDisplayContainerPrunesItsSubtreeFromVisibilityButCollectsPressables() {
        let row = node(
            "AXRow", "Note 900", frame: CGRect(x: 1085, y: 42_718, width: 280, height: 68), press: true,
            children: [node("AXButton", "Delete", frame: CGRect(x: 300, y: 300, width: 40, height: 20), press: true)])
        let result = walk(app(row))
        XCTAssertEqual(
            labels(result), [], "a child claiming an on-screen frame under an off-screen row is still not visible")
        XCTAssertEqual(result.offscreen.map(\.facts.label), ["Note 900", "Delete"])
    }

    func testOffscreenCapStopsCollectingAndPrunesTheRest() {
        let rows = (0..<10).map { index in
            node(
                "AXRow", "Note \(index)", frame: CGRect(x: 100, y: 5_000 + CGFloat(index) * 70, width: 280, height: 68),
                press: true)
        }
        let result = walk(app(rows), caps: AXWalkCaps(offscreenCap: 3))
        XCTAssertEqual(result.offscreen.count, 3)
        XCTAssertTrue(result.complete, "an off-screen cap is not incompleteness; those controls were never on screen")
    }
    private func app(_ children: [FakeNode]) -> FakeNode {
        node("AXApplication", "Finder", frame: CGRect(x: 0, y: 1117, width: 0, height: 0), children: children)
    }

    func testOutsideTheWindowIsNotVisibleExceptForMenus() {
        let elsewhere = node(
            "AXButton", "Other window", frame: CGRect(x: 1500, y: 1000, width: 80, height: 20), press: true)
        let menu = node("AXMenuBarItem", "File", frame: CGRect(x: 60, y: 0, width: 40, height: 22), press: true)
        let result = walk(app(elsewhere, menu))
        XCTAssertEqual(labels(result), ["File"])
        XCTAssertEqual(result.offscreen.map(\.facts.label), ["Other window"])
    }

    func testHiddenNodeEndsItsSubtree() {
        let hidden = node("AXGroup", "Sheet", hidden: true, children: [node("AXButton", "OK", press: true)])
        XCTAssertEqual(labels(walk(app(hidden, node("AXButton", "Cancel", press: true)))), ["Cancel"])
    }

    func testClosedMenuBarItemChildrenAreNeverWalked() {
        let closed = node(
            "AXMenuBarItem", "File", frame: CGRect(x: 60, y: 0, width: 40, height: 22), press: true,
            children: [
                node(
                    "AXMenu", "", frame: .zero,
                    children: (0..<50).map { node("AXMenuItem", "Item \($0)", frame: .zero, press: true) })
            ])
        let open = node(
            "AXMenuBarItem", "Edit", frame: CGRect(x: 110, y: 0, width: 40, height: 22), press: true, menuOpen: true,
            children: [
                node(
                    "AXMenu", "", frame: CGRect(x: 110, y: 22, width: 200, height: 400),
                    children: [
                        node("AXMenuItem", "Undo", frame: CGRect(x: 110, y: 30, width: 200, height: 20), press: true)
                    ])
            ])
        let result = walk(app(closed, open))
        XCTAssertEqual(labels(result), ["File", "Edit", "Undo"])
        XCTAssertEqual(result.visited, 5, "app, File, Edit, the open AXMenu, Undo; nothing under the closed menu")
    }

    func testBareChildBorrowsItsParentControlLabelOnce() {
        let button = node("AXButton", "Share", press: true, children: [node("AXImage", "", press: true)])
        let result = walk(app(button))
        XCTAssertEqual(labels(result), ["Share"], "the decorative image is the same control, not a second option")
    }

    func testRowTakesItsLabelFromAShallowStaticText() {
        let row = node(
            "AXRow", "", press: true,
            children: [node("AXGroup", "", children: [node("AXStaticText", "", text: "Quarterly report")])])
        XCTAssertEqual(labels(walk(app(row))), ["Quarterly report"], "two levels deep is the limit")
        let shallow = node("AXRow", "", press: true, children: [node("AXStaticText", "", text: "Quarterly report")])
        XCTAssertEqual(labels(walk(app(shallow))), ["Quarterly report"])
        let image = node("AXButton", "", press: true, children: [node("AXImage", "Compose")])
        XCTAssertEqual(labels(walk(app(image))), ["Compose"])
    }

    func testSameRoleLabelAndFrameIsWalkedOnce() {
        let frame = CGRect(x: 300, y: 300, width: 80, height: 20)
        let result = walk(
            app(
                node("AXButton", "Save", frame: frame, press: true), node("AXButton", "Save", frame: frame, press: true)
            ))
        XCTAssertEqual(labels(result), ["Save"])
    }

    func testNamelessContainersWithIdenticalFramesAreNeverCollapsed() {
        // Web layouts nest same-sized nameless groups; the second must keep its subtree.
        let frame = CGRect(x: 120, y: 80, width: 800, height: 600)
        let first = node("AXGroup", "", frame: frame, children: [node("AXButton", "Ask Gemini", press: true)])
        let second = node(
            "AXGroup", "", frame: frame,
            children: [node("AXLink", "Pull requests", frame: CGRect(x: 200, y: 140, width: 100, height: 20), press: true)])
        let nested = node("AXGroup", "", frame: frame, children: [first, second])
        XCTAssertEqual(labels(walk(app(nested))), ["Ask Gemini", "Pull requests"])
    }

    func testNodeCapStopsTheWalkAndReportsIncomplete() {
        let many = (0..<40).map {
            node(
                "AXButton", "B\($0)", frame: CGRect(x: 200, y: 100 + CGFloat($0) * 25, width: 80, height: 20),
                press: true)
        }
        let result = walk(app(many), caps: AXWalkCaps(maxNodes: 10))
        XCTAssertEqual(result.candidates.count, 9)
        XCTAssertFalse(result.complete)
    }

    func testTimeCapStopsTheWalk() {
        var ticks = 0
        let clock: () -> ContinuousClock.Instant = {
            ticks += 1
            return ContinuousClock.Instant.now.advanced(by: .milliseconds(ticks * 400))
        }
        let many = (0..<40).map {
            node(
                "AXButton", "B\($0)", frame: CGRect(x: 200, y: 100 + CGFloat($0) * 25, width: 80, height: 20),
                press: true)
        }
        let result = AXTreeWalk.run(
            roots: [app(many)], source: FakeSource(), display: display, window: window,
            caps: AXWalkCaps(timeBudget: .seconds(1)), now: clock)
        XCTAssertFalse(result.complete)
        XCTAssertLessThan(result.candidates.count, 40)
    }

    func testTooManyChildrenOrTooDeepReportsIncomplete() {
        let wide = app((0..<260).map { node("AXStaticText", "t\($0)") })
        XCTAssertFalse(walk(wide, caps: AXWalkCaps(maxChildren: 250)).complete)
        var deep = node("AXButton", "Leaf", press: true)
        for level in 0..<5 { deep = node("AXGroup", "L\(level)", children: [deep]) }
        let result = walk(app(deep), caps: AXWalkCaps(maxDepth: 3))
        XCTAssertFalse(result.complete)
        XCTAssertFalse(labels(result).contains("Leaf"))
    }

    func testWebAreaMarksDescendants() {
        let web = node("AXWebArea", "", children: [node("AXLink", "Docs", press: true)])
        let result = walk(app(node("AXButton", "Back", press: true), web))
        XCTAssertEqual(
            result.candidates.map { ($0.facts.label, $0.inWebArea) }.map { "\($0.0):\($0.1)" },
            ["Back:false", "Docs:true"])
    }

    func testScrollAreaIsACandidateWithoutALabel() {
        let result = walk(app(node("AXScrollArea", "", frame: CGRect(x: 120, y: 80, width: 800, height: 600))))
        XCTAssertEqual(result.candidates.map(\.facts.role), ["AXScrollArea"])
    }
}
