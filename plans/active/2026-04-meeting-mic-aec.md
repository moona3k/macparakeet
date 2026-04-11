# Meeting Recording — Mic Acoustic Echo Cancellation

> Status: **ACTIVE**
> Date: 2026-04-10
> Related ADRs: `spec/adr/014-meeting-recording.md`, `spec/adr/015-concurrent-dictation-meeting.md`
> Related spec: `spec/05-audio-pipeline.md`
> Related files:
> - `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`
> - `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`
> - `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`

## Problem

In a Zoom/Meet/Teams call running over **speakers**, the meeting transcript mis-attributes the remote speaker's words to "Me".

Repro: start a meeting recording while on a Zoom call with the system output going to built-in speakers. Transcript shows alternating "Others"/"Me" segments where the "Me" fragments are garbled partial words that came from the remote speaker, not from the user.

## Root cause

The meeting pipeline captures two **fully independent** streams and labels speakers purely by source:

1. `MicrophoneCapture` taps `AVAudioEngine.inputNode` with `format: nil` — **raw** mic audio. No AEC, no NS, no AGC. (`MicrophoneCapture.swift:83`)
2. `SystemAudioTap` — Core Audio Taps on the default output device. Clean copy of other apps' output.

`AudioSource.microphone` → "Me", `AudioSource.system` → "Others". No diarization, no cross-stream suppression. (`MeetingRecordingService.handleCaptureEvent` at `MeetingRecordingService.swift:242-280`.)

When the user is on speakers, the remote talker is played by Zoom → picked up cleanly by `SystemAudioTap` (correctly labeled Others) **and** leaks acoustically into the mic → picked up by `MicrophoneCapture` → Parakeet squeezes a couple of garbled words out of each 5s chunk → assembler interleaves them with the clean system transcription by timestamp → phantom "Me" fragments.

Grep confirms **no `setVoiceProcessingEnabled` anywhere in the codebase**. There is no echo cancellation today.

## How other apps handle this

- **Granola / Fathom / Otter / Tactiq** use Apple's Voice Processing I/O (VPIO) audio unit on the mic capture path. On macOS, enabling VPIO attaches AEC, noise suppression, and AGC, using the default output device mix as the reference signal — so it cancels *any* app's output (including Zoom) out of the mic input. Granola additionally surfaces a "use headphones" tip in onboarding.
- **Zoom/Teams/Meet** do the same thing inside their own capture path.
- Headphones eliminate the problem at the acoustic source, which is why every meeting-notes app recommends them.

MacParakeet should do the same: enable VPIO on the meeting mic engine, plus a light defense-in-depth check and a one-line UI hint.

## Objective

Eliminate spurious "Me" attributions caused by system-audio bleeding into the microphone during meeting recording, without degrading the dictation mic path.

## Scope

### In scope

- Enable Apple's Voice Processing I/O (VPIO) on the **meeting-recording** microphone engine only.
- Add a cross-stream energy gate in `MeetingRecordingService` that suppresses mic chunks that are residual echo of concurrent system audio.
- Add a small "Use headphones for cleanest separation" hint on the meeting panel / first-meeting affordance.
- Unit tests for the plumbing (init-arg wiring, suppression decision).
- Manual validation on a real Zoom call over speakers.

### Out of scope

- Changes to the dictation mic path. Dictation keeps raw capture (VPIO's AGC/NS degrade single-speaker Parakeet quality and are unnecessary).
- Real speaker diarization on the mic stream (FluidAudio Sortformer for in-room second speaker). Revisit after AEC ships.
- Transcript-fragmentation UX in `MeetingTranscriptAssembler` (adjacent-word merging). Once AEC removes the phantom "Me" words, the fragmentation largely disappears; revisit only if it doesn't.
- ML-based echo suppression (Krisp-style). VPIO is sufficient for v0.6.

### Invariants (must not change)

- Dictation mic capture remains raw (no VPIO).
- ADR-015 concurrent dictation + meeting still works. Each flow owns its own `AVAudioEngine`; enabling VPIO on meeting must not affect the dictation engine.
- `MeetingAudioCapturing` protocol shape is unchanged — no downstream changes in ViewModels/UI.
- File transcription (no mic) is untouched.
- `swift test` stays green.

## Design

### 1. Opt-in VPIO on `MicrophoneCapture`

Add a construction-time flag. Keeping it at init time (not on `start`) makes it obvious at the call site which engine is echo-cancelled and matches the one-shot nature of the setting.

```swift
// MicrophoneCapture.swift
public init(enableVoiceProcessing: Bool = false) {
    self.enableVoiceProcessing = enableVoiceProcessing
}
```

Inside `start(handler:)`, **before** `installTap(onBus:...)` and **before** `audioEngine.start()`:

```swift
if enableVoiceProcessing {
    do {
        try catchingObjCException {
            try inputNode.setVoiceProcessingEnabled(true)
        }
    } catch {
        logger.warning("Voice processing unavailable, falling back to raw capture: \(error.localizedDescription, privacy: .public)")
        // Do NOT fail the session — AEC is best-effort.
    }
}
```

Notes:
- `setVoiceProcessingEnabled(_:)` must be called before the node is used / the engine is started. Our current flow queries `outputFormat(forBus: 0)` before this call — that read should stay but we must ensure format queries after enabling VPIO pick up the new (potentially different) format. The safest order is: enable VPIO → query format → install tap with `format: nil` → start engine. Tap installation already uses `format: nil`, so the new VPIO-imposed format will be picked up automatically.
- Must run inside `catchingObjCException` because the underlying AU call can throw an Obj-C exception on some aggregate devices.
- Failure is non-fatal: log and continue with raw capture. Users on exotic audio setups should still get a working meeting, just without AEC.

### 2. Wire it through `MeetingAudioCaptureService`

```swift
// MeetingAudioCaptureService.swift
public init() {
    self.microphoneCapture = MicrophoneCapture(enableVoiceProcessing: true)
    self.systemAudioTapFactory = { ... }
}
```

The test init that accepts `any MeetingMicrophoneCapturing` stays as-is; test doubles don't care about VPIO.

### 3. Cross-stream energy gate (defense in depth)

Even with VPIO, loud speakers / cheap drivers / multi-party overlap can leave residual echo. Add a cheap deterministic guard in `MeetingRecordingService.handleCaptureEvent`.

State (add to the actor):

```swift
private var recentSystemRms: Float = 0   // EMA of system buffer RMS
private var recentMicRms: Float = 0      // EMA of mic buffer RMS
private static let rmsEmaAlpha: Float = 0.3
private static let systemDominanceRatio: Float = 4.0   // system ≥ 4× mic
private static let systemActiveFloor: Float = 0.02     // ignore silent system
```

On each incoming buffer, update the EMA *before* chunk enqueue. When a mic **chunk** becomes available (the `offsetChunk(...)` returns non-nil inside the `.microphoneBuffer` branch), check the current ratio. If `recentSystemRms > systemActiveFloor` **and** `recentSystemRms / max(recentMicRms, ε) > systemDominanceRatio`, do **not** enqueue the mic chunk for transcription. Still write the raw mic audio to disk (so finalize/mix retains it) and still update `latestLevels.microphone` (so the level meter stays honest).

This keeps the gate at the chunk boundary (not per-buffer), so normal over-talk where the user *is* speaking still goes through — the user's voice raises `recentMicRms` above the ratio threshold.

Thresholds are intentionally generous. Tune in manual validation.

### 4. UI hint

Add a single line on the meeting panel (near the "Start meeting" affordance or in the first-run meeting tip) along the lines of: **"For the cleanest separation between you and other participants, use headphones."** No nag, no persistent banner. One line, one location.

File: `Sources/MacParakeet/Views/MeetingRecording/…` — pick whichever is the existing empty-state / pre-recording copy location.

## Files to change

1. `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift` — add `enableVoiceProcessing` init arg + VPIO enable block.
2. `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` — construct `MicrophoneCapture(enableVoiceProcessing: true)` in the default `init()`.
3. `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` — add RMS EMA state + mic-chunk suppression inside `handleCaptureEvent`.
4. `Sources/MacParakeet/Views/MeetingRecording/…` — add "use headphones" copy (one line).
5. `Tests/MacParakeetTests/…` — tests listed below.

## Tests

- **`MicrophoneCaptureTests`** (new or extended): verify `enableVoiceProcessing` default is `false`; verify a constructor with `true` does not crash (cannot assert VPIO is active in unit tests without a mic — leave that for manual validation).
- **`MeetingAudioCaptureServiceTests`**: confirm via test double that the default init path exercises the voice-processing-enabled code path. Simplest option: add an `init` overload that accepts a `@Sendable () -> any MeetingMicrophoneCapturing` factory instead of a concrete instance, and assert the default factory constructs with VPIO on (an observable flag on a test-only stub).
- **`MeetingRecordingServiceTests`** (new test):
  - Feed a sequence where system buffers have high RMS and mic buffers have low RMS → assert no mic transcription task is enqueued for that window (observable via the existing mock `STTTranscribing`).
  - Feed a sequence where both streams have comparable RMS → assert mic chunks **are** enqueued (user talking over remote, legit overlap).
  - Feed a sequence with only mic (no system) → assert mic chunks are enqueued unconditionally.
- `swift test` green.

## Manual validation

1. Join a Zoom call over built-in speakers with a second participant speaking continuously for ~90s.
2. Start a meeting recording. Stop after the participant finishes.
3. Expected: transcript shows Others → participant's full sentences; Me → empty or only what you actually said. No phantom "Me" fragments.
4. Repeat with AirPods / headphones. Expected: same behavior, no regression.
5. Repeat with both you and the participant talking over each other. Expected: both streams populate; "Me" contains your words, "Others" contains theirs.
6. Run a dictation (hotkey) during a meeting recording. Expected: dictation quality unchanged vs. baseline (no AGC artifacts, no truncation).

## Rollout

- Single PR.
- No migration, no settings surface — VPIO is always on for meeting recording. Rationale: the failure mode (mis-attribution) is severe and the tradeoff (minor AGC/NS on mic) is acceptable for meeting use. Dictation is unaffected.
- If manual validation reveals a regression (e.g., AGC pumping on a specific mic), we can gate behind a hidden `AppRuntimePreferences` flag — but don't ship a user-facing toggle unless we actually need it.

## Risks / open questions

- **VPIO format drift**: enabling VPIO can change the inputNode's output format. Current code reads the format via `outputFormat(forBus: 0)` before tap install. Need to re-read after enabling VPIO. Mitigation: order of operations in §1, plus `format: nil` on the tap.
- **Aggregate devices**: users with aggregate / virtual audio (BlackHole, Loopback, Rogue Amoeba) may fail VPIO enablement. Mitigation: non-fatal fallback to raw capture with a logged warning — they still get a recording.
- **Bluetooth headsets**: VPIO on macOS is known to work well with AirPods and standard Bluetooth; should be a non-issue.
- **ADR-015 concurrency**: dictation engine is a separate `AVAudioEngine` instance, so VPIO on the meeting engine cannot affect dictation capture. Validated manually in step 6.
- **Energy gate thresholds**: picked conservative defaults; may need tuning. Accept that some very quiet user utterances during loud remote speech may be dropped — user can rewind and re-say, much better than phantom attributions.

## Success criteria

- On a speakers-Zoom test call, no "Me" fragments from the remote speaker appear in the transcript.
- Headphones case and user-talks-over-remote case both work correctly.
- Dictation mic quality unchanged.
- All tests pass.
- No new settings surface.

## Coordination

Another agent is actively working in this repo (`2026-04-onboarding-screen-recording-permission.md` + active diffs in `MeetingAudioCaptureService.swift`, `MicrophoneCapture.swift`, and `scripts/dev/ci_local.sh` per `git status`). This plan touches `MicrophoneCapture.swift` and `MeetingAudioCaptureService.swift` — both already dirty in the working tree. Before starting implementation:

1. Diff the current working tree against `main` for those two files to understand the in-flight changes.
2. Rebase/merge on top of them rather than overwriting.
3. Sequence this plan **after** the other agent's changes land, or coordinate a single combined PR if the surfaces conflict.

---

## Instructions for the next coding agent

You are picking this plan up to **review it and then implement it**. Do both phases — do not start editing files until the review phase is done.

### Context you must load first

- Read this entire plan, top to bottom.
- Read `CLAUDE.md` at the repo root (project conventions, invariants, known pitfalls).
- Read `spec/adr/014-meeting-recording.md` and `spec/adr/015-concurrent-dictation-meeting.md` — these are locked. Do not violate them.
- Read `spec/10-ai-coding-method.md` for the kernel workflow and source-of-truth precedence.
- Read the three primary files fully before touching anything:
  - `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`
  - `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`
  - `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`
- Check `git status` and `git diff` for both `MicrophoneCapture.swift` and `MeetingAudioCaptureService.swift`. **Another agent has in-flight changes in these files.** Understand their changes before planning yours. Do not clobber them.

### Phase 1 — Review the plan (do this before writing any code)

Critique this plan for correctness and completeness. Specifically:

1. **AEC approach**: Is `AVAudioInputNode.setVoiceProcessingEnabled(true)` the right call on **macOS 14.2+**? Verify the API contract: what format does the node expose after VPIO is enabled? Does it affect Core Audio Taps at all? Confirm VPIO on macOS uses the default output device as the AEC reference (not just same-process output, as on iOS) — this is load-bearing for the fix.
2. **Order of operations**: Confirm the required ordering: enable VPIO → (re-)query inputNode format → install tap with `format: nil` → start engine. Does calling `setVoiceProcessingEnabled(true)` after the engine has been touched cause issues? Does it need to be called before `inputNode` is accessed for the first time?
3. **Concurrency with dictation (ADR-015)**: Each flow has its own `AVAudioEngine`, but both ultimately pull from the same HAL input device. Verify VPIO on one engine does not hijack the HAL unit or degrade the other engine's capture. If you find evidence it does, stop and report back — do not ship.
4. **Energy gate**: Is the RMS-EMA + ratio approach sound, or is there a trap (e.g. RMS EMAs from two streams arriving at different cadences making the ratio misleading)? Consider whether the gate should key off time-aligned windows rather than a global EMA. Revise the design if you find a flaw.
5. **Test feasibility**: Confirm the proposed tests can actually observe what they claim to observe using the existing `MeetingMicrophoneCapturing` / `STTTranscribing` mock seams. If not, propose the minimal additional seam.
6. **Out-of-scope discipline**: Flag anything in the plan that is scope creep. Cut it.
7. **Risks**: Add any risks the plan missed.

**Deliverable for Phase 1**: a short written review (bullet list, ≤30 lines) posted back to the user with:
   - Anything you changed or want to change in the plan (with rationale).
   - Any blockers that need user input before coding.
   - A go/no-go recommendation.

If you find a blocker, **stop and ask the user**. Do not proceed to Phase 2 until the user greenlights.

### Phase 2 — Implementation

Only start this after Phase 1 is approved.

1. Run `swift test` to establish a green baseline. Record the pass count.
2. Implement in this order, committing mentally (not in git) after each step:
   1. `MicrophoneCapture.swift`: add `enableVoiceProcessing` init arg + VPIO enable block with non-fatal fallback. Default is `false`.
   2. `MeetingAudioCaptureService.swift`: construct `MicrophoneCapture(enableVoiceProcessing: true)` in the default `init()`. Leave the test-seam `init(microphoneCapture:systemAudioTapFactory:)` unchanged.
   3. `MeetingRecordingService.swift`: add RMS-EMA state + mic-chunk suppression inside `handleCaptureEvent`. Keep audio writing + level meter updates unconditional; gate only the transcription enqueue.
   4. Add/extend tests listed in the Tests section. Use the existing `MeetingMicrophoneCapturing` / `STTTranscribing` mock pattern.
   5. Add the one-line "use headphones" copy on the meeting panel. Find the right view file under `Sources/MacParakeet/Views/MeetingRecording/` — do **not** create a new file.
3. After each source change, compile (`swift build`) to surface errors early. After all changes, run `swift test`. All tests must pass and the pass count must equal baseline + new tests.
4. Spawn an **Explore subagent** to review the diff of the changed files for real issues (per CLAUDE.md: "Review agent before commit"). Fix anything it surfaces that is actually a bug, ignore stylistic noise.
5. **Do not commit and do not push.** Leave the working tree dirty with a summary of changes for the user to review. The user will decide whether to merge with the other agent's in-flight work or split into a separate PR.

### Guardrails

- **Do not touch the dictation mic path.** No VPIO, no gating, no changes to dictation's `MicrophoneCapture` construction site.
- **Do not modify `MeetingAudioCapturing` protocol shape or any ViewModel.** The fix must be invisible to the UI layer.
- **Do not add a user-facing setting** for AEC. One line of copy about headphones is the only UI surface.
- **Do not delete or rewrite the other agent's in-flight changes** in `MicrophoneCapture.swift` / `MeetingAudioCaptureService.swift`. Rebase your changes on top.
- **Do not run destructive git commands** (reset --hard, checkout -- on dirty files, branch -D, force push). The working tree contains someone else's work.
- **Do not expand scope.** Anything listed under "Out of scope" stays out. If you think something out-of-scope is actually required, stop and ask the user.
- **Do not add comments/docstrings** to code you didn't change (per CLAUDE.md).

### Done definition

- All bullets in the "Success criteria" section of this plan are met.
- `swift test` green.
- Working tree dirty, changes summarized for the user, ready for their review.
- A note to the user flagging: (a) that manual validation on a real Zoom call is still required before merge, (b) the coordination state with the other agent's in-flight work.
