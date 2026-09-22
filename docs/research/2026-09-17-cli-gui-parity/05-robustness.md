# Brief 05 — CLI robustness and catalog correctness: findings

Investigated against HEAD `fb186349` (`feat/cli-gui-parity`, based on
`origin/main`). Ground truth: `CLI.cliVersion = "4.3.0"`
(`Sources/CLI/MacParakeetCLI.swift:11`), `Sources/CLI/CHANGELOG.md`,
`Sources/CLI/Commands/SpecCommand.swift` (read in full, both halves),
`Sources/CLI/Commands/*.swift`, `Tests/CLITests/SpecCommandTests.swift`, and
`integrations/README.md`. No build product existed
(`.build/*/release|debug/macparakeet-cli` absent), so the catalog was read
directly from source per the brief's fallback, not from a live `spec --json`.

## Method

For each "Investigate" item: read the relevant command source and its
`SpecCommand.swift` catalog entry side by side, then checked
`Tests/CLITests/SpecCommandTests.swift` to see whether the existing test net
would actually catch the gap, then `git log` where a claim needed a date.
Item 5 (#883) was checked against the live GitHub issue and cross-referenced
docs, not assumed from the brief's framing — the brief's own characterization
turned out to be wrong (see Ruled out).

## Ranked findings

### 1. [HIGH] CLI transcript-correction journal is meeting-only; the GUI's is not — real CLI/GUI parity gap

- `Sources/CLI/Commands/MeetingsCommand.swift:221-454` exposes
  `meetings corrections edit-line|merge-lines|undo|redo|reset`, and every one
  resolves its target through `runMeetingCorrection`
  (`Sources/CLI/Commands/MeetingsCommand.swift:1219,1229`), which calls
  `findMeeting(idOrName:repo:)`. `findMeeting`
  (`Sources/CLI/Commands/CLIHelpers.swift:159-166`) hard-filters
  `transcription.sourceType == .meeting` — a file/URL transcription's UUID or
  title cannot resolve here at all (`ValidationError`/`notFound`).
- The underlying data model is **not** meeting-scoped: `SpeakerCorrectionRepository`
  (`Sources/MacParakeetCore/Database/SpeakerCorrectionRepository.swift:5-7`)
  is keyed purely by `transcriptionId`, and `SpeakerCorrectionService.swift`
  has zero references to "meeting" anywhere in the file (`grep -n "meeting"`
  returns nothing). ADR-031 (`spec/adr/031-timed-transcript-corrections.md:29`)
  describes it as "the existing **transcript-scoped** correction journal."
- The GUI does not gate this by source type either: `TranscriptionViewModel
  .applySpeakerCorrection` / `beginSpeakerCorrectionSubmission`
  (`Sources/MacParakeetViewModels/TranscriptionViewModel.swift:2073-2113`)
  key off `currentTranscription?.id` with no `sourceType == .meeting` guard,
  and the sheet call sites in
  `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift:740-759`
  (`TimedTranscriptTextEditSheet`, `SpeakerSplitSheet`) are likewise
  unconditional. `transcribe --speaker-detection on` already runs diarization
  on file/URL/podcast input (`SpecCommand.swift:234-235`), so those
  transcriptions do get speaker labels worth correcting.
- **Impact:** a user (or agent) who diarizes a podcast/YouTube transcription
  via the CLI, gets a mislabeled speaker, and tries to fix it hits a dead end
  — `meetings corrections edit-line <that-id>` fails with "not a meeting" even
  though the GUI's Timed view would let them fix the exact same row. There is
  no `transcript corrections` or `history corrections` equivalent.
  ADR-031's own "Implemented surfaces" list
  (`spec/adr/031-timed-transcript-corrections.md:119-125`) already says "CLI
  meeting JSON" — so this is a stated V1 scope limit, not an accidental
  regression, but it is real, still open, and undocumented as a *known gap*
  anywhere the CLI advertises itself (no mention in `SpecCommand.swift`,
  `integrations/README.md`, or `Sources/CLI/CHANGELOG.md`).
- **Cross-reference:** brief 03 (`briefs/03-mutations.md:14`) asks the same
  question from the mutation-parity angle ("would file/URL transcriptions
  also need a command"). This finding supplies the code-level evidence that
  answers it: yes, the GUI already supports it; the CLI is the one that's
  narrower.
- **Merge-worthy now vs later:** later — this is a real product-surface
  decision (new command family or relaxed `findMeeting`), not a one-line fix.
  Worth a decision, then a scoped PR.

### 2. [MEDIUM] `transcribe` is missing `--no-diarize` from its own catalog entry; `retranscribe`'s identical flag is documented and tested

- `TranscribeCommand.swift` declares `@Flag ... var noDiarize: Bool = false`
  ("Compatibility alias for --speaker-detection off") — added in `fad4eacd`
  ("Add speaker diarization support to CLI transcribe command"), well before
  `retranscribe` existed.
- `SpecCommand.swift`'s `transcribe` options block
  (lines 201-248) never lists `--no-diarize`. The sibling `retranscribe`
  options block (lines 262-301) explicitly documents it: `CLISpecParameter
  .flag("--no-diarize", summary: "Compatibility alias for --speaker-detection
  off.")` (line 300) — added when `retranscribe` shipped
  (`e479ec49`, "Add CLI retranscribe for saved library records (#635)").
- `Tests/CLITests/SpecCommandTests.swift:479`
  (`testRetranscribeSpecDocumentsCurrentSurface`) asserts `retranscribe`'s
  catalog contains `--no-diarize`. The parallel test for `transcribe`
  (`testTranscribeSpecDocumentsCurrentTranscribeSurface`, lines 384-447)
  checks ~13 other option names but never asserts `--no-diarize` — so the
  test suite has no way to catch this, matching the brief's own "Settled"
  observation that `SpecCommandTests` can't detect catalog omissions, just
  extending it: it also can't detect a *documented* command missing one of
  its *own* real flags.
- **Impact:** an agent reading `spec --json` to learn `transcribe`'s surface
  will not learn `--no-diarize` exists, even though it works today and is the
  literal same flag, same meaning, as the one `retranscribe` advertises.
  Low severity (there's a fully-documented equivalent, `--speaker-detection
  off`) but it is genuine, verifiable catalog drift, which is exactly what
  this brief asked to find.
- **Merge-worthy now vs later:** now — one line
  (`CLISpecParameter.flag("--no-diarize", ...)`) plus one assertion in
  `testTranscribeSpecDocumentsCurrentTranscribeSurface`.

### 3. [MEDIUM] `vocab words add` / `vocab snippets add` have no `--json` and never return the created record's ID

- `Sources/CLI/Commands/VocabWordsCommand.swift:98-127` (`AddWord`) and
  `Sources/CLI/Commands/VocabSnippetsCommand.swift:61-86` (`AddSnippet`) have
  no `json` property at all and print only a fixed human string ("Added: X ->
  Y" / "Added vocabulary anchor: X" / "Added: Say ... -> ..."). Every other
  subcommand in both families (`list`, `set`/`edit`, `delete`) has a `--json`
  flag (confirmed at `VocabWordsCommand.swift:49,145,190` and
  `VocabSnippetsCommand.swift` equivalents) and `delete`/`set` return a
  structured `VocabWordWriteResult`/`VocabDeleteResult` with the record's
  `UUID`.
- The catalog matches the code accurately here (`jsonMode: "none"`,
  `SpecCommand.swift:1037,1079`), so this isn't catalog drift — it's a real
  gap in the command itself, and it's worse than "no `--json`": **neither
  output mode ever prints the new word/snippet's UUID.** An agent that adds a
  word has no way to later `vocab words set <id> --disabled` or `delete <id>`
  it without re-running `vocab words list` and string-matching the word text
  (fragile if the same word/phrase is added twice, which the repo does not
  appear to reject).
- **Impact:** breaks the create → reference-by-id pattern every other
  mutator in the CLI follows (`prompts add --json` returns the saved prompt
  including id; `meetings labels add` returns a `MeetingLabel` object;
  `transforms create` returns a `TransformDTO`). Scripted vocabulary bundling
  work-arounds this via `vocab export`/`vocab import` bundles instead, but
  the one-at-a-time `add` path is the one most agents will reach for first.
- **Merge-worthy now vs later:** now for the missing ID (small, additive,
  non-breaking: keep the default human line, add a `--json` flag returning
  `{ok, word}` / `{ok, snippet}` the same shape `set`/`delete` already use).

### 4. [MEDIUM] `prompts restore-defaults` has no `--json` and reports no counts, unlike its closest sibling `transforms restore-defaults`

- `Sources/CLI/Commands/PromptsCommand.swift:958-974`
  (`RestoreDefaultsSubcommand`) calls `repo.restoreDefaults()` and always
  prints one fixed line — no `--json`, no count of what was actually
  restored, not even a distinction between "nothing needed restoring" and
  "restored 4 prompts."
- Its structural sibling
  `Sources/CLI/Commands/TransformsCommand.swift:399-456`
  (`transforms restore-defaults`) supports `--json`, returns a
  `TransformRestoreResult` with `restoredCount`, `transforms`, and
  `clearedShortcuts`, and even differentiates the zero-count case in human
  output ("No missing or hidden built-in Transforms to restore.").
  `quick-prompts restore-defaults` also returns a structured result per its
  catalog entry (`SpecCommand.swift:882-892`).
- **Impact:** an agent running `prompts restore-defaults` cannot tell,
  without a before/after `prompts list` diff, whether anything changed. Three
  near-identical "restore built-ins" commands across `prompts`,
  `transforms`, and `quick-prompts` have three different capability levels.
- **Merge-worthy now vs later:** later — needs a small `PromptRestoreResult`
  type and to decide what "restored" should count (currently
  `repo.restoreDefaults()` doesn't appear to return counts either; check
  `PromptRepository.restoreDefaults()` before committing to a shape).

### 5. [LOW-MEDIUM] `--database` isolation caveat is real and load-bearing, but lives only in prose, not in the machine-readable contract agents are told to read first

- `integrations/README.md:184-187` is accurate and important: "`--database
  PATH` selects a database only where advertised. It does not isolate
  preferences, Keychain, models, downloads, or the audio/artifact paths
  stored in copied rows. Never run destructive commands against a copied
  production database that still points to original user files."
- This is not hypothetical. `history delete-meeting-audio`
  (`Sources/CLI/Commands/HistoryCommand.swift:351-401`) calls
  `TranscriptionAssetCleanup.detachOwnedMeetingAudio`, which "permanently
  removed" the audio file at the path stored in the row — a real filesystem
  path, unaffected by which SQLite file `--database` points at. Running this
  command against a copied/isolated database whose rows still reference the
  original user's audio directory would delete real production audio.
  `retranscribe` similarly reads retained audio via `original.audioPath`
  (`Sources/CLI/Commands/RetranscribeCommand.swift:361`), not anything scoped
  to the chosen database file.
- But `SpecCommand.swift`'s `CLISpecConventions` struct (lines 69-76) has no
  isolation field, and the shared `databaseOption` definition (lines
  146-150) says only "Use a specific MacParakeet SQLite database instead of
  the app default." — no caveat. `integrations/README.md`'s own recommended
  agent workflow (`integrations/README.md:178`) is "Start with `--version`,
  `spec --json`, then the health report" — an agent following that literal
  order would not see the isolation warning until (if ever) it separately
  reads the full `integrations/README.md` prose.
- **Impact:** the exact "copied database still points at real files" trap
  the docs warn about is most likely to be hit by an agent that trusts the
  machine contract (`spec --json`) as sufficient, since that's the workflow
  the docs themselves recommend leading with.
- **Merge-worthy now vs later:** now, small and additive — add one
  `isolation` string field to `CLISpecConventions` (mirroring the existing
  `stdout`/`stderr` fields) carrying the same warning, no behavior change.

### 6. [LOW] Brief's own framing of issue #883 is wrong — not an app+brew install conflict; kill that hypothesis

- `gh issue view 883`: title "I installed both the MacParakeet app and the
  macparakeet-cli. Each time I transc..." — but the actual repro and error
  are about a **CoreML/E5RT runtime message** ("E5RT encountered an STL
  exception... zero shape error") printed after a **successful** `transcribe
  --output-dir ... --format transcript --engine parakeet --parakeet-model
  unified` run on macOS 26.5.2 / M1 Max. The reporter never says removing one
  install fixed anything, and there is no install-path/conflict logic
  anywhere near the failure. `gh issue list --search "brew"` /
  `"install both app cli"` turn up no other candidate issue — #883 is the
  only match for the brief's description, and it doesn't describe what the
  brief says it describes.
- Corroborated by `docs/research/2026-09-09-issue-997-coreml-long-file-stt/report.md:248`,
  which independently classifies #883 as "Post-success log on macOS 26 CLI /
  Unified; different error" while ruling it out as a cause of an unrelated
  long-file failure.
- **Status today:** still `OPEN`, zero comments, filed 2026-08-03, over 6
  weeks stale with no CHANGELOG entry addressing it. `StandardOutputRedirection`
  (`Sources/CLI/Commands/StandardOutputRedirection.swift`) already exists and
  wraps the whole `transcribe` run
  (`Sources/CLI/Commands/TranscribeCommand.swift:515-523`) specifically to
  keep native CoreML/E5RT diagnostics off stdout — added in `## [2.12.0] --
  2026-07-06` per `Sources/CLI/CHANGELOG.md:566-567`, *before* #883 was filed.
  That fix routes the noise to stderr (where it now correctly stays, per the
  reporter's own description — the transcription completed and stdout was
  clean); it does not silence or explain the message, so it still reads as
  an alarming error immediately after a "Done" success line. QA evidence from
  a later release still shows the same message
  (`docs/qa/2026-09-07-0.8.0/evidence/parakeet-v2-en.log:27`).
- **Impact:** none of the "install isolation" investigation this brief asked
  for (item 5) actually applies to #883 — there's no code to check for an
  app/brew conflict because that was never the bug. If this is worth picking
  up, it's a UX-polish item (suppress/annotate this specific known-benign
  E5RT message on macOS 26 + Unified model, post-success, similar to how
  2.12.0 already special-cased CoreML/E5RT noise for the JSON path), not a
  robustness/isolation fix.
- **Merge-worthy now vs later:** N/A for this brief — recommend re-filing
  the investigation ask (if still wanted) against the real symptom rather
  than carrying the "install conflict" framing forward into future briefs.

### 7. [LOW] `flow`→`vocab` alias: the CHANGELOG's own removal promise is now two major versions overdue, unremarked in either major's notes

- `Sources/CLI/CHANGELOG.md:935-940` (`## [2.3.0] -- 2026-05-16`): "`flow`
  command renamed to `vocab`... The old `flow` command remains as a
  deprecated alias for this minor release... and will be removed at the next
  major CLI version."
- Two majors have shipped since: `## [3.0.0] — 2026-07-14` (lines 386-397)
  and `## [4.0.0] — 2026-09-07` (lines 195-198, 252-259) — both have
  "Breaking"/"Removed" sections for unrelated changes, and neither mentions
  `flow` at all. The alias is still live today:
  `Sources/CLI/Commands/VocabCommand.swift:17` (`aliases: ["flow"]`) and the
  hidden `vocab vocabulary export|import|schema` compatibility path
  (`VocabCommand.swift:21-33`, `shouldDisplay: false`) are both unchanged on
  `main` at CLI 4.3.0.
- **Impact:** low — the alias still works, nothing is broken for callers.
  But the CLI's own stated semver contract
  (`Sources/CLI/README.md:33-35`: "removing a command/flag/JSON field... is
  **MAJOR**") implies the reverse should also hold: a promised-for-removal
  item should actually be revisited *at* a major, one way or the other
  (remove it, or explicitly re-defer with a reason). Silently carrying it
  past two majors erodes the credibility of that promise for the next
  deprecation notice written the same way.
- **Overlap:** `briefs/04-docs-drift.md` finding #2 already flags a
  *documentation* staleness angle on this same alias (`docs/cli-testing.md`
  saying "accepted in CLI 3.x"). This finding is the complementary
  *changelog-discipline* angle — the CHANGELOG made a commitment about a
  future major version and hasn't kept or revisited it — not a duplicate.
- **Merge-worthy now vs later:** later, and it's a product decision (remove
  `flow` in the next major vs. write a new deprecation note re-committing to
  a version), not something to silently fix in a robustness pass.

### 8. [LOW] Test coverage holes: `calendar upcoming` and `feedback`

- `calendar upcoming`'s ArgumentParser surface (`--days`, `--filter
  link|participants|all`, ArgumentParser-level validation) has no direct
  test. `Tests/CLITests/CalendarUpcomingJSONTests.swift` (146 lines) only
  exercises the internal `calendarUpcomingJSONEvents(...)` mapper function
  and JSON DTO encoding directly — it never constructs or parses a
  `CalendarCommand.UpcomingCommand`. `grep -rl "CalendarCommand"
  Tests/CLITests/*.swift` returns nothing.
- `feedback` (`Sources/CLI/Commands/FeedbackCommand.swift`) has **zero**
  references anywhere in `Tests/CLITests/` (`grep -rl "FeedbackCommand"` —
  no matches). It's also structurally hard to test as written: `run()`
  instantiates `FeedbackService()` directly with no injection seam, unlike
  e.g. `MeetingImportCommand.swift:57`'s documented "Internal injection keeps
  command tests isolated while production..." pattern used elsewhere in the
  same `Commands/` directory. As written, testing `feedback` requires either
  hitting the real support endpoint or refactoring for DI first.
- Not a hole: `health` (contra a first guess) is well covered —
  `Tests/CLITests/ModelLifecycleCommandTests.swift` has dedicated tests for
  repair-flag parsing, schema-skew detection, and directory-probe
  side-effect-freedom (lines 20-92).
- **Impact:** low-probability breakage surface (both commands are simple),
  but `feedback` sends real user data to a live endpoint with literally no
  regression net, and its lack of a DI seam means the gap won't get
  incidentally closed the way most other commands' seams invite.
- **Merge-worthy now vs later:** later for `feedback` (needs a DI seam
  before it's testable — a real, if small, refactor). `calendar upcoming`
  command-level parsing tests are cheap and could ride along with any other
  calendar-touching change.

## Ruled out

- **Item 1 (catalog path drift):** the ArgumentParser tree was enumerated in
  full (every `CommandConfiguration`/`subcommands:` declaration across
  `Sources/CLI/Commands/*.swift` and `MacParakeetCLI.swift`) and diffed
  against every path in `CLISpecCommand.catalog`. Every real, non-hidden
  command path is present in the catalog and vice versa. The only tree nodes
  absent from the catalog are the two that are explicitly
  `shouldDisplay: false` (`meeting-vad-sim`,
  `MeetingVADSimCommand.swift:18`; `vocab vocabulary`,
  `VocabCommand.swift:26`) — both correctly and deliberately excluded from
  the public/agent-facing surface, matching item 7's premise exactly. Path-level
  catalog drift is **not** currently present; the real gap found under this
  item was one flag on an already-cataloged command (finding #2), not a
  missing command.
- **Item 4 broader claim that isolation is "broken":** it isn't — the
  behavior matches the documented caveat exactly (`--database` really does
  leave Keychain/prefs/model caches/audio paths shared). The finding is a
  documentation-placement gap (prose-only, not in the machine contract), not
  an isolation bug in the code (see finding 5).
- **Item 5, "app + brew CLI install conflict":** confirmed false framing;
  see finding 6.
- **Item 6, `health` as a coverage hole:** checked and ruled out; see
  finding 8.
