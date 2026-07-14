# Microphone Routing from First Principles

> Research and decision proposal for [issue #796](https://github.com/moona3k/macparakeet/issues/796), checked against `origin/main` at `f27d6eabc098351ba50e37c177869c62e9c16484` on 2026-07-14.
>
> Status: reviewed and accepted by Claude Fable. Change 1 is implemented with
> this decision record; the stricter named-microphone contract remains a
> deliberately separate Change 2.

## Decision in one sentence

Remove the **Use Mac mic with Bluetooth headphones** toggle and the
output-dependent routing policy behind it. Make the microphone picker tell the
truth instead: **System Default** follows macOS through AVAudioEngine's implicit
default route, while a named microphone means “use this device or show a clear
failure.” macOS, not MacParakeet, remains responsible for output selection.

The urgent rollback and the stricter picker contract should be implemented as
two reviewable changes. The first removes the regression-prone Bluetooth policy
without expanding scope. The second removes the older silent fallbacks that
currently prevent named microphone selection from being fully deterministic.

## Bottom line

The underlying Bluetooth problem is real. The shipped solution was the wrong
abstraction.

Apple documents that using a Bluetooth headset's microphone moves the headset
from high-quality listening into a lower-quality bidirectional mode. It also
documents separate macOS input and output selections. That establishes the
product boundary: MacParakeet chooses or follows a **microphone input**;
macOS owns the **audio output**. [Apple: reduced Bluetooth sound
quality](https://support.apple.com/en-ca/102217), [Apple: Sound settings on
Mac](https://support.apple.com/guide/mac-help/change-sound-settings-on-mac-mchl9777ee30/mac)

The current toggle crosses that boundary. When the user chose **System
Default**, it made MacParakeet inspect the output transport and sometimes pin a
different input route explicitly. The same label can therefore mean two
different routing mechanisms depending on a transient, unrelated output state.
That is difficult for a user to predict, difficult for support to explain, and
unsafe on hardware for which explicit Core Audio pinning is less compatible
than AVAudioEngine's implicit default path.

The project had already learned this lesson twice:

1. [Issue #218](https://github.com/moona3k/macparakeet/issues/218) found that an
   OBSBOT Meet 2 worked as the implicit system default but failed when the same
   default device was explicitly set. [PR #220](https://github.com/moona3k/macparakeet/pull/220)
   restored the implicit path; the reporter confirmed the fix.
2. [PR #411](https://github.com/moona3k/macparakeet/pull/411) later put an
   explicit default-device attempt before the implicit path to address
   Bluetooth call-mode audio. [Issue #421](https://github.com/moona3k/macparakeet/issues/421)
   reported intermittent no-audio behavior in that release. [PR #422](https://github.com/moona3k/macparakeet/pull/422)
   reverted the pin, and the reporter confirmed the regression disappeared in
   v0.6.18.

[PR #613](https://github.com/moona3k/macparakeet/pull/613) reintroduced the
same risky operation under a more elaborate condition: when output is Bluetooth
or cannot be resolved, it can replace an implicit system-default route with an
explicit built-in-microphone route. The new preference defaults on. That policy
was intended to avoid the real A2DP-to-HFP/SCO transition race from
[issues #481](https://github.com/moona3k/macparakeet/issues/481),
[#541](https://github.com/moona3k/macparakeet/issues/541), and
[#409](https://github.com/moona3k/macparakeet/issues/409), but it invalidated the
earlier compatibility invariant.

The failure was not that nobody considered edge cases. The PR added many branch
tests and received several code reviews. The failure was upstream of those
details: the product contract was not written down first, and the hardware
invariant learned from #218/#421 was not treated as a hard constraint. The
reviews proved the policy's branches matched the implementation; they did not
prove the policy was the right model.

## What issue #796 establishes—and what it does not

The reporter is on v0.7.2 (`afc2eff9dd0c`) with an M5 Pro and macOS 26.5.1.
Their screenshot shows:

- MacParakeet is set to **System Default**.
- The UI resolves that default to **MacBook Pro Microphone**.
- Input Test fails and meeting capture reports **Microphone Unavailable**.
- Downgrading to v0.6.24 fixes the problem.

Sources: [issue #796](https://github.com/moona3k/macparakeet/issues/796),
[screenshot 1](https://raw.githubusercontent.com/moona3k/macparakeet/main/screenshots/1783993183563-1-Screen-Shot-2026-07-14-at-11.38.19-2x.png),
[screenshot 2](https://raw.githubusercontent.com/moona3k/macparakeet/main/screenshots/1783993185510-2-Screen-Shot-2026-07-14-at-11.39.11-2x.png).

Between v0.6.24 and v0.7.2, PR #613 is the change that alters the device-attempt
chain for exactly this state. When the preference is on, the resolved default
equals the built-in microphone, and Bluetooth output is present or unresolved,
the reviewed builder removed the implicit default attempt and returned only an
explicit built-in attempt. Change 1 deletes that policy and preserves the
invariant in
[`testSystemDefaultRemainsImplicitWhenBuiltInIsDefault`](../../Tests/MacParakeetTests/Audio/MicrophoneCaptureTests.swift).

There is also direct field evidence for the exact compatibility hazard. The
diagnostic log attached to [issue #787](https://github.com/moona3k/macparakeet/issues/787)
comes from an M1 Max running macOS 26.5.1 and spans v0.7.0/v0.7.1. On four
starts after PR #613, it records:

```text
mic_attempts_bluetooth_output_policy ... outcome=fired reason=built_in_promoted
shared_mic_engine_input_device_start_failed source=built_in ... error=-10868
shared_mic_engine_input_device_started source=system_default ...
meeting_mic_first_buffer ...
```

The explicit built-in attempt fails, then the implicit System Default attempt
starts and delivers a real buffer. In that log the system default is Bluetooth,
so the builder retains the implicit fallback. In the #796-shaped branch—where
the system default and built-in device IDs are equal—the builder deletes that
working fallback. [Issue #787 diagnostic
log](https://raw.githubusercontent.com/moona3k/macparakeet/main/diagnostics/1783849190966-dictation-audio.log)

This is stronger than extrapolating from #218's USB camera mic: the current
policy's own explicit built-in attempt is already failing in a shipped build.
It does not prove that #796's reporter saw the same error, but it proves the
proposed mechanism exists in the field.

This makes PR #613 the strongest current root-cause candidate:

```text
v0.6.24
System Default + MacBook mic
    -> AVAudioEngine implicit system default
    -> works for reporter

v0.7.2, preference on, Bluetooth output/routing uncertainty
System Default + MacBook mic
    -> explicit Core Audio built-in pin
    -> Input Test fails on reporter's M5 Pro
```

This is a **strong causal inference, not a completed hardware diagnosis**. The
issue has no uploaded `dictation-audio.log`, and its screenshots do not show the
output route or stored preference value. An A/B test with the toggle off, or a
log containing `mic_attempts_bluetooth_output_policy`, would confirm whether the
policy fired. The log should also be checked for `-10868`, although that Core
Audio error is not exclusive to macOS 26.5: an earlier telemetry audit found it
across several macOS/hardware combinations when explicit default routing was
present, then saw it disappear after the implicit-default fix. See
[`2026-05-05-telemetry-error-count-verification.md`](../audits/2026-05-05-telemetry-error-count-verification.md).

Other post-v0.6.24 audio changes add diagnostics, meeting health presentation,
and watchdog correctness, but do not replace the core input attempt ordering in
the same way. Those visibility changes are a partial confound: v0.7.2 may report
a route failure more clearly than v0.6.24 did. The user-reported downgrade
success argues against a pure presentation change, but only a reporter log or
A/B build can close that distinction.

The architecture decision does not need to wait for that confirmation. Even if
#796 has an additional hardware cause, making **System Default** secretly
output-dependent remains an invalid and historically regression-prone contract.

## The first-principles model

### 1. Input and output are separate decisions

MacParakeet records microphone input. It does not own a general audio-output
picker. The user can choose output in macOS Control Center or System Settings;
Apple exposes input and output as separate selections. [Apple: Sound
settings](https://support.apple.com/guide/mac-help/change-sound-settings-on-mac-mchl9777ee30/mac)

Therefore the support instruction is not “choose another output in
MacParakeet.” It is:

- choose the desired **output** in macOS;
- choose or follow the desired **microphone input** in MacParakeet;
- use **Test Input** to verify the actual capture path before dictating or
  recording.

### 2. A choice should have one stable meaning

The proposed contract is:

| User choice | Stable meaning | Failure behavior |
|---|---|---|
| **System Default** | Do not set `kAudioOutputUnitProperty_CurrentDevice`; let AVAudioEngine follow the current macOS input route. | If capture cannot start or yields no usable input, fail visibly and suggest selecting a named mic. |
| **MacBook Pro Microphone** or another named mic | Explicitly pin that exact input device. | If unavailable or unusable, fail visibly; do not silently record from another microphone. |
| Named Bluetooth headset mic | Honor the explicit choice. | Warn that using the headset mic can reduce Bluetooth playback quality; do not override the choice. |
| Audio output | Controlled by macOS, outside this picker. | Link or direct the user to macOS Sound settings when relevant. |

Apple's public documentation describes
`kAudioOutputUnitProperty_CurrentDevice` as a read/write audio-device ID on the
I/O audio unit. MacParakeet's implicit path deliberately avoids writing it;
the explicit path calls `AudioDeviceManager.setInputDevice`. [Apple developer
documentation](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice),
[`MicrophoneEnginePlatform.swift`](../../Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift),
[`AudioDeviceManager.swift`](../../Sources/MacParakeetCore/Audio/AudioDeviceManager.swift).

### 3. “Deterministic” means an honest contract and visible failure

No app can guarantee that every Core Audio device, Bluetooth transition, or
driver state will work. A deterministic recovery model does not mean “this
route can never fail.” It means:

- the same UI choice always asks Core Audio to do the same thing;
- MacParakeet never silently substitutes a different microphone;
- Input Test tells the user whether that choice actually works;
- the error tells them the next concrete choice to try.

This is also a privacy contract, not only a routing preference. If somebody
selects a headset mic and walks away from the laptop, silently falling back to
the built-in mic records a different physical space from the one they chose.
Reliable capture does not justify an undisclosed microphone substitution.

That yields two complementary recovery paths without another feature toggle:

1. If a named device's explicit pin fails, choose **System Default** and let
   macOS/AVAudioEngine route it implicitly. This is the #218 and likely #796
   compatibility path.
2. If **System Default** moves to a Bluetooth mic or causes call-mode behavior,
   explicitly choose **MacBook Pro Microphone** in MacParakeet. The #481 report
   says this was quick and reliable on the affected setup.

This is better than a hidden “resilience” policy because the user can observe,
test, and explain the state.

### 4. Mid-session behavior follows the same contract

The selection must remain meaningful after capture starts:

- **System Default** is allowed to follow macOS when the default input changes
  mid-session; that is the choice's advertised meaning.
- A **named microphone** is retried as that same device during a configuration
  change. If it disconnects or remains unusable, MacParakeet must not switch to
  a different microphone silently.
- For dictation, stop the capture and show the actionable microphone error.
- For a meeting, keep any healthy system-audio stream and durable artifacts,
  mark the microphone track unavailable, and show a prominent in-recording
  health alert. Do not silently begin recording room audio from the built-in
  mic. A later explicit “choose replacement” recovery flow could be designed,
  but automatic invisible failover is outside this contract.

This chooses trust over seamlessness for an irreversible recording. It also
keeps the rule explainable: only **System Default** authorizes device following.

## Why the current picker is not fully deterministic yet

Removing the Bluetooth toggle fixes the newest policy problem, but it does not
finish the first-principles model by itself.

The baseline attempt chain is currently:

```text
named selected mic (explicit, if it resolves)
    -> System Default (implicit)
    -> built-in mic (explicit, if distinct)
```

The platform advances only when the explicit setter fails synchronously or
`AVAudioEngine.start()` throws. Once an attempt starts, it is recorded as
successful before the first microphone buffer is known to be usable. A route
that starts but produces no buffers or digital silence therefore does not
advance to the next attempt. See
[`configureAndStartLocked`](../../Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift)
and the first-buffer handling described in
[`Audio/README.md`](../../Sources/MacParakeetCore/Audio/README.md).

The Settings UI also explicitly promises silent substitution when a saved mic
is missing: “Selected microphone is unavailable. MacParakeet will use System
Default until it returns.” See
[`selectedMicrophoneStatusText`](../../Sources/MacParakeetViewModels/SettingsViewModel.swift)
and its
[`SettingsViewModelTests`](../../Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift).

Consequences:

- a named selection is currently a preference, not a guarantee;
- the app may capture from a physically different microphone than the user
  selected;
- fallback cannot rescue the important “engine started but audio never became
  healthy” class anyway;
- the extra branches provide less resilience than their complexity suggests.

The clean endpoint is one attempt per explicit user intent:

```text
System Default -> [implicit system default]
Named mic      -> [explicit named mic]
Missing named mic -> typed, visible unavailable-device error
```

This stricter change is valuable for trust and predictability, but it is broader
than reverting PR #613 and should not be smuggled into an urgent #796 fix.

## Why the Bluetooth toggle should be removed

The toggle is not a useful escape hatch once the microphone picker is honest.
Everything it attempts to express is already represented more directly:

- Want to keep Bluetooth headphones as output while recording from the Mac?
  Select **MacBook Pro Microphone** as the input.
- Want to use the headset microphone while away from the laptop? Select the
  headset microphone explicitly.
- Want applications to follow the macOS input choice? Select **System
  Default**.

The existing toggle is harder to reason about because its title describes one
input, its condition depends on another device's output transport, and its
effect changes based on whether the selected/default devices resolve during
route churn. It also defaults on, so users inherit behavior they never chose.

It has multiplied the feature surface across:

- Settings UI and `SettingsViewModel` persistence/telemetry;
- `AppRuntimePreferences`;
- `AppEnvironment` routing injection;
- `meetingInputDeviceAttempts` and extensive policy branches;
- CLI `config get|set|list` and machine-readable `spec --json` output;
- CLI changelog/testing docs and unit tests;
- Audio subsystem documentation and diagnostic events.

Relevant sources:
[`SettingsView.swift`](../../Sources/MacParakeet/Views/Settings/SettingsView.swift),
[`SettingsViewModel.swift`](../../Sources/MacParakeetViewModels/SettingsViewModel.swift),
[`AppRuntimePreferences.swift`](../../Sources/MacParakeetCore/AppRuntimePreferences.swift),
[`AppEnvironment.swift`](../../Sources/MacParakeet/App/AppEnvironment.swift),
[`ConfigCommand.swift`](../../Sources/CLI/Commands/ConfigCommand.swift),
[`SpecCommand.swift`](../../Sources/CLI/Commands/SpecCommand.swift), and
[`CLI/CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md).

A preference that controls a valid, durable user goal can justify this cost.
This one controls an implementation workaround that conflicts with the primary
input picker. It should be deleted rather than renamed or hidden.

### Accepted Bluetooth behavior change

Removal is not behavior-neutral. Today the default-on policy automatically
keeps many Bluetooth-output users on the Mac mic. After removal, **System
Default** will follow macOS again. If macOS's default input is the headset—or if
its implicit route moves there—opening the mic can put Bluetooth playback into
the lower-quality bidirectional mode described by Apple. That is the original
#409/#541-shaped behavior.

This is an accepted trade: the app stops making a hidden choice and the user
gets a deterministic remedy—select **MacBook Pro Microphone** explicitly. The
release notes and Bluetooth troubleshooting copy must state that remedy
plainly. Do not replace the deleted setting with another automatic policy or
modal; the existing picker and Input Test are the control surface.

## What should remain

Removing the output-dependent input policy does **not** mean deleting every
Bluetooth-aware behavior.

Keep:

- the microphone picker and Input Test;
- the implicit System Default route introduced by PR #220;
- explicit named-microphone routing;
- first-buffer readiness, silence detection, and privacy-safe diagnostics;
- Core Audio configuration-change recovery;
- suppression of **idle Instant Dictation warm capture** when the resolved
  input is Bluetooth;
- the warm-capture refresh debounce that coalesces Bluetooth/default-input
  route flaps.

That last behavior solves a different, tightly bounded problem from #481: an
idle warm subscriber should not hold a Bluetooth mic open and keep playback in
the lower-quality profile. It does not change the active input chosen for a
user-started recording. The distinction is documented in
[`Audio/README.md`](../../Sources/MacParakeetCore/Audio/README.md) and
implemented through the warm-capture input provider in
[`AppEnvironment.swift`](../../Sources/MacParakeet/App/AppEnvironment.swift).

The warm-hold check is currently coupled to the active route builder: it
classifies `attemptsBuilder().first?.deviceID`. Removing the policy changes the
first attempt from pinned built-in back to the resolved implicit default, so an
actual Bluetooth default input will once again suppress the idle hold. That is
correct, but it needs explicit coverage. When named selection later becomes
strict, an unavailable named device must make the warm-hold check fail closed;
it must not classify a System Default or built-in device from the residual
fallback chain as though that were the unavailable named selection. Prefer
decoupling warm-hold classification from the fallback array so the two
contracts cannot drift together again.

Remove:

- the **Use Mac mic with Bluetooth headphones** Settings row;
- `preferBuiltInMicWhenBluetoothOutput` and its stored default;
- `prefer-built-in-mic-bluetooth-output` from CLI configuration and
  machine-readable spec output;
- the corresponding setting telemetry name;
- output-transport-dependent reordering/removal in
  `meetingInputDeviceAttempts`;
- policy-specific docs, diagnostics, and tests.

`AudioDeviceManager` output-transport helpers should be retained only if another
active behavior uses them after the removal. Otherwise remove the dead helpers
and their tests too.

## Change 1 implementation outcome

The first change follows the boundary above:

- `meetingInputDeviceAttempts` is again only selected explicit → implicit
  System Default → distinct built-in fallback;
- the Settings row, runtime preference, setting telemetry, policy diagnostics,
  and output-transport helpers are removed;
- the shipped CLI configuration key is removed from `config` and `spec --json`;
  its changelog entry marks this as a breaking contract change that must ship
  with the next CLI major version;
- old `preferBuiltInMicWhenBluetoothOutput` UserDefaults values are inert—the
  application no longer reads the key;
- idle Instant Dictation warm-capture suppression and its input-based Bluetooth
  detection remain, with focused wiring coverage; and
- the stricter named-microphone contract below is intentionally not included.

## Recommended implementation sequence

### Change 1: remove the Bluetooth policy and toggle

Goal: restore the v0.6.24 routing invariant with the narrowest reviewable diff.

1. Delete the UI preference, persistence, telemetry, CLI key, spec entry,
   policy diagnostics, and their tests/docs.
2. Simplify `meetingInputDeviceAttempts` back to the pre-PR-613 base chain:
   selected explicit attempt, implicit System Default, built-in fallback.
3. Add an invariant test: with **System Default** selected, the first attempt is
   implicit regardless of Bluetooth output state; the explicit setter may be
   called only if that implicit attempt fails and the existing built-in fallback
   is distinct and tried. Cover both a distinct built-in fallback and the
   default-equals-built-in case, where deduplication must leave one implicit
   attempt and no explicit setter call.
4. Add a migration assertion that an old stored preference is ignored. The
   stale UserDefaults value can be removed opportunistically; it must not
   influence routing.
5. Update CLI changelog/docs to mark the configuration key removed. Because the
   CLI surface is public, choose and document whether old `get/set` calls return
   “unknown key” immediately or remain as a short-lived no-op compatibility
   alias. Prefer explicit removal unless a known automation consumer exists.
6. Ask the #796 reporter to verify the build on the same M5 Pro setup. Also run
   the #409/#481 Bluetooth scenarios by explicitly selecting the Mac mic, which
   is now the supported solution.
7. Add a focused warm-capture test proving that System Default plus a Bluetooth
   default input suppresses the idle hold after policy removal, while a named
   non-Bluetooth mic does not.

This change removes the bad abstraction without simultaneously redefining all
fallback behavior.

### Change 2: make microphone selection authoritative

Goal: complete the deterministic mental model.

1. Before deleting the long-standing implicit-default-to-built-in fallback,
   inspect existing opt-in diagnostics and any privacy-safe aggregate signal to
   determine whether it materially rescues starts. The current uploaded log
   corpus contains no `source=built_in` successful starts, but that small,
   issue-biased sample is not population evidence.
2. Change route resolution so **System Default** yields exactly one implicit
   attempt and a named microphone yields exactly one explicit attempt.
3. Do not let an unavailable named selection collapse into an empty attempt
   list: the current platform treats an empty list as “use whatever AVAudioEngine
   picks.” Return a typed unavailable-selection error instead.
4. Remove “will use System Default until it returns” copy and surface an
   actionable error: reconnect the selected mic, choose System Default, or
   choose another mic.
5. Make Input Test report both success and the effective route/device. A green
   test should answer “what did MacParakeet actually hear?”
6. Implement the mid-session contract above: retry the same named device, keep
   healthy meeting system audio/artifacts if it fails, and surface microphone
   loss without silent substitution.
7. Make the warm-hold classifier fail closed for an unavailable named mic and
   test that it does not classify a residual System Default/built-in fallback as
   the selected input.
8. Consider a concise warning beside an explicitly selected Bluetooth mic:
   playback quality may drop while the mic is active. This is explanatory copy,
   not another preference.

This change should have its own focused tests and Bluetooth/USB/built-in
hardware matrix because it deliberately removes fallback behavior.

## Acceptance matrix

| Scenario | Expected route after Change 1 | Endpoint after Change 2 |
|---|---|---|
| System Default, Mac input, Bluetooth output | Implicit System Default first; output is not queried for input policy. | Implicit System Default only. |
| System Default, Bluetooth input/output | Implicit System Default first; Bluetooth may enter bidirectional mode because the user chose to follow macOS. | Same, with explanatory troubleshooting if Input Test fails. |
| Named Mac mic, Bluetooth output | Explicit named Mac mic first. | Explicit named Mac mic only. |
| Named AirPods mic | Explicit AirPods mic first. | Explicit AirPods mic only, with playback-quality warning. |
| Named USB mic disconnected | Existing implicit-default fallback during Change 1. | Visible unavailable-device error; no silent substitution. |
| Named mic disconnects during a meeting | Existing recovery may walk the fallback chain. | Retry that mic; if it remains unavailable, preserve system audio/artifacts and show mic-track failure without switching microphones. |
| Instant Dictation idle with Bluetooth input | Warm hold remains suppressed. | Unchanged. |
| Mac mini with no built-in mic | Implicit System Default remains available. | System Default or an available named device; no invented built-in fallback. |

## Verification required before shipping

Automated:

- focused routing tests for implicit versus explicit setter behavior;
- warm-hold classification tests independent of active-route fallback ordering;
- Settings persistence/status tests;
- CLI config/spec contract tests;
- `git diff --check`;
- full `swift test` once as the final code-change gate.

Hardware:

- #796 reporter's M5 Pro/macOS 26.5.1 setup;
- MacBook with AirPods and media playing:
  - System Default follows macOS;
  - explicitly selected Mac mic preserves high-quality headphone output;
  - explicitly selected AirPods mic works with the expected quality tradeoff;
- USB/camera mic represented by #218 (OBSBOT Meet 2, preferably on a Mac mini);
- repeated connect/disconnect and default-route changes from #421/#481;
- Input Test, dictation, and meeting microphone capture, all of which share the
  process-wide microphone engine.

The test must verify first usable buffers and non-silent input, not merely that
`AVAudioEngine.start()` returned. The current platform treats successful engine
start as a successful route attempt before capture health is known.

## Root-cause statement for future work

The defensible statement today is:

> Issue #796 is strongly consistent with PR #613 converting the reporter's
> working implicit System Default route into an explicit built-in-device pin
> when Bluetooth-output avoidance fires. The #787 field log independently
> demonstrates that this policy's explicit built-in attempt can fail with
> Core Audio `-10868` while the following implicit System Default attempt
> succeeds and delivers buffers. In #796's built-in-is-default branch, the
> policy removes that working fallback. A reporter log or toggle-off A/B test
> is still needed to prove that #796 took this exact runtime branch.
> Independently of that final confirmation, the policy is an invalid product
> abstraction because it makes an input choice depend invisibly on output
> state.

The tempting one-line change—stop treating “default input equals built-in” as a
reason to fire the policy—would likely avoid the exact #796-shaped branch. It
would not fix the product model, remove the confusing toggle, eliminate other
explicit-pin branches, or make named selection deterministic. It is suitable
as an emergency diagnostic patch, not the final design.

## Primary sources

- [Issue #218: explicit System Default regression](https://github.com/moona3k/macparakeet/issues/218)
- [PR #220: restore implicit System Default](https://github.com/moona3k/macparakeet/pull/220)
- [Issue #409: Bluetooth output enters call mode despite Mac input default](https://github.com/moona3k/macparakeet/issues/409)
- [PR #411: pin resolved System Default before implicit fallback](https://github.com/moona3k/macparakeet/pull/411)
- [Issue #421: v0.6.17 intermittent no-audio regression](https://github.com/moona3k/macparakeet/issues/421)
- [PR #422: revert System Default pinning](https://github.com/moona3k/macparakeet/pull/422)
- [Issue #481: AirPods route transitions and explicit Mac-mic workaround](https://github.com/moona3k/macparakeet/issues/481)
- [Issue #541: Bluetooth transition/silent-capture diagnostic report](https://github.com/moona3k/macparakeet/issues/541)
- [PR #613: output-dependent built-in-mic policy and toggle](https://github.com/moona3k/macparakeet/pull/613)
- [Issue #787 and its field log: explicit built-in fails while implicit default succeeds](https://github.com/moona3k/macparakeet/issues/787)
- [Issue #796: v0.7.2 System Default failure, v0.6.24 works](https://github.com/moona3k/macparakeet/issues/796)
- [`-10868` telemetry audit across app/OS versions](../audits/2026-05-05-telemetry-error-count-verification.md)
- [Apple: Bluetooth microphone reduces headphone sound quality](https://support.apple.com/en-ca/102217)
- [Apple: change input and output in macOS Sound settings](https://support.apple.com/guide/mac-help/change-sound-settings-on-mac-mchl9777ee30/mac)
- [Apple: `kAudioOutputUnitProperty_CurrentDevice`](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice)

## Fable review

Claude Fable reviewed the draft and governing source files read-only. Its direct
verdict was to approve the decision and staging: remove the policy/toggle first,
then make named selection strict in a separate change.

The review identified four material gaps now incorporated above:

1. Define strict-selection behavior when a named device disappears during an
   active meeting, not only at startup.
2. State the accepted regression for users who currently rely on automatic
   Bluetooth HFP avoidance and document explicit Mac-mic selection as the
   supported remedy.
3. Cover the hidden coupling between `warmCaptureInputIsBluetooth` and the first
   device attempt during both changes.
4. Measure whether the older built-in fallback materially rescues starts before
   deleting it in Change 2.

Fable also raised `-10868` on macOS 26.5 as a possible competing contributor.
Primary-source follow-up found a more precise result: the error historically
occurred across several OS/hardware combinations, and the current #787 log
directly records PR #613's explicit built-in attempt failing with `-10868`
before the implicit route succeeds. The document therefore treats the OS and
device interaction as unresolved, but not as an alternative to the routing
mechanism.

Fable's session could read the checkout but was denied Bash/GitHub access. The
issue/PR history, reporter confirmations, version diff, and #787 diagnostic log
were independently rechecked with live `gh`, `git`, and repository sources
before this revision.

A second Fable pass read the revised document and the local source/log evidence.
It found no correctness or decision-blocking issue and returned **Accept** on
the recommendation and two-change staging. Its three remaining wording nits—
warm-hold residual fallback classification, built-in deduplication in the Change
1 invariant test, and the #787 version span—are corrected in this version.
