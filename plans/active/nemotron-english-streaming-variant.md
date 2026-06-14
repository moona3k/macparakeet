# Nemotron Speech Streaming EN 0.6B as a first-class engine variant

> Status: **SHIPPED** (2026-06-14) — merged as #503; `nemotron-english-1120ms`
> (English-only, ~600 MB, opt-in Beta) is selectable in Settings/CLI. The
> branch also gained live dictation partials on
> `nemotron-english-live-transcript-preview` (see ADR-001 amendment 2026-06-14).
> Verify-then-archive to `plans/completed/`. This file is the session handoff;
> it is self-contained (the original approved plan lived at
> `~/.claude/plans/fluidaudio-s-nemotron-speech-streaming-drifting-crayon.md`;
> the 2026-06-12 restart plans live at
> `~/.claude/plans/restart-plans-active-nemotron-english-st-witty-wren.md` and
> `...-reflective-otter.md`).

## Restart-session #2 progress (2026-06-12, Linux sandbox — NO Swift toolchain)

**Standing decisions:** commit → push → CI green, then **HOLD the
draft PR** until the user runs host-side CLI smoke + punctuation gate on their
Mac; research-branch roadmap-row update deferred (PR-note only). CI
(`.github/workflows/ci.yml`, macos-14 swift build+test, runs on push) is the
build/test gate since this sandbox cannot run Swift. Push via explicit HTTPS
URL (`git push https://github.com/athurdekoos/macparakeet.git <branch>`) —
origin is SSH and the sandbox proxy only auths HTTPS; do NOT change remotes.

**DONE session #2 (all prior PENDING items resolved):**
1. Branch state fixed: working tree had been left on
   `research/stt-models-voice-personalization`; switched to
   `feat/nemotron-english-streaming-variant` (clean carry-over — the branches
   differed only by the research-doc commit). User stash `stash@{0}` untouched.
2. Three P3 cli-contract fixes applied (ModelsCommand delete discussion,
   CHANGELOG 2.9.0 warm-up/repair/status/health/clear bullet, cli-testing.md
   nemotron-model key + example) plus three bonus cli-testing.md gaps found by
   re-verification (EN download example, EN select example in Model Selection,
   engine-selection parity sentence; `models list` prose now names both builds).
3. REQ-STT-004 re-tagged `version: v0.6` per the REQ-LLM-004 precedent; yaml
   comment rewritten; owner re-tag alternative goes in the PR description.
   README/traceability/02-features verified already-consistent with v0.6.
4. All four ui-viewmodel findings verified REAL and fixed:
   (a) retranscribe popover card — persisted variant threaded through new
   `RetranscriptionEngineOption.nemotronVariant` field into `EngineOptionCard`;
   EN subtitle "Beta • Nemotron Speech EN streaming"; languageDetail shows
   "Language: English" for the EN build (it ignores hints);
   (b) `TranscriptionViewModel` cached gate now passes
   `modelVariant: SpeechEnginePreference.nemotronModelVariant(defaults:)`
   (NOTE for PR: only consumer is the `alternative == .nemotron` branch, which
   `SpeechEnginePreference.alternative` can't currently produce — correct but
   latent);
   (c) `SettingsViewModel.initialSpeechEngineSwitchDetail` gained a
   `nemotronVariant` param — EN shows "Loading Nemotron Speech EN Beta with
   Core ML..." (multilingual copy unchanged);
   (d) progress subline mirrors the whisper snapshot pattern via new
   `activeProgressNemotronVariant` — EN shows "Nemotron EN Beta · Local Core ML".
   Tests: new `testTranscribeFileProgressSublineUsesNemotronVariantSnapshot`;
   `nemotronVariant` assertion folded into the legacy-meeting-metadata test.
   `TranscriptionViewModel.swift` newly enters the diff (was a feature gap).
5. core-correctness review RAN (focused finder + adversarial verify): one P3
   refuted (unreachable buffer guard); one P2 confirmed-but-accepted — the
   variant-switch restore-failure path logs and rethrows the original error,
   a verbatim mirror of the locked `setParakeetModelVariant` pattern
   (STTRuntime.swift:642-662). Left unchanged by design; PR-note it.

**DONE session #2 (continued):**
6. Committed a0f6a288, pushed; CI run 27448068784 GREEN on the first compile
   (build, bundle smoke, concurrency + Swift 6 checks, full `swift test`).
   Note: the fork's GitHub Actions needed a one-time disable→enable toggle via
   `gh api` to register workflows; the first run was dispatched manually.
7. Host checklist (user, 2026-06-12/13): dev app GUI pass done; **punctuation
   gate PASSED** — EN-build dictation produced punctuated, capitalized text.
8. Side quest: `scripts/dev/run_app.sh` crashed at launch on the user's
   cert-less Mac (ad-hoc signing + `--options runtime` → hardened-runtime
   library validation rejects bundle-local Sparkle). Fixed by adding
   `com.apple.security.cs.disable-library-validation` to a temp entitlements
   copy for the ad-hoc fallback only; user-verified. Landed separately on
   `fix/dev-run-adhoc-signing` (own PR, kept out of this branch); the patch
   rides uncommitted in the local working tree until that PR merges — feature
   commits must use explicit paths, never `git add -A`.

**PENDING:**
1. Draft PR opened against moona3k/macparakeet (2026-06-13) — awaiting review.
2. After merge: archive this plan to `plans/completed/`; user switches default
   via `models select nemotron-english-1120ms` (GUI selection already persists
   it for the dev build).

## Context

June 2026 STT research (`docs/research/stt-models-and-voice-personalization-2026-06.md`
§2.1, roadmap item 2) identified FluidAudio's **Nemotron Speech Streaming EN 0.6B**
as the top dictation-engine candidate for this English-only user (2.28% WER /
65x RTFx at the 1120 ms tier on M5 Pro). The user wants it integrated as their
main local engine.

**Locked decisions (user-confirmed):**
- First-class engine + the user's own default. Fresh-install default stays
  Parakeet v3 (ADR-001 posture unchanged).
- Batch-at-stop only — NO live streaming partials in this change.
- 1120 ms tier only (`NemotronChunkSize.ms1120`).
- Upstream-PR quality: ADR amendment, kernel REQ id, CLI CHANGELOG, full tests.
- **Draft PR only** (`gh pr create --draft`), and **NO Claude co-author
  trailer** on commits (user instruction overriding default).

## Git / session state (as of interruption)

- Branch: `feat/nemotron-english-streaming-variant`, created from `origin/main`
  (30a1bc4b). All changes are uncommitted in the working tree.
- The user's unrelated WIP CLAUDE.md doc tweaks were stashed first:
  stash message "WIP CLAUDE.md doc tweaks (stashed before nemotron-english branch)"
  on `research/stt-models-voice-personalization`. Do NOT drop it; leave for the
  user (their tweaks touch testing/build sections; our CLAUDE.md edit will touch
  the engine bullet — a later `stash pop` should merge cleanly).
- Baseline `swift test` on clean main: GREEN. After all code changes:
  `swift build` (all targets): GREEN, zero warnings. `swift test` NOT yet re-run.

## Key implementation facts (verified, save re-research)

- FluidAudio pinned v0.15.2 already has the model — no dependency bump.
- Manager: `StreamingNemotronAsrManager` (actor), `init(configuration:requestedChunkSize:)`,
  `loadModels(to:configuration:progressHandler:)` auto-downloads
  `Repo.nemotronStreaming1120` = `FluidInference/nemotron-speech-streaming-en-0.6b-coreml/1120ms`
  into `<AppSupport>/FluidAudio/Models/` + `Repo...folderName` = `nemotron-streaming/1120ms`.
  ~600 MB (int8 encoder ~564 MB). `process(audioBuffer: AVAudioPCMBuffer)` /
  `finish()` / `reset()` / `cleanup()`. NO language API, NO detectedLanguage,
  NO appendTerminalPunctuation, NO shared-weights (+Shared) API.
- `ModelNames.NemotronStreaming.metadata` ("metadata.json") and
  `.encoderInt8File` ("encoder/encoder_int8.mlmodelc") are PUBLIC — both used
  by `isModelCached` (metadata required: `NemotronStreamingConfig()` defaults
  to the 2240 ms geometry without it).
- **O(N²) hazard**: the EN manager drains its buffer with `removeFirst` per
  1120 ms chunk — never feed one giant whole-file buffer. The new engine feeds
  10 s slices (160_000 samples) wrapped in 16 kHz/mono/Float32/non-interleaved
  `AVAudioPCMBuffer`s (`AudioConverter.resampleBuffer` fast-path = copy, no
  re-resample).
- Telemetry gotcha (fixed): `TelemetryEvent.safeEngineVariant` allowlisted only
  Whisper sizes; "v2"/"v3"/"multilingual-1120ms"/"english-1120ms" all
  serialized as "custom". First-party ids now added to the allowlist.
- License posture: FluidAudio + conversion Apache-2.0; upstream NVIDIA terms
  opaque → user-triggered download only, never bundle. (In ADR amendment text.)

## DONE (all uncommitted)

### Phase 1 — Core
- `Sources/MacParakeetCore/SpeechEnginePreference.swift`: `.english1120 =
  "english-1120ms"` case (displayName "English Beta", modelName "Nemotron
  Speech Streaming EN 0.6B", ~600 MB, chunk 1120, `isEnglishOnly`,
  `alternative`); `nemotronModelVariantKey = "nemotronModelVariant"` +
  validated `nemotronModelVariant(defaults:)` / `saveNemotronModelVariant`.
- NEW `Sources/MacParakeetCore/STT/NemotronEnglishEngine.swift`: actor,
  `STTTranscribing`; two-lane (interactive/background) with per-lane
  `engineBusy` guard; `prepare()` idempotent (loads 2 managers,
  `requestedChunkSize: .ms1120`); transcribe = reset → detached
  `resampleAudioFile` → 10 s-slice feed loop (cancellation checks, progress
  25→90) → `finish()` → `STTResult(words: [], language: "en", engine:
  .nemotron, engineVariant: "english-1120ms")`; statics
  `defaultCacheRoot`/`isModelCached(cacheRoot:)`/`deleteModel(cacheRoot:)`
  (testable seams)/`downloadModel(onProgress:)` via `DownloadUtils.downloadRepo`;
  copied progress-throttle + error-mapping helpers (per-engine-copy convention).
- `Sources/MacParakeetCore/STT/STTRuntime.swift`: `nemotronModelVariant` now
  `var`; `nemotronEnglishEngine` slot + `ensureNemotronEnglishEngine()`;
  variant branch in `transcribeWithNemotron` (EN ignores language), `warmUp`,
  `performSpeechEngineSwitch` (staged `preparedNemotronEnglish`), `isReady`;
  `unloadNemotron` clears both; `clearModelCache` also removes
  `Models/nemotron-streaming` family root; statics `isNemotronModelCached` /
  `downloadNemotronModel` default downloader / `deleteNemotronModel` branch on
  `variant.isEnglishOnly`; NEW `setNemotronModelVariant(_:onProgress:)`
  mirroring `setParakeetModelVariant` (no-op same value, engineBusy guard,
  deferred path when engine != .nemotron, download-first → unload → swap →
  `prepareActiveNemotronEngine`, restore-on-failure, `nemotron_variant_switch_*`
  logs); protocol requirement added to `STTRuntimeProtocol`.
- `STTClientProtocol.swift`: `SpeechEngineSwitching.setNemotronModelVariant`
  requirement (doc comment); `STTScheduler.setNemotronModelVariant` (verbatim
  parakeet parallel, watchdog reason "set_nemotron_model_variant");
  `STTClient` passthrough.
- Test mocks updated to conform: `Tests/.../STT/MockSTTClient.swift`
  (+`nemotronModelVariantSwitches`/`...SwitchError`), `MockSpeechEngineSwitcher`
  in `SettingsViewModelTests.swift` (+`nemotronVariants`), `MockSTTRuntime` in
  `STTSchedulerTests.swift` (+`nemotronModelVariantSwitches`).
- `TelemetryEvent.swift`: `TelemetrySettingName.nemotronModelVariant =
  "nemotron_model_variant"`; `safeEngineVariant` allowlist += v2, v3,
  multilingual-1120ms, english-1120ms.
- Bootstrap: `AppEnvironment.swift` + CLI `makeConfiguredSTTClient` now pass
  `nemotronModelVariant: SpeechEnginePreference.nemotronModelVariant(...)`.
- `Sources/MacParakeetCore/STT/README.md` engine inventory updated.

### Phase 2 — Surface
- `SettingsViewModel.swift`: `nemotronModelVariant` published prop with didSet →
  `applyNemotronModelVariantChange` (mirror of parakeet; persists on success,
  reverts via `revertNemotronModelVariant`, emits
  `.settingChanged(.nemotronModelVariant)`); `isNemotronVariantSwitch`,
  `isApplyingNemotronVariantState`, `downloadedNemotronVariants:
  Set<NemotronModelVariant>`; `refreshModelStatus` computes per-variant disk
  set (both sttClient/no-sttClient paths; guards include
  `nemotronModelVariant == activeNemotronVariant`); `refreshNemotronModelStatus`
  + `applyNemotronDownloadedStatus` + `downloadNemotronModel` read persisted
  variant; `deleteNemotronModel()` REPLACED by `deleteNemotronVariant(_:)` —
  selected build protected only while Nemotron is the ACTIVE engine (preserves
  old Local-Models-overflow delete capability when inactive), non-selected
  build deletable any time.
- `SettingsView.swift`: `PendingModelDeletion.nemotron` now carries
  `NemotronModelVariant` (variant-driven alert copy); new
  `engineNemotronModelCard` + `nemotronModelOptionRow` +
  `selectNemotronModelVariant` (mirrors Parakeet card; inserted into
  `engineTabContent` as `.id("engine.nemotronModel")`);
  `parakeetVariantStatusBadge` renamed `modelVariantStatusBadge` (shared);
  engine tile generalized (name "Nemotron", tagline "Streaming local models
  (Beta)", strengths/help cover both builds); download banner title
  variant-aware ("Nemotron Speech EN Beta" vs "Nemotron 3.5 Beta") + size
  subtitle from selected variant; `speechEngineSwitchTitle` handles
  `isNemotronVariantSwitch` ("Updating Nemotron model");
  `displayedNemotronModelStatusDetail` fallback uses variant modelName;
  `handleNemotronTileTap` notDownloaded message variant-aware; overflow
  "Delete download…" passes selected variant; switch-confirmation copy now
  "Nemotron is a Beta engine…" (was "Nemotron 3.5").
- `SettingsStatusRules.swift`: doc comment only (params = selected build's
  status; no signature change).
- `SettingsSearchIndex.swift`: new `engine.nemotronModel` entry (anchored to
  `engine.selector`, same hidden-anchor rationale as Parakeet).
- `TranscriptResultView.swift` `engineAttributionLabel`: `"english-1120ms"` →
  "Nemotron EN Beta", else "Nemotron 3.5 Beta".
- CLI `ModelsCommand.swift`: `parseNemotronSelectionVariant` accepts
  `english-1120ms|english|english-only|en`; bare `nemotron` resolves to
  persisted variant (`nemotronDownloadVariant` gained `defaults:` param);
  `Select.run` persists nemotron variant; `loadSelectableSpeechModels` marks
  per-variant selection + `language: "en"` for EN; `loadSpeechStackStatus`
  `nemotronModelVariant` param now optional (nil → persisted); `isModelInUse`
  compares persisted variant; help strings mention `nemotron-english-1120ms`.
- CLI `TranscribeCommand.swift`: `TranscribeNemotronModel` enum
  (`app-default|multilingual-1120ms|english-1120ms`) + `--nemotron-model`
  option + `resolveNemotronModelVariant(_:storedVariant:)`; `.nemotron` engine
  branch constructs `NemotronEnglishEngine()` when EN (stderr note if
  `--language` passed; new `nemotronEnglishEngine` local + unload at end);
  `--language` help notes EN build ignores it.
- CLI `ConfigCommand.swift`: `nemotron-model` key (read/write +
  `parseNemotronModelVariant` with aliases, invalid-value error); discussion
  block updated; `nemotron-language` write prints stderr note when EN build
  selected (value still persists).
- CLI `SpecCommand.swift`: `--nemotron-model` option + config key list +
  `--language` summary updated.
- `Sources/CLI/CHANGELOG.md`: new `## [2.9.0] -- 2026-06-11` section (absorbed
  the `[Unreleased]` timeout item into its Changed); `MacParakeetCLI.swift`
  `cliVersion = "2.9.0"`.

### Phase 2 step 10 — docs (PARTIALLY DONE)
- DONE: `spec/adr/001-parakeet-stt.md` (header amendment line 2026-06-11 +
  full "Addendum: Nemotron English Beta Build (June 2026)" section).
- DONE: `spec/adr/016-centralized-stt-runtime-scheduler.md` (amendment line).
- DONE: `spec/kernel/requirements.yaml` → REQ-STT-004 (version: v0.7 — flag
  to owner in PR; v0.6 is the last closed batch).
- DONE: `spec/kernel/traceability.md` → REQ-STT-004 row.

## REMAINING WORK (in order)

### 1. Finish docs (task #4)
- `spec/06-stt-engine.md`: Nemotron Beta table — list both builds; add
  `--nemotron-model` to CLI flags; rewrite the "surfaced variants" line:
  multilingual-1120ms (default) + english-1120ms (English-only; ignores
  `nemotron-language`); add `models download nemotron-english-1120ms` example.
- `spec/02-features.md`: engine settings diagram/table — add Nemotron build
  picker line + "Nemotron model: multilingual-1120ms / english-1120ms (default
  multilingual)"; app-size note: "~1.5 GB or ~600 MB optional Nemotron download".
- `spec/README.md`: stack table Nemotron clause + progress checkbox (EN 0.6B
  surfaced as second opt-in Beta build with persisted model selection).
- `CLAUDE.md`: engine quick-facts + STT bullet — mention both model ids
  (`nemotron-multilingual-1120ms` ~1.5 GB, `nemotron-english-1120ms` ~600 MB;
  selected via Settings, `config set nemotron-model`, `models select`,
  `transcribe --nemotron-model`). NOTE: edit the branch's CLAUDE.md (user WIP
  tweaks are stashed, separate sections).
- `README.md`: Nemotron engine mention covers both builds; model-id list.
- `docs/telemetry.md`: `engine_variant` paragraph — enumerate first-party
  values (v2, v3, multilingual-1120ms, english-1120ms, whisper sizes; else
  "custom"); add `nemotron_model_variant` to setting_changed settings list.
- `docs/research/stt-models-and-voice-personalization-2026-06.md` §9 roadmap
  row 2: append "*(shipped 2026-06 as opt-in Beta `english-1120ms` variant;
  batch-at-stop, streaming partials not yet surfaced)*".

### 2. Tests (task #5) — mirror existing patterns
- `Tests/MacParakeetTests/STT/SpeechEnginePreferenceTests.swift`:
  default-to-multilingual when unset; round-trip `.english1120`; unknown raw
  value → default; frozen raw value "english-1120ms" + chunk 1120 +
  isEnglishOnly.
- `Tests/MacParakeetTests/STT/ModelDeletionTests.swift` (temp-cacheRoot seams,
  mirror existing lines ~50–134): EN delete removes tier dir + removes empty
  `nemotron-streaming` parent; no-op when absent; `isModelCached(cacheRoot:)`
  requires BOTH metadata.json AND encoder/encoder_int8.mlmodelc;
  download/delete telemetry carries engineVariant "english-1120ms" (injected
  `downloader` closure pattern).
- `Tests/MacParakeetTests/STT/STTSchedulerTests.swift`: quartet
  `testSetNemotronModelVariantForwardsWhenIdle` / `FailsWhileJobIsRunning` /
  `FailsWhileSessionLeaseIsActive` / `FailsWhileSessionBeginIsInFlight`
  (verbatim parallels of parakeet tests at ~lines 246–326). Optional runtime
  deferred-switch test (`STTRuntime(speechEngine: .parakeet)` → set EN variant
  returns without network).
- `Tests/CLITests/ModelLifecycleCommandTests.swift`: extend
  `testNemotronDownloadVariantRecognizesNemotronIDs` (en id + aliases + bare
  nemotron follows persisted); select persists engine AND variant; list marks
  only selected nemotron variant + EN reports language "en"; isModelInUse
  protects only selected variant.
- `Tests/CLITests/ConfigCommandTests.swift`: nemotron-model read default /
  write + alias canonicalization / invalid value rejection;
  nemotron-language-while-EN stderr note (exit 0) if there's a capture helper.
- `Tests/CLITests/TranscribeCommandTests.swift`: `--nemotron-model` parse;
  resolveNemotronModelVariant app-default→stored / explicit override.
- `Tests/CLITests/SpecCommandTests.swift`: update embedded-spec assertions if
  they enumerate options/keys (check; may pass already).
- `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`: variant
  change persists / reverts-on-unavailable / reverts-on-failure (mirror the
  parakeet variant tests in that file); downloaded variants tracked per-build;
  download uses selected variant; deleteNemotronVariant refuses selected-while-
  active / allows non-selected.
- `Tests/MacParakeetTests/TelemetryServiceTests.swift`: first-party variants
  pass allowlist; arbitrary string still → "custom". (Check existing
  assertions expecting "custom" for parakeet/nemotron ids — they may need
  updating to the new literal values.)

### 3. Verification (task #6)
1. `swift test` full suite green.
2. CLI smoke (user approved the ~600 MB download):
   `swift run macparakeet-cli models download nemotron-english-1120ms`, then
   `swift run macparakeet-cli transcribe <sample.wav> --engine nemotron
   --nemotron-model english-1120ms` (a sample can be made with `say -o` +
   afconvert, or use a dictation WAV from the app's data). Verify transcript,
   cache at `~/Library/Application Support/FluidAudio/Models/nemotron-streaming/1120ms`,
   `models list/status` output.
3. **PUNCTUATION GATE (blocker for step 5 below)**: EN manager has no
   appendTerminalPunctuation and docs make no punctuation claim. Check real
   transcript for punctuation/capitalization. If unpunctuated → record it,
   keep Beta label, pick mitigation (engine-side terminal punctuation /
   TextProcessing pipeline / upstream FluidAudio request) BEFORE switching the
   user's default.
4. GUI pass via `scripts/dev/run_app.sh`: Nemotron Model card switch flows,
   delete flows, banner copy, History attribution.
5. Memory sanity: dictation during meeting with EN selected (two managers).

### 4. Ship (task #7)
- Multi-agent adversarial review of the full diff (ultracode is on — use a
  Workflow review pass) before committing.
- Commit: rich format per `docs/commit-guidelines.md` (What Changed / Root
  Intent / Prompt / ADRs Applied: ADR-001 + ADR-016 amendments / Files
  Changed). **NO Co-Authored-By trailer** (user instruction).
- Push to fork, **draft PR only**: `gh pr create --draft` against
  moona3k/macparakeet main per `docs/pr-review-workflow.md`. Description:
  locked decisions, CLI 2.9.0 delta, telemetry allowlist rationale, license
  posture, out-of-scope (no live partials, no 560/2240 tiers, no default
  change), REQ-STT-004, punctuation-gate findings.
- After gate passes: switch the user's machine —
  `swift run macparakeet-cli models select nemotron-english-1120ms`
  (model must be downloaded first; select sets engine+variant).
- Archive this plan to `plans/completed/` when done.

## Out of scope (explicit)
- Live streaming partials in the dictation overlay (follow-up).
- 560 ms / 2240 ms tiers; fresh-install default change; vocabulary boosting.
