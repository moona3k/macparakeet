# Plan: MacParakeet multilingual support via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-27 (expanded from CLI-only to full multilingual: CLI + dictation + meeting recording, single PR)
> Targets: CLI 1.3.0, MacParakeet v0.7.0

---

## TL;DR

Add WhisperKit as a second STT engine across **all three MacParakeet surfaces**: CLI file transcription, GUI dictation, GUI meeting recording. Parakeet stays the default everywhere. One Settings toggle flips the GUI between engines; CLI takes a `--engine` flag per invocation.

**CLI usage:**
```
macparakeet-cli transcribe file.wav                                  # → Parakeet (default, fast)
macparakeet-cli transcribe file.wav --engine whisper                 # → WhisperKit (slower, 99 languages)
macparakeet-cli transcribe file.wav --engine whisper --language ko   # → WhisperKit forced to Korean
```

**GUI:** Settings → Speech Recognition → toggle Parakeet ↔ Whisper. Affects dictation hotkey + meeting recording transcription.

**Single PR.** Integration cost is small once `WhisperEngine` exists — same engine wrapper used by all three surfaces. Doing it all together delivers "MacParakeet supports Korean" as one coherent ship moment, instead of a half-shipped state where CLI works but GUI doesn't.

**Primary user:** Daniel consumes Korean content (YouTube videos, podcasts, meetings). Wants every MacParakeet surface to handle Korean — transcribe Korean videos via CLI, dictate Korean via hotkey, record Korean meetings. WhisperKit's broader multilingual coverage (Vietnamese, Thai, Hindi, Arabic, 95+ others) is a free side-benefit of the same code paths.

**No auto-routing, no abstraction layers, no protocol/registry.** Two engines, switch-statement dispatch.

## Implementation review amendments (2026-04-27)

- Verified WhisperKit from `argmaxinc/argmax-oss-swift` tag `v0.18.0`. The
  original implementation used `v0.9.4`, but CI's Xcode 16.1/Swift 6 release
  build rejected its pinned `swift-transformers` `0.1.8` dependency for strict
  Sendable diagnostics. `v0.18.0` keeps the `WhisperKit` product/API surface we
  use while resolving newer `swift-transformers` 1.x.
- `WhisperKit.WordTiming` in `v0.18.0` exposes `probability` (0...1), not
  `logprob`; MacParakeet still must convert seconds to milliseconds.
- CLI `--engine` is intentionally per-invocation. It must not mutate the GUI
  speech engine preference.
- Meeting recording needs both protections: the Settings toggle is blocked
  while a live meeting session owns an engine lease, and final transcription
  routes through the engine/language captured at recording start from meeting
  metadata/lock-file state.
- The explicit `WhisperKit` product reference remains important, but the
  resolved transitive set now includes newer Hugging Face support packages from
  the `swift-transformers` 1.x line.

## Implementation status (2026-04-27)

- Implemented on branch `feature/multilingual-whisperkit` in the worktree
  `/Users/dmoon/code/macparakeet-multilingual-whisperkit`.
- Covered: WhisperKit dependency, `WhisperEngine`, optional detected language,
  CLI `--engine`/`--language`, Whisper model download/clear hooks, Settings
  speech-engine toggle and model download gate, runtime engine switching,
  scheduler busy/lease guards, meeting engine capture in metadata/lock files,
  meeting retranscription routing, dictation processing/busy affordance,
  docs/license/traceability updates, and focused tests for these paths.
- Manual Korean YouTube validation completed with Whisper large-v3 turbo on
  `hXHghhR8Yps` (KBS News): output language `ko`, Korean transcript text,
  `durationMs` 42200, and zero inverted word timestamp ranges in persisted JSON.
- The current meeting implementation captures the active GUI engine plus the
  global Whisper default language at recording start; a separate per-meeting
  language picker is still a product/UI follow-up.
- `macparakeet-cli --version --verbose` attribution output is not implemented;
  attribution is captured in `THIRD_PARTY_LICENSES.md` and CLI docs for this
  pass.
- PR review follow-up upgraded WhisperKit from `v0.9.4` to `v0.18.0` to clear
  CI release-build failures in transitive `swift-transformers` Swift 6
  diagnostics.
- PR review follow-up also resolves `swift-argument-parser` to `1.7.1`, because
  the previous lockfile's `1.3.0` is not Swift 6 language-mode clean.
- The CI Swift 6 language-mode step sets `MACPARAKEET_SKIP_WHISPERKIT=1` and
  uses an isolated build path. Release, warn-concurrency, and test steps still
  compile the real WhisperKit dependency graph; only the first-party Swift 6
  compile check omits Argmax because latest `v0.18.0` is not Swift 6
  language-mode clean.

---

## Language coverage (user-facing doc copy)

Parakeet TDT v3 is the high-quality default for languages it supports. Whisper is the escape hatch for everything else.

**Important runtime nuance (verified against FluidAudio 0.14.1 source):** `TokenLanguageFilter`'s `Language` enum has no CJK entries — only Latin/Cyrillic, 21 cases. So `--language` is a no-op for any non-Latin/Cyrillic target with `--engine parakeet`. We silently don't pass the hint to Parakeet in those cases (no error, no warning).

| If your audio is… | Use | Notes |
|---|---|---|
| English or one of the 25 European languages Parakeet supports | **Parakeet (default)** | Fastest, highest quality on Apple Silicon. |
| Japanese or Mandarin | **Parakeet** first; switch to Whisper if quality isn't adequate | Parakeet's `tdtJa`/`tdtZh` decode paths handle these. `--language` is ignored (auto-detect). |
| Korean, or any other language | **Whisper** | Whisper supports 99 languages. |

No quantitative WER claims. User picks.

---

## What we're building

### Shared core (used by all three surfaces)

- **`Sources/MacParakeetCore/STT/WhisperEngine.swift`** — actor wrapping `WhisperKit`. **Owns its own load lifecycle** — stored `WhisperKit?` property + `var isLoaded: Bool` guard inside the actor. One static factory `WhisperEngine.make(model:)`, one method `transcribe(audioURL:language:onProgress:) -> STTResult`. Conditionally compiled `#if canImport(WhisperKit)`. `STTRuntime` calls `whisperEngine.transcribe(...)` and the engine self-manages — no lifecycle state in `STTRuntime`.
- **`Sources/MacParakeetCore/SpeechEnginePreference.swift`** — small enum `{ parakeet, whisper }` + UserDefaults persistence + default-language pref. **Place at `MacParakeetCore` root** alongside existing `AppPreferences`, `AppRuntimePreferences`, `CalendarAutoStartPreferences` — don't create a `Settings/` subdirectory for one enum.
- **`Sources/MacParakeetCore/STT/STTResult.swift`** — **add `language: String?` field** (additive, optional). `WhisperEngine` populates with detected language; `ParakeetProvider`-equivalent path leaves it nil. Surfaces in CLI's `--json` output as a top-level optional field. Avoids a v0.8 breaking schema change to expose Whisper's language detection later.
- **`Package.swift`** — add `argmaxinc/argmax-oss-swift` dep. **Important:** explicit product reference `.product(name: "WhisperKit", package: "argmax-oss-swift")`. In verified `v0.18.0`, this pulls `WhisperKit` plus its `swift-transformers` dependency line.

### CLI (file transcription)

- **Modify `Sources/CLI/Commands/TranscribeCommand.swift`:** add `--engine [parakeet|whisper]` flag (default parakeet) + `--language <bcp47>`. Switch on engine: parakeet → existing `STTClient` path; whisper → `WhisperEngine`.
- **Modify `Sources/CLI/Commands/ModelsCommand.swift`:** extend `models download <variant>` to recognize `whisper-*` identifiers. For whisper-*, call `WhisperKit.download(variant:progressCallback:)`. Storage at `~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/`.
- **Help text + CHANGELOG entry.**

### GUI dictation

- **Modify `Sources/MacParakeetCore/STT/STTRuntime.swift`:** `STTRuntime.transcribe()` is the single entry point for *all* job kinds (dictation + meeting + file). The engine switch must happen **inside `transcribe()`**, before `ensureInitialized()` (which today is hard-coded to allocate Parakeet's ANE slot). Read `SpeechEnginePreference` first, branch dispatch: parakeet → existing path; whisper → `WhisperEngine`. **Patching only upstream call sites would silently leave meeting recording on Parakeet.**
- **Dictation overlay** (`DictationOverlayView` + `DictationOverlayViewModel`): **reuse the existing `.processing` overlay state** — don't add a new `.transcribing` enum case (would touch state machine + computed properties + exhaustive switches for marginal benefit). Add a Whisper-aware label ("Transcribing…" or similar) that reads from the active engine — visible during `.processing` only when engine is Whisper, so users see distinct affordance during the 2-5s wait. Add a separate **`.loadingModel` overlay state** for the cold-start prewarm path ("Loading Whisper model…") so the 5-15s first-use latency doesn't look like a hung app.
- **Settings UI (below):** the toggle gates this entire path.

### GUI meeting recording

- **Capture engine preference at recording START, not at transcription time.** Store the engine ID (and chosen language, see below) in meeting metadata when the recording begins. Post-recording transcription dispatches to the engine that was active when the user started — not the engine they may have toggled to in the meantime. (Reviewer caught this as action-at-a-distance: user toggles to Whisper for a quick dictation mid-meeting, the entire meeting batch then unexpectedly runs through Whisper.)
- **Per-meeting language override** (small UI affordance in the meeting recording panel): optional language picker at recording start, defaults to global Whisper default-language pref, overridable per session **without mutating the global setting**. Korean meeting today doesn't force user to flip global setting and remember to revert.
- Audio capture is engine-agnostic — the engine choice only affects post-recording transcription dispatch.
- Meeting transcription is async/batch — Whisper's latency doesn't matter here.

### Engine switch lifecycle (load-bearing — multi-reviewer convergent finding)

The plan's earlier "toggle in Settings, lazy-load on first use" framing handwaved over four implementation gaps that all four reviewers surfaced from different angles. Locking in the actual switch contract:

**Settings toggle invokes a new method on `STTClientProtocol` / `STTRuntime`:**

```swift
func setSpeechEngine(_ preference: SpeechEnginePreference) async throws
```

The implementation:

1. **Refuse to switch if a transcription is in flight** (returns `STTError.engineBusy`). The Settings UI surfaces this — disables the toggle while in-flight, or queues the switch to apply after current job completes. **Toggle is a "between-sessions" change**; the runtime enforces it, not just docs.

2. **Cancel `backgroundWarmUpTask`** if pending; explicitly reset state via `setBackgroundWarmUpState(.idle)`. Without this, `backgroundWarmUp()`'s early-return-on-`.ready` guard leaves the new engine permanently unable to warm up.

3. **Attempt the new engine's `prepare()` BEFORE unloading the previous engine.** If Whisper specialization fails (ANE busy, CoreML compile error, disk full), Parakeet stays loaded, the toggle reverts to `.parakeet`, and the UI surfaces a clear error. The plan's earlier "unload Parakeet, then load Whisper" sequence had a failure mode where both engines end up uninitialized — user presses hotkey, gets `modelNotLoaded`. This sequence prevents that.

4. **After successful new-engine prepare, unload the previous engine** (via existing `AsrManager.shutdown()` for Parakeet, or `WhisperEngine.unload()` for Whisper). Persist the new pref to UserDefaults.

**Hotkey re-entry during Whisper transcribe:** Whisper's 4-8s post-stop window is much longer than Parakeet's sub-second. The existing `DictationService` re-entry guard silently drops a second hotkey press during `.processing`. Either (a) surface a "busy, try again" affordance via brief overlay flash, or (b) queue the second press to start after current transcription completes. Pick (a) for v1 — simpler, matches existing dictation semantics.

**First-toggle download path:** If the user toggles to Whisper without the model downloaded, **the toggle must surface this state immediately** — don't lazy-trigger a 632 MB download on first hotkey press (would block dictation indefinitely with no progress UI). Settings shows "Whisper model: Not downloaded [Download (632 MB)]" inline. Toggle activation is gated on download completion (or user explicitly defers). Force-quit during download → next launch detects partial state via `.partial` suffix and resumes or cleans up.

### Settings UI

New section in `Sources/MacParakeet/Views/Settings/...`:

```
Speech Recognition
──────────────────
●  Parakeet (default)   Fast. English + 25 European languages + Japanese + Mandarin.
○  Whisper              Slower. 99 languages including Korean.
                        Model: Not downloaded  [Download (632 MB)]
                                — or after install —
                        Model: Ready

  When using Whisper:
  • Dictation has a 2-5 second delay (vs Parakeet's near-instant response)
  • First use after switching takes ~5-15s while the model specializes for ANE
  • Meeting recording asks per-meeting language; overrides this default

Default language for Whisper:  [ Auto-detect ▼ ]   (only used with Whisper)
```

Behavior:
- Whisper radio is **disabled** until the model is downloaded (or user clicks Download). Otherwise users could toggle to a non-functional engine and dictate into the void.
- Download surfaces a progress bar inline; cancel reverts state.
- **`In-flight transcription disables the toggle`** — UI reflects the runtime's `engineBusy` semantics. Tooltip: "Finishing current dictation/meeting transcription before switching."
- Meeting recording panel surfaces a per-session language picker (not in Settings; in the meeting start UI). Defaults to this `Default language` pref but doesn't mutate global state when overridden.

~80 lines of SwiftUI total (Settings + meeting recording panel addition).

---

## What we're NOT doing

- **Per-surface toggles** (separate Whisper-for-dictation vs Whisper-for-meeting). One toggle covers GUI surfaces. If users ask for split control later, add it.
- **Auto-detection / `--engine auto`.** Speculative product complexity. v0.8+ if demand surfaces.
- **Streaming WhisperKit (`--stream`).** v0.8+
- **WhisperKit translation mode (`--task translate`).** Defer.
- **Mid-session engine switching.** Toggle is a Settings change between sessions; not changeable mid-recording or mid-dictation.
- **Cross-process ANE coordination.** macOS daemon mediates; many CoreML apps coexist in production without locks. Add ~50 lines of `flock` only if real crashes appear post-ship.
- **`STTProvider` protocol + registry.** Two engines, switch-statement dispatch. Add abstraction when a third engine arrives.
- **`models verify --sha256`.** WhisperKit handles its own integrity. Defer.
- **Disk preflight, retry/backoff, per-variant locks.** Defensive engineering for unobserved risks. Add if we see operational pain.
- **`STTTranscription` wrapper / `--include-metadata` flag.** v0.7 ships byte-identical v1.2 JSON envelope.
- **Telemetry allowlist coordination.** Existing `cliOperation` event is sufficient. Add new events only when we have specific reason.

---

## Implementation notes (things to know during coding, not as gating spikes)

- **WhisperKit Sendable / @MainActor.** WhisperKit 1.x has had `@MainActor`-bound progress callbacks. Verify on the version we pin; if hops to MainActor deadlock the CLI (no `NSApplication` run loop), wrap calls in `Task { @MainActor in ... }`. The GUI doesn't have this concern.
- **WhisperKit word-timing schema mismatch (Codex op finding).** `WhisperKit.WordTiming` in verified `v0.18.0` has `start`/`end` in **seconds (Float)** + `probability` (0...1). MacParakeet's `STTResult.words` is `startMs`/`endMs` (Int milliseconds) + `confidence` 0-1. The `WhisperEngine` mapping must explicitly convert seconds → ms (×1000) and clamp probability to confidence. Without conversion, `MeetingTranscriptFinalizer.shiftedWords()` produces garbage segment boundaries — a 5-second dictation reports as 5ms. **Add a unit test asserting the schema before wiring meeting transcription.**
- **Audio normalization is already done.** `Sources/CLI/AudioFileConverter.swift` produces 16 kHz mono Float32 WAV. Both engines receive the converted file URL. FFmpeg runs once.
- **Whisper load failure must not strand the user.** Order of operations on engine switch: `prepare(.whisper)` → on success, unload Parakeet → persist pref. If Whisper prepare fails, **revert the toggle to `.parakeet`**, leave Parakeet loaded, surface a clear error to the user. Never end up in a both-uninitialized state.
- **WhisperKit issue #300:** `loadModels()` duplicates `.bundle` files in memory each call. Reuse the `WhisperKit` instance within a `WhisperEngine` actor — don't re-init across multiple dictation calls.
- **JSON envelope contract:** existing v1.2 in `Sources/CLI/CHANGELOG.md` is flat `{ ok, error, errorType }`. v1.3.0 adds the optional top-level `language` field on success responses (additive), driven by `STTResult.language`. `--engine` support adds no envelope shape change.
- **In-process double-load:** the GUI loads only one engine at a time (toggle determines which). The CLI loads only one per invocation. Never both simultaneously. So we don't need an in-process semaphore.
- **WhisperKit SPM placement.** Putting `WhisperEngine` in `MacParakeetCore` makes WhisperKit a transitive dep of CLI + GUI + Tests. Even with `#if canImport`, SPM resolve fetches the package. If clean-build / CI time becomes annoying, isolate `WhisperEngine` in a thin `MacParakeetWhisper` target that only the GUI app and CLI link directly. **Default: keep in `MacParakeetCore` for simplicity; revisit if build time hurts.**
- **Cross-process (GUI + CLI both running):** macOS daemon mediates ANE access. Memory is fine — Parakeet ~66 MB ANE working set + WhisperKit large-v3-turbo ~600 MB working set, in separate process address spaces.

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| WhisperKit `@MainActor` deadlock in headless CLI | Possible (version-dependent) | High (CLI hangs) | Verify during impl; `Task { @MainActor in ... }` wrapper if needed |
| `argmax-oss-swift` manifest changes transitive dependencies | Possible | Low (binary bloat / resolve churn) | Pin exact tag and use explicit `.product(name: "WhisperKit", ...)`; `v0.18.0` adds newer Hugging Face support packages through `swift-transformers` |
| Argmax latest is not Swift 6 language-mode clean | Real | Medium (CI strict check fails on upstream code) | Keep full release/test builds on WhisperKit; omit WhisperKit only from CI's first-party Swift 6 build via `MACPARAKEET_SKIP_WHISPERKIT=1` |
| Korean transcription quality unusable in practice | Low (Whisper is well-validated on Korean) | High (kills the load-bearing use case) | Daniel sniff-tests on real Korean content during dev; reversal triggers below |
| Dictation latency on Whisper is unacceptable | Real (2-5 sec is slow) | Low (users self-select via toggle, copy sets expectation) | Settings copy clearly states the trade-off |
| Engine swap fails partway → user stranded with no engine | Possible (Whisper prepare fails for unrelated reasons) | High | Prepare new engine BEFORE unloading previous; revert pref on failure |
| Hotkey re-entry during Whisper transcribe silently dropped (Codex op) | Real (Whisper 4-8s window vs Parakeet sub-second) | Medium | Surface "busy, try again" affordance via overlay flash; existing re-entry guard not sufficient |
| WhisperKit word timing in seconds vs `STTResult.words` in milliseconds | Real | High (meeting diarization produces garbage if not converted) | Explicit unit conversion in `WhisperEngine` mapping; fixture-driven unit test |
| `STTRuntime.ensureInitialized()` hard-coded to Parakeet pre-allocation | Real | High (toggle to Whisper still loads Parakeet on ANE first) | Read pref above `ensureInitialized()`; branch dispatch before |
| First-toggle without download blocks dictation indefinitely | Real | Medium | Settings shows download status inline; toggle disabled until model present |
| Toggle during in-flight transcription corrupts state | Possible | Medium | `setSpeechEngine` returns `engineBusy` if job in flight; UI disables toggle accordingly |
| Meeting engine captured at wrong time (transcription vs recording) | Real | Medium (action-at-a-distance) | Capture engine + language pref at recording **start**, store in meeting metadata |
| `backgroundWarmUpState` stuck at `.ready` after switch | Real (early-return guard) | Medium (new engine fails to warm) | Engine switch path explicitly resets to `.idle` |
| CLI invocation while GUI is active triggers ANE collision | Theoretical, no observed instances on macOS | High if real | Ship without lock; `flock` fast-follow if telemetry shows crashes |

---

## Reversal triggers (when to reconsider engine choice)

Revisit WhisperKit if:

1. **Argmax ships Qwen3-ASR (or equivalent)** in WhisperKit. Verifiable from their releases.
2. **`mlx-qwen3-asr` reaches agent-grade quality** — tagged release, green CI on macOS 14+, zero open P0 for ≥30 days, ≥50 external transcribe operations without crash, mature Swift wrapper.
3. **Field signal:** ≥3 distinct users report "WhisperKit Chinese (or other CJK) output is unusable for my use case."
4. **Quality benchmark:** Qwen3-ASR achieves ≥10% relative CER improvement on our own Mandarin/Japanese/Korean corpus.
5. **Apple ships native multilingual ASR** with WER ≤10% relative penalty vs Whisper-large-v3 on FLEURS-30.

When any trigger fires, integrate as a third engine — don't replace WhisperKit.

---

## License inventory (verified 2026-04-27)

| Component | License | GPL-3.0 compatibility |
|---|---|---|
| `argmaxinc/argmax-oss-swift` (WhisperKit) | MIT | ✅ |
| WhisperKit transitive Swift support deps (`swift-transformers`, `swift-jinja`, Swift Crypto/ASN.1/Collections, yyjson) | Apache 2.0 / MIT | ✅ |
| `FluidInference/FluidAudio` (existing) | Apache 2.0 | ✅ |
| OpenAI Whisper model weights | MIT | ✅ |
| NVIDIA Parakeet TDT v3 weights | CC-BY-4.0 | ✅ (attribution-only) |

**Deliverable:** add `THIRD_PARTY_LICENSES.md` at repo root. `--version --verbose` mentions Parakeet (CC-BY-4.0) and Whisper via WhisperKit (MIT) to satisfy CC-BY attribution.

---

## Implementation order (within the single PR)

Not phases-with-gates — just a suggested order for the implementing engineer:

1. **Add WhisperKit dep** to `Package.swift` with explicit product reference (`.product(name: "WhisperKit", package: "argmax-oss-swift")`).
2. **Add `STTResult.language: String?`** field. Additive, optional, populated only by Whisper path.
3. **Implement `WhisperEngine.swift`** in `MacParakeetCore`. Actor owns its own `WhisperKit?` + `isLoaded` guard. Static `make(model:)` factory. `transcribe(audioURL:language:onProgress:) -> STTResult`. **Word-timing schema conversion: seconds × 1000 → ms; `probability` clamped → confidence.** Add a fixture-driven unit test asserting the schema before wiring to anything else.
4. **Add CLI surface** — `--engine` flag, `--language` flag, `models download whisper-*`. CLI is the easiest validation surface.
5. **Daniel sniff-tests Korean content via CLI.** Run `macparakeet-cli transcribe <korean.mp3> --engine whisper --language ko`. **Load-bearing decision point** — if Korean output is unusable, the rest of the PR is wasted; reversal triggers fire.
6. **Add `SpeechEnginePreference`** at `MacParakeetCore` root (alongside `AppPreferences`). UserDefaults persistence.
7. **Add `setSpeechEngine(_:) async throws` to `STTClientProtocol` / `STTRuntime`.** Implementation: refuse if in-flight; cancel `backgroundWarmUpTask`; reset `backgroundWarmUpState` to `.idle`; **`prepare(new)` BEFORE `shutdown(old)`**; revert pref on prepare failure. This is the load-bearing lifecycle work — multi-reviewer convergent finding.
8. **Wire `STTRuntime.transcribe()` to read pref before `ensureInitialized()`** and branch dispatch by engine for **all `STTJobKind`s** (dictation + meeting + file). Single entry point — patching only upstream call sites would silently leave meeting recording on Parakeet.
9. **Settings UI** — toggle + Whisper download status inline + language picker + latency copy. Toggle disabled until model present and during in-flight jobs.
10. **Dictation overlay** — reuse `.processing` state with Whisper-aware label ("Transcribing…"); add `.loadingModel` substate for cold-start prewarm ("Loading Whisper model…"). Hotkey re-entry during Whisper window: brief "busy" overlay flash.
11. **Meeting recording** — capture engine ID + language at recording start, store in meeting metadata; transcription dispatches from metadata. Per-session language picker on the recording panel (defaults to global, overridable without mutating global).
12. **CHANGELOG, integrations docs, THIRD_PARTY_LICENSES.** Note new top-level `language` field in JSON envelope.
13. **Tests** — engine routing, toggle persistence, lifecycle (refuse on in-flight, prepare-before-unload, fallback on Whisper fail, state reset), word-timing schema fixture, Korean sniff test on a known-good fixture, meeting metadata captures engine at start.

Total estimate: ~7-10 days of focused work for a senior engineer (revised up from ~5-7 after reviewer findings folded in — the engine-switch lifecycle is real work).

---

## Success signals

The honest validation:
1. **Daniel transcribes Korean YouTube content via CLI** — output is good enough to read.
2. **Daniel dictates Korean text** via the GUI hotkey — text appears, accepts the latency.
3. **Daniel records a Korean meeting** and the post-recording transcription is usable.

If all three work for Daniel on real Korean content, the feature ships and is a success regardless of broader uptake.

Secondary signals (4–8 weeks post-ship, gravy):
- Non-zero opt-in usage of Whisper toggle / CLI flag — proves the option is reachable for users beyond Daniel
- ≤1 P0 issue on the Whisper path in first month
- Anyone publishing a "MacParakeet for Korean (or other) transcription" writeup

Bad ship: Korean output is unusable in practice → reversal triggers fire toward Qwen3-ASR.

---

## References

### Internal
- `Sources/CLI/CHANGELOG.md` — v1.2 envelope contract (do not break)
- `plans/active/cli-as-canonical-parakeet-surface.md` — broader CLI positioning
- `Sources/CLI/AudioFileConverter.swift` — produces 16 kHz mono Float32 WAV (used by both engines)
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — current Parakeet-only dispatch; gets a toggle-based switch in this PR

### External
- `argmaxinc/argmax-oss-swift` — WhisperKit, pinned product at meta-package level
- FluidAudio 0.14.1 — `TokenLanguageFilter.swift` `Language` enum (Latin/Cyrillic only); `AsrManager.swift` `tdtJa`/`tdtZh` paths
- VoiceInk, Hex, Dictus — shipping examples of dual Parakeet + WhisperKit (single-process GUI architectures; informed our switch-statement-not-protocol decision)

### Multi-LLM review pass 1 (2026-04-27, initial CLI-only scope, 774-line draft)
3 Gemini + 3 Codex. Findings folded in:
- **FluidAudio CJK enum gap** (Codex 3) → language coverage table
- **JSON envelope contract preservation** (Gemini 3) → no breaking shape change
- **Cross-process ANE collision** (Gemini 1+2) → rejected after self-audit; was extrapolation from iOS to macOS without observed evidence
- **Operational discipline (retries, preflight, locks, telemetry coordination)** (Codex 1+2) → deferred as defensive engineering for unobserved risks

### Multi-LLM review pass 2 (2026-04-27, single-PR all-surfaces scope, 222-line draft)
2 Gemini + 2 Codex. All HIGH/MEDIUM findings folded in via the `Engine switch lifecycle` section, `STTResult.language` field addition, dictation overlay `.processing` reuse with Whisper-aware label, `.loadingModel` substate, meeting engine pinned at recording start, per-session language override, Settings download status indicator. Specific source-grounded catches:
- **Codex Swift:** `STTRuntime.transcribe()` is a single entry point — switch happens there, not at upstream call sites; `SettingsViewModel` needs a new `setSpeechEngine` API surface; `backgroundWarmUpState` `.ready` early-return needs reset on switch; reuse `.processing` overlay state, don't add `.transcribing`
- **Codex operational:** WhisperKit `WordTiming` is in seconds + probability, not ms + MacParakeet word records — explicit conversion required; engine-swap failure must not strand user; first-toggle 632 MB download must surface in Settings, not block dictation; hotkey re-entry during 4-8s Whisper window needs visual affordance
- **Gemini architecture:** `ensureInitialized()` is hard-coded to Parakeet — pref read must happen above it; `STTResult.language` field is a cheap additive change avoiding v0.8 breaking schema; `WhisperEngine` actor owns its own load lifecycle; `SpeechEnginePreference` lives at `MacParakeetCore` root, not in a `Settings/` subdirectory
- **Gemini UX:** spinner without label looks like crash → reuse `.processing` but add Whisper-aware copy; no `.loadingModel` state for prewarm → add one; meeting engine captured at transcription time is action-at-a-distance → capture at recording start; per-meeting language override missing; download state must surface at toggle point

Strategy unchallenged in either pass: zero reviewers questioned Parakeet-default + Whisper-opt-in, WhisperKit-over-Qwen3, or single-PR scope.
