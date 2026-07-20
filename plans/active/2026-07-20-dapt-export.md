# DAPT original-transcript export plan

## Status

- **Issue:** [#850](https://github.com/moona3k/macparakeet/issues/850)
- **Priority:** P1
- **Status:** PR OPEN
- **Branch:** `feat/850-dapt-export`
- **Baseline:** `origin/main` at `1e5502c1d9951457e91725e2fbd1cc69a29b3b29`
- **Research:**
  [`docs/research/2026-07-20-issue-850-dapt-export.md`](../../docs/research/2026-07-20-issue-850-dapt-export.md)

Implementation, focused tests, the final full-suite gate, CLI smoke checks,
both external DAPT validators, and fresh-eye remediation are complete on
[PR #854](https://github.com/moona3k/macparakeet/pull/854). Exact-head hosted
CI/review evidence and the final merge-readiness verdict are tracked on the PR;
this plan remains active until merge.

## Goal

Export any saved or newly produced MacParakeet transcription as a DAPT 1.0
original-language transcript, preserving aligned timing, language, speaker
attribution, and available display labels without inventing metadata when those
inputs are absent.

## Invariants

- DAPT export is local, deterministic, and performs no network I/O.
- Speaker detection remains optional/non-fatal and its runtime behavior is
  unchanged.
- Export never fabricates word timing, speaker identity, confidence, actor
  identity, or source metadata.
- Manually edited transcript text is exported without stale timing or speaker
  alignment.
- Existing TXT/Markdown/SRT/VTT/PDF/DOCX/JSON bytes and defaults do not change.
- Generic transcript export supports meeting rows; the separate
  `meetings export` artifact command remains unchanged.
- Public CLI changes update `spec --json`, the boundary contract, tests,
  integration docs, and CLI changelog together.

## Implementation units

### 1. Core renderer and contract

- Add an isolated pure DAPT renderer and expose it through
  `ExportService.formatDAPT(transcription:)` and
  `exportToDAPT(transcription:url:)`.
- Signal DAPT 1.0, `originalTranscript`, and `audio.dialogue` on the root.
- Use the normalized transcript language, falling back to `xml:lang="und"`.
- Reuse `TranscriptCueBuilder` for aligned timed events.
- Emit character agents only for speaker IDs referenced by aligned events, use
  current renamed labels, and fall back to stored anonymous IDs when the
  optional label roster is missing or incomplete.
- Fall back to one untimed event for timestampless or manually edited text.
- Escape XML markup and remove characters XML 1.0 cannot serialize.
- Use `.dapt.xml` as the product filename convention.
- Add `spec/contracts/dapt-export-v1.md` and register it in the contracts index.

### 2. App export surfaces

- Add DAPT to `TranscriptExportFormat`, single export, bulk export, collision
  handling, telemetry allowlisted format values, and format ordering.
- Add DAPT to `AutoSaveFormat` for both transcription and meeting auto-save.
- DAPT has no TXT/Markdown option toggles; it always exports the strongest
  honest structure available from the record.

### 3. CLI surfaces

- Add `--format dapt` to generic `export`, including stdout and default
  `.dapt.xml` output.
- Add `--format dapt` to one-step `transcribe`, including stdout and
  `--output-dir` parity through the shared renderer.
- Update `SpecCommand`, focused CLI tests, `integrations/README.md`,
  `docs/cli-testing.md`, and `Sources/CLI/CHANGELOG.md`.

### 4. Product docs

- Add DAPT to F12 in `spec/02-features.md`, the `ExportService` architecture
  section, marketing/export format lists, and telemetry format documentation.
- Document the optional speaker behavior and untimed fallback without implying
  diarization accuracy or persistent identity.

### 5. Verification and review

- Focused Swift tests for core export, app export routing, auto-save, CLI
  export/transcribe, and `spec --json`.
- Validate representative timed-labeled-speaker, timed-raw-ID,
  timed-no-speaker, and untimed output with the current W3C schema validator
  and BBC TTML validator.
- Run formatting/diff hygiene and the two-axis standards/spec review.
- Commit, run the full Swift test suite at most once as the final gate, use
  `no-mistakes` when available, push, and open a PR closing #850.
- Run a fresh-eye review against the exact PR head, resolve every blocking
  finding, and require green hosted CI before declaring merge-ready.

## Acceptance criteria

- The output is UTF-8 well-formed XML 1.0 and validates as DAPT 1.0.
- Root metadata includes a non-empty language, `originalTranscript`, and
  `audio.dialogue` representation.
- Aligned word-timed transcripts produce deterministic timed script events.
- Aligned speaker IDs produce valid character agents and event references;
  renamed labels are preserved and XML-escaped, while missing label-map entries
  use anonymous stored IDs without claiming person identity.
- A transcript without diarization produces no agent declarations/references
  and remains valid.
- A transcript without word timing, or with manually edited text, produces an
  untimed event and no stale speaker references.
- App single, bulk, transcription auto-save, and meeting auto-save exports
  write collision-safe `.dapt.xml` files.
- `macparakeet-cli export --format dapt` and
  `macparakeet-cli transcribe --format dapt` share the same renderer and support
  stdout/file output.
- Existing export behavior stays green under focused and final full-suite tests.

## Explicitly out of scope

- Changes to speaker-detection defaults, models, or quality thresholds.
- Persistent speaker identity, voiceprints, cast/talent mapping, or confidence
  extensions.
- Per-event language detection, translation scripts, audio description,
  non-dialogue sound classification, embedded audio, or source-media URLs.
- DAPT import or round-trip editing.
- Adding DAPT to the meeting-artifact-specific `meetings export` command.
