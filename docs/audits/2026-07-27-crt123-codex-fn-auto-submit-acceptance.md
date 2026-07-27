# CRT-123 Codex Fn Auto-Submit Acceptance Record

> **Status:** executable source accepted; upstream publication pending
>
> **Date:** 2026-07-27
>
> **CRT:** CRT-123
>
> **Scope:** focused-composer bare-Fn dictation and guarded Codex auto-submit MVP

This document is the durable acceptance record for CRT-123. It binds the exact
accepted executable source, matching-toolchain CI, bounded owner-local canaries,
and proof limits without treating mutable local runtime state as a source
default or release guarantee.

## Purpose and accepted MVP

CRT-123 adds an opt-in workflow for dictating into an already-focused Codex
composer. A clean bare-Fn gesture captures speech, transcribes locally, pastes
the completed text, and may press Return only after the guarded Codex path
revalidates the frontmost application. The owner remains responsible for
keeping the intended composer focused. The MVP identifies the Codex application
by bundle identifier; it does not identify or route to a particular Codex task
or editor.

## Accepted executable source

| Identity | Exact value |
|---|---|
| Upstream base and merge-base | `408d1bcd0b488c2363bc2de9d5dc62933478d413` |
| Accepted executable tip | `db20aa82ec06e230f9e96781c1432f652ae3710d` |
| Accepted executable tree | `a07feb2c405ff92c3194c7c0bbd7e6d3f40d3648` |
| Base-to-tip full-index diff SHA-256 | `3d80b24f01c440268bde2af8a65ceb45f00b74ee4ee4164c47f900d89a42fa5b` |
| Executable candidate scope | 20 files; 1,660 insertions; 33 deletions |
| Source branch | `crt/123-codex-fn-auto-submit` |

The exact 20-file executable scope is:

- `README.md`
- `Sources/MacParakeet/App/DictationFlowCoordinator.swift`
- `Sources/MacParakeet/Hotkey/HotkeyManager.swift`
- `Sources/MacParakeet/Views/Settings/SettingsView.swift`
- `Sources/MacParakeetCore/AppRuntimePreferences.swift`
- `Sources/MacParakeetCore/DictationFlow/DictationFlowStateMachine.swift`
- `Sources/MacParakeetCore/Services/System/ClipboardService.swift`
- `Sources/MacParakeetCore/Services/System/README.md`
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`
- `Sources/MacParakeetViewModels/SettingsSearchIndex.swift`
- `Sources/MacParakeetViewModels/SettingsViewModel.swift`
- `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift`
- `Tests/MacParakeetTests/DictationFlow/DictationFlowCoordinatorTests.swift`
- `Tests/MacParakeetTests/DictationFlow/DictationFlowStateMachineTests.swift`
- `Tests/MacParakeetTests/Hotkey/HotkeyManagerTests.swift`
- `Tests/MacParakeetTests/Services/System/ClipboardServiceTests.swift`
- `Tests/MacParakeetTests/Services/System/MockClipboardService.swift`
- `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`
- `Tests/MacParakeetTests/ViewModels/TransformsViewModelTests.swift`
- `spec/02-features.md`

The ten-commit executable chain is:

| Order | Commit | Subject |
|---:|---|---|
| 1 | `fea94c0dfb68e628ef356be5baa6ac532ed38297` | CRT-123: add guarded Codex dictation submission |
| 2 | `e881af0ed5cb3be08318290975e1a096d2daaccd` | CRT-123: close guarded submit review gaps |
| 3 | `f0f676f31939425f5a71fe508e64c0b09956d1ba` | CRT-123: make guarded submit warning cause-neutral |
| 4 | `ae0348578b1bdd076128ff3c3d294312358fb4e8` | CRT-123: model suppressed submit separately |
| 5 | `205eef18335f0e0815f0fccccd1ea8edb92f9c1a` | CRT-123: make bare Fn observation passive |
| 6 | `2e3df02b925ab6293c2b4ad55afc36e88ed2deff` | CRT-123: reject contaminated passive Fn gestures |
| 7 | `14d86f71975be801ffc3b278cedfedf9cf4f9ea8` | CRT-123: invalidate contaminated Fn tap windows |
| 8 | `568130d4b22a2cf01397f556390c79baf442ea74` | CRT-123: cancel Fn recovery on Caps latch delta |
| 9 | `93d1a3ff0d36e307d25d535a81b05fefd21f3058` | CRT-123: invalidate pending Fn tap on keyUp |
| 10 | `db20aa82ec06e230f9e96781c1432f652ae3710d` | CRT-123: bind modifier fixtures to physical key code |

This acceptance record is a documentation-only follow-up atop that executable
tip. The validation below is parent executable evidence, not a fresh test run
against the documentation commit.

## Matching-toolchain validation

Private validation [run 30296607430](https://github.com/ctut/macparakeet-crt123-validation/actions/runs/30296607430),
[job 90079112460](https://github.com/ctut/macparakeet-crt123-validation/actions/runs/30296607430/job/90079112460),
passed at exact executable tip `db20aa82ec06e230f9e96781c1432f652ae3710d`.

| Gate | Evidence |
|---|---|
| Toolchain | Xcode 16.1 build 16B40; Apple Swift 6.0.2 |
| Build and contract gates | Release build, CLI contract smoke, release-bundle smoke, concurrency safety, and Swift 6 language mode passed |
| XCTest | 5,108 tests passed |
| Swift Testing | 17 tests passed |

## Durable source truth

- Codex auto-submit defaults **off**. Owner-local enablement does not change the
  source default.
- The built-in bare-Fn path is passive and non-consuming. Observed Fn and
  cancellation events pass through unchanged.
- Pre-held or delivered non-Fn input contaminates/cancels the pending gesture
  under the accepted contract. Duplicate and trailing events remain inert.
- Tap-disabled recovery detects still-held non-Fn input and a Caps Lock latch
  delta. A non-latching key pressed and released entirely during the blind
  interval is not observable after the fact.
- The accepted canary used local Parakeet v3 speech transcription.
- Auto-submit requires the frontmost bundle identifier to normalize exactly to
  `com.openai.codex` at the guarded checks.
- The destination guard is application-wide. It does not prove which Codex
  task, composer, or editor owns focus.

## Dated owner-local runtime evidence

The following is owner-observed, supersedable runtime evidence from 2026-07-27,
not a repository default or portable installation claim:

- An unsigned/ad-hoc development artifact was installed and running locally.
- The owner enabled Codex auto-submit and Instant Dictation for the accepted
  canaries. Both settings remain independent of the source default.
- **Real Codex/Forge canary:** one bare-Fn capture used local Parakeet v3
  transcription, produced one guarded paste and one automatic Return, and
  created exactly one observed Forge user turn.
- **TextEdit canary:** one capture produced one paste, no duplicate, no Return
  or newline, and no Codex or other submission.
- A later TextEdit canary also passed after an application restart with Instant
  Dictation disabled.

No transcript content is retained in this acceptance record.

## Monitored microphone observation

Before the restart, the owner intermittently observed Fn reporting no
microphone while the Settings Test Input still detected voice. Switching
microphones did not restore the Fn path. Restarting the application restored
operation, and the observation has not reproduced after restart with Instant
Dictation disabled.

This is a monitored runtime observation and proof gap. It is not a confirmed
fixed defect, does not establish a source correction, and is not evidence of a
silence-threshold problem. Further action requires a separately bounded,
reproducible diagnostic packet if the symptom recurs.

## Proof boundaries

- The owner-local artifact was unsigned/ad-hoc and not notarized. Incomplete
  resource-seal and Gatekeeper-rejection evidence prevents treating it as a
  distributable or release artifact.
- The canaries prove the required local permissions functioned for those
  bounded runs. They do not prove durable TCC state, fresh-machine behavior,
  Developer ID signing, notarization, or distribution readiness.
- The frontmost-bundle guard does not provide exact-task routing.
- Two successful application canaries do not generalize to arbitrary focus
  transitions, future application versions, future speech providers, or other
  runtime environments.
- Matching CI proves the named source and deterministic test contract. It does
  not substitute for signing, notarization, installation, or physical-runtime
  evidence.

## Follow-ups and exclusions

- The observed lexical rendering of the product name is a later recognition
  quality item. Route name/jargon work through the existing
  [Parakeet custom vocabulary plan](../../plans/active/2026-07-03-parakeet-custom-vocabulary.md),
  not through CRT-123 closure.
- Spoken rendering of inline text or code blocks is outside CRT-123 scope.
- Developer ID signing, notarization, and distribution are later publication
  and release gates.

## Publication state and next gate

At this record's source review point:

- no CRT-123 branch or pull request exists in the public upstream repository;
- the private validation mirror holds the accepted executable tip but is a
  standalone private repository, not an upstream pull-request head; and
- publication therefore requires either an authorized public fork or a
  maintainer-owned writable branch.

The next gate is canonical Harbor review of this one-file record and the
cumulative 21-file publication candidate. Push, pull-request creation, merge,
signing, notarization, installation, and release remain separate actions.

## Action accounting

- Executable/test/build/workflow/package/configuration delta in this follow-up:
  **zero**.
- Runtime, microphone, clipboard, keystroke, Codex-turn, CI-dispatch, and hosted
  publication actions in this follow-up: **none**.
- `agent_caused_failure: none`
