# Plan: Collapse AppSettingsObserverCoordinator's 12 observer triples into a table-driven registration

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 16e3f865f..HEAD -- Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift Tests/MacParakeetTests/App/AppSettingsObserverCoordinatorTests.swift Sources/MacParakeetCore/AppNotifications.swift`
> If any changed since this plan was written, compare the "Current state"
> excerpts against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (soft: do after the DX baseline so `scripts/dev/check.sh` exists)
- **Category**: tech-debt
- **Planned at**: commit `16e3f865f`, 2026-06-15

## Why this matters

`AppSettingsObserverCoordinator` registers 12 NotificationCenter observers using
a hand-rolled triple per observer: one stored `var …Observer: Any?` property, one
`addObserver` block in `startObserving()`, and one matching `removeObserver`
block in `stopObserving()`. That is ~200 lines of mechanical boilerplate where
adding or removing one observed setting means editing three places in lockstep,
and a dropped `removeObserver` is invisible at compile time. Collapsing the 10
"plain" channels (the ones that just call a stored callback) into one
table-driven loop removes the boilerplate and makes the next added setting a
single array row — with **no behavior change**. This is the lowest-risk enabler
of the larger Settings decomposition.

This plan deliberately keeps the *notification names* and the *poster side*
(`SettingsViewModel` `didSet` blocks) unchanged — unifying those into a single
keyed channel is a higher-risk follow-up noted at the end.

## Current state

`Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift` (247 lines).
Structure today:

- 12 injected `@escaping` closures stored as `let` (lines 9–20): `onOpenOnboarding`,
  `onOpenSettings(SettingsTab?)`, `onHotkeyTriggerChanged`,
  `onPushToTalkHotkeyTriggerChanged`, `onMeetingHotkeyTriggerChanged`,
  `onFileTranscriptionHotkeyTriggerChanged`, `onYouTubeTranscriptionHotkeyTriggerChanged`,
  `onAppearanceModeChanged`, `onMenuBarOnlyModeChanged`, `onShowIdlePillChanged`,
  `onInstantDictationChanged`, `onMicrophoneSelectionChanged`.
- 12 stored `private var …Observer: Any?` properties (lines 22–33).
- `startObserving()` (lines 65–188) — 12 `addObserver(forName:object:queue:)`
  blocks. 10 of them are identical except for the name + callback:
  ```swift
  hotkeyTriggerObserver = notificationCenter.addObserver(
      forName: .macParakeetHotkeyTriggerDidChange, object: nil, queue: .main
  ) { [weak self] _ in
      Task { @MainActor in self?.onHotkeyTriggerChanged() }
  }
  ```
  The 2 that differ: `onboardingObserver` (no payload) and `settingsObserver`
  (parses a `SettingsTab` from `notification.userInfo` via the static helper
  `settingsTab(from:)`, lines 190–195).
- `stopObserving()` (lines 197–246) — 12 `if let …Observer { removeObserver; = nil }` blocks.
- `nonisolated static let settingsTabUserInfoKey = "settingsTab"` (line 6) and
  `nonisolated private static func settingsTab(from:)` (lines 190–195) — keep both.

The 10 "plain" channels (each `{ [weak self] _ in Task { @MainActor in self?.onX() } }`):
`macParakeetHotkeyTriggerDidChange`, `…PushToTalkHotkeyTriggerDidChange`,
`…MeetingHotkeyTriggerDidChange`, `…FileTranscriptionHotkeyTriggerDidChange`,
`…YouTubeTranscriptionHotkeyTriggerDidChange`, `…AppearanceModeDidChange`,
`…MenuBarOnlyModeDidChange`, `…ShowIdlePillDidChange`, `…InstantDictationDidChange`,
`…MicrophoneSelectionDidChange`.

The notification names live in `Sources/MacParakeetCore/AppNotifications.swift`
(do not change them).

Existing test: `Tests/MacParakeetTests/App/AppSettingsObserverCoordinatorTests.swift`
— this is your safety net and your structural pattern. **Read it fully before
editing**; it constructs the coordinator with stub callbacks and posts
notifications to assert each fires.

The init signature (12 labeled closures) is called from
`Sources/MacParakeet/App/AppEnvironmentConfigurer.swift`. **The init signature
must not change** so that caller is untouched.

## Commands you will need

| Purpose            | Command                                                                                  | Expected           |
|--------------------|------------------------------------------------------------------------------------------|--------------------|
| Confirm single-observer ownership | `grep -rn "macParakeetHotkeyTriggerDidChange\|macParakeetMicrophoneSelectionDidChange\|macParakeetShowIdlePillDidChange\|macParakeetInstantDictationDidChange\|macParakeetAppearanceModeDidChange\|macParakeetMenuBarOnlyModeDidChange\|macParakeetMeetingHotkeyTriggerDidChange\|macParakeetFileTranscriptionHotkeyTriggerDidChange\|macParakeetYouTubeTranscriptionHotkeyTriggerDidChange\|macParakeetPushToTalkHotkeyTriggerDidChange" Sources --include=*.swift \| grep addObserver` | only matches inside `AppSettingsObserverCoordinator.swift` |
| Focused test       | `swift test --filter AppSettingsObserverCoordinator`                                     | all pass           |
| Build              | `swift build`                                                                            | exit 0             |
| Full tests         | `swift test`                                                                             | all pass           |

## Scope

**In scope** (the only files you should modify):
- `Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift`
- `Tests/MacParakeetTests/App/AppSettingsObserverCoordinatorTests.swift` (only to
  add coverage if a channel is currently untested — do not weaken existing assertions)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/MacParakeetCore/AppNotifications.swift` — names stay as-is.
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` — the poster side is a
  separate follow-up.
- `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift` — the init signature
  must remain identical, so this caller does not change.
- The two payload-carrying observers (`onboarding`, `settings`) — keep them as
  explicit blocks; only the 10 plain channels become table-driven.

## Git workflow

- Branch: `advisor/settings-observer-fanout-collapse` off `origin/main`.
- Commit style: concise subject + body, e.g.
  `Refactor: table-driven AppSettingsObserverCoordinator (no behavior change)`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Read the existing test and confirm channel coverage

Read `Tests/MacParakeetTests/App/AppSettingsObserverCoordinatorTests.swift` in
full. List which of the 12 channels it already asserts fire. If any of the 10
plain channels has no test, note it — you will add one in Step 4.

**Verify**: `swift test --filter AppSettingsObserverCoordinator` → all pass
(establish the green baseline before changing anything).

### Step 2: Confirm the 10 plain names are observed only here

Run the "Confirm single-observer ownership" command above.

**Verify**: every `addObserver` match for those 10 names is inside
`AppSettingsObserverCoordinator.swift`. If any plain name is observed by another
type, that name is NOT safe to assume single-owner — **STOP** (it isn't, per
this plan's assumption).

### Step 3: Refactor to table-driven registration

Replace the 12 `private var …Observer: Any?` properties with a single token
array, and the 10 plain `addObserver` blocks with one loop. Target shape:

```swift
private var observerTokens: [NSObjectProtocol] = []

func startObserving() {
    stopObserving()

    // Payload-carrying intents stay explicit.
    observerTokens.append(notificationCenter.addObserver(
        forName: .macParakeetOpenOnboarding, object: nil, queue: .main
    ) { [weak self] _ in
        Task { @MainActor in self?.onOpenOnboarding() }
    })
    observerTokens.append(notificationCenter.addObserver(
        forName: .macParakeetOpenSettings, object: nil, queue: .main
    ) { [weak self] notification in
        let tab = Self.settingsTab(from: notification)
        Task { @MainActor in self?.onOpenSettings(tab) }
    })

    // Plain "setting changed -> re-read" channels.
    let plainChannels: [(Notification.Name, () -> Void)] = [
        (.macParakeetHotkeyTriggerDidChange, onHotkeyTriggerChanged),
        (.macParakeetPushToTalkHotkeyTriggerDidChange, onPushToTalkHotkeyTriggerChanged),
        (.macParakeetMeetingHotkeyTriggerDidChange, onMeetingHotkeyTriggerChanged),
        (.macParakeetFileTranscriptionHotkeyTriggerDidChange, onFileTranscriptionHotkeyTriggerChanged),
        (.macParakeetYouTubeTranscriptionHotkeyTriggerDidChange, onYouTubeTranscriptionHotkeyTriggerChanged),
        (.macParakeetAppearanceModeDidChange, onAppearanceModeChanged),
        (.macParakeetMenuBarOnlyModeDidChange, onMenuBarOnlyModeChanged),
        (.macParakeetShowIdlePillDidChange, onShowIdlePillChanged),
        (.macParakeetInstantDictationDidChange, onInstantDictationChanged),
        (.macParakeetMicrophoneSelectionDidChange, onMicrophoneSelectionChanged),
    ]
    for (name, handler) in plainChannels {
        let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Preserve the original weak-self semantics: do not fire after the
            // coordinator is deallocated.
            guard self != nil else { return }
            Task { @MainActor in handler() }
        }
        observerTokens.append(token)
    }
}

func stopObserving() {
    for token in observerTokens {
        notificationCenter.removeObserver(token)
    }
    observerTokens.removeAll()
}
```

Keep: the 12 stored `let` callbacks, the init signature, `settingsTabUserInfoKey`,
and `settingsTab(from:)`. Delete: the 12 individual `…Observer: Any?` properties.

Notes:
- `addObserver(forName:object:queue:)` returns `NSObjectProtocol`; storing tokens
  as `[NSObjectProtocol]` is correct.
- The `guard self != nil else { return }` keeps the exact "don't invoke after
  dealloc" behavior the per-observer `self?.` calls had.

**Verify**: `swift build` → exit 0.

### Step 4: Run the existing test; add coverage for any untested plain channel

Run the focused test. If Step 1 found a plain channel with no assertion, add one
following the existing test's pattern (construct the coordinator with a flag-set
callback, `startObserving()`, post the notification, await, assert the flag).

**Verify**: `swift test --filter AppSettingsObserverCoordinator` → all pass,
including any channel you added.

### Step 5: Confirm line-count reduction and no stray properties

**Verify**:
- `grep -c "Observer: Any?" Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift` → `0`
- `grep -c "addObserver" Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift` → `3` (onboarding, settings, the one in the loop)
- `grep -c "removeObserver" Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift` → `1`
- The file is well under 247 lines (`wc -l` should be ~90–110).

## Test plan

- The existing `AppSettingsObserverCoordinatorTests.swift` is the regression net:
  every channel that fired before must still fire. All existing assertions must
  remain and pass unchanged.
- Add a test only for any plain channel that lacked one (Step 4). Model it on the
  existing tests in that file.
- Verification: `swift test --filter AppSettingsObserverCoordinator` → all pass
  (≥ the prior count of tests).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0.
- [ ] `swift test --filter AppSettingsObserverCoordinator` passes; test count ≥ baseline.
- [ ] `swift test` exits 0 (full suite).
- [ ] `grep -c "Observer: Any?" …/AppSettingsObserverCoordinator.swift` → 0.
- [ ] `addObserver` appears exactly 3 times; `removeObserver` exactly 1 time in that file.
- [ ] The init signature is byte-for-byte unchanged (`git diff` shows no change to the `init(` parameter list).
- [ ] `AppNotifications.swift`, `SettingsViewModel.swift`, `AppEnvironmentConfigurer.swift` are unmodified (`git status --porcelain` excludes them).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- Any of the 10 plain notification names is observed by a type other than
  `AppSettingsObserverCoordinator` (Step 2) — the single-owner assumption is false.
- The existing test asserts on the *internal observer properties* (not just
  behavior) and so breaks structurally — report; do not delete the assertion.
- `swift build` fails with a Sendable/concurrency error on the `plainChannels`
  closures that you cannot resolve in one attempt (the stored callbacks are
  `@escaping () -> Void`; if Swift 6 mode complains about capturing them in a
  `@Sendable` observer block, report rather than changing the callback types).
- The init signature would need to change to make it compile.

## Maintenance notes

- **Deferred higher-risk follow-up:** unify the *poster* side — the
  `SettingsViewModel` `didSet` blocks that triple up `defaults.set` + `post` +
  `Telemetry.send`, and the 10 distinct names in `AppNotifications.swift` — into
  a single `.macParakeetSettingDidChange` notification carrying a `SettingChange`
  enum in `userInfo`. That touches the poster side and is MED risk; do it only
  with characterization tests and as its own plan. This plan intentionally stops
  at the consumer side.
- A reviewer should confirm the refactor is behavior-preserving: same channels,
  same weak-self no-fire-after-dealloc semantics, same init signature.
