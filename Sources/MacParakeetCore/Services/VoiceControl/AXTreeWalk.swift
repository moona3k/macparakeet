import CoreGraphics
import Foundation

/// The cheap facts the walk needs to decide whether a node is worth a closer
/// look. Everything expensive (value, settable, selection, fingerprint) is read
/// later, and only for the nodes the walk kept.
public struct AXWalkFacts: Sendable, Equatable {
    public var role: String
    /// Title, description or help, in that order. Empty when the app gave none.
    public var label: String
    /// Screen points. `nil` when the app reports no frame; a zero-size frame is
    /// a container and is never taken as evidence of being off screen.
    public var frame: CGRect?
    public var hidden: Bool
    public var pressable: Bool
    /// Menu bar items expose an open menu through `AXSelected`. Closed menus are
    /// thousands of zero-size items and are never walked.
    public var menuOpen: Bool
    /// Static text keeps its words in `AXValue`; the source reads it only for
    /// that role so the summary can be built without a second pass.
    public var text: String?

    public init(
        role: String, label: String = "", frame: CGRect? = nil, hidden: Bool = false, pressable: Bool = false,
        menuOpen: Bool = false, text: String? = nil
    ) {
        self.role = role; self.label = label; self.frame = frame; self.hidden = hidden
        self.pressable = pressable; self.menuOpen = menuOpen; self.text = text
    }
}

/// The only way into the tree. Production wraps `AXUIElement`; tests use a dict.
public protocol AXTreeSource {
    associatedtype Node: Hashable
    func children(of node: Node) -> [Node]
    func facts(of node: Node) -> AXWalkFacts
}

public struct AXWalkCaps: Sendable, Equatable {
    public var maxNodes: Int
    public var maxChildren: Int
    public var maxDepth: Int
    public var timeBudget: Duration
    public var offscreenCap: Int
    /// Anything thinner is a Chromium sliver for a scrolled-out node, not a control.
    public var minSide: CGFloat
    public init(
        maxNodes: Int = 1_200, maxChildren: Int = 250, maxDepth: Int = 32, timeBudget: Duration = .seconds(2),
        offscreenCap: Int = 120, minSide: CGFloat = 4
    ) {
        self.maxNodes = max(1, maxNodes); self.maxChildren = max(1, maxChildren); self.maxDepth = max(1, maxDepth)
        self.timeBudget = timeBudget; self.offscreenCap = max(0, offscreenCap); self.minSide = minSide
    }
}

public struct AXWalkEntry<Node: Hashable>: Equatable {
    public let node: Node
    /// Facts with the label recovered from a parent control or a shallow child
    /// when the node itself had none.
    public let facts: AXWalkFacts
    public let depth: Int
    public let inWebArea: Bool
    public let isFocused: Bool
    /// True when the node's frame is on the display and inside the window;
    /// false for the off-screen pressables offered separately.
    public let visible: Bool
}

public struct AXWalkResult<Node: Hashable> {
    /// Candidates in traversal order: visible, labelled or editable or focused.
    public var candidates: [AXWalkEntry<Node>] = []
    /// Labelled pressables the app exposes but does not show. `AXPress` does not
    /// need visibility; a mouse click would land somewhere else entirely.
    public var offscreen: [AXWalkEntry<Node>] = []
    /// Visible static text in traversal order, for the snapshot summary.
    public var staticText: [String] = []
    public var visited = 0
    /// False when a cap cut the walk short or a container had more children than allowed.
    public var complete = true
}

/// Depth-first hunt for controls, pure over an `AXTreeSource`. Pruning rules:
///
/// 1. A hidden node ends its subtree.
/// 2. A closed menu bar item's children are never walked.
/// 3. A real frame wholly off the display ends its subtree for visibility, but
///    labelled pressables inside it are still collected as off-screen controls
///    until `offscreenCap`, after which the subtree is dropped outright.
/// 4. A node under `minSide` on either edge is a sliver, never visible.
/// 5. A control with no label borrows one: a bare child (usually a decorative
///    image) takes its parent control's label and is then not emitted twice; a
///    row, cell or button takes the first shallow static text or image name.
/// 6. Nameless groups are layout boxes, never candidates, even when pressable.
/// 7. The same role, name and frame is the same control however many objects
///    the bridge hands over for it. Nameless nodes are never de-duplicated.
/// 8. Node and time caps stop the walk and say so.
private struct WalkFrame<Node: Hashable> {
    let node: Node
    let depth: Int
    let inWeb: Bool
    let hidden: Bool
    let parentLabel: String
    let parentEmitted: Bool
}

public enum AXTreeWalk {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    static let controlRoles: Set<String> = [
        "AXButton", "AXCell", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor", "AXLink",
        "AXMenuBarItem", "AXMenuButton", "AXMenuItem", "AXPopUpButton", "AXRadioButton", "AXRow", "AXScrollArea",
        "AXSearchField", "AXSlider", "AXTab", "AXTextArea", "AXTextField",
    ]
    /// A bare child borrows the label of a parent that is itself a control.
    static let labelParentRoles: Set<String> = [
        "AXButton", "AXCell", "AXCheckBox", "AXLink", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXRow",
        "AXTab",
    ]
    /// These keep their label in a shallow child rather than on themselves.
    static let labelDescendantRoles: Set<String> = [
        "AXButton", "AXCell", "AXLink", "AXMenuButton", "AXPopUpButton", "AXRow", "AXTab",
    ]
    static let menuRoles: Set<String> = ["AXMenuBarItem", "AXMenuItem", "AXMenu", "AXMenuBar"]
    static let labelFanout = 8

    public static func run<S: AXTreeSource>(
        roots: [S.Node], source: S, display: CGRect, window: CGRect?, focused: S.Node? = nil,
        caps: AXWalkCaps = AXWalkCaps(), now: () -> ContinuousClock.Instant = { .now }
    ) -> AXWalkResult<S.Node> {
        var result = AXWalkResult<S.Node>()
        let deadline = now().advanced(by: caps.timeBudget)
        var stack = roots.reversed().map {
            WalkFrame(node: $0, depth: 0, inWeb: false, hidden: false, parentLabel: "", parentEmitted: false)
        }
        var visited: Set<S.Node> = []
        var seenKeys: Set<String> = []
        var textLength = 0

        while let frame = stack.popLast() {
            guard result.visited < caps.maxNodes, now() < deadline else { result.complete = false; break }
            guard visited.insert(frame.node).inserted else { continue }
            result.visited += 1
            var facts = source.facts(of: frame.node)
            if facts.hidden { continue }
            if let key = subtreeKey(facts), !seenKeys.insert(key).inserted { continue }

            let offDisplay = frame.hidden || isOffDisplay(facts.frame, display: display)
            if offDisplay, result.offscreen.count >= caps.offscreenCap { continue }
            let kids = source.children(of: frame.node)

            var inherited = false
            if facts.label.isEmpty, labelDescendantRoles.contains(facts.role) {
                facts.label = descendantLabel(kids, source: source)
            }
            if facts.label.isEmpty, !frame.parentLabel.isEmpty, facts.role != "AXStaticText" {
                facts.label = frame.parentLabel; inherited = true
            }
            let duplicateOfParent = inherited && frame.parentEmitted
            let namelessGroup = facts.role == "AXGroup" && facts.label.isEmpty
            let isFocused = focused.map { $0 == frame.node } ?? false
            let visible =
                !offDisplay
                && isVisible(facts, role: facts.role, display: display, window: window, minSide: caps.minSide)
            let inWeb = frame.inWeb || facts.role == "AXWebArea"

            var emitted = false
            if !duplicateOfParent, !namelessGroup {
                if visible {
                    let editable = textRoles.contains(facts.role)
                    let pressableText = facts.role == "AXStaticText" && facts.pressable
                    let control = facts.pressable || controlRoles.contains(facts.role)
                    // Scroll areas are rarely labelled and are addressed by position, not name.
                    let unlabelledOK = facts.role == "AXScrollArea"
                    if isFocused || editable || pressableText || (control && (!facts.label.isEmpty || unlabelledOK)) {
                        result.candidates.append(
                            AXWalkEntry(
                                node: frame.node, facts: facts, depth: frame.depth, inWebArea: inWeb,
                                isFocused: isFocused, visible: true))
                        emitted = true
                    } else if facts.role == "AXStaticText", textLength < 3_000 {
                        let words = facts.label.isEmpty ? (facts.text ?? "") : facts.label
                        if !words.isEmpty {
                            let clipped = String(words.prefix(250))
                            result.staticText.append(clipped); textLength += clipped.count
                        }
                    }
                } else if facts.pressable, !facts.label.isEmpty, facts.frame != nil,
                    result.offscreen.count < caps.offscreenCap
                {
                    result.offscreen.append(
                        AXWalkEntry(
                            node: frame.node, facts: facts, depth: frame.depth, inWebArea: inWeb, isFocused: isFocused,
                            visible: false))
                }
            }

            let closedMenu = facts.role == "AXMenuBarItem" && !facts.menuOpen
            guard !closedMenu else { continue }
            if frame.depth >= caps.maxDepth {
                if !kids.isEmpty { result.complete = false }
                continue
            }
            if kids.count > caps.maxChildren { result.complete = false }
            let childLabel = labelParentRoles.contains(facts.role) ? facts.label : ""
            for kid in kids.prefix(caps.maxChildren).reversed() {
                stack.append(
                    WalkFrame(
                        node: kid, depth: frame.depth + 1, inWeb: inWeb, hidden: offDisplay, parentLabel: childLabel,
                        parentEmitted: emitted))
            }
        }
        if !stack.isEmpty { result.complete = false }
        return result
    }

    static func isOffDisplay(_ frame: CGRect?, display: CGRect) -> Bool {
        guard let frame, frame.width > 0, frame.height > 0 else { return false }
        return !frame.intersects(display)
    }

    static func isVisible(_ facts: AXWalkFacts, role: String, display: CGRect, window: CGRect?, minSide: CGFloat)
        -> Bool
    {
        guard let frame = facts.frame, frame.width > 0, frame.height > 0 else { return false }
        guard min(frame.width, frame.height) >= minSide else { return false }
        guard frame.intersects(display) else { return false }
        if let window, !menuRoles.contains(role) { return frame.intersects(window) }
        return true
    }

    /// Identity for de-duplication. Only a *named* node with a real frame has one:
    /// nameless containers (web layouts nest same-sized `AXGroup`s many levels
    /// deep) must never collapse into each other, or the second one's subtree is
    /// lost.
    static func subtreeKey(_ facts: AXWalkFacts) -> String? {
        guard let frame = facts.frame, frame.width > 0, frame.height > 0 else { return nil }
        let name = facts.label.isEmpty ? (facts.text ?? "") : facts.label
        guard !name.isEmpty else { return nil }
        return
            "\(facts.role)|\(name)|\(Int(frame.minX.rounded()))|\(Int(frame.minY.rounded()))|\(Int(frame.width.rounded()))|\(Int(frame.height.rounded()))"
    }

    static func descendantLabel<S: AXTreeSource>(_ kids: [S.Node], source: S) -> String {
        for kid in kids.prefix(labelFanout) {
            let facts = source.facts(of: kid)
            if facts.role == "AXStaticText" || facts.role == "AXImage", !facts.label.isEmpty { return facts.label }
            if facts.role == "AXStaticText", let text = facts.text, !text.isEmpty, text.count <= 120 { return text }
        }
        for kid in kids.prefix(labelFanout) {
            for grandkid in source.children(of: kid).prefix(labelFanout) {
                let facts = source.facts(of: grandkid)
                if facts.role == "AXStaticText" || facts.role == "AXImage", !facts.label.isEmpty { return facts.label }
                if facts.role == "AXStaticText", let text = facts.text, !text.isEmpty, text.count <= 120 { return text }
            }
        }
        return ""
    }
}
