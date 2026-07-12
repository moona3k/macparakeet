# Plan: Meeting Knowledge Layer — segments, FTS, cards, agent search

> **Executor instructions**: This plan makes the accumulated transcript library
> *answer questions*. It adds a retrieval substrate (normalized segments +
> SQLite FTS5 + a per-recording "card") and agent-facing CLI verbs. The design
> was converged between Fable 5 and GPT-5.6 (xhigh) on 2026-07-10; grounding
> facts below were verified against the live codebase the same day. The schema
> section is the one-way door — get design review on any deviation from it
> before coding. Everything else (prompts, CLI flags, card fields) is
> deliberately two-way.
>
> **Drift check (run first)**:
> ```bash
> git fetch origin
> git diff --stat origin/main -- \
>   Sources/MacParakeetCore/Database/DatabaseManager.swift \
>   Sources/MacParakeetCore/Database/TranscriptionRepository.swift \
>   Sources/MacParakeetCore/Services/TranscriptionService.swift \
>   Sources/CLI/Commands/
> # Re-confirm the "grounding facts" claims below before building.
> ```

## Status

- **State**: **PARTIAL — Phases 1+2 SHIPPED.** Phase 1 = PR #781 (merged
  2026-07-11). Phase 2 (cards) = PR #784 (merged 2026-07-12; Greptile
  converged 4/5→3/5→4/5→5/5 + fresh-eye 6-MAJOR round, all fixed).
  Remaining: Phase 3 (trace-run refinement; + two noted efficiency
  short-circuits in CardRepository), Phase 4 (MCP wrapper, publish seam).
- **Priority**: P1 (north-star work: "make the local library more useful,
  expose it safely to the user and their agents" — ADR-027)
- **Effort**: L (staged; Phase 1 is M and ships standalone)
- **Risk**: MED — new migrations on the user database; mitigated by
  derived/rebuildable design (§3) and additive-only CLI changes.
- **Depends on**: none. (Original gate — the AEC release — shipped: v0.7.1
  live on tags + appcast, verified 2026-07-10.)
- **Category**: database, cli, retrieval, agent-integration
- **Planned at**: 2026-07-10 (main at `448ee8540`)

## 1. Product intent

Target queries, in increasing difficulty:

1. "What was discussed at my last meeting?" (recency)
2. "Find the meeting where we discussed Sparkle cache-busting." (needle)
3. "What did we decide about X?" (decision retrieval — precision matters)
4. "What's the most meaningful insight across all X-related meetings?"
   (cross-corpus synthesis)

The architectural bet (per ADR-027 and the CLI-canonical positioning):
**MacParakeet does not answer questions; it gives agents the tools to.**
The query runtime is whatever agent the user already runs (Claude Code, Codex,
ChatGPT), talking to `macparakeet-cli`. No in-app chat in this plan.

Corpus math: a heavy user accrues 1–2k recordings ≈ 10–50M tokens over years.
Too big to scan raw; trivially small for SQLite FTS5. This is an
"index + agent drill-down" problem, not a RAG problem.

**Scope**: meetings + file/URL transcriptions. **Dictations are deliberately
excluded** — Daniel wants dictation analyzed separately later as a
thought-pattern surface, not mixed into this index. The schema keeps
`dictation` representable (source filtering, no exclusion baked into tables)
so adding it later is a data decision, not a redesign.

## 2. The abstraction: cards are index entries, not summaries

A card is a lossy, **regenerable projection** of one recording, optimized for
an agent deciding *whether to open the transcript, and where* (progressive
disclosure — the skill-frontmatter pattern). Three jobs, and every field must
justify itself against one:

- **Scan** — an agent reads *all* cards in one pass. Hard token budget
  (~250–400 tokens/card); 1k recordings ≈ 300k tokens of card layer.
- **Filter** — deterministic columns come from existing data (date, source,
  duration, attendees via the persisted `calendarEventSnapshot`) and are
  **never duplicated into the card row** — always joined.
- **Route** — decisions/actions carry citations back into transcript segments.

Card text optimizes for *findability, not readability*: names, nouns, numbers,
the vocabulary actually used. AI-extracted decisions/actions are **candidates,
never authoritative** — the agent verifies against cited segments before
asserting "you decided X".

Extraction stays **meeting-local at write time** (parallelizable, regenerable,
no cross-recording entity resolution). Cross-meeting joining happens at read
time, by the agent. This is the explicit defense against the knowledge-graph
trap.

## 3. Grounding facts (verified 2026-07-10, GPT-5.6 investigation)

1. **No normalized segment table exists.** Meetings materialize timestamped,
   speaker-labeled durable segments as JSON-in-TEXT
   (`transcriptions.transcriptSegments`,
   `Services/TranscriptionService.swift:1217`); plain file/URL transcription
   persists `wordTimestamps` + speaker JSON but does **not** materialize
   segments (`TranscriptionService.swift:1558`). Legacy plain-text meetings and
   Cohere output have **no word timings** (`STT/README.md:62`).
2. **FTS5 was added and removed once already**: `dictations_fts` (commit
   `92460f82f`) was dropped in `v0.5-drop-unused-fts` (commit `3336e55bc`)
   *because it had no consumer*. Current search is escaped `LIKE`
   (`Database/DictationRepository.swift:215`) and a Unicode-folded Swift row
   scan (`Database/TranscriptionRepository.swift:392`). Lesson encoded in this
   plan: the FTS index and its consuming `search` verb ship **in the same PR**.
3. **Summary pipeline seam**: completed transcriptions flow through
   `PromptResultsViewModel.autoGeneratePromptResults`
   (`MacParakeetViewModels/PromptResultsViewModel.swift:354`) into
   `LLMService`; results land in `summaries` keyed by `transcriptionId`
   (`Database/DatabaseManager.swift:469`). Generic **JSON-schema output already
   exists** in `LLMService` (used by the LM Studio formatter path,
   `Services/LLM/LLMService.swift:440`, `Models/LLMTypes.swift:56`). Card
   extraction piggybacks this seam and this capability.
   **Nuance**: use the raw timed/speaker AI context
   (`TextProcessing/TranscriptAIContextFormatter.swift:16`) as extraction
   input, not the flat `cleanTranscript` (the cleaned-XOR-speakers collision).
4. **Calendar attendees are persisted in code — but empty in practice.** The
   `transcriptions.calendarEventSnapshot` column decodes title, schedule,
   attendees, organizer, URL/service, confidence
   (`Models/MeetingCalendarSnapshot.swift:3`,
   `Database/DatabaseManager.swift:1138`) — but the 2026-07-10 census found
   **0 of 289 real meetings** carry a snapshot (calendar auto-start defaults
   off). Consequence: attendee card fields and attendee filters are
   speculative until calendar integration is actually used; design keeps the
   join but must not depend on it. Investigate separately whether this is
   purely the default-off setting or a persistence gap.
5. **CLI agent conventions exist**: JSON stdout / human stderr, ISO-8601,
   sorted keys, structured failure envelopes (`CLI/Commands/CLIHelpers.swift:238`,
   `:525`). New verbs follow them. `meetings show` resolves UUID prefix;
   transcript output supports text/JSON/SRT/VTT (`MeetingsCommand.swift:130`).
6. **Migration conventions**: ordered inline registrations in
   `DatabaseManager.makeMigrator()`, named `vX.Y-<feature>`; historical
   migrations must use schema-era **raw SQL**, never Codable `.insert`
   (`DatabaseManager.swift:503`, `:1120`).

## 4. Schema (the one-way door)

Naming follows existing conventions (lowercase-plural tables, camelCase
columns). All new tables are **derived and rebuildable** from the
`transcriptions` row, which remains the single source of truth; a rebuild
command must exist from day one.

### 4.1 `segments` — normalized retrieval units

```sql
CREATE TABLE segments (
  id INTEGER PRIMARY KEY,                 -- rowid; internal only, never cited
  transcriptionId TEXT NOT NULL
    REFERENCES transcriptions(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,                   -- 0-based order within the recording
  startMs INTEGER,                        -- NULL for legacy/Cohere (no timings)
  endMs INTEGER,
  speaker TEXT,                           -- NULL when undiarized
  text TEXT NOT NULL,
  segmenterVersion INTEGER NOT NULL,      -- bump when segmentation rules change
  UNIQUE(transcriptionId, seq)
);
CREATE INDEX idx_segments_transcription ON segments(transcriptionId, seq);
```

Population rules — applied in priority order per row (census 2026-07-10:
only 12/289 meetings have `transcriptSegments` JSON; 265/382 rows have
`wordTimestamps` only, so **word-timestamp derivation is the dominant
backfill path for meetings too**, not just file/URL):
- **`transcriptSegments` JSON present**: decode it.
- **`wordTimestamps` present** (most meetings + file/URL): derive segments
  from word timestamps + speaker attribution; sentence-ish chunking, target
  200–500 chars. New file/URL captures also materialize this at finalization
  (new behavior at `TranscriptionService.swift:1558` area).
- **Empty transcript** (66 rows in the census): skip; no segment rows.
- **Legacy / no-timing rows**: deterministic pseudo-segmentation of the best
  available text (sentence-boundary chunks, `startMs = NULL`). Search works;
  `--around <timestamp>` degrades to `--around-seq` gracefully.
- **Dictations**: not populated (see scope). Nothing in the schema forbids it.

**Determinism requirement**: rebuilding segments under the same
`segmenterVersion` must be byte-identical (citations depend on it). The
pseudo-segmentation algorithm is therefore frozen per version — pure
function of the input text, no locale/OS/NL-framework dependence — and any
rule change bumps `segmenterVersion`.

Citation address = `(transcriptionId, seq range [, startMs..endMs when
available])`. Because segments are rebuildable, cards record the
`segmenterVersion` they cited against; a version bump marks dependent cards
stale rather than silently dangling.

### 4.2 `segments_fts` — FTS5 external-content index

```sql
CREATE VIRTUAL TABLE segments_fts USING fts5(
  text, speaker UNINDEXED,
  content='segments', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
-- plus the standard external-content sync triggers (INSERT/UPDATE/DELETE)
```

Ranking: `bm25()` with recency as a secondary sort exposed to the CLI, not
baked into the index. Ships in the same PR as the `search` verb (see fact #2).

**Tokenizer decision (Daniel, 2026-07-10): optimize for English/space-delimited
languages.** `unicode61 remove_diacritics 2` serves English plus all
space-delimited languages (the entire Parakeet v3 European set, Cyrillic,
Arabic, Hebrew, Hindi; Korean mostly, via eojeol spacing). Known blind spot,
named deliberately: **non-segmented scripts (Chinese, Japanese, Thai) do not
word-tokenize** and would get empty FTS results. Mitigations:

- The `search` verb detects Han/Kana/Thai codepoints in the query and falls
  back to a substring (`LIKE`) scan over `segments` — exactly correct for
  non-segmented scripts, unranked and slower (acceptable at this corpus
  size). Cards scanning, `cards list`, and `transcript --around` are
  unaffected by tokenization in any language.
- Upgrade path is a **rebuild, not a migration** (the FTS table is derived
  machinery, not a one-way door): drop `segments_fts`, recreate with
  `tokenize='trigram'`, reindex from `segments`. Revisit trigger: a CJK
  engine ships past its benchmark gate, or the LIKE fallback's latency
  starts to matter for real users.
- Verify `remove_diacritics` support in the system SQLite at the macOS
  deployment floor during Phase 1.

### 4.3 `cards` — one per recording, versioned and disposable

```sql
CREATE TABLE cards (
  transcriptionId TEXT PRIMARY KEY
    REFERENCES transcriptions(id) ON DELETE CASCADE,
  cardSchemaVersion INTEGER NOT NULL,
  transcriptHash TEXT NOT NULL,           -- hash of extraction input text
  segmenterVersion INTEGER NOT NULL,      -- what citations were resolved against
  promptVersion TEXT NOT NULL,
  model TEXT NOT NULL,
  generatedAt TEXT NOT NULL,              -- ISO-8601
  synopsis TEXT NOT NULL,                 -- 2-3 sentences, findability-first
  topics TEXT NOT NULL,                   -- JSON array of strings
  decisions TEXT NOT NULL,                -- JSON [{text, seqStart, seqEnd, startMs?, endMs?}]
  actions TEXT NOT NULL                   -- JSON [{text, owner?, seqStart, seqEnd, ...}]
);
```

- **Staleness/idempotency**: a card is stale iff
  `(transcriptHash, promptVersion, cardSchemaVersion, segmenterVersion)`
  differs from current. Backfill = "generate where missing or stale". Prompt
  improvements regenerate the whole layer cheaply — this property is the point.
- Deterministic fields (date, source, duration, attendees, title) are
  **joined** from `transcriptions` + `calendarEventSnapshot` at read time,
  never stored in `cards`.
- Source-conditional extraction: meetings get the full field set; file/URL
  cards get synopsis + topics only (decisions/actions are meeting semantics).
- Hard budget enforced in the extraction prompt and validated on write
  (~350 tokens of card text max; truncate topics before synopsis).
- Optional (open question §8.3): a tiny `cards_fts` over synopsis+topics.

### 4.4 Migrations

Two migrations (`vX.Y-segments-fts`, `vX.Y-cards`), raw SQL per fact #6.
Segment backfill runs as an idempotent post-migration maintenance task (or CLI
command), **not** inside the migration transaction — deriving from JSON blobs
over thousands of rows shouldn't block first launch.

## 5. Extraction pipeline

- Trigger: the existing post-completion auto-run seam
  (`PromptResultsViewModel.autoGeneratePromptResults`), async, after
  finalization. **A recording is complete without a card**; extraction runs
  only when an opted-in LLM provider is configured (same privacy surface as
  AI summaries today — no new consent).
- Mechanism: `LLMService` JSON-schema completion (already exists, fact #3),
  input = `TranscriptAIContextFormatter` timed/speaker context.
- Citations: model returns approximate quotes/timestamps; a deterministic
  post-pass resolves them to `seq` ranges (fuzzy match against segment text);
  unresolvable citations are dropped, not guessed.
- Backfill: `macparakeet-cli cards generate [--all|--stale|<id>]` — iterates
  the library, respects staleness, reports cost/progress. Works on
  audio-deleted recordings (transcripts persist).
- **Retranscription invalidation**: when a transcript is regenerated (the
  `retranscribe` command, or any future transcript-mutating flow), segments
  for that `transcriptionId` are rebuilt (delete + reinsert; FTS triggers
  follow) and the changed `transcriptHash` marks the card stale
  automatically. This hook is part of Phase 1, wired into the transcript
  write path — not left to the manual rebuild command.

## 6. CLI contract (additive; update `Sources/CLI/CHANGELOG.md` + `integrations/README.md`)

Follow existing output conventions (fact #5). Verbs are **discovered, not
designed**: this is the v1 hypothesis, refined by Phase 3 trace-runs before
the surface is documented as stable.

```
macparakeet-cli search <query> [--since --until --source meeting|file|url]
                               [--speaker <name>] [--limit N] [--json]
  → segment hits: {transcriptionId, title, recordedAt, source, seq,
     startMs?, speaker?, snippet, rank}

macparakeet-cli cards list [--since --until --source --limit] [--json|--ndjson]
  → card + joined deterministic fields (title, date, duration, attendees, source)

macparakeet-cli transcript <id> [--around <hh:mm:ss|ms> --window <dur>]
                                [--around-seq <n> --context <k>]
  → segment slice with timestamps/speakers (extends the existing transcript
    output path; exact command placement is open question §8.1)
```

`search` documents FTS5 query-syntax passthrough (phrase `"..."`, prefix
`term*`, AND/OR) so agents can query deliberately, and notes the CJK
substring-fallback behavior (§4.2).

Deliberate omissions (add only when trace-runs demand them): `--topic` filter
on cards (reintroduces vocabulary mismatch — agents grep the dump instead),
pagination beyond `--limit`, any ranking knobs.

## 7. Phasing

- **Phase 0 — gate + questions + census.** 0.6.25 ships. Daniel writes ~15
  real questions against his own library (the trace-run corpus; grows
  organically — no formal eval harness, per 2026-07-10 decision). Every
  post-ship miss gets appended to a `missed-queries` log; that log is the
  embeddings tripwire. **Data census** (read-only SQL against the real
  database): count how many `transcriptions` rows fall into each segment
  population case (§4.1 — segment JSON present / word timestamps only /
  plain text, per source type). The census sizes the pseudo-segmentation
  path and validates backfill assumptions before any migration is written.
- **Phase 1 — substrate (no LLM, ships standalone).** `segments` table +
  materialization + backfill + rebuild command; `segments_fts`; `search` verb;
  `transcript --around`. Valuable to every user regardless of LLM opt-in.
- **Phase 2 — cards.** Migration, extraction prompt + JSON schema, auto-run
  integration, `cards generate` backfill, `cards list` verb.
- **Phase 3 — trace-run refinement.** Run the Phase 0 questions through
  Claude Code + the CLI; log flails; adjust verbs/flags/prompt; then document
  the surface in `integrations/README.md` as the stable contract, plus an
  "ask your meetings" recipe.
- **Phase 4 — out of scope here, separate plans:** MCP wrapper (after the verb
  surface stabilizes); publish-to-Slack/webhook seam + team-endpoint
  experiment; dictation thought-pattern analysis (parked, Daniel's separate
  concept).

## 7b. Prior art (OSS peer survey, 2026-07-10)

GPT-5.6 source audits of Meetily (`0281737`), Muesli (`9b8e75a`), and Anarlog
(ex-Hyprnote, `8d5c237`); full reports in
`journal/2026-07-10-oss-meeting-apps-knowledge-layer/`. Headline: **no
local-first peer has a real knowledge layer** — two use raw `LIKE` scans, all
three store summaries as write-over Markdown with zero provenance, none uses
embeddings/RAG for retrieval, and the only corpus Q&A that exists (Anarlog's)
is an agent-with-tools loop, not RAG — independent validation of this plan's
core bets. Adopted into this plan:

- **Failure-safe card regeneration** (from Meetily): keep the previous card
  until the replacement validates; restore on failure/cancel. Applies to
  `cards generate` and the auto-run path.
- **Char-safe snippets** (Meetily anti-lesson): their snippet code slices
  UTF-8 at byte offsets and can panic on CJK/emoji; our `search` snippet
  generation must be character/grapheme-safe. Add a CJK-text snippet test.
- **Post-meeting completion hook** (from Muesli): a user-configurable
  executable receiving `meeting.completed` + recording ID enables
  hook → CLI fetch → external analysis → write-back loops. Phase 4 candidate
  alongside the publish seam; converges with the existing local scripting
  bridge idea (PR #47 follow-up).
- **`related <id>` verb candidate** (from Anarlog): deterministic
  related-meeting retrieval via recurrence, shared attendees
  (`calendarEventSnapshot`), and date adjacency — cheap, no LLM. Goes on the
  Phase 3 trace-run candidate list, not v1.
- **Obsidian Copilot (audited 2026-07-10, same journal dir): the
  embeddings-first counterexample that retreated.** v2 Vault QA was
  embedding-required single-shot RAG (Orama index + HyDE); v3's *default* is
  now index-free lexical retrieval (optional LLM query expansion → grep
  candidate recall → ephemeral BM25 ranking) with embeddings off by default,
  after production failures: 2.2 GB indexes that can't reload (their #2325),
  freezes/rebuilds at 1,400 notes (#2365), provider-change index breakage
  (#2377). Their paid tier monetizes agent orchestration and ingestion, not
  corpus search. Strongly validates defer-embeddings (as *defer*, not
  *never* — tripwire stands). Their time-query design bug — natural-language
  date ranges that silently DROP the topical predicate and treat
  edit-time as authorship — is an anti-lesson for our `search`
  `--since/--until`: time bounds must always compose with the text query,
  never replace it.
- **Cautionary tale reinforcing §4 rules (Anarlog):** its Tantivy indexer
  references a field absent from the canonical schema, so transcript text
  silently never gets indexed, and change-listeners miss updates — production
  silent-recall failure. Our external-content FTS + trigger sync + rebuild
  command exists precisely to make this class of drift impossible.

## 8. Design decisions (Daniel, 2026-07-10 — all questions closed)

1. **Command placement**: new top-level `search` command. **DECIDED.**
2. **Card token budget**: ~350 tokens/card. **DECIDED** (two-way; revisit via
   traces).
3. **`cards_fts`**: yes, index synopsis+topics. **DECIDED** (two-way).
4. **File/URL segment materialization**: yes — finalization writes durable
   `transcriptSegments` for new file/URL captures. **DECIDED.**
5. **Sequencing**: build immediately (the former 0.6.25 gate is moot — v0.7.1
   shipped); normal PR/review flow governs merge.

## 9. Invariants (must not change)

- Local-first: FTS/search/segments are fully on-device; the only network is
  the already-opted-in LLM provider for card extraction.
- `transcriptions` remains the source of truth; `segments`/`cards` are derived
  and rebuildable; no migration mutates or deletes existing transcript data.
- No user-data deletion anywhere in this plan.
- CLI changes are additive; existing commands keep their output shapes.
- Dictations are untouched (not indexed, not extracted, not searched).
- AI-extracted decisions/actions surface as *candidates with citations*, never
  as unqualified facts, in any output this plan ships.

## 10. Explicit don't-builds (agreed 2026-07-10, don't re-suggest)

- Vector embeddings / RAG pipeline — **tripwire**: recurring semantic-recall
  misses in the missed-queries log that prompt/verb fixes don't cure; then
  hybrid vectors bolt on *behind* the same `search` verb.
- Knowledge graph, cross-meeting entity resolution, canonical topic taxonomy,
  tag-management UI.
- In-app chat / Q&A UI.
- Precomputed digests or "meaningfulness" scores.
- Formal eval harness / OSS-benchmark integration (QMSum etc.) — wrong corpus;
  dogfood log instead.
