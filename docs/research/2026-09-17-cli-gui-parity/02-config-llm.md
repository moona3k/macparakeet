# Brief 02 — Shared preferences and LLM config robustness

Investigated against HEAD `fb186349` (`feat/cli-gui-parity`, based on
`origin/main`). Ground truth: `Sources/MacParakeetCore/Services/AppPaths.swift`,
`Sources/CLI/Commands/CLIHelpers.swift`, `Sources/MacParakeetCore/Services/LLM/*`,
`Sources/CLI/Commands/*.swift`, `Tests/CLITests/CLIHelpersTests.swift`,
`Tests/CLITests/MeetingSplitCommandTests.swift`.

## How the shared-preferences mechanism actually works

`AppPaths.appDefaults(bundleIdentifier: Bundle.main.bundleIdentifier)`
(`Sources/MacParakeetCore/Services/AppPaths.swift:98-105`) is the resolver:
if the calling process's own bundle identifier already equals
`com.macparakeet.MacParakeet` (the running GUI app, or an executable embedded
in its bundle), it returns `.standard` (already the right domain). Otherwise
(a standalone binary such as the Homebrew CLI, whose `Bundle.main.bundleIdentifier`
is `nil` — the CLI target has no `Info.plist`, confirmed via `Package.swift:138-144`)
it opens the named suite `UserDefaults(suiteName: "com.macparakeet.MacParakeet")`
explicitly. This asymmetry is intentional and tested
(`Tests/CLITests/CLIHelpersTests.swift:9-29`,
`Tests/CLITests/MeetingSplitCommandTests.swift:427-462`).

`macParakeetAppDefaults()` (`Sources/CLI/Commands/CLIHelpers.swift:16-20`) is
the CLI-local alias for that resolver. The established convention across the
codebase: types that need a preferences domain (`SpeechEnginePreference`,
`UserDefaultsAppRuntimePreferences`, `AppPreferences`, `AppPaths`) default
their `defaults:` parameter to `.standard` for the GUI's convenience, and
**every CLI call site is expected to explicitly pass `macParakeetAppDefaults()`
(or `AppPaths.appDefaults()`)** to override that default. This is a
call-site discipline, not something the type system enforces.

## Hypothesis 1 — CONFIRMED BUG: `LLMConfigStore`/`LocalCLIConfigStore` break this discipline in exactly two CLI call sites

`LLMConfigStore` (`Sources/MacParakeetCore/Services/LLM/LLMConfigStore.swift:25-31`)
and `LocalCLIConfigStore` (`Sources/MacParakeetCore/Services/LLM/LocalCLIExecutor.swift:104-111`)
both default `defaults: UserDefaults = .standard` — consistent with the
convention above. `LLMService`'s convenience init and
`StoredLLMExecutionContextResolver`'s init both default to constructing these
with no override
(`Sources/MacParakeetCore/Services/LLM/LLMService.swift:324-336`,
`Sources/MacParakeetCore/Services/LLM/LLMExecutionContext.swift:29-39`), so a
bare `LLMService()` reads/writes `.standard`.

I grepped every CLI command file for `LLMService()`, `LLMConfigStore()`, and
`LocalCLIConfigStore()` used with no arguments (i.e. relying on the `.standard`
default instead of passing the suite). Exactly two call sites do this, and
both are real bugs on the Homebrew/standalone CLI:

1. **`Sources/CLI/Commands/SavedMeetingProcessingContext.swift:17`** —
   `let llmService = LLMService()`. This is especially telling because the
   *same initializer*, three lines above, correctly resolves
   `let defaults = AppPaths.appDefaults()` (line 15) and threads it through
   `UserDefaultsAppRuntimePreferences(defaults: defaults)` (line 16),
   `SpeechEnginePreference.*(defaults: defaults)` (lines 30-33), `STTClient(...,
   defaults: defaults, ...)` (line 34), and
   `SpeechEngineSelection.finalTranscription(defaults: defaults)` (line 56) —
   every other suite-aware collaborator in this exact struct gets `defaults`
   except `llmService`. This struct backs both `meeting import`
   (`MeetingImportCommand.swift:143`) and `meeting split`
   (`MeetingSplitCommand.swift:589`), and its `llmService` is used for AI
   Formatter transcript cleanup, saved-audio auto-prompt completion, and
   knowledge-card generation (lines 49, 63, 73).
2. **`Sources/CLI/Commands/CardsCommand.swift:141`** —
   `completionProvider: LLMService()` inside `CardsGenerateCommand.run()`
   (`macparakeet-cli cards generate`). This file never computes a `defaults`
   local at all.

**Effect on the standalone/Homebrew CLI:** `AppPaths.appDefaults()` there
resolves to the named suite, not `.standard`. `LLMConfigStore(defaults:
.standard).loadConfig()` looks for the `llm_provider_config` key in the
*wrong* UserDefaults domain, finds nothing, and returns `nil` before it ever
reaches the Keychain lookup for the API key. `StoredLLMExecutionContextResolver.resolveContext()`
then returns `nil`, and `LLMService` throws `LLMError.notConfigured`
(`Sources/MacParakeetCore/Services/LLM/LLMService.swift:1434`) even when the
user has a working provider configured in the GUI. This is not a crash —
it's a per-item silent-looking failure: `SavedAudioAutoPromptCompletionService`
catches the error and records `.failed(message: error.localizedDescription)`
per prompt (`Sources/MacParakeetCore/Services/SavedAudioAutoPromptCompletionService.swift:187-189`)
and `.knowledgeCardFailed(message:)` for cards (line 261), so `meeting import`/`meeting
split --json` reports "not configured" for every auto-prompt and card on a
completely valid GUI-configured Homebrew install. `cards generate` fails the
same way per transcription.

Confirmed *not* affected: `macparakeet-cli transcribe` never applies AI
Formatter at all regardless of this bug — `TranscribeCommand.swift`'s
`TranscriptionService(...)` call passes neither `llmService:` nor
`shouldUseAIFormatter:`, so both default to disabled
(`Sources/MacParakeetCore/Services/TranscriptionService.swift:348-458`). That's
a separate, apparently deliberate scope decision (file/URL transcription
never LLM-formats), not this bug.

Confirmed *not* affected: the stateless `llm chat` / `llm transform` /
`llm summarize` / `prompts run` / `transforms run` commands never touch the
stored `LLMConfigStore` at all — they build an `LLMExecutionContext` entirely
from `LLMInlineOptions.buildExecutionContext()`
(`Sources/CLI/Commands/LLMInlineConfig.swift:119-239`), which requires
`--provider` plus an explicit credential per invocation
(`--api-key`/`--api-key-env`/env var). This is a deliberate, distinct,
stateless design (the type's own doc comment: "Shared options for CLI
commands that call an LLM provider directly (no Keychain)") and correctly
has nothing to do with GUI-saved provider state.

### Recommended smallest fix

Follow the exact pattern already used one line above the bug in
`SavedMeetingProcessingContext.swift` — construct the suite-aware stores
explicitly instead of changing the type-level defaults (which would be a
wider, less consistent change than the codebase's established per-call-site
convention):

```swift
// SavedMeetingProcessingContext.swift:17 — defaults is already in scope (line 15)
let llmService = LLMService(
    configStore: LLMConfigStore(defaults: defaults),
    cliConfigStore: LocalCLIConfigStore(defaults: defaults)
)
```

```swift
// CardsCommand.swift — CardsGenerateCommand.run(), hoist a `defaults` local
// the same way ModelsCommand.swift / TranscribeCommand.swift do
let defaults = macParakeetAppDefaults()
...
completionProvider: LLMService(
    configStore: LLMConfigStore(defaults: defaults),
    cliConfigStore: LocalCLIConfigStore(defaults: defaults)
)
```

No test currently exercises this: `Tests/CLITests/CardsCommandTests.swift`
never asserts on `LLMService`/`UserDefaults` wiring (grepped, zero hits), and
`testCardsGenerateStaleReportsOnlyPrefilteredStaleSubsetAsSelected` only
exercises the pre-filter selection with no completed transcriptions, so the
LLM path is never invoked. A regression test should assert
`CardsGenerateCommand`/`SavedMeetingProcessingContext` resolve provider
config from an isolated non-`.standard` suite injected via
`AppPaths.appDefaults(bundleIdentifier:)`, mirroring
`testStandaloneCLIUsesSharedAppPreferenceDomain`
(`Tests/CLITests/CLIHelpersTests.swift:16-29`) and
`testSplitMeetingRecordingsRootURLHonorsACustomAppDefaultsFolderPreference`
(`Tests/CLITests/MeetingSplitCommandTests.swift:434-448`).

**Not investigated further (flagged, not confirmed):** `KeychainKeyValueStore`
(`Sources/MacParakeetCore/Licensing/KeychainKeyValueStore.swift`) uses
`kSecClassGenericPassword` with no `kSecAttrAccessGroup`, and MacParakeet is
not sandboxed (`scripts/dist/MacParakeet.entitlements` has no
`com.apple.security.app-sandbox` key). Whether a differently-signed standalone
Homebrew binary can silently read a Keychain item created by the signed
`.app` (vs. triggering a one-time Keychain ACL prompt) is a live question the
brief didn't ask about and I did not test empirically — the UserDefaults bug
above is confirmed and sufficient to explain the reported symptom on its own
(`loadConfig()` returns `nil` before the Keychain read is ever attempted), so
this is a secondary risk worth a follow-up, not a blocker for the fix above.

## Hypothesis 2 — DISPROVEN: no CLI path forgets to pass the suite to `SpeechEnginePreference`

Grepped every `SpeechEnginePreference.*(` and `SpeechEngineSelection.*(` call
in `Sources/CLI/Commands/*.swift`. Every single call site passes an explicit
`defaults:` argument, and in every file that argument is a local bound to
`macParakeetAppDefaults()` (`ModelsCommand.swift:59,106,225,257,307`,
`RetranscribeCommand.swift:213`, `TranscribeCommand.swift:534`,
`VocabWordsCommand.swift:19`, `VocabProcessCommand.swift:30`,
`AudioInputDiagnostics.swift:36`) or `AppPaths.appDefaults()`
(`MeetingSplitCommand.swift:588`, `MeetingImportCommand.swift:145`,
`SavedMeetingProcessingContext.swift:15`). A repo-wide grep for
`UserDefaults.standard` under `Sources/CLI/` returns zero matches. Killed.

## Hypothesis 3 — DISPROVEN: no CLI path forgets to pass the suite to `UserDefaultsAppRuntimePreferences`

Same method, same result: every `UserDefaultsAppRuntimePreferences(` call in
`Sources/CLI/` (`AudioInputDiagnostics.swift:42`, `ConfigCommand.swift:382`,
`RetranscribeCommand.swift:381`, `SavedMeetingProcessingContext.swift:16`,
`VocabWordsCommand.swift:27`) passes a suite-resolved `defaults`/`store`
local. Killed. (The GUI's own bare `UserDefaultsAppRuntimePreferences()` at
`Sources/MacParakeet/App/AppEnvironment.swift:154` is correct as written: the
GUI process's own bundle identifier is `com.macparakeet.MacParakeet`, so
`.standard` there already *is* the shared domain — this is not the same bug
as hypothesis 1, where the CLI is the one silently defaulting.)

## Hypothesis 4 — `config` key coverage vs `AppRuntimePreferences` / `AppPreferences` / `CalendarAutoStartPreferences`

`macparakeet-cli config get/set/list` exposes exactly 25 keys
(`Sources/CLI/Commands/ConfigCommand.swift:81-232`). Below is every
`UserDefaults` key I found declared across `AppRuntimePreferences.swift`,
`AppPreferences.swift`, and `CalendarAutoStartPreferences` (same file), plus
the two LLM stores, classified against the CLI surface. "Automation-relevant"
means: some CLI-reachable code path (a command, or a service a command
constructs) actually reads that key and changes behavior based on it, and a
Homebrew-CLI-only workflow (fleet provisioning, headless meeting box, CI Mac)
would plausibly want to set it without opening Settings — matching
`ConfigCommand`'s own stated purpose ("lets users who only install the CLI...
persist preferences... a later GUI install picks the same values up
automatically", `ConfigCommand.swift:14-19`). "GUI-only chrome" means: no
CLI-reachable code consumes it, it's visual/interactive-only, or it's
internal bookkeeping/consent state that must not be set blindly.

| Key (constant) | Classification | Why |
|---|---|---|
| `telemetryEnabledKey` | already-exposed | `config telemetry` |
| `processingModeKey` | already-exposed | `config processing-mode` |
| `removeUmFillerKey` | already-exposed | `config remove-um-filler` |
| speech-engine / parakeet-model / nemotron-model / nemotron-language / whisper-language / cohere-language (`SpeechEnginePreference`) | already-exposed | `config` rows of the same names |
| `speakerDiarizationKey` | already-exposed | `config speaker-detection` |
| `meetingSpeakerDiarizationKey` | already-exposed | `config meeting-speaker-detection` |
| `autoGenerateMeetingTitlesKey` | already-exposed | `config auto-meeting-titles` |
| `voiceReturnEnabledKey` | already-exposed | `config voice-return-enabled` |
| `voiceReturnTriggersKey` | already-exposed | `config voice-return-triggers` |
| `voiceReturnTriggerKey` | already-exposed | written as a derived legacy single-value mirror by the same handler (`ConfigCommand.swift:480`) |
| `preserveDiscardedDictationsKey` | already-exposed | `config preserve-discarded-dictations` |
| `saveTranscriptionAudioKey` | already-exposed | `config save-transcription-audio` |
| `meetingAudioRetentionKey` + `meetingAudioRetentionDeleteAfterDaysKey` | already-exposed | `config meeting-audio-retention` writes both via `saveMeetingAudioRetention` |
| `saveMeetingAudioKey` | already-exposed | `config save-meeting-audio` (legacy alias) |
| `meetingAudioSourceModeKey` | already-exposed | `config meeting-audio-source` |
| `startMeetingsMutedKey` | already-exposed | `config start-meetings-muted` |
| `youtubeAudioQualityKey` | already-exposed | `config youtube-audio-quality` |
| `AppPaths.meetingArtifactsFolderKey` | already-exposed | `config meeting-artifacts-folder` |
| `MeetingAutomationHookConfiguration.{enabledKey,executablePathKey,timeoutSecondsKey}` | already-exposed | `config meeting-hook-*` |
| `aiFormatterEnabledKey` | **expose** | Master AI-Formatter (LLM cleanup) switch. Gates `SavedMeetingProcessingContext`'s LLM formatting for `meeting import`/`meeting split` (`SavedMeetingProcessingContext.swift:51`). No CLI surface at all today; directly in this brief's LLM scope. |
| `aiFormatterEnabledForTranscriptionsKey` | **expose** | Same gate, transcription-scope half (`SavedMeetingProcessingContext.swift:51`). |
| `aiFormatterEnabledForDictationKey` | **expose** | Same feature family, dictation-scope half; consumed by the GUI dictation flow. |
| `aiFormatterPromptKey` | **expose** | Custom cleanup prompt template text; a CLI-only user has no way to set it. |
| `aiFormatterSmartDefaultsEnabledKey` | **expose** (secondary) | Tunes formatter heuristics; lower priority than the on/off switches above. |
| `aiFormatterDisabledSmartDefaultCategoriesKey` | gui-only (advanced) | Set-typed fine-tuning list; low value as a flat `config set` string, better left to GUI or a dedicated future subcommand. |
| `customVocabularyRecognitionBoostingEnabledKey` | **expose** | Confirmed gap: `vocab words add/set/delete` fully manage individual words, but nothing toggles this master switch — a CLI-only user can populate a vocab list that never actually boosts recognition. |
| `meetingLiveTranscriptionEnabledKey` | **expose** | Changes resource/latency behavior of meeting recording; automation-relevant for unattended meeting boxes. |
| `rememberSpeakersKey` | **expose** | Voiceprint-based cross-meeting speaker memory; affects diarization labels a CLI `meetings show`/`export` would surface. (Per project history this feature is still being gated on corpus/consent maturity — expose only once that gating is otherwise resolved.) |
| `silenceAutoStopKey` | **expose** | Whether meeting recording auto-stops on silence — directly changes unattended recording duration/outcome. |
| `silenceDelayKey` | **expose** | Paired delay for the above. |
| `meetingAutoStopEnabledKey` | **expose** | Whether meeting recording auto-stops on other triggers (e.g. call-app close); same automation category as `silenceAutoStopKey`. |
| `selectedMicrophoneDeviceUIDKey` | **expose** | Device selection matters for headless/CI Macs with non-default audio interfaces; currently GUI-picker-only. |
| `saveDictationHistoryKey` | **expose** | Parity gap: `save-transcription-audio` (file/URL) is exposed but the dictation-history equivalent isn't. |
| `saveAudioRecordingsKey` | **expose** | Same parity gap, dictation audio retention specifically. |
| `CalendarAutoStart.mode` | **expose** | Whole calendar-driven auto-start feature (ADR-017) is otherwise unreachable from a CLI-only install — a fleet-provisioning script cannot turn this on/off today. |
| `CalendarAutoStart.reminderMinutes` | **expose** | Paired with mode above. |
| `CalendarAutoStart.triggerFilter` (stored default) | **expose** | Note: `calendar upcoming --trigger-filter` already accepts this as a per-invocation flag, but the *stored default* the live auto-start feature actually uses has no persistent CLI setter. |
| `CalendarAutoStart.excludedCalendarIds` | **expose** | Needed to fully configure calendar auto-start without the GUI's calendar picker. |
| `CalendarAutoStart.skippedOccurrences` / `.skippedEvents` | gui-only (runtime state) | Per-occurrence "user dismissed this one" state, not a general preference; already correctly read-only via `calendar upcoming`. |
| `lastMeetingAudioRetentionSweepAtKey` | gui-only (internal) | Bookkeeping timestamp of the last sweep run, not a user-facing setting. |
| `voiceprintConsentAcknowledgedAtKey` | gui-only (consent, intentional) | Legal consent timestamp; must go through the actual consent UI, not a blind `config set`. |
| `hasCompletedFirstDictationKey` | gui-only (internal) | Onboarding-completion flag, not a preference. |
| `transcriptAIContextModeKey` | gui-only | Grepped: zero references under `Sources/CLI/`. Only the GUI's in-app Ask/chat panel reads it (`MeetingRecordingPanelViewModel.swift`, `TranscriptionViewModel.swift`, `LLMSettingsViewModel.swift`). Nothing to expose yet — no CLI command consumes it. |
| `dictationInsertionStyleKey` | gui-only | Governs how the system-wide dictation hotkey inserts text (paste vs. keystroke sim); tied entirely to the interactive hotkey flow, not any CLI command. |
| `pauseMediaDuringDictationKey` | gui-only | Same hotkey-flow category. |
| `instantDictationEnabledKey` | gui-only | Same hotkey-flow category. |
| `keepDictationOnClipboardKey` | gui-only | Same hotkey-flow category; low automation value. |
| `showLiveDictationPreviewKey` / `dictationPreviewTextSizeKey` / `dictationUndoCountdownKey` | gui-only | Pure HUD/visual behavior during the interactive hotkey flow. |
| `showIdlePillKey` / `showDiscoverKey` / `showMeetingRecordingPillKey` | gui-only | Pure visual chrome (menu bar pill / tab visibility). |
| `openAppAfterMeetingEndKey` | gui-only | GUI window-activation behavior; meaningless from a CLI invocation. |
| `notifyOnMeetingEndKey` / `notifyOnTranscriptionCompleteKey` | gui-only (low priority) | macOS user-notification toggles; borderline for headless setups but low automation value today — no CLI command's behavior changes based on them. |
| `transcriptFontScaleKey` | gui-only | Pure text-rendering scale. |
| `appearanceModeKey` | gui-only | Light/dark/system theme. |
| `menuBarOnlyModeKey` / `showMenuBarIconKey` | gui-only | Dock/menu-bar presentation chrome. |
| `llm_provider_config` (`LLMConfigStore`) | gui-only, by design — but currently buggy for its CLI *readers* | Deliberately **not** a flat `config set` key: persisting an API key through `config set <key> <value>` would put secrets in shell history/process args, which the brief's own "Settled" section already rules out. The GUI Settings flow (and Keychain) remains the only way to *write* stored provider config. The bug is entirely on the *read* side (hypothesis 1 above) — CLI consumers of the already-GUI-configured value use the wrong preferences domain. |
| `local_cli_config` (`LocalCLIConfigStore`) | gui-only, by design — same caveat | Same reasoning as `llm_provider_config`; timeout/command-template for the "cli" provider. |

## Summary

- **Confirmed bug, 2 call sites:** `SavedMeetingProcessingContext.swift:17`
  and `CardsCommand.swift:141` construct `LLMService()` with no suite
  override, so `meeting import`, `meeting split`, and `cards generate` on a
  standalone/Homebrew CLI install cannot see a GUI-configured LLM provider —
  every AI Formatter cleanup, auto-prompt completion, and knowledge card on
  those paths fails with a misleading "not configured" message even when the
  provider works fine in the GUI. Smallest fix: pass `LLMConfigStore(defaults:)`
  / `LocalCLIConfigStore(defaults:)` explicitly at both sites, mirroring the
  pattern already used one line above the bug.
- **Disproven:** hypotheses 2 and 3 — every CLI call site for
  `SpeechEnginePreference` and `UserDefaultsAppRuntimePreferences` already
  passes the correctly-resolved suite. No fix needed there.
- **Config coverage:** 25 keys already exposed; ~19 keys are genuine
  automation-relevant gaps (AI Formatter on/off + prompt, custom-vocabulary
  boosting master switch, meeting auto-stop/silence/live-transcription,
  mic-device selection, dictation-history/audio retention parity, and the
  entire Calendar auto-start feature), and the rest are correctly GUI-only
  chrome, consent state, or internal bookkeeping. The AI Formatter and
  Calendar auto-start gaps are the two clusters worth prioritizing if `config`
  coverage work follows this brief, since both are whole features currently
  unreachable from a CLI-only install.
