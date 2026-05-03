import Foundation
import GRDB

/// A user-customizable shortcut surfaced as a pill in the live meeting Ask tab.
///
/// Two flavors, discriminated by `kind`:
/// - **starter** — meeting-context prompts shown in the empty Ask state and the
///   sparkle popover ("Summarize so far", "Action items", …). Optionally
///   grouped via `groupLabel` (CATCH UP / CAPTURE / CHALLENGE).
/// - **followUp** — response-shaping shortcuts shown above the input mid-conversation
///   ("Tell me more", "Why?", "TL;DR"). Always flat, never grouped.
///
/// `label` is what the user sees on the chip and in their own message bubble;
/// `prompt` is the more comprehensive instruction sent to the LLM. Keep them
/// separate so the conversation reads cleanly while the model gets enough
/// scaffolding to answer well.
public struct QuickPrompt: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: Kind
    public var label: String
    public var prompt: String
    public var groupLabel: String?
    public var sortOrder: Int
    public var isVisible: Bool
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case starter
        case followUp = "follow_up"
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        prompt: String,
        groupLabel: String? = nil,
        sortOrder: Int = 0,
        isVisible: Bool = true,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.prompt = prompt
        self.groupLabel = groupLabel
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension QuickPrompt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "quick_prompts"

    public enum Columns: String, ColumnExpression {
        case id, kind, label, prompt, groupLabel, sortOrder, isVisible, isBuiltIn, createdAt, updatedAt
    }
}

// MARK: - Built-in seeds

extension QuickPrompt {
    /// Built-in pill definitions shipped with the app.
    ///
    /// Reserved UUIDs — never reuse, never repurpose. The reconciler matches
    /// existing rows by these IDs; reusing one would silently rebrand a user's
    /// edited row. If a built-in is retired, leave its UUID retired in this
    /// list's history (commit log) and do not assign it to a new pill.
    ///
    /// See also `Prompt.builtInPrompts()` for the parallel pattern in the
    /// summary-prompt library, and ADR-020's burned UUID
    /// `1C5A1B4A-7E2C-4D38-B3EF-5C0F8A7E3E1A` (Memo-Steered Notes) which is
    /// **not** owned by this list but documents the same don't-reuse rule.
    public static func builtInPrompts(now: Date = Date()) -> [QuickPrompt] {
        builtInStarters(now: now) + builtInFollowUps(now: now)
    }

    /// Subset by kind — convenience for the reconciler and tests.
    public static func builtInPrompts(kind: Kind, now: Date = Date()) -> [QuickPrompt] {
        switch kind {
        case .starter:  return builtInStarters(now: now)
        case .followUp: return builtInFollowUps(now: now)
        }
    }

    public static func builtInPrompt(id: UUID, now: Date = Date()) -> QuickPrompt? {
        builtInPrompts(now: now).first { $0.id == id }
    }

    /// Set of canonical built-in UUIDs. Used by the export DTO to coerce a
    /// claimed `isBuiltIn: true` to `false` on import unless the id is genuinely
    /// one of ours — prevents a malicious or careless import file from forging
    /// "built-in" status on a custom row.
    public static let builtInIDs: Set<UUID> = Set(builtInPrompts().map(\.id))

    private static func builtInStarters(now: Date) -> [QuickPrompt] {
        [
            QuickPrompt(
                id: UUID(uuidString: "242D9804-A7C5-4C0A-8A7A-B075957BC1E5")!,
                kind: .starter,
                label: "Summarize so far",
                prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler.",
                groupLabel: "CATCH UP",
                sortOrder: 0,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "7218D518-9B15-41C1-B5A9-060FD1BB5554")!,
                kind: .starter,
                label: "What did I miss?",
                prompt: "Catch me up on the most recent shifts in the meeting — the latest decisions, new arguments, or topic changes. Skip what was clearly settled earlier. Be terse, signal-rich.",
                groupLabel: "CATCH UP",
                sortOrder: 1,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "6D0E7D82-50C1-48A3-B485-6616DC273D18")!,
                kind: .starter,
                label: "Decisions made",
                prompt: "List the decisions reached in the meeting so far. For each, note what was decided and the brief context that explains why. Skip topics that were only discussed without a decision.",
                groupLabel: "CAPTURE",
                sortOrder: 2,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "F678E4F0-4128-4FD5-80FC-96D6EDC330BF")!,
                kind: .starter,
                label: "Action items",
                prompt: "List concrete action items from the meeting so far — what needs to happen next, by whom, and by when if mentioned. Be specific. Skip vague intentions.",
                groupLabel: "CAPTURE",
                sortOrder: 3,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "FEEDC4DD-D9B3-4AB0-BCCA-709A1517E23F")!,
                kind: .starter,
                label: "Who owns what?",
                prompt: "Map who owns what from the meeting so far — assignments, commitments, areas of responsibility. If ownership for an item is unclear or unstated, flag that explicitly.",
                groupLabel: "CAPTURE",
                sortOrder: 4,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "AE32274B-E3E7-4950-A16E-F1DF64660FB2")!,
                kind: .starter,
                label: "What's unresolved?",
                prompt: "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific.",
                groupLabel: "CHALLENGE",
                sortOrder: 5,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "7107DFB7-F2F0-44E6-864A-5FFD3BC45798")!,
                kind: .starter,
                label: "What question is worth asking?",
                prompt: "Based on the meeting so far, suggest one sharp, useful question I could ask next that would advance the discussion or surface something important that hasn't been addressed.",
                groupLabel: "CHALLENGE",
                sortOrder: 6,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "9A80A522-A54C-4A57-BA71-43F5F054714F")!,
                kind: .starter,
                label: "What's worth pushing back on?",
                prompt: "Identify any claims, assumptions, or decisions in the meeting so far that deserve scrutiny. What might be wrong, weak, or worth challenging?",
                groupLabel: "CHALLENGE",
                sortOrder: 7,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "AFC8F517-E186-41C7-A39F-0BE0FAF4E9EA")!,
                kind: .starter,
                label: "Where are we going in circles?",
                prompt: "Have we revisited the same topic or argument without making progress? If so, point out where we're looping and what would actually move things forward.",
                groupLabel: "CHALLENGE",
                sortOrder: 8,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }

    private static func builtInFollowUps(now: Date) -> [QuickPrompt] {
        [
            QuickPrompt(
                id: UUID(uuidString: "9EC1C9BC-92BC-417E-ACC4-7F7633102DB1")!,
                kind: .followUp,
                label: "Tell me more",
                prompt: "Expand on your previous response with more concrete detail from the meeting itself — quotes, specifics, who said what. Surface nuances or caveats you compressed out the first time.",
                sortOrder: 0,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "DE860BF2-E6B2-4E05-9A77-D678F68FA86D")!,
                kind: .followUp,
                label: "Why?",
                prompt: "Explain the reasoning behind your previous answer. What from the meeting transcript supports it?",
                sortOrder: 1,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "EB113B55-D5EE-44C1-A208-D5D5474CF4E2")!,
                kind: .followUp,
                label: "Give an example",
                prompt: "Give one specific, concrete example that illustrates your previous response. Pull it from the meeting itself — a moment, exchange, or quote. If the meeting doesn't contain a clean example, say so plainly and offer the closest analogue.",
                sortOrder: 2,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "3256EB3B-7436-4019-9367-7AAB5698B3EC")!,
                kind: .followUp,
                label: "Counter-argument?",
                prompt: "What's the strongest counter-argument to your previous response? Steelman the opposing view, and use anything in the meeting that supports it.",
                sortOrder: 3,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "D7216011-7568-4B1E-87E0-F32A5EF0EAA3")!,
                kind: .followUp,
                label: "TL;DR",
                prompt: "Give the punchy, no-fluff TL;DR of your previous response — one or two sentences. No headers, no list, no preamble.",
                sortOrder: 4,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
