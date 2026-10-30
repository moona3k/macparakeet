# Dictation insertion and guarded submission

## Purpose

Ordinary dictation inserts a completed transcript into the active application.
An optional Codex setting adds Return after paste. It does not select a task,
window, editor, or composer, and does not broaden Voice Control authority.

## Producers and consumers

`SettingsViewModel` writes the preference and `UserDefaultsAppRuntimePreferences`
reads it. `DictationFlowCoordinator` chooses the insertion path and owns its
cancellation. `ClipboardServiceProtocol` provides clipboard paste and optional
post-paste actions; `DictationFlowStateMachine` presents completion or partial
completion. Transforms and other ordinary clipboard callers keep their existing
unguarded behavior unless they explicitly supply a required application.

## Stable semantics

- `autoSubmitCodexDictation` is a Boolean UserDefaults key, default false. It
  affects only nonempty completed dictation when no explicit Voice Return
  action was requested. Onboarding practice never adds automatic Return.
- Eligibility requires the current application's bundle identifier to normalize
  to `com.openai.codex`. Normalization trims surrounding whitespace and compares
  case-insensitively; prefix and suffix matches do not qualify.
- Eligible dictation uses clipboard paste without a trailing space, even when
  streaming cursor is enabled. Existing explicit actions, generic paste, and
  non-Codex streaming behavior retain their established semantics.
- A non-nil `requiredFrontmostBundleIdentifier` guards both text insertion and
  the optional post-paste action. Unknown focus or an invalid required identifier
  fails before clipboard mutation or event posting, including when no action is
  requested. A nil requirement preserves ordinary caller behavior.
- Cancellation is checked on entering the guarded-action service, before any
  clipboard write or event. After a successful paste, cancellation or losing
  the required application during the settling delay suppresses Return. The
  preexisting clipboard restore task still follows its ownership/change-count
  checks and the user's Keep dictation on clipboard preference.
- The service returns true only when the requested keystroke was posted. False
  after paste does not mean the text needs to be pasted again. Neither result
  proves that a remote application accepted or submitted a message.
- Focus/event failure after a guarded paste uses `postPasteActionSuppressed`,
  without a second paste or a claim that text was copied for recovery. A failed
  pre-paste focus check follows ordinary copy-for-manual-paste recovery. A
  cancelled insertion retains the coordinator's cancellation outcome.
- The application-wide guard cannot prove which Codex composer is focused.
  Users must keep the intended composer focused until submission.

## Non-stable details and compatibility

The 200 ms settling delay, UI copy, and diagnostic log wording are implementation
details. Changing the persisted key or default requires migration/release review;
changing guarded-effect or cancellation semantics requires this contract and its
tests to change together. No public CLI command is added. Settings telemetry is
the closed `codex_auto_submit` Boolean setting under the existing telemetry policy.

## Verification

`AppRuntimePreferencesTests` and `SettingsViewModelTests` cover defaults and
persistence. `DictationFlowCoordinatorTests`, `DictationFlowStateMachineTests`,
and `ClipboardServiceTests` cover eligibility, practice exclusion, guarded focus,
partial completion, cancellation, and clipboard restoration. Tests use injected
event posting; physical Cmd+V/Return delivery and the intended Codex composer
require separate native acceptance.
