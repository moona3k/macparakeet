# MacParakeet Architecture Deep-Dive

> Date: 2026-07-16
>
> Baseline: `origin/main` at `6599603c0f775d32009422a7ddad6385a8a932df`
> Release context: `0.7.3` candidate; architecture work should not expand the
> release patch

Canonical consolidated record:
[`2026-07-16-v0.7.3-comprehensive-codebase-release-architecture-audit.md`](./2026-07-16-v0.7.3-comprehensive-codebase-release-architecture-audit.md).

## Verdict

MacParakeet's architecture is healthy. The codebase does not need a broad
reorganization, a new control plane, or a rewrite of its core capture and
transcription flows. Its strongest modules have useful depth:

- `STTRuntime` plus `STTScheduler` centralize engine ownership, leases,
  warm-up, and inference ordering.
- Shared microphone capture and meeting flow now have explicit ownership,
  bounded teardown, recovery, and settlement seams.
- The text-processing pipeline keeps ordered dictation and transcription work
  in one implementation.
- GRDB repositories isolate user-data access, while `DatabaseManager` remains
  an auditable migration ledger.

The active improvement opportunities are concentrated around those modules.
They are missing or incomplete deeper modules where policy is currently spread
across several callers.

## Priority 1: Deepen speech-model lifecycle

**Recommendation: Strong. Top recommendation.**

### Evidence

- `STTRuntime.swift` is 2,661 lines and combines inference ownership with
  static model download, cache, deletion, disk-layout, and telemetry operations.
- Model lifecycle callers reach through different implementations:
  `EngineSettingsViewModel`, `SettingsViewModel`,
  `OnboardingViewModel`, `ModelsCommand`, `STTClient`, and
  `TranscriptionViewModel` call static runtime or engine methods directly.
- Whisper, Parakeet, and Nemotron availability/deletion paths do not share one
  lifecycle seam.
- FluidAudio 0.15.5 replaced the `DownloadUtils` surface still used by the
  current implementation. The release audit therefore had to exact-pin 0.15.4.
  A deliberate ModelHub migration currently has a wide change radius.

### Direction

Establish one deep speech-model lifecycle module that owns model catalog,
availability, download, deletion, cache location, operation telemetry, and the
quiescence required for disk mutation. Keep inference, engine leases,
scheduling, warm-up, and live sessions in the existing runtime/scheduler
control plane.

Settings, onboarding, and CLI code should remain adapters to the lifecycle
module rather than independently selecting engine storage operations.

### Wins

- A smaller upstream dependency-upgrade radius.
- One executable model policy shared by GUI and CLI.
- Clearer concurrency around cache mutation and loaded engines.
- Focused lifecycle tests instead of static reach-through in unrelated tests.
- Less responsibility in `STTRuntime` without weakening ADR-016's central
  runtime decision.

## Priority 2: Make microphone selection authoritative

**Recommendation: Strong; hardware-gated behavior change.**

### Evidence

`meetingInputDeviceAttempts` currently builds this ordered chain:

1. Explicitly selected input, if resolvable.
2. Implicit macOS System Default.
3. Explicit built-in microphone.

`SettingsViewModel` tells the user an unavailable named microphone will fall
back to System Default. Capture can therefore succeed on a different route
than the user chose.

The first-principles microphone-routing review already distinguishes the two
intents:

- System Default means exactly the implicit macOS route.
- A named microphone means exactly that explicit route.

### Direction

Make that distinction executable across preparation, start, configuration
recovery, Input Test, and diagnostics. A named route that cannot be honored
should produce a typed, visible failure instead of silent substitution. Report
the effective route while recording.

### Wins

- User intent becomes the capture contract.
- A failed named route cannot silently open a room microphone.
- Bluetooth and USB failures become reproducible instead of looking like poor
  recognition.
- Input Test and diagnostic evidence match the route that supplied buffers.

This should be a separate change after the `0.7.3` candidate, with real
Bluetooth, USB, sleep/wake, and mid-session route validation.

## Priority 3: Unify the read-only Speech Memory query path

**Recommendation: Strong; strategic product leverage.**

### Evidence

The current product has multiple search meanings:

- The GUI Library calls `TranscriptionRepository.fetchLibraryPage`.
- Dictation history calls `DictationRepository.search`.
- `macparakeet-cli search` calls `SegmentRepository.search` and returns
  cited FTS segment hits.
- CLI history also exposes separate transcription and dictation keyword paths.
- Future agent work is split between two tentative plans:
  `2026-07-04-context-engine-agent-tools.md` and
  `2026-06-19-meetings-workspace-productization.md`.

Without a shared query module, Library, CLI, and future agent adapters will
continue to disagree about filtering, ranking, context, and citations.

### Direction

Build one deep, read-only Speech Memory query module over the existing
repositories and derived segment index. It should own query interpretation,
local filtering, ranking, context budgeting, and citation provenance. GUI, CLI,
and later agent integrations should be adapters to the same meaning.

Reconcile the two tentative plans before implementation. Start with the local
read-only index and citations; do not give this module LLM-provider, chat, or
mutation ownership.

### Wins

- One local-first truth surface for saved speech.
- Consistent citations across human and agent workflows.
- High leverage from the existing segment index.
- Direct alignment with ADR-027: the private speech memory of the Mac.

## Priority 4: Turn transcript detail into composed deep panes

**Recommendation: Worth exploring.**

### Evidence

`TranscriptResultView.swift` is 3,879 lines and owns more than 40 local state
values. It coordinates:

- Adaptive audio/video layout and media navigation.
- Transcript editing, find, highlights, and autoscroll.
- Speaker labels, summaries, timed segments, and caches.
- Prompt generation and generated-result display.
- Transcript chat and conversation selection.
- Retranscription, export options, copy state, and artifact deletion.

Useful view-model modules already exist—`TranscriptionViewModel`,
`PromptResultsViewModel`, `TranscriptChatViewModel`, and
`TranscriptFindModel`—but the screen still owns a broad behavior surface.

### Direction

Keep one transcript-detail composition view while deepening coherent reader,
speaker/timeline, generated-results, chat, and export/media panes. Extend the
existing view-model modules where they already own the domain. A mechanical
file split with the same cross-file state would be shallow and is not the goal.

### Wins

- Smaller cognitive and review radius.
- Fewer unrelated state interactions.
- Focused preview and test surfaces.
- Better locality for both maintainers and coding agents.

## Cross-cutting priority: Make current-toolchain concurrency contracts explicit

**Recommendation: Strong engineering hardening.**

A strict Swift 6 language-mode build on Xcode 26.4.1 / Swift 6.3.1 exposes
three isolation errors in the now-removed in-app CLI installer seam, plus two
related ScreenCaptureKit completion-handler warnings. Signed-app release QA
showed that the installer itself crossed the wrong product boundary, and PR
#827 removed its service, protocol, test doubles, and Settings calls before
0.7.3 publication. Those three errors are therefore historical evidence, not
a reason to recreate or refactor that service.

Add a current-Xcode or scheduled compiler lane alongside the pinned
reproducible release lane, then make remaining protocols that genuinely cross
actors explicit about isolation and `Sendable`. Start with live production
seams such as the ScreenCaptureKit callbacks. This is separate from the
speech-model lifecycle recommendation and should remain a compiler-boundary
hardening slice, not a broad concurrency rewrite.

## Priority 5: Finish the Settings domain split

**Recommendation: Worth exploring.**

### Evidence

- `SettingsView.swift` is 3,921 lines.
- `SettingsViewModel.swift` is 1,855 lines.
- `SettingsViewModelTests.swift` is 3,124 lines.
- `SettingsRootViewModel` is 97 lines and owns tab/search state, but it does
  not yet compose the domain view-model modules.
- Engine and LLM settings have started moving into
  `EngineSettingsViewModel` and `LLMSettingsViewModel`; microphone,
  capture, hotkey, startup, permissions, storage, reset, and CLI-install
  behavior remain in the general view-model.

### Direction

Make the root a real composition module over capture, engine/models,
system/permissions, storage/privacy, and integrations. Move persistence and
behavior together, one domain at a time, with compatibility forwarding during
migration. Do not create a view-model per row.

### Wins

- Better test locality and smaller fixtures.
- Fewer cross-domain regressions.
- Clear ownership for settings persistence.
- Safer deletion of stale settings and feature flags.

## Deliberate non-candidates

These modules pass the deletion test and should not be split merely because
they are large:

- **`DatabaseManager`:** splitting the chronological migration ledger would
  reduce data-change auditability.
- **STT runtime/scheduler control plane:** central inference ownership is the
  correct depth. Extract model lifecycle policy, not engine-specific runtimes.
- **Meeting settlement:** a second finalization module would duplicate the
  current ownership and recovery seam.
- **Text-processing pipeline:** it already centralizes ordered shared behavior.
- **`AppEnvironment`:** it is a composition root. Its startup side effects
  merit observation, but blind subdivision would spread construction across
  callers.
- **Repository interfaces:** they are useful user-data and test seams. Add the
  Speech Memory query module above them rather than replacing them.

## Recommended sequence

1. Freeze architecture for `0.7.3`; finish physical signed-candidate QA.
2. Deepen speech-model lifecycle, then use it to migrate FluidAudio ModelHub.
3. Make microphone route intent authoritative in a hardware-gated change.
4. Reconcile the two Speech Memory plans and implement a read-only
   query/citation slice.
5. Deepen transcript-detail and Settings presentation incrementally while
   holding behavior fixed.

The first architecture exploration should answer one question: what is the
smallest speech-model lifecycle slice that allows FluidAudio to move past
0.15.4 without touching every caller?
