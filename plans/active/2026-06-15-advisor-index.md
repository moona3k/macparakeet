# Advisor Audit Index — 2026-06-15 (architecture & maintainability)

Advisor (`/improve`) run at `main` HEAD `16e3f865f`. Scope was **architecture,
structure, abstractions, and maintainability** — not a correctness/security/perf
pass (the 2026-06-09 two-pass audit and the 2026-06-12 advisor run cleared that
surface; their verdicts stand and were not re-litigated).

Six read-only audit agents fanned out over: god-object services, the App-layer
coordinator/DI composition root, cross-cutting coupling & layering, abstraction
quality & duplication, the View/ViewModel layer, and test architecture/DX. Every
finding that reached the table below was re-opened and confirmed by direct reads.

## Headline: the architecture is sound; the debt is concentrated, not systemic

Verified strengths (credit where due): clean 4-target graph with no reverse deps
(`Core ← ViewModels ← GUI`, `CLI ← Core`); no circular dependencies among the
nine `Services/` subfolders; **100% uniform** `@MainActor @Observable` state
management (zero legacy `ObservableObject`/`@Published`); justified protocol/DI
discipline (~60 protocols, nearly all with a real second impl — premature
abstraction was specifically hunted and not found); the riskiest flow logic is
already extracted to tested Core state machines; only 4 true singletons (Telemetry
is an injectable facade). `DatabaseManager` looks huge but is 77% an append-only
migration ledger — correctly so.

The real debt is concentrated in three places where growth outran the original
seams: **Settings** (a stalled, documented VM/view split that is actively
doubling), the **three capture modes** (duplicated AI-formatter + post-processing
orchestration that has already drifted), and the **cross-cutting LLM layer**
(provider switch-soup + copy-pasted operation scaffolding). Plus a missing DX
safety net (no formatter/lint/`.editorconfig`).

Baseline `swift test` was not re-run this session (read-only audit); CI runs the
full suite on every push and the Jun-12 run recorded green.

## Plans spawned (this run)

| Plan | Title | Priority | Effort | Risk | Status |
|------|-------|----------|--------|------|--------|
| [2026-06-15-dx-format-lint-baseline](2026-06-15-dx-format-lint-baseline.md) | swift-format + .editorconfig + dev scripts + informational CI | P2 | S | LOW | TODO |
| [2026-06-15-settings-observer-fanout-collapse](2026-06-15-settings-observer-fanout-collapse.md) | Table-driven AppSettingsObserverCoordinator | P2 | S | LOW | TODO |
| [2026-06-15-settings-engine-characterization-tests](2026-06-15-settings-engine-characterization-tests.md) | Characterize the Settings engine/model surface | P2 | M | LOW | TODO |
| [2026-06-15-settings-engine-viewmodel-extraction](2026-06-15-settings-engine-viewmodel-extraction.md) | Extract EngineSettingsViewModel (extract-and-delegate) | P2 | L | MED | TODO (depends on the char-tests) |
| [2026-06-15-transcript-formatter-dedup](2026-06-15-transcript-formatter-dedup.md) | Shared TranscriptFormatter (kill the dup AI-formatter path) | P2 | M | MED | TODO |

Recommended order by leverage/dependency:
1. **DX baseline** (S, LOW, protective — defuses the documented CRLF-flip pitfall, gives agents a fast loop).
2. **Settings observer fan-out collapse** (S, LOW, behavior-identical enabler).
3. **Settings engine characterization tests** → **EngineSettingsViewModel extraction** (the extraction is HARD-gated on the test net).
4. **TranscriptFormatter dedup** (independent; biggest service-layer tax).

These map to the three improvement clusters the maintainer selected on 2026-06-15:
DX safety net (#1), Settings decomposition (#3→#2), three-modes dedup (#4). The
"LLM layer seams" cluster was reviewed but deliberately **not** turned into plans.

## Reconciliation (existing plans)

- **`2026-04-settings-ia-overhaul.md` (PARTIAL):** its open remainder is the
  `SettingsView`/`SettingsViewModel` god-file decomposition, which both that plan
  and the 2026-06-12 index deferred as "high-risk, no test net." This run
  **supersedes the Engine portion** of that remainder with two executable,
  test-first plans (characterization tests → extract-and-delegate). The IA plan's
  §3 design (sub-VM list, conventions) is the reference the extraction follows; its
  Engine row should be marked done when the extraction lands. The other slices
  (Capture/Dictation/Transcription/Meeting/System) remain that plan's to track.
- No other active plan overlaps. The architecture scope is orthogonal to the
  open feature/test plans (onboarding, meeting auto-stop, telemetry guard, etc.).

## Findings reviewed but NOT turned into plans (this run)

Real, confirmed, and worth doing later — left out because the maintainer scoped
this round to three clusters, or because they need a characterization-test net
first. Recorded so they aren't re-mined from scratch.

1. **LLM layer seams (deferred cluster):**
   - `LLMClient.swift` (~1,388 lines) hard-branches on the 8-provider enum across
     ~10 sites (request/auth/stream-sentinel/model-filter); adding a provider is a
     shotgun edit. Fix = a `LLMProviderStrategy`/adapter protocol (OpenAI-compat /
     Anthropic / Ollama). L, MED, clean fixture-test story.
   - `LLMService.swift` (~1,216 lines) repeats ~60–95 lines of operationID/context-
     load/telemetry scaffolding across 4 "detailed" + 3 streaming methods (~40% of
     the file). Fix = a generic `LLMOperationRunner`. M, LOW-MED — the cheapest pure
     refactor on the whole list; good warm-up before the adapter work.
2. **STT runtime (ADR-016 constrained):** `STTRuntime.swift` (~1,651 lines) mixes
   per-engine lifecycle, the live-dictation session state machine, warm-up, and a
   `nonisolated static` model-file CLI surface; engines bypass the existing
   `STTTranscribing` seam (26 `case .parakeet/.nemotron/.whisper`; Parakeet isn't
   behind the seam at all). The concrete actor has **no behavioral tests** (only the
   scheduler is tested, via `MockSTTRuntime`). Safe first moves: extract the
   `nonisolated static` model-file ops into an `STTModelStore` (zero actor-state
   risk); add a model-loader seam + characterization tests **before** any engine
   re-routing. M-L, MED-HIGH. Do NOT split the single runtime owner (ADR-016).
3. **Other god-object services:** `DictationService` (24-dep init, 3 parallel
   transcription paths, ad-hoc reentrancy snapshots), `AudioRecorder` (33 stored
   fields, ~320-line `start()` — extract pure downmix/ring-buffer/diagnostics
   utilities first, LOW risk), `MeetingRecordingService` (pause/mute/metering
   host-time state → value-type collaborators). All L, MED→HIGH; the cross-cutting
   ROI pattern is "extract the actor-trapped pure logic into testable value types
   first."
4. **App-layer:** the two flow coordinators duplicate the effect-executor scaffold +
   generation-guarded-Task idiom; auto-stop/pause-reconcile decisions are trapped in
   GUI polling loops with no pure-function test seam (extract a `SilenceAutoStopEvaluator`
   / `MeetingPillReconciler` to Core). `AppEnvironment` is a 68-property locator with
   a side-effecting `init` (telemetry/backfill/yt-dlp-update/crash-send) — move the 4
   side effects to an explicit `activate()`. `MenuBarCoordinator` is the lone
   service-locator consumer (`environmentProvider`) — replace with its 3 real deps
   (S, LOW).
5. **Smaller, clean (S, LOW):** settings persistence is spread across 219
   `UserDefaults` sites / 4 uncoordinated owners (read defaults in Core enums vs
   write defaults in VMs can drift — consolidate into one `SettingsStore`); update
   the stale Core-AppKit adapter charter (CLAUDE.md says 4 adapters, reality is 7 —
   add an allowlist test); drop spurious `import SwiftUI` from ViewModels + the
   `Binding<String>` leak in `MeetingNotesViewModel`; consolidate the 11 hand-rolled
   `waitUntil` test pollers and fix the documented flaky test with an injectable
   clock; decompose the `SettingsView` (3,467) / `TranscriptResultView` (3,112) view
   god-structs into per-section files (the latter's panes are already VM-backed).

## Findings considered and rejected (do not re-audit)

- **`DatabaseManager` is a god object** — rejected. 77% is an append-only migration
  ledger the subsystem README forbids editing after release; "splitting" it would
  break the schema source-of-truth and risk field-data corruption for zero
  testability gain. Leave it.
- **Premature abstraction / single-impl protocols** — rejected. The suspects
  (`STTRuntimeProtocol`, `ProcessAliveChecking`, `MeetingArtifactStoring`,
  `AppRuntimePreferencesProtocol`) each have a real mock/alt impl; unprotocoled
  types are leaf utilities where a protocol would be ceremony.
- **Singletons undermine DI** — rejected. Only 4 true `static let shared` in Core,
  all benign; the "41 `.shared`" count is overwhelmingly `URLSession.shared` /
  `NSWorkspace.shared`. `Telemetry` is an injectable facade (`configure` + protocol
  + `NoOpTelemetryService`).
- **`Utilities/`/`Extensions/` are junk drawers** — rejected. Cohesive, narrowly
  named single-purpose files; no high-fan-in catch-all.
- **Core leaks UI** — rejected as a *bug* (it's a doc-staleness item only): the 3
  "extra" AppKit imports in Core are Transforms system-query adapters
  (`SelectionReplacementService`, `SelectionCaptureService`, `FocusedAppContextService`),
  charter-consistent (no UI ownership) but undocumented → folded into the
  adapter-charter cleanup above.
- **Models carry behavior/persistence** — rejected. `Dictation`/`Transcription` are
  zero-method value types; GRDB conformances are isolated in trailing extensions.

## Coverage notes

- Audited: all four targets' structure; the 10 largest source files by line count;
  the App/ coordinator + DI layer; Services subfolder coupling; the View/VM layer;
  test architecture + DX tooling. Confirmed by direct reads of the cited code.
- Not covered (out of architecture scope): correctness/security/perf of the June
  churn (covered by prior audits), runtime-only behavior, and the CLI command tree's
  internal structure.
