import Foundation

/// What a committed utterance is, given the conversation it arrives in: an
/// answer to the pending question, a correction of the open task, or a new
/// instruction. Without this, a clarification captures whatever is said next
/// (`open Safari` became `User clarification: open Safari`), and a finished
/// task is revised by `undo` or `make it shorter`.
///
/// Rules, in order:
/// - A closed task (completed, failed, cancelled) or no task: always a new
///   instruction. Nothing is pending and nothing is revisable.
/// - Awaiting a clarification: an offered label or a spoken pick (`2`,
///   `the second one`, `select 2`, `click Open` when `Open` is offered) answers. Then corrections, then command-shaped
///   text starts a new task. Anything else answers, because a clarification can
///   ask for free text (`Say the text to enter`).
/// - Awaiting a confirmation: isolated confirm/decline words answer; `ok` and
///   `okay` do not. Corrections revise; everything else is a new instruction.
/// - A running or paused task: corrections revise; everything else is new.
///
/// `undo` is a command, never a correction. Pure and synchronous, so the
/// coordinator can call it before deciding between `clarify`, `revise` and `submit`.
public enum VoiceControlUtteranceIntent: String, Sendable, Equatable, CaseIterable {
    case answer, newInstruction, correction

    public struct State: Sendable, Equatable {
        public var awaitingClarification: Bool
        public var awaitingConfirmation: Bool
        /// A task is running, paused, or awaiting a response.
        public var hasOpenTask: Bool
        /// The last task completed, failed or was cancelled. Wins over the other flags.
        public var taskClosed: Bool
        /// Labels of the open numbered pick, if any. Saying one is an answer.
        public var offeredLabels: [String]
        public init(
            awaitingClarification: Bool = false, awaitingConfirmation: Bool = false,
            hasOpenTask: Bool = false, taskClosed: Bool = false, offeredLabels: [String] = []
        ) {
            self.awaitingClarification = awaitingClarification; self.awaitingConfirmation = awaitingConfirmation
            self.hasOpenTask = hasOpenTask; self.taskClosed = taskClosed; self.offeredLabels = offeredLabels
        }
    }

    public static func classify(_ text: String, state: State) -> VoiceControlUtteranceIntent {
        let n = VoiceControlSessionGrammar.normalize(text)
        guard !state.taskClosed, state.hasOpenTask || state.awaitingClarification || state.awaitingConfirmation,
            !n.isEmpty
        else { return .newInstruction }
        if state.awaitingConfirmation,
            VoiceControlSessionGrammar.acceptsConfirmation(n) || VoiceControlSessionGrammar.declinesConfirmation(n)
        {
            return .answer
        }
        if state.awaitingClarification {
            // Said as offered (`Select All`) or after a pick verb (`click Select All`).
            let named = withoutPickVerb(n)
            if state.offeredLabels.contains(where: { [n, named].contains(VoiceControlSessionGrammar.normalize($0)) }) {
                return .answer
            }
            if VoiceControlSpokenPick.index(in: named, count: 10) != nil { return .answer }
        }
        if isCorrection(n) { return .correction }
        if state.awaitingClarification, !isCommandShaped(n) { return .answer }
        return .newInstruction
    }

    /// Leads with an unambiguous interface verb (`open`, `click`, `press`, `tap`,
    /// `select`, `scroll`, `type`, `undo`, `go to`, `switch to`), names a new item
    /// (`new message`, `new tab`), or asks for help. Words that also open
    /// ordinary answers (`New York trip`, `Find a time to meet`, `Close`, `down`)
    /// are not commands, so they can answer a clarification.
    /// Shared with the router, which routes an amended goal's newest segment
    /// locally only when that segment is itself a command.
    public static func isCommandShaped(_ text: String) -> Bool {
        var n = VoiceControlSessionGrammar.normalize(text)
        if n.hasPrefix("please ") { n = String(n.dropFirst(7)) }
        guard !n.isEmpty, !isSpokenPick(n) else { return false }
        if ["help", "show commands", "what can i say", "what can i say here"].contains(n) { return true }
        let words = n.split(separator: " ")
        if let first = words.first, commandVerbs.contains(String(first)) { return true }
        return words.count > 1 && commandPhrases.contains("\(words[0]) \(words[1])")
    }

    /// `2`, `the second one`, `option two`, and the same after a pick verb (`select 2`).
    static func isSpokenPick(_ normalized: String) -> Bool {
        VoiceControlSpokenPick.index(in: withoutPickVerb(normalized), count: 10) != nil
    }
    /// `select 2` → `2`, `click Select All` → `select all`. Shared with the
    /// runner, so whatever the classifier calls an answer also resolves the pick.
    static func withoutPickVerb(_ normalized: String) -> String {
        for verb in ["select ", "choose ", "pick ", "click ", "press ", "tap "] where normalized.hasPrefix(verb) {
            return String(normalized.dropFirst(verb.count))
        }
        return normalized
    }

    /// Correction openers, minus `undo`, which is its own command.
    static func isCorrection(_ normalized: String) -> Bool {
        let n = normalized
        // `not sure` and `no preference` answer a question; they correct nothing.
        if ["not sure", "no preference", "no idea", "not really", "no thanks"].contains(where: n.hasPrefix) {
            return false
        }
        let openers = ["actually ", "no ", "instead ", "rather ", "change that", "change the ", "make it ", "not "]
        if openers.contains(where: n.hasPrefix) || ["actually", "instead", "change that"].contains(n) { return true }
        if n.hasPrefix("the other") || n.hasPrefix("other one") { return true }
        return n.hasSuffix(" instead")
    }

    private static let commandVerbs: Set<String> = ["open", "click", "press", "tap", "select", "type", "scroll", "undo"]
    private static let commandPhrases: Set<String> = [
        "go to", "switch to", "new message", "new email", "new tab", "new window", "new note", "new folder",
        "new document", "close window", "close tab", "close this",
    ]
}
