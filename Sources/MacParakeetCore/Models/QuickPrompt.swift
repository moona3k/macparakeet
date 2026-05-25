import Foundation
import GRDB

/// A user-customizable shortcut surfaced as a pill in the live meeting Ask tab.
///
/// One unified library, two render modes:
/// - **Empty Ask state + sparkle popover** — every visible prompt, grouped by
///   `groupLabel` (CATCH UP / CAPTURE / CHALLENGE / unnamed). Full title +
///   body preview.
/// - **After-response strip** — visible `isPinned` prompts, title-only pills,
///   in sortOrder. Pinning is unbounded; the strip scrolls horizontally.
///
/// `label` is what the user sees on the chip and in their own message bubble;
/// `prompt` is the more comprehensive instruction sent to the LLM. Keep them
/// separate so the conversation reads cleanly while the model gets enough
/// scaffolding to answer well.
public struct QuickPrompt: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var label: String
    public var prompt: String
    public var groupLabel: String?
    public var sortOrder: Int
    public var isVisible: Bool
    public var isPinned: Bool
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        prompt: String,
        groupLabel: String? = nil,
        sortOrder: Int = 0,
        isVisible: Bool = true,
        isPinned: Bool = false,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.groupLabel = groupLabel
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.isPinned = isPinned
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct QuickPromptTelemetryIdentity: Sendable, Hashable {
    public static let custom = QuickPromptTelemetryIdentity(group: "custom", label: "custom")

    public let group: String
    public let label: String
}

extension QuickPrompt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "quick_prompts"

    public enum Columns: String, ColumnExpression {
        case id, label, prompt, groupLabel, sortOrder, isVisible, isPinned, isBuiltIn, createdAt, updatedAt
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
        defaultUnpinned(now: now) + defaultPinned(now: now)
    }

    public static func builtInPrompt(id: UUID, now: Date = Date()) -> QuickPrompt? {
        builtInPrompts(now: now).first { $0.id == id }
    }

    public var telemetryIdentity: QuickPromptTelemetryIdentity {
        guard isBuiltIn,
              let canonical = Self.builtInPrompt(id: id),
              hasCanonicalTelemetryContent(matching: canonical),
              let identity = Self.builtInTelemetryIdentities[id] else {
            return .custom
        }
        return identity
    }

    /// Set of canonical built-in UUIDs. Used by the export DTO to coerce a
    /// claimed `isBuiltIn: true` to `false` on import unless the id is genuinely
    /// one of ours — prevents a malicious or careless import file from forging
    /// "built-in" status on a custom row.
    public static let builtInIDs: Set<UUID> = Set(builtInPrompts().map(\.id))

    private static let builtInTelemetryIdentities: [UUID: QuickPromptTelemetryIdentity] = [
        UUID(uuidString: "242D9804-A7C5-4C0A-8A7A-B075957BC1E5")!: QuickPromptTelemetryIdentity(group: "catch_up", label: "summarize_so_far"),
        UUID(uuidString: "7218D518-9B15-41C1-B5A9-060FD1BB5554")!: QuickPromptTelemetryIdentity(group: "catch_up", label: "what_did_i_miss"),
        UUID(uuidString: "6D0E7D82-50C1-48A3-B485-6616DC273D18")!: QuickPromptTelemetryIdentity(group: "capture", label: "decisions_made"),
        UUID(uuidString: "F678E4F0-4128-4FD5-80FC-96D6EDC330BF")!: QuickPromptTelemetryIdentity(group: "capture", label: "action_items"),
        UUID(uuidString: "FEEDC4DD-D9B3-4AB0-BCCA-709A1517E23F")!: QuickPromptTelemetryIdentity(group: "capture", label: "who_owns_what"),
        UUID(uuidString: "AE32274B-E3E7-4950-A16E-F1DF64660FB2")!: QuickPromptTelemetryIdentity(group: "challenge", label: "unresolved"),
        UUID(uuidString: "7107DFB7-F2F0-44E6-864A-5FFD3BC45798")!: QuickPromptTelemetryIdentity(group: "challenge", label: "question_worth_asking"),
        UUID(uuidString: "9A80A522-A54C-4A57-BA71-43F5F054714F")!: QuickPromptTelemetryIdentity(group: "challenge", label: "pushback"),
        UUID(uuidString: "AFC8F517-E186-41C7-A39F-0BE0FAF4E9EA")!: QuickPromptTelemetryIdentity(group: "challenge", label: "going_in_circles"),
        UUID(uuidString: "9EC1C9BC-92BC-417E-ACC4-7F7633102DB1")!: QuickPromptTelemetryIdentity(group: "follow_up", label: "tell_me_more"),
        UUID(uuidString: "DE860BF2-E6B2-4E05-9A77-D678F68FA86D")!: QuickPromptTelemetryIdentity(group: "follow_up", label: "why"),
        UUID(uuidString: "EB113B55-D5EE-44C1-A208-D5D5474CF4E2")!: QuickPromptTelemetryIdentity(group: "follow_up", label: "give_example"),
        UUID(uuidString: "3256EB3B-7436-4019-9367-7AAB5698B3EC")!: QuickPromptTelemetryIdentity(group: "follow_up", label: "counter_argument"),
        UUID(uuidString: "D7216011-7568-4B1E-87E0-F32A5EF0EAA3")!: QuickPromptTelemetryIdentity(group: "follow_up", label: "tldr"),
    ]

    private func hasCanonicalTelemetryContent(matching canonical: QuickPrompt) -> Bool {
        label == canonical.label
            && prompt == canonical.prompt
            && Self.normalizedTelemetryGroup(groupLabel) == Self.normalizedTelemetryGroup(canonical.groupLabel)
    }

    private static func normalizedTelemetryGroup(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Default unpinned prompts — meeting-context starters that show up in the
    /// empty Ask state and the sparkle popover. Grouped via `groupLabel`.
    /// SortOrder ranges 0-8 (independent of the pinned bucket).
    private static func defaultUnpinned(now: Date) -> [QuickPrompt] {
        [
            QuickPrompt(
                id: UUID(uuidString: "242D9804-A7C5-4C0A-8A7A-B075957BC1E5")!,
                label: "Summarize so far",
                prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler.",
                groupLabel: "CATCH UP",
                sortOrder: 0,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "7218D518-9B15-41C1-B5A9-060FD1BB5554")!,
                label: "What did I miss?",
                prompt: "Catch me up on the most recent shifts in the meeting — the latest decisions, new arguments, or topic changes. Skip what was clearly settled earlier. Be terse, signal-rich.",
                groupLabel: "CATCH UP",
                sortOrder: 1,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "6D0E7D82-50C1-48A3-B485-6616DC273D18")!,
                label: "Decisions made",
                prompt: "List the decisions reached in the meeting so far. For each, note what was decided and the brief context that explains why. Skip topics that were only discussed without a decision.",
                groupLabel: "CAPTURE",
                sortOrder: 2,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "F678E4F0-4128-4FD5-80FC-96D6EDC330BF")!,
                label: "Action items",
                prompt: "List concrete action items from the meeting so far — what needs to happen next, by whom, and by when if mentioned. Be specific. Skip vague intentions.",
                groupLabel: "CAPTURE",
                sortOrder: 3,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "FEEDC4DD-D9B3-4AB0-BCCA-709A1517E23F")!,
                label: "Who owns what?",
                prompt: "Map who owns what from the meeting so far — assignments, commitments, areas of responsibility. If ownership for an item is unclear or unstated, flag that explicitly.",
                groupLabel: "CAPTURE",
                sortOrder: 4,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "AE32274B-E3E7-4950-A16E-F1DF64660FB2")!,
                label: "What's unresolved?",
                prompt: "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific.",
                groupLabel: "CHALLENGE",
                sortOrder: 5,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "7107DFB7-F2F0-44E6-864A-5FFD3BC45798")!,
                label: "What question is worth asking?",
                prompt: "Based on the meeting so far, suggest one sharp, useful question I could ask next that would advance the discussion or surface something important that hasn't been addressed.",
                groupLabel: "CHALLENGE",
                sortOrder: 6,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "9A80A522-A54C-4A57-BA71-43F5F054714F")!,
                label: "What's worth pushing back on?",
                prompt: "Identify any claims, assumptions, or decisions in the meeting so far that deserve scrutiny. What might be wrong, weak, or worth challenging?",
                groupLabel: "CHALLENGE",
                sortOrder: 7,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "AFC8F517-E186-41C7-A39F-0BE0FAF4E9EA")!,
                label: "Where are we going in circles?",
                prompt: "Have we revisited the same topic or argument without making progress? If so, point out where we're looping and what would actually move things forward.",
                groupLabel: "CHALLENGE",
                sortOrder: 8,
                isPinned: false,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }

    /// Default pinned prompts — universal response-shaping moves that show up
    /// as compact pills in the after-response strip. Five built-ins seed a
    /// useful default strip; users can pin/unpin without a hard cap. SortOrder
    /// ranges 0-4 for the shipped seeds (independent of the unpinned bucket).
    private static func defaultPinned(now: Date) -> [QuickPrompt] {
        [
            QuickPrompt(
                id: UUID(uuidString: "9EC1C9BC-92BC-417E-ACC4-7F7633102DB1")!,
                label: "Tell me more",
                prompt: "Expand on your previous response with more concrete detail from the meeting itself — quotes, specifics, who said what. Surface nuances or caveats you compressed out the first time.",
                sortOrder: 0,
                isPinned: true,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "DE860BF2-E6B2-4E05-9A77-D678F68FA86D")!,
                label: "Why?",
                prompt: "Explain the reasoning behind your previous answer. What from the meeting transcript supports it?",
                sortOrder: 1,
                isPinned: true,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "EB113B55-D5EE-44C1-A208-D5D5474CF4E2")!,
                label: "Give an example",
                prompt: "Give one specific, concrete example that illustrates your previous response. Pull it from the meeting itself — a moment, exchange, or quote. If the meeting doesn't contain a clean example, say so plainly and offer the closest analogue.",
                sortOrder: 2,
                isPinned: true,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "3256EB3B-7436-4019-9367-7AAB5698B3EC")!,
                label: "Counter-argument?",
                prompt: "What's the strongest counter-argument to your previous response? Steelman the opposing view, and use anything in the meeting that supports it.",
                sortOrder: 3,
                isPinned: true,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "D7216011-7568-4B1E-87E0-F32A5EF0EAA3")!,
                label: "TL;DR",
                prompt: "Give the punchy, no-fluff TL;DR of your previous response — one or two sentences. No headers, no list, no preamble.",
                sortOrder: 4,
                isPinned: true,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
