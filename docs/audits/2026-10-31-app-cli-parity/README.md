# App, documentation, and agent parity review

> Date: 2026-10-31. Source baseline: `79cf1ca92` from freshly fetched
> `origin/main`. Published app: 0.8.10 (`394e630b4`). Installed app: 0.8.10;
> bundled CLI: 5.1.0. Review branch: `review/app-cli-docs-2026-10-31`.

## Verdict

The product direction is coherent: capture speech locally, retain a useful
library, and expose it through stable contracts. The CLI already covers much
of the durable corpus workflow. Complete GUI/CLI parity is not established:
three history JSON reads bypass timed corrections, source-track recovery is
GUI-owned, and some transcript editing operations lack CLI equivalents.
Truthful evidence and durable recovery deserve priority over additional
presentation controls or a speculative MCP server.

This change set reconciles documentation and plan status. It deliberately does
not claim to fix the runtime findings or qualify the latest native app. The
[capability map](../../../integrations/capabilities.md) gives agents an explicit
workflow map and safe alternatives while those gaps remain open.

## Follow-up: verification and PR preparation

The owner subsequently authorized validating findings and opening PRs. The
[code inventory](code-inventory.json), [UI/tooling review](ui-tooling-review.md),
[capture review](capture-review.md), and [data/agent review](data-agent-review.md)
record the broader pass. At that follow-up the history JSON defect had a
separate fix branch, `fix/history-effective-projection`, with synthetic
regression tests in
[PR #1304](https://github.com/moona3k/macparakeet/pull/1304). That PR has since
merged as `264c11c33` and this branch is rebased onto it; see the status note
under P1. The gaps below describe the baseline; the fix does not expand capture
or editing APIs.

`no-mistakes` was found outside PATH at the follow-up and is used for PR gating.
Its local test stage is deferred to hosted macOS CI because available disk space
is constrained. Greptile is installed but not authenticated. Final behavioral
claims belong to each PR's actual CI head, not this earlier discovery receipt.

## Scope and preservation

- Reviewed current release/flag claims, ADR-002/027/031/033/034 boundaries,
  integration instructions, the CLI catalog and core Library/meeting workflows,
  and changes between `v0.8.10` and the baseline.
- Independent source reviewers covered GUI/CLI parity, documentation/ADRs,
  and agent-facing discovery/privacy/error semantics. Findings were checked
  against source; reviewer agreement is not an executable test.
- Work lives on `review/app-cli-docs-2026-10-31`, created from
  fetched `origin/main`. The original checkout's Voice Control work, staged
  plan index, untracked notes, and generated material were preserved.
- The initial review performed no app capture, user database access, preference
  writes, provider calls, model downloads or publication. The authorized
  follow-up opens review PRs; it does not merge or release the app.
- No Jev judgment calls were used: this work involved code/contract reasoning
  and deterministic comparisons, with no new semantic classifier or routing
  feature. The repository's TypeSafe guidance remains applicable to such work.

## Documentation findings corrected

| Finding | Correction |
|---|---|
| README/spec/distribution called 0.8.9 current and 0.8.10 unpublished; vision still called 0.8.7 current | Current release framing now names published 0.8.10/CLI 5.1.0, distinguishes later source, and directs repeated version claims to the canonical table. |
| 0.8.10 preparation notes lacked publication closeout | Added observed GitHub metadata and installed version checks; retained historical preparation and unverified qualification boundaries. |
| Reusable agent skill said the state override was Debug-only | It now agrees with `AppPaths`: explicit absolute `MACPARAKEET_DEBUG_APP_STATE_DIR` works in both configurations but does not isolate defaults, Keychain or existing row paths. |
| Agent overview listed Apple Intelligence under summarization | Corrected to cleanup-only, matching `LLMExecutionContext` and ADR-011. |
| README, LLM spec, architecture diagram, Ask ADR and integration guide still presented Apple Intelligence as serving summaries, chat, Ask or Transforms | Reworded to cleanup-only, matching `LLMProviderID.canServe(_:)` and the Ask contract. Dated ADR-011 amendments and dated plans remain unchanged. |
| Integration scope treated all settings/sounds as having no automation counterpart | Distinguished GUI presentation from supported shared preferences and opt-in app URL control. |
| Settings spec described Modes and simultaneous capture cards | Updated current UI description to Capture, shared mic strip and selected workflow card. Historical UI roadmap retained. |
| Voice Control privacy boundary was hard to discover from ADR-002 | Added the separate Jev context/consent cross-reference; audio and pixels remain local. |
| Existing contracts were absent from the contract index | Added Ask, voiceprints and whole-transcript edits with release gates where relevant. |
| Plan board and original plan headers still said pending/feature-branch for integrated work | Reconciled timed editing, calendar skip, Apple Intelligence, event taps, streaming, wrapping-up, sharing, voiceprints and capture-finalization status. Dated evidence remains historical. |

## Runtime findings

### P1: History JSON omits later timed corrections

**Trigger:** edit timed text or speaker attribution, then request
`history transcriptions --json`, `history search-transcriptions --json`, or
`history favorites --json`.

**Impact:** agents can receive old `cleanTranscript`, speakers and segments,
including when corrected text caused the search hit. This violates the intended
effective-projection rule in ADR-031; it is not an intentional read boundary.

**Evidence at the baseline:**

- `Sources/CLI/Commands/HistoryCommand.swift:105`, `:218`, `:498`: fetches
  `.items` and serializes original rows.
- `Sources/MacParakeetCore/Database/TranscriptionRepository.swift:431` and
  `:480`: library pages return effective text separately.
- `SpeakerCorrectionService.swift:167`: correction journal and derived indexes
  update without replacing original automatic evidence.
- `Sources/CLI/Commands/ExportCommand.swift:55` and
  `MeetingsCommand.swift:147` correctly resolve the shared projection.

**Current workaround:** discover IDs through history, then use
`export <id> --format json --stdout` or `meetings show <id> --json` for corrected
content. Do not infer speaker/text freshness from a search hit alone.

**Bounded next fix:** resolve each returned record through
`SpeakerAttributionReadService` in all three JSON reads; preserve array shape,
original raw evidence, stable IDs and existing fields. Add synthetic regression
coverage for corrected text, speakers, corrected-term search, favorites and
unedited rows, then run `swift test --filter HistoryCommandTests` and the
related correction/export tests. Run the full suite once as the final gate.
No schema change or new endpoint should be needed. Consider list-query cost
before turning this into an unbounded per-record database pattern.

**Executable confirmation:** the installed CLI 5.1.0 reproduced all three stale
reads using a fresh synthetic database. Public correction commands committed
new text and a speaker name; meeting detail/export returned those corrections,
while history returned the originals. All 16 probe commands succeeded. See the
[reproduction script](history-projection-repro.py) and
[receipt](history-projection-repro.json). At the baseline, PR #1304
implemented the source fix and this documentation branch did not contain it.

**Status note (2026-10-31, after rebase):** PR #1304 merged as `264c11c33` and
this branch is rebased onto it, so source at the branch head resolves all three
JSON reads through `SpeakerAttributionReadService`. The baseline evidence and
the 5.1.0 reproduction above are unchanged. The published CLI 5.1.0 still
returns stored rows: the fix is listed under Unreleased in the CLI changelog,
and no release containing it is claimed here. The workaround applies to the
installed binary until one ships.

### P2: CLI cannot retry retained source tracks without canonical audio

`RetranscribeCommand.swift:528` requires an existing canonical `filePath`
before choosing archived tracks. The app's `TranscriptionViewModel.swift:1818`
and `MeetingAudioFile.swift:105` accept recoverable `.sourcesSaved` state.
After capture settlement/playback finalization failure, the GUI can offer Retry
where CLI retranscription rejects the input.

Use GUI Retry for that case. A future shared retry operation must preserve
queue/finalization ownership, user deletion, source-selection and retention
rules. Do not just remove the file-existence guard or re-import the recording.
Test source-only, mixed-ready, missing-all-audio, active-finalization and
concurrent-deletion cases. This is a confirmed source-level capability gap;
no physical failure was induced during review.

### P2: Editing parity is incomplete across source types

The GUI's timed edit eligibility is source-independent
(`TranscriptResultView.swift:2873`), while CLI correction helpers call
`findMeeting` (`MeetingsCommand.swift:1577`, `:1608`; `CLIHelpers.swift:184`).
The GUI also offers word-boundary splitting (`TranscriptResultView.swift:825`)
that is absent from CLI correction subcommands. Untimed/legacy whole-text edits
have their own GUI persistence contract and no equivalent public CLI write.

A source-neutral correction surface should reuse the revision, anchor and
fingerprint checks. Do not silently reinterpret `meetings` commands. This is
additive contract work, lower priority than fixing misleading reads.

### Lower-priority differences

Per-cue sound style/volume, native playback, window presentation and PDF/DOCX
export do not have complete CLI counterparts. The sound master switch and
machine-oriented exports already exist. These gaps do not justify an automatic
feature expansion. URL controls intentionally have no state/save receipt;
launch success cannot certify recording success.

### P2: Punctuation-bearing vocabulary and snippet boundaries

The [data/agent review](data-agent-review.md) reproduces Foundation matching
failures for standalone `C++`, `C#`, and `.NET`, plus false matches inside
larger identifiers. A separate fix branch, `fix/vocabulary-literal-boundaries`
([PR #1305](https://github.com/moona3k/macparakeet/pull/1305)),
shares Unicode-aware literal boundaries across custom words and plain snippets.
Its regression cases cover punctuation, Unicode, literal expansion, empty rules
and meeting token metadata. Trailing actions retain their existing contract.

### P2 follow-up: Dictation deletion failure policy

The [data/agent review](data-agent-review.md) identifies inconsistent GUI/CLI
handling when audio removal or database deletion fails. A shared policy must
report partial failures and retain a safe retry path. Reversing the operations
alone shifts orphan risk; no speculative deletion change is included.

## Verification and evidence

- [Published app metadata](app-release.json), fetched through GitHub CLI:
  October 14 publication, target `394e630b4`, DMG size 181,247,157 bytes.
- [Installed CLI version](installed-cli-version.txt),
  [help](installed-cli-help.txt), and [catalog](installed-cli-spec.json):
  version 5.1.0, 139 advertised command paths and 30 config keys. Captured with
  `MACPARAKEET_TELEMETRY=0`; these discovery commands do not open the library.
- [Verification receipt](verification.json): all 139 catalog command paths
  resolve through installed `--help`; all 16 documented feature flags match
  source; local Markdown file links resolve (the receipt records the final count).
  The source README reference checker passes. An unknown-option probe returns
  exit 2, empty stdout and a stderr diagnostic, as documented.
- Review-fix follow-up: the first receipt ran `git diff --check` before the audit
  files were tracked, so it did not cover the committed range. Over the committed
  baseline-to-head range it reported a trailing blank line at the end of
  `data-agent-review.md`. The line was removed and the range check was re-run.
  The receipt's `followUp2026-10-31ReviewFixes` section records the re-derived
  Markdown link scope and document hashes for every Markdown file changed since
  the baseline. The original 139-command, 16-flag, installed-binary and raw
  artifact receipts are unchanged.
- Referenced merge commits in reconciled plans were checked as ancestors of
  the review baseline. That establishes integration, not current CI or release.

At the initial review, remaining disk space was approximately 5.3 GiB. A new owning-worktree Swift
build and full test suite were not attempted; another worktree's build would
not prove this source. No Swift runtime code changes are included in this documentation PR. The
follow-up inventoried 1,274 first-party code files, parsed all 658 source Swift
files, checked eight JavaScript files, and ran 46 CI-helper tests successfully.
Syntax parsing is not compilation or behavioral verification. The two code
fixes have separate review/CI evidence. `no-mistakes` was initially absent from
PATH but was subsequently located and used. No native UI, VoiceOver, hardware, long recording, model inference,
provider, signing, or update test was performed. The live appcast request was
blocked with HTTP 403; GitHub publication and installed metadata do not prove
Sparkle delivery. Original dated QA remains evidence only for its named build.

This was a focused cross-surface deep review, not an exhaustive correctness or
security audit of every audio/ASR subsystem, every historical note, the website,
or the gated Voice Control implementation. Open plans were corrected where
integration evidence was clear; historical notes were not rewritten to claim
new verification.
