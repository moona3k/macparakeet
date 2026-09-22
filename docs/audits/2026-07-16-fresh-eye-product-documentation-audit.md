# MacParakeet Fresh-Eye Product and Documentation Audit

> **Status:** COMPLETE
> **Date:** 2026-07-16
> **Baseline:** clean worktree from live `origin/main` at
> `fd87448cf21b6fba5ec54577c41cf1120c21f6ed`
> **Scope:** app-facing copy, README, current specs and ADRs, all 302 Markdown
> files tracked at baseline (303 including this audit), plan indexes,
> brand/marketing sources, repository metadata, and release-facing truth
> surfaces
> **Release impact:** no new code release blocker found; the corrections in
> this audit are documentation, copy, metadata, and archive hygiene independent
> of the already-published v0.7.3 binary

## 1. Bottom line

The codebase's current product truth was stronger than several of its written
surfaces. The app and v0.7.3 release already implement a coherent product:
three primary capture modes, local speech recognition with multiple local
engine choices, optional networked AI, Transforms, and a public CLI. The main
documentation problems were drift around that truth rather than missing
architecture.

This pass corrected the meaningful inconsistencies:

1. First-run onboarding is six steps. Meeting Recording and Calendar setup are
   no longer onboarding steps; their permissions are requested in context.
2. Current Parakeet performance claims use the reproducible M4 Pro benchmark
   (~81–93x steady realtime and 115–131 MB peak RSS by build), not the older
   migration-era `155x` / `~66 MB` figures.
3. Current copy no longer makes unsupported "fastest", "only", universal
   offline, or universal media-site compatibility claims.
4. The README, in-app About subtitle, brand guide, rendered social assets,
   marketing brief, and repository About description use one defensible
   positioning model.
5. Shipped plans and old CLI 2.3.1 campaign drafts no longer appear as active
   engineering work.
6. All tracked relative Markdown links resolve after the plan archival.

The remaining notable item is repository license detection: GitHub currently
reports the license as `Other` even though the README badge and repository
license text describe GPL-3.0. That is a legal/repository-policy decision and
was deliberately not changed silently during a documentation audit.

## 2. Audit method

The review used a clean, fetched `origin/main` worktree so unrelated local
changes could not affect the result. Claims were checked against the following
live or governing sources, in descending order of authority:

1. shipping implementation and feature flags;
2. v0.7.3 build/release metadata and the public CLI version;
3. tested boundary contracts under `spec/contracts/`;
4. accepted ADRs and current specs;
5. README, active brand/marketing material, and current plans;
6. historical audits, research, completed plans, and blog posts.

Historical documents were not rewritten to pretend they were authored today.
Where an old number or decision remains useful provenance, the document now
labels it as historical and points to the current authority.

The Markdown inventory was evaluated in three classes:

| Class | Treatment |
|---|---|
| Current authority | Must agree with implementation and release truth; corrected in place. |
| Active working material | Must state an honest open remainder and appear on the plan board. |
| Historical evidence | Preserve point-in-time facts, add supersession/archive notes where readers could mistake them for current guidance. |

## 3. Verified product truth map

| Surface | Current truth |
|---|---|
| Product | Fast, private, local-first voice app for Apple Silicon Macs. |
| Platform | macOS 14.2+, Apple Silicon only. |
| Primary modes | System-wide dictation, file/media transcription, and meeting recording. |
| Default speech engine | Parakeet v3 through FluidAudio CoreML/ANE on the standard path; locale-aware onboarding selects WhisperKit when preferred languages contain no English and include Korean, Japanese, Chinese, or Cantonese. |
| Optional local engines | Parakeet v2/Unified, Nemotron Beta, Cohere Transcribe, and WhisperKit, with different language/live/timestamp/resource capabilities. |
| Speech privacy | Core speech recognition is on-device after required models are installed. |
| Network boundaries | Media imports, model/update flows, telemetry, and cloud/remote AI providers may use the network. AI features are separate and opt-in; telemetry is opt-out. |
| Text processing | Deterministic cleanup is local and needs no LLM; optional AI formatting/summaries/chat/Transforms use the configured provider. |
| Onboarding | Six-step dictation-first flow. Meeting Recording and Calendar are excluded. |
| Meeting permissions | Microphone is requested when needed; Screen & System Audio Recording is requested in context only for capture modes that include system audio. |
| Calendar | Optional Settings surface; EventKit data stays local; auto-start defaults off. |
| Release | Stable notarized DMG is v0.7.3. `main` is development. |
| CLI | Public automation surface at CLI 3.0.0; bundled with the app and separately available through Homebrew. |
| Current Parakeet benchmark | Apple M4 Pro: ~81–93x steady realtime, 115–131 MB peak RSS by Parakeet build. |

## 4. Findings and resolutions

### 4.1 Onboarding and permission timing contradicted the app

**Severity:** high documentation risk; no implementation defect found.

ADR-005, ADR-017, the architecture spec, and permission timing language still
contained remnants of the former Meeting Recording and Calendar onboarding
steps. The current implementation and feature-flag comments correctly use a
six-step dictation-first flow and in-context setup.

**Resolution:** amended ADR-005 and ADR-017, corrected ADR-014 and the
architecture/audio specs, and made permission timing explicit. Historical
rationale remains intact.

### 4.2 Current performance figures mixed two benchmark eras

**Severity:** high public-claim risk.

The current benchmark and README use the measured M4 Pro results from
`benchmarks/asr/`, while vision/features/architecture and older ADR prose still
used `155x` / `~66 MB`. The older values describe the FluidAudio migration era
and are not interchangeable with the present multi-build benchmark.

**Resolution:** current specs now use ~81–93x and 115–131 MB, with hardware and
method context. ADR-001, ADR-007, and the historical engineering blog preserve
their original figures behind explicit benchmark-era notes.

### 4.3 Product positioning relied on unsupported superlatives

**Severity:** medium-to-high trust risk.

The vision, brand assets, and marketing brief included "fastest", "only", and
competitor-ranking language without a current, maintained comparative evidence
set. This conflicted with the repository's own no-superlative copy guidance.

**Resolution:** the stable tagline is now:

> Fast, private, local-first voice app for Mac.

The README adds the Apple Silicon qualifier. Competitive claims were replaced
with durable product commitments: local-first speech, explicit network
boundaries, multiple capture modes, optional AI, and a public automation CLI.
The SVG sources and their checked-in PNG exports were regenerated and visually
verified.

### 4.4 Privacy, compliance, and media language overreached

**Severity:** medium user-expectation risk.

"Works offline" language did not distinguish local core flows from media
downloads, updates, telemetry, or remote providers. The vision also implied
regulatory compliance and "no tracking" despite opt-out telemetry; local speech
architecture alone cannot certify a user's complete workflow. Media-site copy
could be read as a guarantee that every `yt-dlp`-supported site will always
work.

**Resolution:** the README now states that core dictation, local-file
transcription, and meeting recording can work offline after model setup. It
names the networked boundaries and qualifies media-link support as subject to
upstream site changes. The vision now describes privacy-conscious users without
making compliance claims, and the architecture distinguishes "no required
account" from optional telemetry.

### 4.5 The repository About description was too narrow

**Severity:** medium positioning drift.

The previous description named only YouTube, meeting recording, and Parakeet
TDT. It omitted broader media/podcast input, optional local engines,
Transforms, and the public CLI, and could be read as a Parakeet-only product.

**Resolution:** use this concise repository description:

> Fast, private, local-first voice app for Apple Silicon Macs — dictation,
> file/media transcription, meeting recording, Transforms, and a public
> automation CLI. Free and open-source.

This is repository metadata, not the macOS `Info.plist` About panel. The
in-app About card uses the shorter brand line.

### 4.6 The active plan board advertised shipped work

**Severity:** high agent-execution risk.

The active plan directory mixed real open work with shipped implementation
records, verify-then-archive leftovers, and CLI 2.3.1 community/registry drafts.
That makes an agent likely to repeat completed work or use stale launch copy.

**Resolution:** moved the following records to `plans/completed/` with explicit
archive status:

- engine settings layout (#819/#822);
- live/final speech routing (#813);
- bounded meeting capture lifecycle (#814);
- meeting artifact naming v2 (#744);
- AEC artifact provenance (#676/#681);
- STT capability-registry Phase A (#720);
- onboarding stall watchdog (#518);
- Library bulk delete (#572);
- back-to-back meeting recording (`2667cd83`);
- Nemotron English streaming variant (#503);
- live dictation preview readout (#534);
- five completed 2026-06-15 developer-experience/architecture records;
- the shipped CLI strategy record and its historical CLI 2.3.1 campaign
  folders.

The board now indexes all 38 remaining active Markdown files. Previously
unindexed partial plans for the Meeting Knowledge Layer, meeting title
follow-ups, AEC closure, and ASR/model expansion now state their shipped slices
and honest remainder.

### 4.7 Relative documentation links had drifted

**Severity:** medium agent-navigation risk.

Two links were already invalid before this pass: a tracked audit linked to an
untracked private journal file, and a historical advisor index pointed to the
wrong plan location. Archiving plans created additional path changes that were
updated in the same change.

**Resolution:** all tracked relative Markdown links now resolve. Private journal
provenance is described as text rather than presented as a repository link.

### 4.8 Volatile wording appeared in durable specs

**Severity:** low-to-medium maintenance risk.

Several specs used "current branch", stale universal latency/WER targets, or
volatile popularity/competitor framing. Those statements age even when product
behavior does not.

**Resolution:** replaced branch-relative language with implementation/public
build language, tied performance claims to the current benchmark harness, and
removed volatile promotional facts from governing docs. The May agent-tool
landscape notes now identify themselves as dated research snapshots, vendor
pricing carries a revalidation warning, and the old #91 crash investigation is
marked resolved by #93 instead of "active / not shipped."

### 4.9 The `um` cleanup fix and issue #786 are separate

**Severity:** clarification; no new defect introduced by this audit.

PR [#817](https://github.com/moona3k/macparakeet/pull/817) (`6eb21fa7`)
removed `um` from the deterministic Clean pipeline's
always-removed filler list because `um` is meaningful in supported languages
such as Portuguese and German. The current code removes only the conservative
hesitation spellings `uh`, `umm`, and `uhh`; README and
`spec/07-text-processing.md` match that behavior, and a focused regression test
preserves `"um, dois, três"`.

GitHub issue [#786](https://github.com/moona3k/macparakeet/issues/786) is not
that cleanup bug. It reports Spanish speech switching back into English
mid-sentence and remains open. Treating #817 as the resolution for #786 would
conflate deterministic post-processing with speech-engine language recognition.

## 5. Updated surface inventory

The complete file-level inventory is the PR/commit diff. Grouped by role, the
change covers:

- **Public product/automation entry points:** `README.md`, the in-app Settings
  About subtitle, `Sources/CLI/CHANGELOG.md`, and the Homebrew scaffold HOWTO.
- **Current specs:** vision, features, architecture, audio pipeline, and the
  affected LLM/processing wording in specs 11 and 12.
- **Accepted decisions:** ADR-001, ADR-005, ADR-007, ADR-011, ADR-013, ADR-014,
  ADR-017, ADR-022, ADR-026, ADR-027, and ADR-028.
- **Brand/marketing:** brand identity, marketing production brief,
  marketing-video script, three active composition SVGs, and their regenerated
  OG/wordmark/story PNG exports.
- **Current operational/research guidance:** CLI testing, telemetry vendor-limit
  warning, agent-landscape index and snapshots, historical three-chip blog
  status note, and the resolved #91 crash investigation status.
- **Audit/research navigation:** the telemetry verification record,
  meeting-stop readiness record, v0.7.3 comprehensive audit, live/final routing
  review reference, and this fresh-eye audit.
- **Plan truth:** `plans/README.md`, nine active plan/advisor records, two older
  completed-plan cross-references, one completed advisor status, 17 archived
  implementation records, and two archived CLI campaign directories.
- **Live repository metadata:** the GitHub About description, updated outside
  the file diff and re-read after mutation.

## 6. Validation

The final change was checked with:

| Check | Result |
|---|---|
| Tracked Markdown inventory | 302 baseline files reviewed/classified; 303 files in the final tree including this audit |
| Relative Markdown link scan | 330 links checked; 0 missing targets |
| Active-plan index reconciliation | 38 active files; 38 indexed; 0 missing |
| Subsystem README source-reference check | Pass |
| Stale current-claim scans | No unqualified current `155x`/`~66 MB`, old About copy, unsupported brand superlative, or pre-v0.7 stable-release claim in authoritative surfaces |
| Brand export regeneration | 21 exports rendered; three changed tagline images visually inspected |
| `git diff --check` | Pass |
| Focused Swift tests | 30 `SettingsSearchIndexTests` pass; locale-aware CJK/Korean onboarding recommendation test passes |
| Hosted full Swift suite | One exact-head run passed all 4,903 tests; its duplicate exposed a scheduler-dependent 40 ms fixed-sleep test, which was replaced with condition-based waiting and passed 21 consecutive focused local runs |
| Marketing video TypeScript | Not run: `marketing/video/node_modules` is not installed in the clean worktree; the change is string-only |

The hosted final gate ran the full suite. The product behavior was green; the
duplicate run uncovered a brittle timing assumption in
`MeetingRecordingTileTests.testAudioSavedConfirmationAutoClears`. The test now
waits for the observable condition with a bounded deadline instead of assuming
that a main-actor child task will always run within 40 milliseconds under
parallel CI load. No shipping behavior changed.

## 7. What was intentionally not changed

1. **Historical facts were not erased.** Accepted ADRs and historical blogs may
   retain old measurements when clearly labeled and linked to current evidence.
2. **No licensing text was rewritten.** GitHub's `Other` detection needs an
   owner/legal decision about the exact license file, not an agent guess.
3. **No external-link crawler was added.** All internal links were checked;
   live release/repository metadata and the most important public endpoints
   were verified directly. Bulk crawling every historical research citation
   would add noise and does not improve product truth.
4. **No feature flags or product behavior changed.** This audit aligned the
   written system to the shipping implementation.
5. **No broad plan was deleted.** Completed records remain available under
   `plans/completed/`; partial plans remain active only when they name a real
   remainder.

## 8. Future-review checklist

Use this compact order for future documentation audits:

1. Read `spec/README.md` release/flag state and `AppFeatures.swift` together.
2. Verify the stable tag, appcast, CLI version, and GitHub About description.
3. Compare README claims to `spec/06-stt-engine.md` and `benchmarks/asr/`.
4. Check ADR amendments for current onboarding, privacy, persistence, and
   permission timing.
5. Require every `plans/active/*.md` record to appear on `plans/README.md` with
   a concrete open remainder.
6. Run the tracked relative-link scan and `scripts/check-readme-references.sh`.
7. Preserve historical evidence, but label it so agents cannot mistake it for
   current instructions.
