# Brief 06 — GUI lagging the CLI (reverse parity)

**Verdict: skip.** None of the six investigated areas need a GUI follow-through
in this PR wave. Four are already at parity (retranscribe, meeting
import/split, DAPT export, meeting artifact folder access); two look like
gaps at first glance but are documented, deliberate product-boundary
decisions (knowledge-card browsing, ranked/FTS library search), not oversights.

## Method

Read current source for each area (`TranscriptionLibraryViewModel` /
`TranscriptionRepository`, `CardRepository` / `CardGenerationService` wiring,
`MeetingArtifactStore` / `MeetingArtifactActions`, `TranscriptionViewModel`
retranscribe path, `MeetingImportSheetView` / `MeetingSplitSheetView`,
`ExportService` / `TranscriptResultActions`), cross-checked against
`spec/adr/027-product-north-star.md`, `spec/02-features.md`, and
`plans/active/2026-06-19-meetings-workspace-productization.md`, and confirmed
recent Git history for the meeting-import GUI sheet.

## Findings by area

### 1. Library search vs CLI `search` — real behavioral gap, but by design (skip)

Confirmed, not stale: GUI Library search is still substring matching, not the
CLI's ranked FTS5 segment search.

- CLI `search` queries `SegmentRepository.search` with FTS5 syntax (phrase,
  prefix, AND/OR) and returns ranked snippet hits —
  `Sources/CLI/Commands/SearchCommand.swift:58-79`.
- GUI Library search (`TranscriptionLibraryViewModel.searchText` →
  `TranscriptionRepository.fetchLibraryPage`) resolves to
  `fetchUnicodeSearchLibraryPage`, which streams every candidate row through a
  Swift cursor and tests `transcriptionMatchesLibrarySearch` per row —
  `Sources/MacParakeetCore/Database/TranscriptionRepository.swift:316-328`,
  `:371-427`, `:952-977`. The match itself is
  `UnicodeSearch.contains` — a case/diacritic/width-insensitive
  `String.contains` — `Sources/MacParakeetCore/Utilities/UnicodeSearch.swift:8-10`.
  No ranking, no snippet, no phrase/prefix/AND-OR syntax, no FTS index used.

This is a deliberate, documented split, not an accidental miss:

- `plans/active/2026-06-19-meetings-workspace-productization.md:85-88` records
  the same repository lines and states plainly: "That is acceptable for
  library filtering but not a foundation for cross-meeting Ask."
- `spec/adr/027-product-north-star.md:62-76` ("Agent access is a first-class
  product surface") and `spec/02-features.md:2096-2103` ("Local knowledge
  retrieval and agent automation") both scope segment FTS search, bounded
  transcript context, and knowledge cards as the **CLI/agent** surface, and
  explicitly say first-class automation "does not require mirroring... every
  GUI affordance."

Recommendation: skip. Upgrading Library search to ranked FTS would be a
correctness/UX improvement, not a reuse-the-CLI-plumbing bug fix — the
product has already decided GUI browsing and agent retrieval can diverge.
If it's ever picked up, it is Core reuse (`SegmentRepository`), not a new
engine, consistent with the brief's constraint — but it's a deliberate scope
call, not a small wiring gap, so it does not belong in this pass.

### 2. Cards visibility in GUI — real gap, but by design (skip)

Confirmed: the GUI generates knowledge cards automatically (write-path
parity with the CLI) but has **no UI to browse, list, or read them.**

- GUI writes cards through the same Core service the CLI uses:
  `AppEnvironment` constructs `cardRepo`/`cardGenerationService` from
  `CardRepository`/`CardGenerationService` —
  `Sources/MacParakeet/App/AppEnvironment.swift:21-22,96-97`. Generation
  fires automatically after transcription completion via
  `PromptResultsViewModel.generateKnowledgeCard(transcriptionId:)` —
  `Sources/MacParakeetViewModels/PromptResultsViewModel.swift:579-594` —
  called from `TranscriptionViewModel.swift:1077` and from
  `SavedAudioAutoPromptCompletionService.swift:146,252`.
- No GUI view or view model references `CardListItem`, `.synopsis`, or any
  card-browsing surface. `CardRepository`/`CardGenerationService` usage
  outside tests is limited to CLI commands
  (`Sources/CLI/Commands/CardsCommand.swift`) and the write-path wiring above;
  grepping `Sources/MacParakeet/` and `Sources/MacParakeetViewModels/` for
  card-listing symbols returns nothing beyond that wiring.

Cards are explicitly scoped as a CLI/agent-facing feature: `spec/02-features.md:2096-2100`
— "Cards are derived routing hints: verify candidate actions and decisions
against cited transcript segments" — describes cards as machine-consumption
routing hints backing agent automation, not a human-browsing feature. Nothing
in `spec/02-features.md`, the ADRs, or active plans proposes a GUI card
browser.

Recommendation: skip. A GUI cards tab would be new UI surface, not a small
wiring gap — and the product has already drawn this exact boundary in
ADR-027.

### 3. Meeting artifact folder / markdown in GUI vs `meetings artifact` — no gap (already reused)

GUI already reuses the same Core artifact writer the CLI's `meetings
artifact` command uses, and keeps it live automatically:

- `MeetingArtifactStore.materialize(...)` (manifest + markdown + prompt
  results) is called from both the CLI (`Sources/CLI/Commands/MeetingsCommand.swift`)
  and the GUI: `TranscriptionViewModel.swift:3191-3210` refreshes the artifact
  after notes/metadata/speaker-correction writes, and
  `PromptResultsViewModel.swift:908-925` refreshes it after prompt-result
  changes. This runs automatically as part of normal meeting use — the GUI
  never needs an explicit "materialize" action the way a one-shot CLI
  invocation does.
- GUI exposes the resulting folder via `MeetingArtifactActions.openFolder` /
  `.copyFolderPath` — `Sources/MacParakeet/Views/Transcription/MeetingArtifactActions.swift:22-40`
  — wired into `TranscriptionLibraryView.swift:444-471`,
  `TranscriptResultView.swift:1121-1130`, and `MeetingsView.swift:697-742`.
- The markdown's actual content (auto notes, prompt results) is already
  rendered natively in-app as prompt-result tabs; the raw `.md` file is an
  export artifact for external tools (e.g., Obsidian sync), not the primary
  read surface even in the CLI story.

Recommendation: no action. This is already Core reuse, already wired, already
kept in sync automatically — ahead of, not behind, the CLI's one-shot
materialize command.

### 4. Retranscribe in GUI vs CLI — no gap (GUI has full parity)

GUI has a complete retranscribe feature, including engine override and
speaker-selection, calling the same `TranscriptionService` retranscribe path
the CLI uses:

- `TranscriptionViewModel.retranscribe(_:speechEngineOverride:speakerSelection:)` —
  `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:975-1054` —
  dispatches to `TranscriptionService.retranscribe`/`retranscribeMeeting`,
  mirroring `Sources/CLI/Commands/RetranscribeCommand.swift:427-514`.
- Invoked from a GUI action in `Sources/MacParakeet/Views/MainWindowView.swift:184`,
  with "Retranscribe" UI surfaced across `TranscriptResultView.swift`,
  `TranscriptionLibraryView.swift`, and `MeetingsView.swift`.

Recommendation: no action.

### 5. Meeting import/split GUI vs CLI — no gap (stale claim, recently shipped)

Old plans claiming GUI import/split were missing are stale:

- `MeetingSplitSheetView` and its `MeetingSplitViewModel`/`MeetingSplitTimecode`
  support are wired into `TranscriptionLibraryView.swift:296`,
  `TranscriptResultView.swift:1292`, and `MeetingsView.swift:206-216`.
- `MeetingImportSheetView` is wired into `MeetingsView.swift:217-225`, backed
  by `MeetingImportViewModel` and Core's `MeetingImportService`.
- Git history confirms this is recent, not aspirational:
  `eb89658d feat(meetings): import existing recordings (#1030)`, plus prior
  split-hardening commits (`9d0c16de`, `b07815b1`). No feature flag gates
  either sheet in the views above.
- CLI's `meetings import`/`meetings split` (`Sources/CLI/Commands/MeetingImportCommand.swift`,
  `MeetingSplitCommand.swift`) expose comparable single-file/single-operation
  scope to the GUI sheets — no batch capability in either surface to create a
  meaningful delta.

Recommendation: no action. Update/remove any research notes or plan
checklists that still claim GUI import/split is missing — that's a docs-drift
item for the doc-drift brief, not new GUI work here.

### 6. Export DAPT in GUI — no gap (already present)

GUI already exposes DAPT export through the same `ExportService` the CLI
uses:

- `TranscriptResultActions` lists a `.dapt` export case labeled "DAPT
  Transcript" and calls `exportService.exportToDAPT(transcription:url:)` —
  `Sources/MacParakeet/Views/Transcription/TranscriptResultActions.swift:16,29,329`.
- Same Core renderer both sides: `ExportService.exportToDAPT`/`formatDAPT` →
  `DAPTDocumentRenderer.render` — `Sources/MacParakeetCore/Services/ExportService.swift:187-194`
  — also used by `Sources/CLI/Commands/ExportCommand.swift:96,117`.

Recommendation: no action.

## Summary table

| Area | Status | Action this wave |
| --- | --- | --- |
| Library search (FTS vs substring) | Real gap, but ADR-027-scoped as deliberate GUI/agent divergence | Skip |
| Cards visibility | Real gap (write-only, no browse UI), but ADR-027-scoped as CLI/agent surface | Skip |
| Meeting artifact folder/markdown | No gap — already reused, auto-synced, ahead of CLI's one-shot command | None |
| Retranscribe | No gap — full parity, arguably richer UI (speaker selection) | None |
| Meeting import/split | No gap — shipped via #1030; old claims are stale docs | None (flag docs drift separately) |
| Export DAPT | No gap — shared `ExportService`/`DAPTDocumentRenderer` | None |
