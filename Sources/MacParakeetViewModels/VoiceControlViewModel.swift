import Foundation
import Observation
import MacParakeetCore

public struct VoiceControlConversationState: Sendable {
    public enum Response: Sendable { case confirmation, clarification }
    public private(set) var expectedResponse: Response?
    public var shouldPauseForSpeech: Bool { expectedResponse == nil }
    public init() {}
    public mutating func receive(_ event: VoiceControlEvent) {
        switch event {
        case .confirmation: expectedResponse = .confirmation
        case .clarification: expectedResponse = .clarification
        case .paused, .cancelled, .completed, .failed: expectedResponse = nil
        default: break
        }
    }
    public static func isCorrection(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["actually", "no,", "no ", "instead", "change that", "change the", "make it", "not ", "the other", "other one", "undo"].contains { value.hasPrefix($0) }
    }
    public mutating func cancel() { expectedResponse = nil }
    public mutating func takeConfirmation() -> Bool {
        guard expectedResponse == .confirmation else { return false }
        expectedResponse = nil
        return true
    }
    public mutating func takeClarification() -> Bool {
        let result = expectedResponse == .clarification
        expectedResponse = nil
        return result
    }
}

@MainActor @Observable
public final class VoiceControlViewModel {
    public enum Phase: Equatable {
        case idle, listening, transcribing, working, confirmation, clarification, paused, done, failed
    }
    public var phase: Phase = .idle
    public var conversation = VoiceControlConversationState()
    public var microphoneOn = false
    public var literalMode = false
    public var audioLevel: Float = 0
    public var goal = ""
    public var activityExpanded = false
    public var diagnosticsExpanded = false
    public var diagnosticsText = ""
    public var diagnosticsStatus = "Saved on this Mac. Copy diagnostics omits the instruction and labels."
    public var diagnosticsLogPath = VoiceControlTraceStore.defaultLatestURL.path
    public var onRefreshDiagnostics: (() -> Void)?
    public var onCopyDiagnostics: (() -> Void)?
    public var onOpenDiagnosticsFolder: (() -> Void)?
    public var onCopyDiagnosticsPath: (() -> Void)?
    public var transcript = ""
    public var partialTranscript = ""
    public var message = "Hold Control–Option–Space to give an instruction."
    public var steps: [String] = []
    /// Numbered choices of the open pick, in order. Rows in the panel; badges on screen.
    public var choices: [VoiceControlHighlight.Mark] = []
    /// The control the current step is about, for the status line.
    public var focusLabel: String?
    public var onChoose: ((Int) -> Void)?
    public var needsSetup = true
    public var keyInput = ""
    public var consent = false
    public var writingConsent = false
    /// Opt-in Vision OCR of the frontmost window; stays on this Mac, needs Screen Recording.
    public var screenText = UserDefaults.standard.bool(forKey: AppFeatures.voiceControlScreenTextDefaultsKey)
    public var onScreenTextChanged: ((Bool) -> Void)?
    public var holdTrigger = HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 49)
    public var onShortcutRecording: ((Bool) -> Void)?
    public var validateShortcut: ((HotkeyTrigger) -> HotkeyTrigger.ValidationResult)?
    public var input = ""
    public var onListen: (() -> Void)?
    public var onCommit: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onStopListening: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onEnd: (() -> Void)?
    public var onConfirm: (() -> Void)?
    public var onResume: (() -> Void)?
    public var onSubmit: ((String) -> Void)?
    public var onSaveSetup: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onDisable: (() -> Void)?
    public var onRevokeConsent: (() -> Void)?
    public var onRevokeWritingConsent: (() -> Void)?
    public init() {}
    public func appendActivity(_ detail: String) {
        steps.append(detail)
        if steps.count > 100 { steps.removeFirst(steps.count - 100) }
    }
    /// The effect, named: `Clicking ‘Sent’…`, `Typing into ‘Search mail’…`.
    public static func describe(_ action: VoiceControlAction, label: String?) -> String {
        let name = (label ?? action.targetLabel).flatMap { $0.isEmpty ? nil : "‘\($0)’" }
        switch action.operation {
        case .press: return name.map { "Clicking \($0)" } ?? "Clicking"
        case .select: return name.map { "Selecting \($0)" } ?? "Selecting"
        case .setValue, .insertText: return name.map { "Typing into \($0)" } ?? "Typing"
        case .scroll: return "Scrolling " + (action.value ?? "down") + (name.map { " in \($0)" } ?? "")
        case .key: return "Pressing " + (action.value.map { $0.capitalized } ?? "the key")
        case .activateApp: return name.map { "Switching to \($0)" } ?? "Switching apps"
        }
    }

    public func apply(_ event: VoiceControlEvent) {
        conversation.receive(event)
        switch event {
        case .highlight, .activity, .clarification: break
        default: choices = []
        }
        switch event {
        case .paused(let detail), .failed(let detail), .completed(let detail), .clarification(let detail): appendActivity(detail)
        default: break
        }
        switch event {
        case .observing: phase = .working; message = "Looking at the current app…"
        case .deciding: phase = .working; message = "Choosing the next step…"
        case .acting(let action):
            phase = .working
            let effect = Self.describe(action, label: focusLabel)
            message = effect + "…"
            appendActivity(effect)
        case .highlight(let highlight):
            focusLabel = highlight.style == .numbered ? nil : highlight.marks.first?.label
            if highlight.style == .numbered { choices = highlight.marks }
        case .confirmation(_, let message): phase = .confirmation; self.message = message
        case .clarification(let message): phase = .clarification; self.message = message
        case .paused(let message): phase = .paused; self.message = message
        case .completed(let message): phase = .done; self.message = message
        case .failed(let message): phase = .failed; self.message = message
        case .activity(let detail): appendActivity(detail)
        case .cancelled:
            phase = .idle; message = "Task cancelled."
            goal = ""; steps = []; choices = []
        }
    }
}
