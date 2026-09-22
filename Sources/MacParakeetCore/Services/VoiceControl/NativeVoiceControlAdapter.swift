import AppKit
import ApplicationServices
import Foundation

public enum NativeVoiceControlError: Error, LocalizedError, Sendable, Equatable {
    case permission, noWindow, changed, unsupported, excluded, targetChanged, windowChanged, observationExpired
    public var errorDescription: String? {
        switch self {
        case .permission: "Enable Accessibility for MacParakeet to control this app."
        case .noWindow: "No accessible window is available."
        case .changed: "The app or control changed. Please try again."
        case .targetChanged: "The control’s contents or selection changed. Please repeat the request."
        case .windowChanged: "The focused app or window changed. Please repeat the request."
        case .observationExpired: "The observed interface expired. Please repeat the request."
        case .unsupported: "This control does not support that operation."
        case .excluded: "Voice Control is unavailable in this app."
        }
    }
}

/// Actual AX handles never leave this actor. An ID belongs to exactly one snapshot.
/// Synchronous AX IPC uses a short messaging timeout and never runs on MainActor.
private final class AwaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

public actor NativeVoiceControlAdapter: VoiceControlAdapter {
    private struct Element: @unchecked Sendable { let value: AXUIElement }
    private struct BoundTarget {
        /// `nil` for a text-only target recognised from pixels; it is pressed by a click.
        let element: Element?
        let target: VoiceControlTarget
        let fingerprint: String
        let frame: CGRect?
        let pixelPoint: CGPoint?
        init(
            element: Element?, target: VoiceControlTarget, fingerprint: String, frame: CGRect? = nil,
            pixelPoint: CGPoint? = nil
        ) {
            self.element = element; self.target = target; self.fingerprint = fingerprint
            self.frame = frame; self.pixelPoint = pixelPoint
        }
    }
    private let screenText: (any ScreenTextReading)?
    /// A read that outlasted the observation budget. The next observation of the
    /// same window uses it; a different window cancels it.
    private var pendingScreenText: (token: UUID, pid: Int32, frame: CGRect, task: Task<[ScreenTextBlock], Never>)?
    /// Counts from the last `observe()`, for tests and logging. Never carries text.
    public private(set) var lastObservationStats: (axCandidates: Int, screenTextBlocks: Int, screenTextTargets: Int) =
        (0, 0, 0)
    private var handles: [String: BoundTarget] = [:]
    private var applications: [String: Int32] = [:]
    private var current: VoiceControlSnapshot?
    private var window: Element?
    private var processID: Int32 = 0
    private var observedAt = ContinuousClock.now
    private var undoEdit: (element: Element, window: Element, before: String, after: String, pid: Int32, time: Date)?
    private var undoTargetID: String?
    private let excludedBundleIDs: Set<String>
    private let walkCaps: AXWalkCaps
    private let includeMenus: Bool
    private let includeApplications: Bool
    /// Chromium rebuilds its AX tree when these flags are first set. Ask once per process.
    private var chromiumAccessibilityPIDs: Set<Int32> = []

    public init(
        excludedBundleIDs: Set<String> = [
            "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
            "com.bitwarden.desktop", "com.apple.Passwords",
        ], maxNodes: Int = 1_200, includeMenus: Bool = true, includeApplications: Bool = true,
        screenText: (any ScreenTextReading)? = nil, expectedProcessID: Int32? = nil
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.walkCaps = AXWalkCaps(maxNodes: min(2_000, max(1, maxNodes)))
        self.includeMenus = includeMenus; self.includeApplications = includeApplications
        self.screenText = screenText
        self.expectedProcessID = expectedProcessID
    }

    /// When set, observation refuses every other frontmost app. E2E uses this so a
    /// focus slip cannot snapshot the person's real windows.
    private let expectedProcessID: Int32?

    public func observe() async throws -> VoiceControlSnapshot {
        guard AXIsProcessTrusted() else { throw NativeVoiceControlError.permission }
        var last = NativeVoiceControlError.noWindow
        var acquired: (Int32, String, String, [(Int32, String, String)], AXUIElement)?
        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(180)) }
            let context = await MainActor.run { () -> (Int32, String, String, [(Int32, String, String)])? in
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                let running = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                }.compactMap { app -> (Int32, String, String)? in
                    guard let bundle = app.bundleIdentifier else { return nil }
                    return (app.processIdentifier, app.localizedName ?? bundle, bundle)
                }
                return (app.processIdentifier, app.localizedName ?? "App", app.bundleIdentifier ?? "", running)
            }
            guard let (pid, name, bundle, running) = context else { last = .noWindow; continue }
            if let expectedProcessID, pid != expectedProcessID { last = .windowChanged; continue }
            if excludedBundleIDs.contains(bundle) { throw NativeVoiceControlError.excluded }
            if pid == ProcessInfo.processInfo.processIdentifier { last = .excluded; continue }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let root = Self.focusedOrMainWindow(app) else { last = .noWindow; continue }
            acquired = (pid, name, bundle, running, root)
            break
        }
        guard let (pid, name, bundle, running, initialRoot) = acquired else { throw last }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        try await enableChromiumAccessibilityIfNeeded(app: app, pid: pid, bundle: bundle)
        let root = Self.focusedOrMainWindow(app) ?? initialRoot
        let snapshotID = UUID()
        handles.removeAll(); applications.removeAll(); undoTargetID = nil
        window = Element(value: root); processID = pid; observedAt = .now
        var targets: [VoiceControlTarget] = []
        let focused = Self.element(app, kAXFocusedUIElementAttribute)
        let isBrowser = Self.isBrowserBundle(bundle)
        var roots: [AXNodeHandle] = []
        if includeMenus, !isBrowser, let menu = Self.element(app, kAXMenuBarAttribute) {
            roots.append(AXNodeHandle(menu))
        }
        roots.append(AXNodeHandle(root))
        if let focused { roots.append(AXNodeHandle(focused)) }
        // Display and window geometry are read once per observation, not per node.
        let display = Self.activeDisplayBounds()
        let windowFrame = Self.frame(root)
        // Screen text is read on its own actor while the walk runs here, under
        // its own budget: a slow OCR pass never eats the Accessibility budget.
        let screenTextRead = screenTextTask(processID: pid, windowFrame: windowFrame)
        let walkStarted = ContinuousClock.now
        let walk = AXTreeWalk.run(
            roots: roots, source: LiveAXTreeSource(), display: display, window: windowFrame,
            focused: focused.map(AXNodeHandle.init), caps: walkCaps)
        try Task.checkCancellation()
        var complete = walk.complete
        let text = walk.staticText
        var pending: [(target: VoiceControlTarget, bound: BoundTarget, inWeb: Bool)] = []
        var secureFrames: [CGRect] = []
        for entry in walk.candidates {
            let node = entry.node.element
            let role = entry.facts.role
            guard !Self.isSecure(node, role: role) else {
                if let frame = entry.facts.frame { secureFrames.append(frame) }
                continue
            }
            var label = entry.facts.label
            let readableValue = Self.attribute(node, kAXValueAttribute)
            let value = (readableValue as? String) ?? (readableValue as? NSNumber)?.stringValue ?? ""
            let enabled = Self.attribute(node, kAXEnabledAttribute) as? Bool ?? true
            var operations: Set<VoiceControlOperation> = []
            label = Self.actionLabel(label, value: value, role: role, pressable: entry.facts.pressable)
            if enabled, entry.facts.pressable { operations.insert(.press) }
            if enabled, AXTreeWalk.textRoles.contains(role) {
                operations.formUnion(Self.textOperations(
                    role: role, readableValue: readableValue is String,
                    valueSettable: Self.settable(node, kAXValueAttribute),
                    selectionSettable: Self.settable(node, kAXSelectedTextAttribute)))
            }
            if role == kAXScrollAreaRole { operations.insert(.scroll) }
            if entry.isFocused, enabled { operations.insert(.key) }
            guard !operations.isEmpty else { continue }
            var inWeb = entry.inWebArea
            if isBrowser, !inWeb { inWeb = Self.ancestorIsWebArea(node) }
            let publicLabel = Self.contextLabel(label, role: role)
            let target = VoiceControlTarget(
                id: "pending", label: String(publicLabel.prefix(240)), role: role,
                value: value.isEmpty || publicLabel != label ? nil : String(value.prefix(500)), operations: operations,
                isNavigation: Self.isOrdinaryControl(role: role, pressable: operations.contains(.press)),
                isFocused: entry.isFocused,
                selectedText: AXTreeWalk.textRoles.contains(role) ? Self.completeSelection(node) : nil,
                valueIsComplete: value.count <= 500,
                region: VoiceControlTarget.region(of: entry.facts.frame, in: windowFrame))
            pending.append(
                (target,
                 BoundTarget(
                    element: Element(value: node), target: target, fingerprint: Self.fingerprint(node),
                    frame: entry.facts.frame), inWeb))
        }
        let axCandidates = pending.count
        // Screen text: words the AX tree never named, read locally from pixels.
        var textSummary: [String] = []
        var screenTextBlocks = 0
        var screenTextTargets = 0
        if let (token, screenTextTask) = screenTextRead {
            let blocks: [ScreenTextBlock]
            if let finished = await Self.awaiting(screenTextTask, budget: Self.screenTextBudget) {
                blocks = finished
                if pendingScreenText?.token == token { pendingScreenText = nil }
            } else {
                VisionScreenTextReader.note("observe: screen text still running after \(Self.screenTextBudget)")
                blocks = []
            }
            try Task.checkCancellation()
            screenTextBlocks = blocks.count
            let controls = pending.compactMap { item -> (label: String, frame: CGRect)? in
                guard let frame = item.bound.frame else { return nil }
                return (item.target.label, frame)
            }
            let result = Self.textTargets(
                from: blocks, controls: controls,
                excludedFrames: secureFrames + Self.ownWindowFrames(), existingText: text)
            // Text targets follow the page: in a browser with web content they are web content.
            let textInWeb = isBrowser && pending.contains { $0.inWeb }
            for (bare, block) in zip(result.targets, result.blocks) {
                let target = VoiceControlTarget(
                    id: bare.id, label: bare.label, role: bare.role, operations: bare.operations,
                    isNavigation: bare.isNavigation, region: VoiceControlTarget.region(of: block.frame, in: windowFrame))
                pending.append(
                    (target,
                     BoundTarget(
                        element: nil, target: target, fingerprint: "text|" + target.label, frame: block.frame,
                        pixelPoint: CGPoint(x: block.frame.midX, y: block.frame.midY)), textInWeb))
            }
            screenTextTargets = result.targets.count
            textSummary = result.summaryLines
        }
        lastObservationStats = (axCandidates, screenTextBlocks, screenTextTargets)
        // Off-screen pressables: reachable by AXPress, addressable only by exact name.
        // A label the visible list already carries is dropped: the on-screen
        // control is the better way to reach it, and one label must not split.
        let visibleLabels = Set(pending.map { $0.target.label.lowercased() })
        var offscreenKeys = Set<String>()
        for entry in walk.offscreen.prefix(walkCaps.offscreenCap) {
            let node = entry.node.element
            guard !Self.isSecure(node, role: entry.facts.role) else { continue }
            let key = entry.facts.role + "|" + entry.facts.label.lowercased()
            guard !visibleLabels.contains(entry.facts.label.lowercased()), offscreenKeys.insert(key).inserted else { continue }
            let target = VoiceControlTarget(
                id: "pending", label: String(Self.contextLabel(entry.facts.label, role: entry.facts.role).prefix(240)),
                role: entry.facts.role, operations: [.press],
                isNavigation: Self.isOrdinaryControl(role: entry.facts.role, pressable: true), isOffscreen: true)
            pending.append(
                (target, BoundTarget(element: Element(value: node), target: target, fingerprint: Self.fingerprint(node)), entry.inWebArea))
        }
        if walk.visited >= walkCaps.maxNodes { complete = false }
        let hasWebContent = pending.contains { $0.inWeb }
        for item in pending
        where Self.keepOfferedControl(
            isBrowser: isBrowser, inWebArea: item.inWeb, hasWebContent: hasWebContent, label: item.target.label,
            role: item.target.role)
        {
            let id = "n:\(targets.count)"
            let target = VoiceControlTarget(
                id: id, label: item.target.label, role: item.target.role, value: item.target.value,
                operations: item.target.operations, isNavigation: item.target.isNavigation,
                isFocused: item.target.isFocused, selectedText: item.target.selectedText,
                valueIsComplete: item.target.valueIsComplete, consequence: item.target.consequence,
                isOffscreen: item.target.isOffscreen, region: item.target.region)
            handles[id] = BoundTarget(
                element: item.bound.element, target: target, fingerprint: item.bound.fingerprint,
                frame: item.bound.frame, pixelPoint: item.bound.pixelPoint)
            targets.append(target)
        }
        var seenApps = Set<String>()
        for (appPID, appName, appBundle) in running.prefix(includeApplications ? 15 : 0)
        where !excludedBundleIDs.contains(appBundle) && appPID != pid {
            let key = appName.lowercased()
            guard seenApps.insert(key).inserted else { continue }
            let id = "app:\(appPID)"
            applications[id] = appPID
            targets.append(
                VoiceControlTarget(
                    id: id, label: appName, role: "application", operations: [.activateApp], isNavigation: true))
        }
        if isBrowser {
            for destination in VoiceControlWebDestination.all {
                targets.append(
                    VoiceControlTarget(
                        id: destination.id, label: destination.label, role: "url",
                        operations: [.press], isNavigation: true))
            }
        }
        if let undo = undoEdit, undo.pid == pid, CFEqual(undo.window.value, root), Self.isVisible(undo.element.value),
            Date().timeIntervalSince(undo.time) < 30,
            Self.attribute(undo.element.value, kAXValueAttribute) as? String == undo.after
        {
            let id = "undo"
            let target = VoiceControlTarget(
                id: id, label: "Undo last text edit", role: "undo", operations: [.press], isNavigation: true)
            targets.append(target)
            handles[id] = BoundTarget(
                element: undo.element, target: target, fingerprint: Self.fingerprint(undo.element.value))
            undoTargetID = id
        } else {
            undoEdit = nil
        }
        let title = Self.string(root, kAXTitleAttribute)
        let contextID = "ax:\(pid):\(CFHash(root))"
        let summaryLines = [title] + text + (textSummary.isEmpty ? [] : ["Screen text:"] + textSummary)
        let snapshot = VoiceControlSnapshot(
            id: snapshotID, contextID: contextID, applicationName: name,
            targets: targets, summary: String(summaryLines.joined(separator: "\n").prefix(4000)),
            isComplete: complete,
            metrics: VoiceControlObservationMetrics(
                nodesVisited: walk.visited, capped: !walk.complete,
                walkMilliseconds: Int(walkStarted.duration(to: .now).components.seconds) * 1000
                    + Int(walkStarted.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)))
        current = snapshot
        return snapshot
    }

    public func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot,
        authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        try authority.check()
        // Pixels from before this effect must not become the next observation's targets.
        pendingScreenText?.task.cancel()
        pendingScreenText = nil
        guard current?.id == snapshot.id, observedAt.duration(to: .now) < .seconds(20) else {
            throw NativeVoiceControlError.observationExpired
        }
        let expectedPID = processID
        guard let expectedWindow = window else { throw NativeVoiceControlError.windowChanged }
        let foregroundPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard foregroundPID == processID else { throw NativeVoiceControlError.windowChanged }
        try validateContext()
        if action.operation == .activateApp {
            guard let pid = applications[action.targetID] else { throw NativeVoiceControlError.changed }
            current = nil
            try authority.check()
            let activated = await VoiceControlAppActivation.bringForward(processID: pid)
            try authority.check()
            return VoiceControlReceipt(
                status: activated ? .verified : .failed,
                message: activated ? "Brought the requested app forward." : "Couldn’t activate that app.")
        }
        if let destination = VoiceControlWebDestination.named(action.targetID) {
            guard action.operation == .press, snapshot.targets.contains(where: { $0.id == destination.id }) else {
                throw NativeVoiceControlError.unsupported
            }
            current = nil
            let opened = try await MainActor.run {
                try authority.perform {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else {
                        throw NativeVoiceControlError.windowChanged
                    }
                    return NSWorkspace.shared.open(destination.url)
                }
            }
            guard opened else { return VoiceControlReceipt(status: .failed, message: "Couldn’t open that website.") }
            try await Task.sleep(for: .milliseconds(1_800))
            return VoiceControlReceipt(
                status: .transitionObserved, message: "Opened the requested website.")
        }
        guard let bound = handles[action.targetID], bound.target.operations.contains(action.operation) else {
            throw NativeVoiceControlError.unsupported
        }
        guard let element = bound.element else {
            return try await clickScreenText(bound: bound, action: action, authority: authority,
                                             expectedPID: expectedPID, expectedWindow: expectedWindow)
        }
        let node = element.value
        // An off-screen control is pressed by identity; there is no pixel to check.
        guard bound.target.isOffscreen || Self.isVisible(node, within: expectedWindow.value),
            Self.fingerprint(node) == bound.fingerprint, !Self.isSecure(node, role: bound.target.role)
        else {
            throw NativeVoiceControlError.targetChanged
        }
        // Consume the observation before dispatch: a thrown/unknown result cannot be replayed.
        current = nil
        let observedValue = Self.attribute(node, kAXValueAttribute)
        if [.setValue, .insertText].contains(action.operation) || action.targetID == undoTargetID {
            guard observedValue is String else { throw NativeVoiceControlError.targetChanged }
        }
        let beforeValue = (observedValue as? String) ?? (observedValue as? NSNumber)?.stringValue ?? ""
        if action.targetID == undoTargetID, let undo = undoEdit, action.operation == .press {
            undoEdit = nil
            guard undo.pid == processID, let window, CFEqual(undo.window.value, window.value),
                Date().timeIntervalSince(undo.time) < 30, beforeValue == undo.after
            else {
                throw NativeVoiceControlError.changed
            }
            try validateContext()
            guard Self.fingerprint(node) == bound.fingerprint else { throw NativeVoiceControlError.targetChanged }
            try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
            let status = try authority.perform {
                return AXUIElementSetAttributeValue(node, kAXValueAttribute as CFString, undo.before as CFString)
            }
            return VoiceControlReceipt(
                status: status == .success && Self.attribute(node, kAXValueAttribute) as? String == undo.before
                    ? .verified : .unknown,
                message: "Checked the restored text.")
        }
        switch action.operation {
        case .setValue, .insertText:
            guard let supplied = action.value, supplied.utf16.count <= 32_000 else {
                throw NativeVoiceControlError.unsupported
            }
            let replacement: String
            if action.operation == .insertText {
                if let range = Self.selectedRange(node), beforeValue.utf16.count <= 64_000,
                    range.location >= 0, range.length >= 0,
                    range.location <= beforeValue.utf16.count,
                    range.length <= beforeValue.utf16.count - range.location
                {
                    replacement = (beforeValue as NSString).replacingCharacters(
                        in: NSRange(location: range.location, length: range.length), with: supplied)
                } else {
                    replacement = beforeValue + supplied
                }
            } else {
                replacement = supplied
            }
            try validateContext()
            guard Self.fingerprint(node) == bound.fingerprint else { throw NativeVoiceControlError.targetChanged }
            try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
            // Replace only the selected span in rich text. Setting AXValue on
            // an NSTextView can flatten styling and attachments in the document.
            let usesSelection = action.operation == .insertText && Self.settable(node, kAXSelectedTextAttribute)
            let plainField = [kAXTextFieldRole, kAXComboBoxRole].contains(bound.target.role)
            if action.operation == .setValue {
                guard plainField else { throw NativeVoiceControlError.unsupported }
            }
            var status: AXError = .cannotComplete
            var verified = false
            if usesSelection || plainField {
                status = try authority.perform {
                    AXUIElementSetAttributeValue(node,
                        (usesSelection ? kAXSelectedTextAttribute : kAXValueAttribute) as CFString,
                        (usesSelection ? supplied : replacement) as CFString)
                }
                // Browser accessibility caches can lag a successful setter. Verify
                // the same retained control with bounded reads; never retry the write.
                verified = await verifyTextValue(node, expected: replacement, authority: authority)
                if !verified, usesSelection, Self.settable(node, kAXValueAttribute) {
                    status = try authority.perform {
                        AXUIElementSetAttributeValue(
                            node, kAXValueAttribute as CFString, replacement as CFString)
                    }
                    verified = await verifyTextValue(node, expected: replacement, authority: authority)
                }
            }
            // Chrome webpage search often reports a successful AX write while
            // AXValue stays empty and the field does not change. Type into the
            // still-focused control only when the readable value did not move.
            // A blind HID type into a field whose AXValue never reads back is a
            // transition, not a verified value: the runner may continue on an
            // ordinary step, but the receipt must not claim a readback it lacks.
            var typedBlind = false
            if !verified, action.operation == .insertText {
                let current = Self.attribute(node, kAXValueAttribute) as? String ?? ""
                if current == beforeValue {
                    try typeUnicode(supplied, authority: authority)
                    verified = await verifyTextValue(node, expected: replacement, authority: authority)
                    typedBlind = !verified && beforeValue.isEmpty
                }
            }
            if plainField, verified {
                undoEdit = (Element(value: node), expectedWindow, beforeValue, replacement, expectedPID, Date())
                if bound.target.role == kAXComboBoxRole {
                    try await Task.sleep(for: .milliseconds(450))
                }
            }
            if !plainField { undoEdit = nil }
            if verified {
                return VoiceControlReceipt(status: .verified, message: "Checked the text field after the change.")
            }
            if typedBlind {
                return VoiceControlReceipt(
                    status: .transitionObserved,
                    message: "Typed into the focused field; the app does not expose the value for readback.")
            }
            return VoiceControlReceipt(
                status: .unknown,
                message: status == .success ? "Text was dispatched; its result could not be verified." : "The app reported a text error; check whether it changed.")
        case .press, .select:
            let beforeTransition = transitionEvidence()
            try validateContext()
            guard Self.fingerprint(node) == bound.fingerprint else { throw NativeVoiceControlError.targetChanged }
            try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
            let status = try authority.perform {
                return AXUIElementPerformAction(node, kAXPressAction as CFString)
            }
            guard status == .success else {
                // AX errors can arrive after an app handled the action. Without
                // a definitive postcondition, retrying could duplicate a commitment.
                return VoiceControlReceipt(status: .unknown, message: "The app reported a press error; check whether the action completed.")
            }
            try await Task.sleep(for: .milliseconds(120))
            // A successful AX return only proves dispatch. Controls with observable state
            // changes can be verified; generic buttons must remain unknown.
            if bound.target.role == kAXCheckBoxRole || bound.target.role == kAXRadioButtonRole {
                let after = Self.attribute(node, kAXValueAttribute)
                let afterValue = (after as? String) ?? (after as? NSNumber)?.stringValue
                return VoiceControlReceipt(
                    status: afterValue.map { $0 != beforeValue } == true ? .verified : .unknown,
                    message: "Checked the control’s state.")
            }
            if bound.target.role == kAXPopUpButtonRole || bound.target.role == kAXMenuBarItemRole {
                if Self.attribute(node, "AXExpanded") as? Bool == true ||
                    (bound.target.role == kAXMenuBarItemRole && Self.attribute(node, kAXSelectedAttribute) as? Bool == true) {
                    return VoiceControlReceipt(status: .verified, message: "Menu opened.")
                }
            }
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(120))
                try authority.check()
                let afterTransition = transitionEvidence()
                if afterTransition != beforeTransition, !afterTransition.isEmpty {
                    return VoiceControlReceipt(
                        status: .transitionObserved,
                        message: "The interface changed after the press; checking the next step.")
                }
            }
            return VoiceControlReceipt(
                status: .unknown, message: "Control pressed. Check the result before continuing.")
        case .key:
            guard let key = action.value, let code = Self.keyCodes[key.lowercased()] else {
                throw NativeVoiceControlError.unsupported
            }
            guard let focused = Self.element(AXUIElementCreateApplication(processID), kAXFocusedUIElementAttribute),
                CFEqual(focused, node)
            else { throw NativeVoiceControlError.changed }
            try validateContext()
            guard
                let currentFocus = Self.element(AXUIElementCreateApplication(processID), kAXFocusedUIElementAttribute),
                CFEqual(currentFocus, node)
            else { throw NativeVoiceControlError.changed }
            try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
            let beforeTransition = transitionEvidence()
            try authority.perform {
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                else {
                    throw NativeVoiceControlError.unsupported
                }
                down.setIntegerValueField(.eventSourceUserData, value: StreamingCursorEventMarker.userData)
                up.setIntegerValueField(.eventSourceUserData, value: StreamingCursorEventMarker.userData)
                down.postToPid(expectedPID); up.postToPid(expectedPID)
            }
            if ["return", "enter", "tab", "escape"].contains(key.lowercased()) {
                for _ in 0..<4 {
                    try await Task.sleep(for: .milliseconds(120))
                    try authority.check()
                    let afterTransition = transitionEvidence()
                    if afterTransition != beforeTransition, !afterTransition.isEmpty {
                        return VoiceControlReceipt(
                            status: .transitionObserved,
                            message: "The interface changed after the key; checking the next step.")
                    }
                }
            }
            return VoiceControlReceipt(status: .unknown, message: "Key sent. Check the result before continuing.")
        case .scroll:
            let direction = action.value?.lowercased() ?? "down"
            guard ["up", "down"].contains(direction) else { throw NativeVoiceControlError.unsupported }
            let scrollbarAttribute =
                direction == "up" || direction == "down"
                ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
            guard let bar = Self.element(node, scrollbarAttribute),
                let value = Self.attribute(bar, kAXValueAttribute) as? Double,
                Self.settable(bar, kAXValueAttribute)
            else { throw NativeVoiceControlError.unsupported }
            let next = min(1, max(0, value + (direction == "down" ? 0.2 : -0.2)))
            try validateContext()
            try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
            let status = try authority.perform {
                return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
            }
            let observed = Self.attribute(bar, kAXValueAttribute) as? Double
            return VoiceControlReceipt(
                status: status == .success && observed == next ? .verified : .unknown,
                message: "Checked the scroll position.")
        case .activateApp: throw NativeVoiceControlError.unsupported
        }
    }

    /// A text-only target has no AX node: it is pressed with a marked click at the
    /// recognised word's centre. There is no readback, so the receipt is at most a transition.
    private func clickScreenText(
        bound: BoundTarget, action: VoiceControlAction, authority: ActionAuthority,
        expectedPID: Int32, expectedWindow: Element
    ) async throws -> VoiceControlReceipt {
        guard action.operation == .press, let point = bound.pixelPoint else { throw NativeVoiceControlError.unsupported }
        guard bound.fingerprint == "text|" + bound.target.label else { throw NativeVoiceControlError.targetChanged }
        current = nil
        let beforeTransition = transitionEvidence()
        try validateContext()
        try await validateForeground(expectedPID: expectedPID, expectedWindow: expectedWindow)
        try authority.perform {
            guard AXIsProcessTrusted() else { throw NativeVoiceControlError.permission }
            let source = CGEventSource(stateID: .hidSystemState)
            let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
            for type in types {
                guard let event = CGEvent(
                    mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                else { throw NativeVoiceControlError.unsupported }
                StreamingCursorEventMarker.mark(event)
                event.post(tap: .cghidEventTap)
            }
        }
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(120))
            try authority.check()
            let afterTransition = transitionEvidence()
            if afterTransition != beforeTransition, !afterTransition.isEmpty {
                return VoiceControlReceipt(
                    status: .transitionObserved,
                    message: "The interface changed after the click; checking the next step.")
            }
        }
        return VoiceControlReceipt(status: .unknown, message: "Clicked on-screen text. Check the result before continuing.")
    }

    /// The pure part of the screen-text pass: merge OCR lines, drop what an AX
    /// control or a secure field already explains, order, cap, and shape targets
    /// plus summary lines. `blocks` is aligned with `targets`.
    static func textTargets(
        from blocks: [ScreenTextBlock], controls: [(label: String, frame: CGRect)], excludedFrames: [CGRect],
        existingText: [String]
    ) -> (targets: [VoiceControlTarget], blocks: [ScreenTextBlock], summaryLines: [String]) {
        let merged = ScreenTextMerge.mergeLines(blocks)
        let unexplained = ScreenTextMerge.readingOrder(
            ScreenTextMerge.unexplained(merged, controls: controls, excludedFrames: excludedFrames))
        var seen = Set(existingText.map(ScreenTextMerge.normalize))
        var summary: [String] = []
        var targets: [VoiceControlTarget] = []
        var kept: [ScreenTextBlock] = []
        for block in unexplained {
            if seen.insert(ScreenTextMerge.normalize(block.text)).inserted { summary.append(block.text) }
            guard targets.count < 80 else { continue }
            targets.append(
                VoiceControlTarget(
                    id: "pending", label: String(block.text.prefix(240)), role: "text", operations: [.press],
                    isNavigation: false))
            kept.append(block)
        }
        return (targets, kept, summary)
    }

    private func verifyTextValue(_ node: AXUIElement, expected: String, authority: ActionAuthority) async -> Bool {
        for attempt in 0..<6 {
            guard authority.isValid, !Task.isCancelled else { return false }
            if Self.attribute(node, kAXValueAttribute) as? String == expected { return true }
            if attempt < 5 { try? await Task.sleep(for: .milliseconds(60)) }
        }
        return false
    }

    /// Webpage fields often ignore AXSelectedText. Unicode HID posts are the
    /// same path dictation already uses for Chrome, marked so hotkeys ignore them.
    private func typeUnicode(_ text: String, authority: ActionAuthority) throws {
        try authority.perform {
            guard AXIsProcessTrusted() else { throw NativeVoiceControlError.permission }
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                throw NativeVoiceControlError.unsupported
            }
            let units = Array(text.utf16)
            var index = units.startIndex
            while index < units.endIndex {
                let end = units.index(index, offsetBy: 20, limitedBy: units.endIndex) ?? units.endIndex
                var chunk = Array(units[index..<end])
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else {
                    throw NativeVoiceControlError.unsupported
                }
                down.flags = []
                up.flags = []
                StreamingCursorEventMarker.mark(down)
                StreamingCursorEventMarker.mark(up)
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                index = end
            }
        }
    }

    /// Bounded structural evidence, not a model's success assertion. Changes to
    /// editable values, menus, URLs or window identity permit fresh planning.
    private func transitionEvidence() -> Set<String> {
        guard let root = Self.focusedOrMainWindow(AXUIElementCreateApplication(processID)) else {
            return []
        }
        var evidence: Set<String> = ["window:\(CFHash(root))"]
        var queue = [root]
        var visited: Set<CFHashCode> = []
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(350))
        while let node = queue.popLast(), visited.count < 200, ContinuousClock.now < deadline {
            guard visited.insert(CFHash(node)).inserted else { continue }
            let role = Self.string(node, kAXRoleAttribute)
            guard !Self.isSecure(node, role: role), Self.attribute(node, "AXHidden") as? Bool != true else { continue }
            if Self.isVisible(node),
                [
                    kAXTextFieldRole, kAXComboBoxRole, kAXPopUpButtonRole, kAXMenuRole, kAXMenuItemRole,
                    kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXStaticTextRole, "AXWebArea", "AXLink",
                ].contains(role)
            {
                evidence.insert(
                    role + "|" + Self.label(node) + "|" + Self.string(node, kAXValueAttribute)
                        + "|" + String(describing: Self.attribute(node, kAXURLAttribute)))
            }
            if let children = Self.attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(80).reversed())
            }
        }
        return evidence
    }

    private func validateContext() throws {
        guard let window,
            let focused = Self.focusedOrMainWindow(AXUIElementCreateApplication(processID)),
            CFEqual(focused, window.value)
        else { throw NativeVoiceControlError.windowChanged }
    }
    private static let keyCodes: [String: CGKeyCode] = [
        "tab": 48, "escape": 53, "enter": 36, "return": 36,
        "left": 123, "right": 124, "down": 125, "up": 126, "backspace": 51, "delete": 117,
    ]
    static let screenTextBudget: Duration = .milliseconds(1_200)

    private func screenTextTask(processID pid: Int32, windowFrame: CGRect?) -> (UUID, Task<[ScreenTextBlock], Never>)? {
        guard let screenText, let windowFrame else { return nil }
        if let pending = pendingScreenText, pending.pid == pid, pending.frame == windowFrame, !pending.task.isCancelled {
            return (pending.token, pending.task)
        }
        pendingScreenText?.task.cancel()
        let token = UUID()
        let task = Task { await screenText.read(window: windowFrame, processID: pid) }
        pendingScreenText = (token, pid, windowFrame, task)
        return (token, task)
    }
    /// The task's value if it finishes within `budget`, else nil. Returning does
    /// not cancel `task`: a slow read can still complete for the next observation.
    static func awaiting<T: Sendable>(_ task: Task<T, Never>, budget: Duration) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = AwaitGate()
            Task {
                let value = await task.value
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: budget)
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Frames of this process's own on-screen windows (the Voice Control panel,
    /// the menu bar extra's popover). Text drawn there — the user's instruction,
    /// our status lines — is never the app's screen text.
    static func ownWindowFrames() -> [CGRect] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"], w > 0, h > 0
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// Union of the active displays, read once per observation.
    static func activeDisplayBounds() -> CGRect {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success, count > 0 else { return .infinite }
        return displays.prefix(Int(count)).map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
    }
    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(node, kAXPositionAttribute),
            let rawSize = attribute(node, kAXSizeAttribute),
            CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        let position = unsafeDowncast(rawPosition as AnyObject, to: AXValue.self)
        let size = unsafeDowncast(rawSize as AnyObject, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
    static func attributeValue(_ node: AXUIElement, _ name: String) -> CFTypeRef? { attribute(node, name) }
    static func stringValue(_ node: AXUIElement, _ name: String) -> String { string(node, name) }
    static func labelValue(_ node: AXUIElement) -> String { label(node) }
    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.15)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }
    private static func focusedOrMainWindow(_ app: AXUIElement) -> AXUIElement? {
        if let focused = element(app, kAXFocusedWindowAttribute) { return focused }
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first
    }
    private static func string(_ node: AXUIElement, _ name: String) -> String {
        if let value = attribute(node, name) as? String { return value }
        if let value = attribute(node, name) as? NSNumber { return value.stringValue }
        return ""
    }
    private static func label(_ node: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            let value = string(node, key)
            if !value.isEmpty { return value }
        }
        return ""
    }
    private static func isSecure(_ node: AXUIElement, role: String) -> Bool {
        let subrole = string(node, kAXSubroleAttribute).lowercased()
        let name = label(node).lowercased()
        return subrole.contains("secure") || role.lowercased().contains("secure")
            || ["password", "passcode", "one-time", "verification code", "api key", "secret", "credit card"].contains(
                where: name.contains)
    }
    static func actionLabel(_ label: String, value: String, role: String, pressable: Bool) -> String {
        // Web list choices can be pressable static text with their name only in AXValue.
        guard label.isEmpty, role == kAXMenuItemRole || (role == kAXStaticTextRole && pressable) else { return label }
        return value
    }

    static func contextLabel(_ label: String, role: String) -> String {
        // Browser account badges expose personal names/emails in their accessible
        // descriptions. The task needs the menu capability, not that identity.
        guard [kAXButtonRole, kAXPopUpButtonRole, "AXMenuButton"].contains(role) else { return label }
        let lower = label.lowercased()
        if lower.hasPrefix("google account:") { return "Account menu" }
        if lower.hasPrefix("profile:") || lower.hasPrefix("profile ") { return "Browser profile menu" }
        return label
    }

    static func textOperations(role: String, readableValue: Bool, valueSettable: Bool,
                               selectionSettable: Bool) -> Set<VoiceControlOperation> {
        guard readableValue, [kAXTextFieldRole, kAXComboBoxRole, kAXTextAreaRole].contains(role) else { return [] }
        var result: Set<VoiceControlOperation> = []
        if [kAXTextFieldRole, kAXComboBoxRole].contains(role), valueSettable {
            result.formUnion([.setValue, .insertText])
        }
        if selectionSettable { result.insert(.insertText) }
        return result
    }
    static func isOrdinaryControl(role: String, pressable: Bool) -> Bool {
        // Opening selectors and choosing an offered option is ordinary task
        // work. A checkbox or HTTP link can still subscribe, share, or commit.
        if [kAXMenuBarItemRole, kAXPopUpButtonRole, kAXMenuItemRole, kAXComboBoxRole, kAXRadioButtonRole]
            .contains(role)
        {
            return true
        }
        return role == kAXStaticTextRole && pressable
    }
    static func isBrowserBundle(_ bundle: String) -> Bool {
        [
            "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition", "com.microsoft.edgemac", "com.brave.Browser",
            "company.thebrowser.Browser",
        ].contains(bundle)
    }
    static func isChromiumBundle(_ bundle: String) -> Bool {
        [
            "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
            "company.thebrowser.Browser",
        ].contains(bundle)
    }
    /// Electron honours AXManualAccessibility; Chromium honours AXEnhancedUserInterface.
    /// Setting them rebuilds the tree, so this runs once per process and then waits for a page.
    private func enableChromiumAccessibilityIfNeeded(app: AXUIElement, pid: Int32, bundle: String) async throws {
        guard Self.isChromiumBundle(bundle) else { return }
        let firstAsk = chromiumAccessibilityPIDs.insert(pid).inserted
        if firstAsk {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            for _ in 0..<8 {
                if Self.hasPopulatedWebArea(app) { return }
                try await Task.sleep(for: .milliseconds(150))
            }
            return
        }
        // Chromium can drop its tree after a navigation; ask once more, briefly.
        guard !Self.hasPopulatedWebArea(app) else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(250))
    }
    static func hasPopulatedWebArea(_ app: AXUIElement) -> Bool {
        guard let window = focusedOrMainWindow(app) else { return false }
        var pending = [window]
        var visited = 0
        while let node = pending.popLast(), visited < 400 {
            visited += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
                if !children.isEmpty { return true }
                continue
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children)
            }
        }
        return false
    }
    static func isBrowserShellNoise(label: String, role: String) -> Bool {
        let lower = label.lowercased()
        if lower.contains("memory usage") || lower.contains("cpu usage") || lower.contains("gpu usage") {
            return true
        }
        if lower.contains("address and search") || lower == "tab search" || lower.hasPrefix("tab search") {
            return true
        }
        if role == kAXStaticTextRole, lower.contains("book your ticket"), lower.contains("google flights") {
            return true
        }
        return false
    }
    static func keepOfferedControl(
        isBrowser: Bool, inWebArea: Bool, hasWebContent: Bool, label: String, role: String
    ) -> Bool {
        if isBrowserShellNoise(label: label, role: role) { return false }
        if isBrowser, hasWebContent, !inWebArea, role != "application", role != "undo" { return false }
        return true
    }
    private static func ancestorIsWebArea(_ node: AXUIElement) -> Bool {
        var current = node
        for _ in 0..<24 {
            guard let parent = element(current, kAXParentAttribute) else { return false }
            if string(parent, kAXRoleAttribute) == "AXWebArea" { return true }
            current = parent
        }
        return false
    }
    private static func isVisible(_ node: AXUIElement, within window: AXUIElement? = nil) -> Bool {
        guard attribute(node, "AXHidden") as? Bool != true,
            let rawPosition = attribute(node, kAXPositionAttribute),
            let rawSize = attribute(node, kAXSizeAttribute),
            CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return false }
        let position = unsafeDowncast(rawPosition as AnyObject, to: AXValue.self)
        let size = unsafeDowncast(rawSize as AnyObject, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return false }
        var point = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent),
            extent.width > 0, extent.height > 0
        else { return false }
        let frame = CGRect(origin: point, size: extent)
        if let window, ![kAXMenuBarItemRole, kAXMenuItemRole, kAXMenuRole].contains(string(node, kAXRoleAttribute)),
           let windowPosition = attribute(window, kAXPositionAttribute),
           let windowSize = attribute(window, kAXSizeAttribute),
           CFGetTypeID(windowPosition) == AXValueGetTypeID(), CFGetTypeID(windowSize) == AXValueGetTypeID() {
            let wp = unsafeDowncast(windowPosition as AnyObject, to: AXValue.self)
            let ws = unsafeDowncast(windowSize as AnyObject, to: AXValue.self)
            var origin = CGPoint.zero; var dimensions = CGSize.zero
            guard AXValueGetType(wp) == .cgPoint, AXValueGetType(ws) == .cgSize,
                  AXValueGetValue(wp, .cgPoint, &origin), AXValueGetValue(ws, .cgSize, &dimensions),
                  CGRect(origin: origin, size: dimensions).intersects(frame) else { return false }
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).intersects(frame) }
    }
    private func validateForeground(expectedPID: Int32, expectedWindow: Element) async throws {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontmost == expectedPID, processID == expectedPID, let window,
            CFEqual(window.value, expectedWindow.value)
        else { throw NativeVoiceControlError.windowChanged }
        try validateContext()
    }
    private static func fingerprint(_ node: AXUIElement) -> String {
        [
            string(node, kAXRoleAttribute), string(node, kAXSubroleAttribute), label(node),
            string(node, kAXValueAttribute), string(node, kAXEnabledAttribute),
            String(describing: attribute(node, kAXURLAttribute)),
            String(describing: selectedRange(node)),
        ].joined(separator: "\u{1f}")
    }
    private static func settable(_ node: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(node, name as CFString, &result) == .success && result.boolValue
    }
    private static func completeSelection(_ node: AXUIElement) -> String? {
        let selected = string(node, kAXSelectedTextAttribute)
        return selected.count <= 4000 ? selected : nil
    }
    private static func selectedRange(_ node: AXUIElement) -> CFRange? {
        guard let raw = attribute(node, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }
}


/// `AXUIElement` as a hashable node for `AXTreeWalk`. Two fetches of one
/// control compare equal, so a self-listing app is walked once.
struct AXNodeHandle: Hashable, @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: AXNodeHandle, rhs: AXNodeHandle) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// The production tree source. Reads only the facts the walk needs; the
/// adapter reads values, settability and selection for the kept nodes.
struct LiveAXTreeSource: AXTreeSource {
    typealias Node = AXNodeHandle
    /// One IPC round trip per node for everything the walk needs. Missing
    /// attributes come back as AXValue error placeholders, not as failures.
    private static let batch: [String] = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
        kAXPositionAttribute, kAXSizeAttribute, "AXHidden", kAXSelectedAttribute, kAXValueAttribute,
    ]
    func children(of node: AXNodeHandle) -> [AXNodeHandle] {
        (NativeVoiceControlAdapter.attributeValue(node.element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AXNodeHandle.init)
    }
    func facts(of node: AXNodeHandle) -> AXWalkFacts {
        let element = node.element
        AXUIElementSetMessagingTimeout(element, 0.15)
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, Self.batch as CFArray, [], &raw)
        let values = status == .success ? (raw as? [AnyObject] ?? []) : []
        func at(_ index: Int) -> AnyObject? {
            guard values.indices.contains(index) else { return nil }
            let value = values[index]
            // A placeholder for a missing attribute is an AXValue of error type.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError {
                return nil
            }
            return value
        }
        func string(_ index: Int) -> String {
            if let text = at(index) as? String { return text }
            if let number = at(index) as? NSNumber { return number.stringValue }
            return ""
        }
        let role = string(0)
        var label = ""
        for index in 1...3 where label.isEmpty { label = string(index) }
        var frame: CGRect?
        if let position = at(4), let size = at(5), CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        {
            var point = CGPoint.zero; var extent = CGSize.zero
            if AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
            {
                frame = CGRect(origin: point, size: extent)
            }
        }
        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = actionNames as? [String] ?? []
        return AXWalkFacts(
            role: role, label: label, frame: frame,
            hidden: at(6) as? Bool == true,
            pressable: actions.contains(kAXPressAction),
            menuOpen: role == kAXMenuBarItemRole && at(7) as? Bool == true,
            text: role == kAXStaticTextRole ? (at(8) as? String) : nil)
    }
}
