import Foundation

public enum VoiceControlOperation: String, Codable, Sendable, CaseIterable {
    case press, setValue, insertText, select, scroll, key, activateApp
}

public struct VoiceControlTarget: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let role: String
    public let value: String?
    public let operations: Set<VoiceControlOperation>
    /// Adapter-proven navigation is one input to consequence-based confirmation.
    public let isNavigation: Bool
    public let isFocused: Bool
    public let selectedText: String?
    public let valueIsComplete: Bool
    public let consequence: VoiceControlConsequence?
    /// The app exposes this pressable control but does not show it (scrolled out,
    /// parked off the display, an auto-hidden Dock). Reachable by `AXPress` and by
    /// an exact spoken name only; never offered to the model.
    public let isOffscreen: Bool
    /// Where the control sits in its window, as one of nine words (`top-left` …
    /// `bottom-right`). Cheap to compute, and the one thing that tells two
    /// identically labelled controls apart in a criteria string.
    public let region: String?
    public init(
        id: String, label: String, role: String, value: String? = nil,
        operations: Set<VoiceControlOperation>, isNavigation: Bool = false,
        isFocused: Bool = false, selectedText: String? = nil, valueIsComplete: Bool = true,
        consequence: VoiceControlConsequence? = nil, isOffscreen: Bool = false, region: String? = nil
    ) {
        self.id = id; self.label = label; self.role = role; self.value = value
        self.operations = operations; self.isNavigation = isNavigation
        self.isFocused = isFocused; self.selectedText = selectedText; self.valueIsComplete = valueIsComplete
        self.consequence = consequence; self.isOffscreen = isOffscreen; self.region = region
    }
    private enum CodingKeys: String, CodingKey {
        case id, label, role, value, operations, isNavigation, isFocused, selectedText, valueIsComplete, consequence,
            isOffscreen
        case region
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        role = try container.decode(String.self, forKey: .role)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        operations = try container.decode(Set<VoiceControlOperation>.self, forKey: .operations)
        isNavigation = try container.decode(Bool.self, forKey: .isNavigation)
        isFocused = try container.decode(Bool.self, forKey: .isFocused)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        valueIsComplete = try container.decode(Bool.self, forKey: .valueIsComplete)
        consequence = try container.decodeIfPresent(VoiceControlConsequence.self, forKey: .consequence)
        isOffscreen = try container.decodeIfPresent(Bool.self, forKey: .isOffscreen) ?? false
        region = try container.decodeIfPresent(String.self, forKey: .region)
    }

    /// Nine-cell grid position of `frame` inside `window`; nil without both.
    public static func region(of frame: CGRect?, in window: CGRect?) -> String? {
        guard let frame, let window, !frame.isInfinite, !frame.isNull, !window.isInfinite, !window.isNull,
            frame.width > 0, frame.height > 0, window.width > 0, window.height > 0,
            [
                frame.origin.x, frame.origin.y, frame.width, frame.height, window.origin.x, window.origin.y,
                window.width, window.height,
            ]
            .allSatisfy(\.isFinite)
        else { return nil }
        let x = (frame.midX - window.minX) / window.width
        let y = (frame.midY - window.minY) / window.height
        guard x.isFinite, y.isFinite else { return nil }
        // Compare thirds directly. Int() of a non-finite AX coordinate traps.
        func cell(_ value: CGFloat) -> Int { value < 1.0 / 3.0 ? 0 : (value < 2.0 / 3.0 ? 1 : 2) }
        return ["top", "middle", "bottom"][cell(y)] + "-" + ["left", "center", "right"][cell(x)]
    }
}

/// How an observation was produced: what the walk cost and whether a cap cut it.
public struct VoiceControlObservationMetrics: Codable, Sendable, Equatable {
    public var nodesVisited: Int
    public var capped: Bool
    public var walkMilliseconds: Int
    public init(nodesVisited: Int, capped: Bool, walkMilliseconds: Int) {
        self.nodesVisited = nodesVisited; self.capped = capped; self.walkMilliseconds = walkMilliseconds
    }
}

public struct VoiceControlSnapshot: Codable, Sendable, Equatable {
    public let id: UUID
    public let contextID: String
    public let applicationName: String
    public let targets: [VoiceControlTarget]
    public let summary: String
    public let isComplete: Bool
    public let metrics: VoiceControlObservationMetrics?
    public init(
        id: UUID = UUID(), contextID: String, applicationName: String,
        targets: [VoiceControlTarget], summary: String = "", isComplete: Bool = true,
        metrics: VoiceControlObservationMetrics? = nil
    ) {
        self.id = id; self.contextID = contextID; self.applicationName = applicationName
        self.targets = targets; self.summary = summary; self.isComplete = isComplete; self.metrics = metrics
    }
}

public struct VoiceControlAction: Codable, Sendable, Equatable {
    public let operation: VoiceControlOperation
    public let targetID: String
    /// Text is an exact source span, or an explicitly approved generated rewrite.
    public let value: String?
    public let targetLabel: String?
    public let requiresConfirmation: Bool
    /// Populated only in executed history; a transition is not verified goal success.
    public let receiptStatus: VoiceControlReceipt.Status?
    public let consequence: VoiceControlConsequence?
    public let modelID: String?
    public let decisionConfidence: Double?
    public let postcondition: VoiceControlPostcondition
    public init(
        operation: VoiceControlOperation, targetID: String, value: String? = nil, targetLabel: String? = nil,
        requiresConfirmation: Bool = false, receiptStatus: VoiceControlReceipt.Status? = nil,
        consequence: VoiceControlConsequence? = nil, modelID: String? = nil, decisionConfidence: Double? = nil,
        postcondition: VoiceControlPostcondition = .unknown
    ) {
        self.operation = operation; self.targetID = targetID; self.value = value; self.targetLabel = targetLabel;
        self.requiresConfirmation = requiresConfirmation; self.receiptStatus = receiptStatus;
        self.consequence = consequence; self.modelID = modelID; self.decisionConfidence = decisionConfidence
        self.postcondition = postcondition
    }

    func referring(to target: VoiceControlTarget) -> Bool {
        if targetID == target.id { return true }
        guard let targetLabel, !targetLabel.isEmpty else { return false }
        return targetLabel.localizedStandardCompare(target.label) == .orderedSame
    }
}

/// Synchronous revocation is independent of any actor currently awaiting I/O.
public final class ActionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    public init() {}
    public func revoke() { lock.lock(); revoked = true; lock.unlock() }
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return !revoked }
    public func check() throws { if !isValid { throw CancellationError() } }
    /// Serialize the final check with a synchronous individual effect. Never await inside this closure.
    public func perform<T>(_ effect: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { throw CancellationError() }
        return try effect()
    }
}

public struct VoiceControlReceipt: Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case verified, transitionObserved, unknown, failed }
    public let status: Status
    public let message: String
    public init(status: Status, message: String = "") { self.status = status; self.message = message }
}

public protocol VoiceControlAdapter: Sendable {
    func observe() async throws -> VoiceControlSnapshot
    func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot,
        authority: ActionAuthority
    ) async throws -> VoiceControlReceipt
}

public enum VoiceControlDecision: Sendable, Equatable {
    case action(VoiceControlAction)
    case clarify(String)
    /// Local numbered disambiguation. Saying the number must not call Jev.
    case pick(prompt: String, labels: [String], targetIDs: [String])
    /// Model inference is never reported as independently verified task completion.
    case finished
    /// Exact local command whose requested effect was independently verified.
    case directCompleted(String)
    /// A local answer; no action or effect verification is implied.
    case information(String)
}

public protocol VoiceControlDecisionEngine: Sendable {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    func decide(
        goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
        events: [VoiceControlEnabledEvent]
    ) async throws -> VoiceControlDecision
}

public enum VoiceControlEvent: Sendable, Equatable {
    case observing, deciding
    case acting(VoiceControlAction)
    case confirmation(VoiceControlAction, String)
    case clarification(String)
    case paused(String)
    case completed(String)
    case failed(String)
    case cancelled
    /// Ephemeral task content for the panel, deliberately excluded from diagnostic traces.
    case activity(String)
}
