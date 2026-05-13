import Foundation

public struct TransformRule: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let instruction: String
    public let defaultEnabled: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        instruction: String,
        defaultEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.instruction = instruction
        self.defaultEnabled = defaultEnabled
    }

    public static func rules(for prompt: Prompt) -> [TransformRule] {
        switch prompt.builtInTransformKind {
        case .polish:
            return [
                TransformRule(
                    id: "polish.concise",
                    title: "Make more concise",
                    detail: "Trim filler and repetition without losing intent.",
                    instruction: "Make the output more concise by removing filler, repetition, throat-clearing, and weak hedges while preserving meaning."
                ),
                TransformRule(
                    id: "polish.clarity",
                    title: "Reword for clarity",
                    detail: "Prefer direct, specific language.",
                    instruction: "Reword unclear phrases for clarity. Prefer direct, specific language over vague or ornamental phrasing."
                ),
                TransformRule(
                    id: "polish.reorder",
                    title: "Reorder for readability",
                    detail: "Move the strongest point where it belongs.",
                    instruction: "Reorder sentences or clauses when doing so makes the text easier to read, but do not change the author's intent."
                ),
                TransformRule(
                    id: "polish.structure",
                    title: "Add structure for readability",
                    detail: "Use bullets or short paragraphs when helpful.",
                    instruction: "Add lightweight structure when the input is hard to scan. Use bullets only when they genuinely improve readability."
                ),
                TransformRule(
                    id: "polish.tone",
                    title: "Maintain your tone",
                    detail: "Keep the same register and personality.",
                    instruction: "Preserve the author's register, personality, and level of formality. Do not make casual text corporate or formal text chatty."
                ),
            ]
        case .distill:
            return [
                TransformRule(
                    id: "distill.signal",
                    title: "Keep only signal",
                    detail: "Compress without dropping action items.",
                    instruction: "Keep only the highest-signal content. Preserve action items, decisions, constraints, names, numbers, and concrete claims."
                ),
                TransformRule(
                    id: "distill.shape",
                    title: "Match the output shape",
                    detail: "Use prose or bullets based on the source.",
                    instruction: "Match the output shape to the source and destination. Use compact prose for one idea, bullets for multiple separable ideas."
                ),
                TransformRule(
                    id: "distill.why",
                    title: "Keep the why",
                    detail: "Preserve the reasoning behind the point.",
                    instruction: "Do not lose the reasoning behind the point. If the input includes why something matters, keep that reason."
                ),
            ]
        case .decide:
            return [
                TransformRule(
                    id: "decide.question",
                    title: "Name the decision",
                    detail: "State what needs to be decided.",
                    instruction: "State the decision or question explicitly, even when the input only implies it."
                ),
                TransformRule(
                    id: "decide.tradeoffs",
                    title: "Surface tradeoffs",
                    detail: "Show what each option costs and buys.",
                    instruction: "Surface the live options and their tradeoffs. Do not invent options or data the input does not support."
                ),
                TransformRule(
                    id: "decide.recommendation",
                    title: "Recommend the next move",
                    detail: "End with a concrete next step when possible.",
                    instruction: "End with a recommended next move and a short reason when the input contains enough information to support one."
                ),
                TransformRule(
                    id: "decide.blocker",
                    title: "Call out missing info",
                    detail: "Name the smallest blocker if a decision is not possible.",
                    instruction: "If there is not enough information to decide, name the smallest concrete question that must be answered next."
                ),
            ]
        case .custom:
            return [
                TransformRule(
                    id: "custom.facts",
                    title: "Preserve facts",
                    detail: "Keep names, numbers, links, and claims intact.",
                    instruction: "Preserve names, numbers, URLs, quoted text, code identifiers, and factual claims unless the custom prompt explicitly says otherwise."
                ),
                TransformRule(
                    id: "custom.intent",
                    title: "Preserve intent",
                    detail: "Change the wording, not the user's goal.",
                    instruction: "Preserve the user's intent and do not add new ideas, claims, promises, or enthusiasm unless the custom prompt explicitly asks for it."
                ),
            ]
        }
    }
}

public enum BuiltInTransformKind: Sendable, Equatable {
    case polish
    case distill
    case decide
    case custom
}

public extension Prompt {
    var builtInTransformKind: BuiltInTransformKind {
        switch id.uuidString.uppercased() {
        case "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11":
            return .polish
        case "1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55":
            return .distill
        case "2BE8D3C1-4A7F-4EBD-8F12-7C9A1E0B3D44":
            return .decide
        default:
            return .custom
        }
    }

    var transformPurpose: String {
        switch builtInTransformKind {
        case .polish:
            return "Make selected text clearer and more finished while keeping your voice."
        case .distill:
            return "Compress selected text to the highest-signal version without losing meaning."
        case .decide:
            return "Turn messy discussion into a decision-ready note with tradeoffs and next steps."
        case .custom:
            return "Run your own instructions against selected text anywhere on your Mac."
        }
    }
}
