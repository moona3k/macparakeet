import Foundation
import GRDB

public struct Prompt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var content: String
    public var category: Category
    public var isBuiltIn: Bool
    public var isVisible: Bool
    public var isAutoRun: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    /// JSON-encoded `KeyboardShortcut`. Persisted on `.transform` prompts as
    /// the bound hotkey for the floating Transforms registry. NULL on
    /// `.result` prompts (they have no hotkey concept). Decode via
    /// `KeyboardShortcut.decoded(from:)`.
    public var keyboardShortcut: String?

    /// Optional override for the running pill label (e.g. *"Polishing…"*).
    /// NULL means derive a short running label from the name when it reads
    /// naturally, falling back to *Transforming…* for awkward names.
    public var runningLabel: String?

    public enum Category: String, Codable, Sendable {
        // Keep the stored raw value as "summary" until the prompts table itself is migrated.
        case result = "summary"
        case transform
    }

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        category: Category = .result,
        isBuiltIn: Bool = false,
        isVisible: Bool = true,
        isAutoRun: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        keyboardShortcut: String? = nil,
        runningLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible
        self.isAutoRun = isAutoRun
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.keyboardShortcut = keyboardShortcut
        self.runningLabel = runningLabel
    }

    // MARK: - Transform convenience

    /// Decoded shortcut binding for `.transform` prompts, or nil if unbound
    /// (or if the column is malformed — treated as "no binding").
    public var shortcut: KeyboardShortcut? {
        KeyboardShortcut.decoded(from: keyboardShortcut)
    }

    /// Verb-form label rendered by the floating Transforms pill while this
    /// transform is running. Honors `runningLabel` if set, otherwise derives
    /// a short label from the name when it reads naturally.
    public var derivedRunningLabel: String {
        if let runningLabel, !runningLabel.isEmpty { return runningLabel }
        return Self.defaultRunningLabel(forName: name)
    }

    public static func defaultRunningLabel(forName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Transforming…" }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return "Transforming…" }
        let lower = trimmed.lowercased()
        // Awkward gerunds — names ending in -ing, -ed, -er, etc. fall through
        // to the generic label rather than producing "Polishinging…".
        let awkwardSuffixes = ["ing", "tion", "ment", "ness", "ed", "er"]
        for suffix in awkwardSuffixes where lower.hasSuffix(suffix) {
            return "Transforming…"
        }
        // English drop-e: "Polish" → "Polishing", "Make" → "Making".
        let stem: String
        if lower.hasSuffix("e") && !lower.hasSuffix("ee") {
            stem = String(trimmed.dropLast())
        } else {
            stem = trimmed
        }
        return "\(stem)ing…"
    }

    // Used for compatibility fallback paths. This is not a fallback for the
    // explicit "no auto-run prompts enabled" state.
    public static var defaultPrompt: Prompt {
        builtInPrompts().first(where: { $0.isAutoRun }) ?? builtInPrompts()[0]
    }

    public static func classicSummaryPrompt(now: Date = Date()) -> Prompt {
        let prompts = builtInPrompts(now: now)
        return prompts.first(where: { $0.name == "Summary" }) ?? prompts[0]
    }

    private static func makeBuiltInPrompt(
        id: String,
        name: String,
        content: String,
        isAutoRun: Bool = false,
        sortOrder: Int,
        now: Date
    ) -> Prompt {
        Prompt(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            content: content,
            category: .result,
            isBuiltIn: true,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func makeBuiltInTransform(
        id: String,
        name: String,
        content: String,
        sortOrder: Int,
        defaultShortcut: KeyboardShortcut?,
        runningLabel: String?,
        now: Date
    ) -> Prompt {
        Prompt(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            content: content,
            category: .transform,
            isBuiltIn: true,
            isVisible: true,
            isAutoRun: false,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now,
            keyboardShortcut: defaultShortcut?.encodedString(),
            runningLabel: runningLabel
        )
    }

    /// Built-in prompt definitions shipped with the app.
    /// `community-prompts.json` is kept in sync as a contribution/reference artifact.
    ///
    /// Note: the "Memo-Steered Notes" prompt was reverted on 2026-05-02. Its
    /// canonical UUID `1C5A1B4A-7E2C-4D38-B3EF-5C0F8A7E3E1A` must not be reused
    /// for a different prompt — the reconciler deletes any existing row with
    /// that ID on next launch (because it is no longer in the canonical list),
    /// and reissuing the UUID would resurrect the prompt on installs that still
    /// have its row in their DB. See ADR-020 (2026-05-02 amendment).
    ///
    /// Reserved Transform UUIDs (ADR-022, do not reuse):
    /// - `0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11` — Polish
    /// - `1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55` — Distill
    /// - `2BE8D3C1-4A7F-4EBD-8F12-7C9A1E0B3D44` — Decide
    public static func builtInPrompts(now: Date = Date()) -> [Prompt] {
        builtInResultPrompts(now: now) + builtInTransformPrompts(now: now)
    }

    private static func builtInResultPrompts(now: Date) -> [Prompt] {
        [
            makeBuiltInPrompt(
                id: "A4882688-E72C-415A-9A5E-1F6AC82DF0D0",
                name: "Summary",
                content: """
                    Analyze this transcript and produce a structured summary.

                    Open with a single sentence that captures what this is about and why it matters. Then organize the rest under clear headings:

                    **Key Points** — The 3–7 most important ideas, findings, or arguments. Each should be a complete thought, not a fragment. If speakers are identified, attribute claims to them.

                    **Decisions & Outcomes** — Anything that was agreed upon, concluded, or resolved. If nothing was decided, omit this section entirely — don't fabricate consensus.

                    **Open Questions** — Unresolved threads, disagreements, or topics raised but not settled. Only include these if they're genuinely unresolved in the transcript.

                    Be direct. Prefer specifics over generalizations — names, numbers, and concrete details beat vague summaries. If the transcript is short or straightforward, keep the output proportionally brief. Don't pad.
                    """.replacingOccurrences(of: "                    ", with: ""),
                isAutoRun: true,
                sortOrder: 0,
                now: now
            ),
            makeBuiltInPrompt(
                id: "65A093C3-2732-4628-8A5C-1F722BCBE736",
                name: "Action Items & Decisions",
                content: """
                    Extract every concrete commitment, task, and decision from this transcript.

                    **Decisions Made**
                    List each decision as a single clear statement. Include who made or endorsed it if identifiable. Only list things that were actually decided — not proposals that were merely floated.

                    **Action Items**
                    For each task or commitment:
                    - What needs to happen (specific enough to act on)
                    - Who owns it (if stated or clearly implied)
                    - When it's due (if any timeline was mentioned — use exact wording as spoken, don't convert or guess)

                    **Needs Follow-Up**
                    Anything flagged as needing attention but with no clear owner or next step yet.

                    If the transcript contains no clear actions or decisions, say so plainly — don't invent structure where none exists. Order items by the sequence they appeared.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 1,
                now: now
            ),
            makeBuiltInPrompt(
                id: "FF4C9E18-0E21-4F58-82B2-EA5A3177908D",
                name: "Chapter Breakdown",
                content: """
                    Break this transcript into logical chapters or segments.

                    For each chapter:
                    - **Title** — A concise, descriptive name (not generic labels like "Discussion 1" or "Part 2")
                    - **Summary** — 2–4 sentences capturing what happened in this segment
                    - **Notable Moments** — Any standout quotes, turning points, or key data points (attribute to the speaker if identifiable)

                    Chapters should reflect natural topic shifts, not arbitrary time splits. A short transcript might have 2–3 chapters; a long one might have 8–12. Let the content dictate the structure.

                    If the transcript is a monologue (lecture, presentation, solo recording), organize by topic or argument progression instead of conversational turns.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 2,
                now: now
            ),
            makeBuiltInPrompt(
                id: "A97D4655-241A-421E-A967-CF2951B67B17",
                name: "Study Guide",
                content: """
                    Transform this transcript into a learning resource.

                    **Overview** — One paragraph: what is being taught or discussed, and who would benefit from understanding it.

                    **Key Concepts** — Each concept gets:
                    - A clear, jargon-free explanation
                    - An example or analogy from the transcript (quote directly when useful)
                    - Why it matters or how it connects to the bigger picture

                    **Common Misconceptions** — If the speaker corrects misunderstandings, challenges assumptions, or contrasts their view with a popular one, capture those moments. Omit this section if none exist.

                    **Review Questions** — 3–5 questions to test understanding. Favor questions that require thinking over recall — "Why does X matter?" over "What is X?"

                    **Key Terms** — Specialized vocabulary worth remembering, with concise definitions drawn from context.

                    Write for someone encountering this material for the first time. Prioritize understanding over completeness.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 3,
                now: now
            ),
            makeBuiltInPrompt(
                id: "00C9B6AE-540D-418E-B55F-9AB4C31C5B38",
                name: "Blog Post",
                content: """
                    Rewrite this transcript as a well-crafted blog post that stands entirely on its own — a reader who never heard the original should find it clear, engaging, and complete. Never reference "the transcript" or "the recording."

                    **Title** — Specific and compelling. Not clickbait, not boring.

                    **Opening** — Hook the reader with the most interesting or surprising point. No throat-clearing or background preamble.

                    **Body** — Develop the key ideas in a logical flow. Use direct quotes from speakers to add texture and credibility (attribute them by name). Break up dense sections with subheadings.

                    **Closing** — End with a takeaway, provocation, or call to reflection — not a generic "In conclusion."

                    Write in a clear, conversational tone. Vary sentence length. Cut filler. If the original conversation wandered or repeated itself, reorganize for the reader's benefit — the post should be tighter than the transcript, not a 1:1 rewrite.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 4,
                now: now
            ),
            makeBuiltInPrompt(
                id: "F87B8B91-6EAD-4E48-B9D3-4D56E0FAE679",
                name: "What Stood Out",
                content: """
                    Read this transcript closely and surface what's easy to miss. Don't summarize — the reader already knows what was discussed. Instead, focus on:

                    **Underlying Tensions** — Where did people talk past each other, avoid a topic, or agree too quickly? What wasn't said that probably should have been?

                    **Surprising Moments** — Anything unexpected: a reversal of position, an offhand remark that revealed more than intended, a data point that contradicts the prevailing narrative.

                    **Patterns** — Recurring themes, repeated concerns, or ideas that surfaced in different forms across the conversation. What's the through-line the participants themselves might not have named?

                    **Strongest Claim, Weakest Evidence** — Identify the most confidently stated position that had the least support. Not adversarial — just flagging where the group might be over-indexing on confidence.

                    Be specific and grounded in the text. Every observation should point to a concrete moment in the transcript. If you're speculating, say so.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 5,
                now: now
            ),
        ]
    }

    /// Built-in `.transform` prompts (ADR-022). Three shipped Transforms,
    /// each pedagogically distinct so the lineup itself teaches what
    /// Transforms is for:
    ///
    /// - *Polish* (⌥1) — make text read like the writer's best version, voice
    ///   intact. The everyday driver.
    /// - *Distill* (⌥2) — compress to signal, raise information density.
    ///   The "I have a rambling braindump" tool.
    /// - *Decide* (⌥3) — turn discussion into a decision-ready note with
    ///   tradeoffs + recommended next step. The forward-motion tool.
    ///
    /// Together: **Improve → Re-shape → Re-direct**. Three slots; ⌥4–9
    /// reserved for user customization.
    ///
    /// Each row is seeded by the reconciler at app launch if missing; user
    /// edits to the row are preserved — the reconciler never overwrites
    /// content, shortcut, or runningLabel on existing built-in transform
    /// rows.
    ///
    /// UUIDs are reserved — never reuse for a different prompt.
    private static func builtInTransformPrompts(now: Date) -> [Prompt] {
        [
            makeBuiltInTransform(
                id: "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11",
                name: "Polish",
                content: """
                    Rewrite the selected text so it reads like the best version of itself: clear, specific, finished. Preserve the author's intent, factual claims, structure, and level of formality.

                    Remove hedging, filler, repetition, throat-clearing, and vague intensifiers. Prefer plain words over performative polish. Keep technical terms, names, code identifiers, URLs, numbers, and quoted text exactly intact.

                    Do not change the register. If the input is casual, keep it casual; if formal, keep it formal. Do not add new ideas, examples, claims, apologies, or enthusiasm. Do not make it sound like marketing copy. Do not introduce AI tells ("delve," "comprehensive," "navigate the landscape of," "in today's fast-paced world"). If the input is a single short fragment (a label, a search query, a name), return it unchanged or with the smallest correction necessary.

                    Return ONLY the rewritten text. No preamble, no quoting, no commentary, no headings.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 100,
                defaultShortcut: KeyboardShortcut(
                    modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                    keyCode: 0x12, // kVK_ANSI_1
                    keyLabel: "1"
                ),
                runningLabel: "Polishing…",
                now: now
            ),
            makeBuiltInTransform(
                id: "1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55",
                name: "Distill",
                content: """
                    Compress the selected text to its signal. Reduce volume by 40–60% while keeping 100% of the actionable meaning.

                    Identify the core point, the primary insight, or the bottom line. Discard the preamble, the connective tissue, and the throat-clearing. Replace passive voice and weak phrasing with active, precise verbs. Replace vague hedges with the specific claim underneath them.

                    Architecture: use bullets when the input is a list of points or a sequence of ideas; use compact prose when it's a single argument. Don't lose the "why" — the reasoning behind a decision belongs in the distillation. Don't lose the "who" — if the input names people, parties, or systems, keep them.

                    Match output shape to context: a Slack message becomes a tight paragraph, an email becomes a short list, a long doc becomes a few crisp bullets. The result should be readable in three seconds and lose nothing important.

                    Return ONLY the distilled text. No preamble, no "Here is the condensed version," no meta-commentary.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 101,
                defaultShortcut: KeyboardShortcut(
                    modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                    keyCode: 0x13, // kVK_ANSI_2
                    keyLabel: "2"
                ),
                runningLabel: "Distilling…",
                now: now
            ),
            makeBuiltInTransform(
                id: "2BE8D3C1-4A7F-4EBD-8F12-7C9A1E0B3D44",
                name: "Decide",
                content: """
                    Rewrite the selected text as a decision-ready note. The reader is busy and needs to understand what is being decided and what should happen next.

                    Separate signal from noise. Surface:
                    - **The question** — what's actually being decided. State it explicitly, even if the input only implied it.
                    - **The options** — the live choices, named clearly. Drop dead options unless their absence would surprise the reader.
                    - **The tradeoffs** — what each option costs and what it buys. One clean line each, no padding.
                    - **The recommendation** — your suggested next move, with a single-sentence reason. If the input already chose, make the choice explicit.
                    - **The block** — if there isn't enough information to decide yet, name the smallest concrete question that must be answered next.

                    Honor unresolved disagreement when it's there — don't flatten it into false consensus. Don't manufacture pros-and-cons that the input doesn't support. Don't invent data. Don't write a strategy memo unless the input warrants one — most decisions earn a paragraph, not a page.

                    Return ONLY the rewritten note. No preamble, no "Here is the decision-ready version," no headings beyond what the structure above requires.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 102,
                defaultShortcut: KeyboardShortcut(
                    modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                    keyCode: 0x14, // kVK_ANSI_3
                    keyLabel: "3"
                ),
                runningLabel: "Deciding…",
                now: now
            ),
        ]
    }
}

extension Prompt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompts"

    public enum Columns: String, ColumnExpression {
        case id, name, content, category, isBuiltIn, isVisible, isAutoRun
        case sortOrder, createdAt, updatedAt
        case keyboardShortcut, runningLabel
    }
}
