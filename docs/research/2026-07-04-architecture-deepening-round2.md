# Architecture Deepening — Round 2 (verified verdicts and fix plan)

> Status: **VERIFIED PLAN** (2026-07-04). Follow-up to
> [2026-06-28-architecture-deepening-opportunities.md](./2026-06-28-architecture-deepening-opportunities.md).
> Nine candidates (two standing from June, four new from the AEC/LocalVQE surface,
> three revived from the June "unwritten six") were adversarially verified against
> `origin/main` @ `8a709ce83` by four independent Codex reviewers instructed to
> refute. Five were cut or already implemented, five confirmed with narrow scopes. Line anchors were
> current at `8a709ce83`; re-check before acting — they drift.

Vocabulary as in the June doc: **module / interface / implementation / deep /
shallow / seam / adapter / leverage / locality**, and the **deletion test**.

## Headline: the codebase moved faster than the review

Three candidates surfaced by exploration were already implemented on `main`
before this round could propose them:

- **Cleaned-mic readiness**: `MeetingCleanedMicrophoneReadiness` is now a deep
  module owning render scheduling, timeout policy, cancellation, fallback
  reasons, and final source resolution, with tests for wait/timeout/cancel/
  invalid/render-failure. Finalization resolves the mic source once before
  source STT. A second "finalization module" would be a shallow pass-through.
- **Cleaned-mic artifact visibility**: `cleanedMicrophoneAudioPath` is in the
  artifact snapshot, manifest, markdown frontmatter, CLI output, and contract
  (`spec/contracts/meeting-artifacts-v1.md`), with tests.
- **STT capability registry (June Finding 3, Phase A)**: `SpeechEngineCapabilities`
  landed with #721 — a pure, model-free registry keyed by (engine, variant)
  covering native live, tail preview, word timestamps, language policy, custom
  vocabulary, and telemetry identity, with totality/invariant tests. Runtime
  preview/live/telemetry/default-language sites and scheduler admission already
  read it. The June finding is now a **read-site adoption gap**, not a design gap.

Lesson recorded deliberately: exploration reports from a stale checkout are
leads; verification against live `main` is what makes them actionable.

## Verdict table

| # | Candidate | Verdict | Owner surface |
|---|-----------|---------|---------------|
| R2-1 | Adopt capability registry in retranscription options | **FIX** (small) | `TranscriptionViewModel` |
| R2-2 | Capture-failure push signal (June Finding 1, narrowed) | **FIX** (medium) | Meeting recording flow |
| R2-3 | AEC release-gate default-SHA verification | **FIX** (small, release-relevant) | `scripts/dist` |
| R2-4 | LLM HTTP provider adapters | **FIX** (medium) | `Services/LLM` |
| R2-5 | Hotkey conflict policy Core module | **FIX** (medium, user-facing risk) | Hotkey, 3 targets |
| — | Final-STT handoff module | CUT — already implemented (`MeetingCleanedMicrophoneReadiness`) |
| — | Cleaned mic in manifest | CUT — already implemented |
| — | LocalVQE Swift use-case policy | CUT — config/factory already concentrated; policy types would add surface without deleting implementation |
| — | Unify live/offline mic conditioning | CUT — two genuinely different control planes (streaming lockstep vs offset-aligned batch) share one deep primitive (`MicConditioning`); a unifying module needs MORE interface than either caller; no divergence bug in history |
| — | Shared text-processing orchestrator | CUT — pure pipeline already deep; caller shapes only superficially similar (Voice Return/insertion style vs title/artifacts/telemetry vs meeting source policy); shared module fails the deletion test |
| — | STT optional-engine lifecycle wrapping | DEFER — unblock when a new engine family creates a second implementation-level caller; Phase A already captures the leverage without actor churn |
| — | Broad meeting transition stream | CUT — pause reconciliation and continuous concerns keep the poll regardless; failure-only signal captures the win |

## Confirmed fixes (implementation specs)

### R2-1 — Retranscription options read the capability registry

`RetranscriptionEngineOption.producesWordTimestamps` still switches on
engine/Parakeet variant locally (`TranscriptionViewModel.swift:50-58`), and
option building owns engine ordering/availability/advisory/default-language
(`:495-576`) — the last shallow leak of the capability matrix. Fix: carry
`SpeechEngineCapabilities` on each retranscription choice and read
`providesWordTimestamps` from it. Keep model-download availability and
cold-start advisory in the view model — those are environment/UI policy, not
engine capability. Out of scope: `STTRuntime` lifecycle, scheduler, sidecar
behavior. Tests: `TranscriptionViewModelTests` driven by injected registry
capabilities; keep `SpeechEngineCapabilitiesTests`, `RetranscribeCommandTests`,
`TranscribeCommandTests` green.

### R2-2 — Capture-failure push signal (failure-only)

`failCapture(_:)` still notifies nothing (`MeetingRecordingService.swift:1088-1100`;
reachable from muted-buffer, writer-failure, interruption, and `.error` paths,
so the emitter must be idempotent), and the coordinator still synthesizes
`.captureFailed` from a 1 s sample (`MeetingRecordingFlowCoordinator.swift:1054-1073`).
Fix: add a lossless, per-session, generation-guarded capture-failure
notification to the service; consume it in the coordinator to send
`.captureFailed`; retire only the synthesized-failure poll branch. The poll
survives for levels/elapsed/mute/health and pause-divergence reconciliation.
Update the stale "150ms polling reconciler" comment and the state-machine
doc-comment that says polling emits `.captureFailed`. No transition stream, no
state-machine rewrite. ADR-014/019 stop-boundary and recovery semantics
unchanged. Tests: one failure signal → exactly one `.captureFailed` flow event;
duplicate failure calls; failure while paused; existing
`MeetingRecordingFlowCoordinatorTests` + `MeetingRecordingServiceTests` suites.

### R2-3 — AEC release gate verifies the default model SHA

`verify_meeting_echo_assets.sh` only checks SHA when
`MACPARAKEET_MEETING_ECHO_MODEL_SHA256` is set (`:4`, `:110`) and does not
source `meeting_echo_asset_defaults.sh` — while `docs/distribution.md:72-73,210`
promises checksum failure on the direct release gate and `sign_notarize.sh:167-170`
calls the verifier without SHA. History shows this gate has drifted before
(`619f075c1`, `78380a25b`, `0d5d6de5f`). Fix: source the defaults; when SHA env
is absent and the bundled basename is the default model name, verify against
`DEFAULT_MEETING_ECHO_MODEL_SHA256`; when required/strict assets use a
non-default model without SHA, fail loudly. Out of scope: Swift-side changes,
bundle-script rewrite, manifest formats. Tests: verifier cases for
default-name/no-env mismatch, default-name/env pass, custom-name/no-SHA fail
under `REQUIRE_MEETING_ECHO_ASSETS=1`; `bash -n` the dist scripts;
`MeetingEchoSuppressionRuntimeTests` green. Relevant to the 0.6.25 release gate.

### R2-4 — LLM HTTP provider adapters

`LLMClient` dispatches chat/streaming by provider, embeds native Ollama and
Anthropic implementations, and holds provider request/auth/model/sentinel rules
in one implementation (`LLMClient.swift:67,121,219,385,733,817,1016`), with 27
commits of churn since March. `LocalCLILLMClient` already proves the adapter
shape at the routing seam. Fix: split into an HTTP transport plus three
**character-identical** adapters (OpenAI-compatible, Anthropic, Ollama); move
only wire DTOs/request builders/parsers/sentinel policy. Preserve byte-for-byte
request semantics: URLs, headers, timeouts, body fields, model filters, stream
termination, cancellation. Out of scope: `LLMClientProtocol`, `RoutingLLMClient`,
`LLMService`, call sites, config models, MLX. Tests: golden request/header/body
tests per adapter; streaming sentinel EOF tests; `LLMClientTests`,
`RoutingLLMClientTests`, `LLMServiceTests` green.

Note (not this fix's scope): `plans/active/2026-06-27-on-device-local-llm.md`
proposes `.inProcessLocal` via a new `InProcessLLMClient`, which conflicts with
ADR-011's accepted "no bundled LLM runtime" stance — the ADR must be revised
deliberately when that plan is picked up.

### R2-5 — Hotkey conflict policy moves to Core (small version only)

Do **not** unify `HotkeyTrigger` and `KeyboardShortcut` — they are different
problems (canonical matching vs Transform persistence/display/parsing) with a
working bridge. The bug is policy locality: the pure collision checker lives in
the GUI target (`TransformsHotkeyRegistry.swift:240`), so `SettingsView`
repeats validation/message matrices (`SettingsView.swift:1471-1784`) and
`TransformEditorViewModel` needs a mirror protocol + adapter
(`TransformEditorViewModel.swift:210-230`,
`TransformsHotkeyRegistry+ViewModelAdapter.swift`). Spec-required behavior
(`spec/08-error-handling.md:57`, `spec/02-features.md:1772-1775`) is enforced in
three places. Fix: new Core module (e.g. `HotkeyConflictPolicy` +
`TransformShortcutCollisionChecker`) using existing `KeyboardShortcut.hotkeyTrigger`
and `TransformShortcutReservedHotkey`; move only pure collision
decisions/results/messages; delete the mirror protocol/enum and GUI adapter.
Out of scope: event taps, recorder behavior, side-specific modifiers,
persistence, migrations. Regression surface is user-facing (bare-modifier
dictation sharing, dead keys, F-key/Fn) — tests proportional:
Core policy tests for all conflict cases + `TransformsHotkeyRegistryTests`,
`TransformEditorViewModelTests`, `GlobalShortcutManagerTests`,
`HotkeyManagerTests`, `SettingsViewModelTests`.

## Sequencing

All five touch disjoint files and can proceed in parallel worktrees off
`origin/main`. R2-3 first (release-relevant, smallest). R2-2 conflicts with
nothing on `main` today but touches `MeetingRecordingService`, which has
in-flight work on a feature branch — rebase whichever lands second. R2-5 last
(largest regression surface). Full `swift test` once per PR as the final gate,
per repo policy.
