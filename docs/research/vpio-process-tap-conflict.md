---
title: VPIO vs Core Audio Process Taps — Architecture Research & Decision
status: IMPLEMENTED
date: 2026-04-11
authors: Claude Opus 4.6 (research), Codex/GPT (independent review), Daniel Moon (direction)
---

# VPIO vs Core Audio Process Taps — Architecture Research & Decision

> Status: **IMPLEMENTED** — decision recorded and shipped on 2026-04-11.
> Implemented in: `e815396f`
> Note: This document is preserved as the research record behind the architecture change. Some narrative sections below describe the pre-fix investigation state.

## TL;DR

MacParakeet ships two concurrent features in the same process: dictation (hotkey-triggered mic capture) and meeting recording (mic + system audio simultaneously). Meeting recording uses a Core Audio process tap introduced in macOS 14.2 to capture system audio.

A refactor on 2026-04-10 (commit `97134e9b` "Refactor meeting recording to VPIO-first pipeline") turned on `AVAudioInputNode.setVoiceProcessingEnabled(true)` (VPIO) for the meeting microphone path to get Apple's hardware acoustic echo cancellation. Motivation: the laptop mic was picking up audio leaking through the speakers from the far-end meeting participant, producing duplicated/echoed content in the mic transcript.

Empirical result: **VPIO cannot coexist with Core Audio process taps in the same process.** Reproducible failure modes (documented below) show that any `setVoiceProcessingEnabled(true)` call in the process silently kills any Core Audio process tap and leaves stale aggregate devices that break subsequent `AVAudioEngine` instances. The user's explicit requirement — "trigger dictation while a meeting is actively recording" — is architecturally incompatible with VPIO being enabled anywhere in the process.

**Decision:** Remove VPIO from the shipped default path. Ship raw mic capture in both dictation and meeting recording, keep VPIO only as explicit opt-in plumbing, and handle echo bleed at the transcript layer via the existing `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription` logic (drop mic chunks when system-audio RMS dominates). Recommend headphones for best meeting quality. This matches what every production open-source macOS meeting recorder does (Recap, AudioCap, VoiceInk).

Codex (OpenAI GPT) independently reviewed the analysis and agreed with the decision, while tightening two overclaims in my mechanism explanation.

---

## Background: what we're building

MacParakeet is a macOS 14.2+ Swift 6 / SwiftUI app with three co-equal modes. Two of them are relevant here:

1. **Dictation** — hotkey-triggered mic capture. User presses fnfn, speaks, text is pasted into the focused app. Class: `AudioRecorder` in `Sources/MacParakeetCore/Audio/AudioRecorder.swift`. Owns its own `AVAudioEngine`. Captures from `inputNode` with `installTap(onBus: 0, bufferSize: 4096, format: nil)` at line 266. **Does not use VPIO.**

2. **Meeting recording** — captures both mic and system audio simultaneously, transcribes both locally, shows a meeting panel with paired transcript. Mic capture uses a separate class `MicrophoneCapture` (`Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`) with its own `AVAudioEngine`. System audio capture uses Core Audio process taps: `SystemAudioTap` (`Sources/MacParakeetCore/Audio/SystemAudioTap.swift`) builds a `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` + `AudioHardwareCreateProcessTap` + `AudioHardwareCreateAggregateDevice` + `AudioDeviceCreateIOProcIDWithBlock`.

**User requirement (explicit):** A user must be able to trigger dictation WHILE a meeting is actively recording. Both must keep working concurrently in the same process. Each feature owns its own `AVAudioEngine`; macOS HAL multiplexes mic input across multiple engines in the same process natively.

The architectural scaffolding for meeting recording is defined in [ADR-014](../../spec/adr/014-meeting-recording.md). Concurrent dictation + meeting is defined as a hard requirement in [ADR-015](../../spec/adr/015-concurrent-dictation-meeting.md).

---

## The incident

### Timeline

- **2026-04-07 (`118d7e6f`)**: "Stabilize meeting capture: remove VP and add joined dual-stream pipeline." Meeting mic was running on raw `AVAudioEngine` tap. `SoftwareAECConditioner` + `MeetingSoftwareAEC` existed as the software AEC path. This was the last known-working architecture.
- **2026-04-10 (`97134e9b`)**: "Refactor meeting recording to VPIO-first pipeline." Default `MeetingMicProcessingMode` changed to `.vpioPreferred`. The refactor was motivated by the observed echo-bleed problem (see "Root problem" below).
- **2026-04-11**: User reported that meeting recording was capturing mic audio but producing 557-byte empty `system.m4a` files (header only, no data). Investigation began.

### Root problem that motivated VPIO

When a user records a meeting while playing audio through laptop speakers (e.g., Zoom call on speakers, Safari video), the microphone picks up that speaker audio via the acoustic path (speaker → air → mic). This means the same content appears in two places in the final transcript:

- Cleanly, from the system-audio stream captured by the process tap.
- Muddily, from the microphone stream, time-shifted by the acoustic-path delay and degraded.

The result is a transcript that duplicates far-end speech, sometimes with diarization errors ("Them" content attributed to "Me"). The instinct to reach for VPIO (Apple's hardware AEC) is textbook correct — its literal purpose is to subtract speaker audio from mic input.

The VPIO refactor was an attempt to solve this problem at the audio level. The conflict discovered in this investigation shows VPIO is not viable in this process, and the problem must be solved at the transcript layer instead.

### Empirical observations (from 2026-04-11 testing)

All observations on macOS 15, Apple Silicon, built-in microphone and speakers, dev build of MacParakeet:

**Observation 1: VPIO enabled, meeting first, dictation second**
- Meeting recording starts cleanly. No OSStatus errors. Logs: `System audio tap started`, `Microphone capture started`, `meeting_mic_processing mode=vpio requested=vpioPreferred effective=vpio`.
- Mic stream captures normally: `microphone.m4a` is 71–98 KB, contains user's voice.
- System stream is empty: `system.m4a` is 557 bytes (AIFF/WAV header only, no data). `LiveChunkTranscriber` reports zero buffers received from the system source.
- After meeting stops, dictation is triggered via hotkey: captures silence. Transcript is empty regardless of speaking duration.

**Observation 2: VPIO enabled, dictation first, meeting second**
- Dictation works normally in isolation.
- Meeting recording started after dictation: both mic AND system streams are silent. Both `.m4a` files are header-only.

**Observation 3: VPIO disabled (raw mic), any ordering**
- Dictation alone: works.
- Meeting alone: both mic and system streams capture normally. `system.m4a` contains the Safari video audio cleanly.
- Dictation → meeting → dictation: all three captures work.
- Meeting → dictation → meeting: all three captures work.

**Observation 4: HAL device enumeration during failure**
- During the VPIO-enabled failure state, `AudioObjectID` enumeration showed virtual devices present: `VPAUAggregateAudioDevice` and `CADefaultDeviceAggregate-<PID>-<N>` (N=0, 1, 2 across repeated sessions).
- These virtual devices persisted after the `MicrophoneCapture` `AVAudioEngine` was stopped and deallocated.
- They disappeared when the app process exited.

### Reordering attempt (did not fix the problem)

An early attempted fix was to reorder `MeetingAudioCaptureService.start(handler:)` to start the system audio tap BEFORE enabling VPIO on the microphone engine (the theory being that if the tap snapshots the real default output device first, VPIO's later aggregate creation wouldn't poison it). Result: both mic and system went silent. Reordering did not fix the conflict. The shipped implementation removed that experimental reorder and switched the default path to raw mic capture instead.

### User reframing

After the reorder failure, the user (Daniel) made an important observation: the investigation had been framed as "restore the known-good state," but in Daniel's view, this concurrent-dictation-plus-meeting architecture had **never fully worked**. There was no prior-working baseline to restore — the fix had to be architectural, not restorative.

---

## Code audit findings

Verified via grep and direct file reads on 2026-04-11:

### VPIO call sites (production code)

- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift:226` — `try inputNode.setVoiceProcessingEnabled(enabled)` — **the only `setVoiceProcessingEnabled` call in the entire codebase.**
- The mode is controlled by `MeetingMicProcessingMode` enum (`vpioPreferred`, `vpioRequired`, `raw`).
- `MicrophoneCapture.start(processingMode:)` at line 46 has method default `.vpioPreferred`.
- `MeetingAudioCaptureService` has three init signatures (lines 59, 73, 83), all with default `micProcessingMode: MeetingMicProcessingMode = .vpioPreferred`.
- `MicrophoneCapture` is instantiated in production only at `MeetingAudioCaptureService.swift:60` (`self.microphoneCapture = MicrophoneCapture()`).

### VPIO call sites (tests)

- `Tests/MacParakeetTests/Audio/MeetingAudioCaptureServiceTests.swift` — 7 references to `.vpioPreferred`.
- `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift:480` — 1 reference.

### Dictation path does NOT use VPIO

- `Sources/MacParakeetCore/Audio/AudioRecorder.swift` — no `setVoiceProcessingEnabled` anywhere (confirmed by grep). Raw `AVAudioEngine` with `inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil)` at line 266.
- Dictation has been running raw since v0.1, with no user complaints about mic quality for dictation specifically.

### Spec references

- `spec/05-audio-pipeline.md:158-159` documents `MeetingMicProcessingMode` with `vpioPreferred` as the documented default. Needs update as part of the fix.

### Software AEC infrastructure exists but is not currently wired in by default

- `Sources/MacParakeetCore/Services/MicConditioner.swift` defines `MicConditioning` protocol with two implementations:
  - `VPIOConditioner.condition(microphone:speaker:) -> [Float]` returns `microphone` unchanged (pass-through, since hardware VPIO would have already done AEC).
  - `SoftwareAECConditioner` wraps `MeetingSoftwareAEC` and does actual echo cancellation in Swift.
- `MeetingRecordingService.configureMicConditioner` (around line 414) switches between them based on the effective mic processing mode returned by the capture start report.
- When the meeting is running raw, `SoftwareAECConditioner` is selected automatically.
- `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription` (around line 487) provides an independent transcript-layer suppression path that drops mic chunks from STT when system-audio RMS dominates the mic over the same time window. This is the "right" approach for a transcription-only app (see Codex review below).

### CaptureOrchestrator pair-joining pipeline

- `Sources/MacParakeetCore/Services/CaptureOrchestrator.swift` owns a `MeetingAudioPairJoiner` that pairs mic and system samples into `MeetingAudioPair` records with bounded lag (`maxLag = 4` pair slots, `maxLagDurationSeconds = 1`, `maxQueueSize = 30`). Pairs are fed through `micConditioner.condition(microphone:speaker:)` before chunking.
- The pair joiner assumes 1:1 sample-rate alignment between mic and system over time. Codex flagged this as a latent drift risk (see "Follow-up work").

---

## Mechanism analysis

### Verified facts (cited)

1. **VPIO is not a filter — it's a duplex I/O unit.** `setVoiceProcessingEnabled(true)` switches the AVAudioEngine into voice-processing mode using `kAudioUnitSubType_VoiceProcessingIO`, the same audio unit that powers FaceTime and Zoom on macOS. Source: WWDC19 "What's New in AVAudioEngine" (https://developer.apple.com/videos/play/wwdc2019/510/). Apple explicitly states voice processing requires both I/O nodes to be in VP mode; enabling it on the input node flips the output node too.

2. **VPIO mutates input format from mono to multichannel deinterleaved.** After `setVoiceProcessingEnabled(true)`, `inputNode.outputFormat(forBus: 0)` changes from e.g. `1ch 44100 Float32` to `3ch 44100 Float32 deinterleaved`. Source: Apple Developer Forums thread 710151 "Enabling Voice Processing changes…" (https://developer.apple.com/forums/thread/710151). This is independently confirmed by the `76475477` commit in MacParakeet's own git history ("Fix meeting buffer copy for VPIO multichannel formats").

3. **VPIO requires matched input/output devices and fails with `-10876` otherwise.** The error is `AggregateDevice channel count mismatch` and indicates VPIO internally constructs an aggregate device pairing the current input + current output. If they can't be paired (different sample rates, different channel counts), VPIO fails. Source: Apple Developer Forums threads 128518 (https://developer.apple.com/forums/thread/128518), 810129 (https://developer.apple.com/forums/thread/810129), AudioKit issues #2606 (https://github.com/AudioKit/AudioKit/issues/2606) and #2130 (https://github.com/AudioKit/AudioKit/issues/2130).

4. **VPIO's aggregate device has been observed in production.** Apple engineer response in thread 733733 (https://developer.apple.com/forums/thread/733733) discusses `AUVPAggregate` and the aggregate construction pattern.

5. **AVAudioEngine has documented HAL side effects.** Chris Liscio's engineering post "It's over between us, AVAudioEngine" (https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/) documents: "the mere presence of an Aggregate audio device in your system's audio device list would cause the crash" and "merely creating the AVAudioEngine causes the sound degradation … calling outputNode now triggers the issue." The contrast is drawn with the older AUGraph API which "is fine with aggregate audio devices."

6. **Core Audio process taps need a clock-providing main subdevice.** `AudioHardwareCreateAggregateDevice` requires `kAudioAggregateDeviceMainSubDeviceKey` to be set to a sub-device UID. That sub-device provides the clock for the aggregate. If the clock device's IO is not running, the aggregate's IO proc does not fire. Source: AudioCap reference implementation (`ProcessTap.swift` at https://github.com/insidegui/AudioCap) and Apple's own Core Audio taps sample code (https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

7. **AudioCap and Recap pin the main subdevice by UID, not by AudioObjectID.** Both read `kAudioHardwarePropertyDefaultSystemOutputDevice` at tap-creation time, resolve it to a UID string, and pass that UID in the aggregate description. Verified by direct reads of:
   - AudioCap `ProcessTap.swift` (https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/ProcessTap.swift)
   - Recap `ProcessTap.swift` (https://github.com/RecapAI/Recap/blob/main/Recap/Audio/Capture/Tap/ProcessTap.swift)

8. **No production open-source macOS meeting recorder uses VPIO.** Verified by grep:
   - Recap `MicrophoneCapture+AudioEngine.swift` and `MicrophoneCapture+AudioProcessing.swift`: zero `setVoiceProcessingEnabled` calls, zero echo-handling code. Raw mic engine, raw system audio, two separate streams.
   - AudioCap: no microphone capture at all, tap only. No VPIO.
   - VoiceInk (`CoreAudioRecorder.swift`, 914 lines): no VPIO, no AEC. Dictation-only use case.

### Hypotheses (tighter wording per Codex review)

**Original wording (too strong):** "VPIO mutates the process's view of `kAudioHardwarePropertyDefaultSystemOutputDevice` to point at the virtual VPAU aggregate device, and subsequently-built process tap aggregates clock off the virtual device instead of real hardware."

**Codex's pushback:** "That is plausible but there is no hard proof from Apple docs that this specific property is what changes. More defensible wording: VPIO introduces/uses internal aggregate devices and may alter HAL device topology/selection behavior in-process. Your tap setup that depends on 'current default output identity at creation time' can then bind to the wrong or unstable device chain, causing silent callbacks."

**Revised wording (used going forward):** VPIO activation introduces process-scoped aggregate-device state (`VPAUAggregateAudioDevice`) that alters HAL device topology or selection behavior in ways that cause Core Audio process taps — whose aggregate devices depend on the current default-output identity at creation time — to bind to the wrong or unstable device chain. The observable effect is that the tap's IO proc never fires, producing silent buffers. The precise property that is mutated is not documented by Apple; the property-level explanation above is the best mechanistic account consistent with the symptoms but is not independently verified against Apple source.

**Original wording (too strong):** "Stale `CADefaultDeviceAggregate-<PID>-N` virtual devices persist forever after VPIO teardown and break subsequent AVAudioEngine instances."

**Codex's pushback:** "This is not always proof of irreversible contamination. It can be asynchronous teardown lag, HAL caching/lifecycle timing, or route reconfiguration race conditions."

**Revised wording:** VPIO side effects are process-scoped and can outlive a single engine instance long enough to break another engine unless the first engine is carefully isolated. Stale `CADefaultDeviceAggregate-<PID>-N` virtual devices have been observed in the HAL after VPIO teardown; whether that persistence is permanent (for the lifetime of the process) or merely an asynchronous teardown lag is not proven. In either case, for a production app with concurrent features, the contamination window is long enough to reliably break subsequent engine instantiations.

---

## Why VPIO + process taps collide (synthesis)

Putting verified facts and the tightened hypothesis together:

1. The meeting-recording process tap needs its aggregate device to be clocked off a real hardware output device. This is fundamental to how Core Audio aggregates work.
2. AudioCap/Recap achieve this by reading `kAudioHardwarePropertyDefaultSystemOutputDevice` at tap-creation time, resolving to a UID, and pinning `kAudioAggregateDeviceMainSubDeviceKey` to that UID.
3. If VPIO has been activated in the process before the tap is created, HAL device topology / selection has been mutated in ways that make "the current default output" resolve to a virtual device rather than real hardware. The tap then pins to a virtual device and never receives buffers.
4. If VPIO is activated in the process AFTER the tap is already running, HAL state changes (aggregate device creation, possible default-device reselection, stale aggregate leakage) can still disturb the running tap's IO chain mid-stream. The observable symptom is the same: silent buffers.
5. Therefore: as long as the app ships a Core Audio process tap, VPIO cannot be safely enabled anywhere in the same process. This is a **process-wide ban** triggered by the presence of the tap, not a constraint on any specific feature.
6. A corollary: if dictation enabled VPIO while a meeting was actively recording, the meeting's system-audio stream would go silent from the moment the dictation hotkey was pressed. This directly violates the user's concurrent-dictation-plus-meeting requirement.

**Practical conclusion:** For this app, `setVoiceProcessingEnabled(true)` is a forbidden API. The ban applies to dictation, meeting recording, and any future feature that handles microphone input in-process.

---

## Evidence from the macOS audio community

### Apple first-party sources

- **WWDC19 "What's New in AVAudioEngine"** (https://developer.apple.com/videos/play/wwdc2019/510/) — introduces voice processing support in `AVAudioEngine`; states VP mode applies to both I/O nodes.
- **WWDC22 "Meet ScreenCaptureKit"** (https://developer.apple.com/videos/play/wwdc2022/10156/) — introduces SCK audio capture path (alternative to Core Audio taps).
- **WWDC23 "What's new in voice processing"** (https://developer.apple.com/videos/play/wwdc2023/10235/) — updates on VPIO.
- **Apple — Capturing system audio with Core Audio taps** (https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) — canonical sample code.
- **Apple — Using voice processing** (https://developer.apple.com/documentation/avfaudio/audio_engine/audio_units/using_voice_processing)

### Apple Developer Forums

- **Thread 128518** — AVAudioEngine and Voice Processing Unit macOS (https://developer.apple.com/forums/thread/128518) — long-running thread on VPIO failing with mismatched I/O devices and `-10876` AggregateDevice channel count errors.
- **Thread 710151** — "Enabling Voice Processing changes…" (https://developer.apple.com/forums/thread/710151) — documents channel count mutation on input node.
- **Thread 721535** — Volume issue when Voice Processing IO is used (https://developer.apple.com/forums/thread/721535).
- **Thread 733733** — macOS echo cancellation AUVoiceProcessingIO (https://developer.apple.com/forums/thread/733733) — Apple engineer response on VP I/O coupling.
- **Thread 751100** — Voice Processing in multiple apps (https://developer.apple.com/forums/thread/751100).
- **Thread 756323** — Device Volume Changes After Setting Voice Processing (https://developer.apple.com/forums/thread/756323) — title alone indicates device-level state mutation.
- **Thread 810129** — aggregate construction / default-pair errors with VP (https://developer.apple.com/forums/thread/810129).
- **Thread 71008** — macOS AVAudioEngine I/O nodes tied to system defaults (https://developer.apple.com/forums/thread/71008).
- **Thread 747303** — mixing ScreenCaptureKit audio with AVAudioEngine (https://developer.apple.com/forums/thread/747303).

### Open-source reference implementations

- **Recap** (https://github.com/RecapAI/Recap) — production open-source meeting recorder. Same architecture (mic engine + process tap + two-stream local transcription). Zero `setVoiceProcessingEnabled` calls. Raw mic, raw system audio, no real-time AEC, transcript-layer handling only. **This is the closest analog to MacParakeet's meeting mode in the public open-source world.**
- **AudioCap** (https://github.com/insidegui/AudioCap) — canonical Core Audio Taps sample by Guilherme Rambo (ex-Apple). Tap-only. No VPIO. Snapshot-and-pin-by-UID pattern.
- **VoiceInk** (https://github.com/Beingpax/VoiceInk) — GPL Swift dictation app. `CoreAudioRecorder.swift` has no VPIO, no AEC, no aggregate-device manipulation.
- **AudioTee** (https://github.com/makeusabrew/audiotee) — filed FB17411663 against Apple's own process-tap sample for aggregate-device errors. See https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos.
- **Azayaka** (https://github.com/Mnpn/Azayaka) — menu bar screen/audio recorder using ScreenCaptureKit audio + separate `AVAudioEngine` mic. Different architecture but confirms SCK audio is viable alongside AVAudioEngine.
- **AECAudioStream** (https://github.com/kasimok/AECAudioStream) — Swift wrapper around `kAudioUnitSubType_VoiceProcessingIO`. **Explicit trap: this will hit the exact same conflict because it wraps the same underlying AU.** Do not use as a workaround.

### Engineering writeups

- **Chris Liscio, "It's over between us, AVAudioEngine"** (https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/) — broader documentation of AVAudioEngine HAL side effects, aggregate device crashes, and the contrast with the older AUGraph API.
- **Strongly Typed, "AudioTee: capture system audio output on macOS"** (https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos) — includes FB17411663 reference to errors in Apple's own tap sample.
- **"From Core Audio to LLMs: Native macOS Audio Capture for AI-Powered Tools"** (https://dev.to/yingzhong_xu_20d6f4c5d4ce/from-core-audio-to-llms-native-macos-audio-capture-for-ai-powered-tools-dkg).

### Related issues in other projects

- **sudara gist** — Core Audio Tap API in macOS 14.2 example (https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f).
- **screenpipe issue #101** — system audio capture not working from MacBook speakers on macOS 14.5 (https://github.com/screenpipe/screenpipe/issues/101) — another instance of tap aggregate going silent under specific output-device conditions.
- **OBS issue #10401** — System Audio Recording permission alone insufficient for macOS audio capture (https://github.com/obsproject/obs-studio/issues/10401).
- **Electron issue #47490** — `desktopCapturer` ScreenCaptureKit loopback (https://github.com/electron/electron/issues/47490).
- **Historical CoreAudio list** — report of `CADefaultDeviceAggregate-*` (https://www.mail-archive.com/coreaudio-api@lists.apple.com/msg00870.html).

### Software AEC alternatives

- **Google WebRTC AEC3** — the modern AEC from Chromium/WebRTC. Quality is the closest open-source match to Apple VPIO. No maintained Swift Package wrapper; would need to vendor `webrtc-audio-processing` (https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing), build as universal static lib, write a thin C/Swift bridge. Estimated effort: 3–5 days end-to-end.
- **Speex AEC (`speexdsp`)** — older, simpler, much lower quality on hard echoes. Demonstrated Rust bridge at https://github.com/thewh1teagle/aec. Not competitive with VPIO or AEC3.

---

## Alternatives considered

### (a) Drop VPIO entirely — CHOSEN

Match Recap's architecture exactly. Both dictation and meeting use raw `AVAudioEngine` mic capture. Meeting system audio continues to use the Core Audio process tap. Handle echo bleed in meeting transcripts at the transcript layer via the existing `shouldSuppressMicrophoneChunkTranscription` logic. Recommend headphones in meeting panel copy for best quality.

**Pros:**
- Eliminates all VPIO-related HAL contamination.
- Restores concurrent dictation + meeting capability (the user's hard requirement).
- Matches every production open-source meeting recorder on macOS.
- 30 minutes of code changes, fully reversible.
- Zero cost to dictation quality (it never used VPIO to begin with).
- `SoftwareAECConditioner` + `MeetingSoftwareAEC` infrastructure already exists in the codebase from commit `118d7e6f`.

**Cons:**
- Mic transcripts in meetings will contain residual echo bleed from speakers when users don't wear headphones. Transcript-layer suppression mitigates but does not fully eliminate this.
- During double-talk (user interjects while far-end is still talking), transcript suppression may drop valid user speech. Real audio-level AEC would preserve it. This is a known quality gap (per Codex review).

**Decision:** Accept the cons. They're the same tradeoffs Recap, AudioCap, Granola, Otter, and Fireflies all accept.

### (b) Migrate system audio capture to ScreenCaptureKit

Replace Core Audio process taps with `SCStream` + `SCStreamConfiguration.capturesAudio = true`. In theory, SCK's audio path runs through `replayd` out of process and should not be affected by in-process VPIO. This would allow VPIO to remain enabled on the meeting mic.

**Pros:**
- Potentially allows real hardware AEC on the meeting mic.
- Avoids Core Audio taps entirely.

**Cons:**
- Hypothesis unverified: nobody has publicly confirmed SCK audio is immune to same-process VPIO activation.
- Adds ~100–200ms latency (audio goes through `replayd`).
- SCK audio requires "Screen & System Audio Recording" TCC permission — same as process taps, so no net UX cost, but the label is more alarming.
- macOS 15 required for in-stream mic capture; on macOS 14.2 we'd still need `AVAudioEngine` for mic → VPIO contamination returns.
- Changes capture semantics: SCK captures the selected display's audio, coarser than per-process exclusion in taps.
- Not necessary if we drop VPIO — we already have a working tap.

**Decision:** Rejected. Defer indefinitely. Would be useful if Apple ever deprecates Core Audio taps, but no signal of that.

### (c) Vendor WebRTC AEC3

Keep VPIO disabled. Replace the current `MeetingSoftwareAEC` (which may be a simpler implementation) with WebRTC AEC3 for higher-quality software-level echo cancellation on the mic stream.

**Pros:**
- Highest-quality software AEC available.
- Preserves near-end speech during double-talk (the main transcript-layer suppression weakness).
- No HAL conflicts.

**Cons:**
- 3–5 day integration effort (vendor lib, universal static lib build, C/Swift bridge, tuning).
- Marginal ROI for a transcript-only app — the existing `shouldSuppressMicrophoneChunkTranscription` gets most of the practical benefit.
- Adds a large C++ dependency to the codebase.

**Decision:** Deferred. Revisit if post-launch user reports indicate transcript-layer suppression is insufficient. Ship without it for now.

### (d) Single shared `AVAudioEngine` with VPIO enabled at app launch

Instead of two separate engines (one for dictation, one for meeting mic), use one process-wide engine with VPIO enabled once at launch. Dictation and meeting both tap into it.

**Pros:**
- Resolves the "multiple engines both trying to enable VPIO" instability documented in Apple forum thread 751100.

**Cons:**
- Still creates the `VPAUAggregateAudioDevice` that breaks process taps. The core conflict is unchanged.
- Large refactor: dictation and meeting have very different lifecycle/ownership semantics today.

**Decision:** Rejected. Doesn't solve the actual problem.

### (e) VPIO in a separate helper process

Isolate all VPIO use in a helper process connected via XPC or shared memory. The main process hosts the Core Audio tap and never touches VPIO.

**Pros:**
- Cleanest architectural separation. VPIO side effects contained to the helper process; main process HAL state is pristine.
- Preserves hardware AEC quality.

**Cons:**
- Significant architectural complexity. Helper process bundle, XPC interface, IPC audio streaming, permission handling, lifecycle management.
- Probably a week+ of work.
- Not needed for launch.

**Decision:** Noted as a future option if echo quality ever becomes a blocking user complaint. Not on the roadmap.

---

## Decision

**Ship option (a): drop VPIO entirely.**

Rationale:
1. Hard user requirement: concurrent dictation + active meeting recording. VPIO anywhere in the process kills meeting's system audio tap. No workaround found.
2. Zero cost to dictation: it never used VPIO.
3. Zero architectural cost: the infrastructure for raw capture + software conditioning + transcript suppression already exists from commit `118d7e6f` (4 days before the VPIO refactor).
4. Industry alignment: matches Recap, AudioCap, VoiceInk, and (by observable behavior) Granola, Otter, Fireflies.
5. Independent confirmation: Codex/GPT reviewed the analysis and agreed with this choice over ScreenCaptureKit, WebRTC AEC3, shared-engine, and helper-process alternatives.

---

## Implementation plan (minimum fix)

1. `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` lines 59, 73, 83 — change `micProcessingMode: MeetingMicProcessingMode = .vpioPreferred` to `.raw` in all three init signatures.
2. `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` — revert the tap-before-mic reorder introduced during investigation (put `microphoneCapture.start(...)` back before `tap.start(...)`). Without VPIO, start order is immaterial, but the original ordering is cleaner.
3. `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift:46` — change method default `processingMode: MeetingMicProcessingMode = .vpioPreferred` to `.raw`.
4. Leave the `MeetingMicProcessingMode` enum, the `vpioPreferred` / `vpioRequired` cases, and all the fallback plumbing in place. They become dead code for now but removing them expands the diff for no benefit, and we may want to revisit if we ever pursue option (e).
5. Update 8 test references:
   - `Tests/MacParakeetTests/Audio/MeetingAudioCaptureServiceTests.swift` — 7 references to `.vpioPreferred` → `.raw`.
   - `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift:480` — 1 reference.
6. Update `spec/05-audio-pipeline.md:158-159` to document `.raw` + software conditioning + transcript-layer suppression as the meeting default, with a note about why VPIO is not used.
7. Audit `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription` and `shouldTranscribeChunk` to verify the VPIO refactor did not inadvertently bypass them. If they are bypassed, wire them back in.
8. Add lightweight diagnostic logging to `SystemAudioTap.start` and `MicrophoneCapture.start`: at start time, log selected device ID, device UID, sample rate, channel count, aggregate device ID (for the tap). At first-buffer-callback time (or N-second timeout), log whether the callback actually fired. This addresses Codex's "557-byte-file class bugs must be diagnosable in the field" concern and is cheap to add.
9. Rebuild via `scripts/dev/run_app.sh` and run `swift test`.
10. Manual verification (with Safari playing a video):
    - Dictation alone → transcript contains user's voice.
    - Meeting alone → both `microphone.wav` and `system.wav` contain real audio; final meeting transcript shows both sides.
    - Dictation → meeting → dictation → all three captures produce real audio.
    - Meeting → dictation → meeting → all three captures produce real audio.
    - **Concurrent: start meeting, wait 30s, trigger dictation via hotkey without stopping meeting, speak a dictation command, return to meeting for another 30s, stop meeting.** Verify the meeting recording has unbroken system audio for the full duration AND the dictation captured separately. This is the critical test.
11. Update traceability: `spec/kernel/traceability.md` if any requirement IDs are touched.

### Not in scope for the minimum fix

- Ripping out `MeetingMicProcessingMode` / `VPIOConditioner` / `vpioPreferred` fallback code.
- Handling route changes mid-recording (see Follow-up work).
- Self-capture exclusion (see Follow-up work).
- Clock drift handling in `MeetingAudioPairJoiner` (see Follow-up work).
- WebRTC AEC3 integration.
- ScreenCaptureKit migration.

---

## Independent review (Codex / GPT)

A Codex agent was briefed with the full problem, my analysis, and my proposed decision, and asked to push back hard if anything was wrong.

### Where Codex agreed

- **Shipping decision is correct.** Option (a) — drop VPIO, ship raw capture + transcript-layer suppression + headphones recommendation — was confirmed as the right choice over alternatives (b), (c), (d), and (e).
- **VPIO is not "just a filter."** Citing WWDC19 and Apple engineer forum quotes. Enabling VP mode flips both I/O nodes.
- **VPIO + Core Audio taps in the same process is effectively banned.** Not a proven formal impossibility, but "pragmatically correct for shipping" given reproducible failures and no documented coexistence pattern.
- **Cross-engine contamination is real.** VPIO side effects are process-scoped and can outlive one engine long enough to break another.
- **Recap/AudioCap snapshot-and-pin-by-UID is the right tap aggregate pattern.**
- **Transcript-layer suppression is the right default for a local-transcription-only app.**

### Where Codex pushed back

**Overclaim 1:** "`setVoiceProcessingEnabled(true)` mutates `kAudioHardwarePropertyDefaultSystemOutputDevice`."

Codex: Not proven from Apple docs. More defensible wording is "VPIO introduces/uses internal aggregate devices and may alter HAL device topology/selection behavior in-process. Tap setups that depend on 'current default output identity at creation time' can then bind to the wrong or unstable device chain, causing silent callbacks." This documentation uses the revised wording.

**Overclaim 2:** "Stale `CADefaultDeviceAggregate-<PID>-N` devices persist forever after VPIO teardown."

Codex: Could be asynchronous teardown lag, HAL caching, or route reconfig races. More defensible: "VPIO side effects are process-scoped and can outlive one engine instance long enough to break another unless carefully isolated." This documentation uses the revised wording.

**Overclaim 3:** "Transcript-layer suppression is equivalent to audio-level AEC for this use case."

Codex: For transcript-only output, suppression is the right default, but be clear about the tradeoff. Pure suppression can drop valid user interjections during double-talk (user says "wait" while far-end is still talking), which hurts diarization and timestamp continuity. True AEC preserves near-end speech during double-talk. The right framing: "suppression is the correct default, but it is an NLP/post-audio problem, not equivalent to AEC."

### Additional concerns Codex raised (deferred to follow-up work)

1. **Route-change handling.** The current tap aggregate is pinned at creation time. If the default output device changes mid-recording (user unplugs headphones, AirPods disconnect, Bluetooth route flips), the tap's pinned main subdevice may become stale and go silent. Should subscribe to `kAudioHardwarePropertyDefaultOutputDevice` change notifications and rebuild the tap aggregate deterministically on route changes.

2. **Self-capture feedback loop.** `stereoGlobalTapButExcludeProcesses: []` with an empty exclusion list includes MacParakeet's own audio output. If the app ever plays audio (beep sound, meeting playback, onboarding voice sample), that audio would appear in the meeting's system-audio stream and pollute suppression logic. Need to add `Bundle.main.bundleIdentifier`'s AudioObjectID to the exclusion list.

3. **Bluetooth HFP profile downgrades.** Under full-duplex capture (mic + speaker both active simultaneously), Bluetooth headsets can downgrade to HFP (hands-free profile) with lower audio quality and different channel formats. Should be tested with AirPods specifically.

4. **Clock / sample-rate drift between mic and system streams.** `MeetingAudioPairJoiner` pairs samples 1:1 over time. Over long meetings (30+ min), mic and system clocks can drift enough to desync the pair-joined stream. Need robust resampling/alignment or periodic resync anchors.

5. **Start/stop diagnostic telemetry.** Partially addressed in the minimum fix (step 8 of implementation plan). Codex's recommendation is to make "557-byte file" class bugs diagnosable from field logs without requiring a live repro session.

### Revised conclusion wording (suggested by Codex, adopted)

> "Given reproducible failures on macOS 15 when VPIO is active, and no documented Apple-supported coexistence pattern for VPIO plus Core Audio process taps in one process, MacParakeet will disable VPIO in-process and use raw mic capture with transcript-layer echo/dedup controls."

---

## Follow-up work (deferred from minimum fix)

Tracked here for future PRs. None of these block the minimum fix or the concurrent dictation + meeting requirement.

1. **Route-change handling** — Subscribe to `kAudioHardwarePropertyDefaultOutputDevice` property listener on the HAL. On change, tear down and rebuild the `SystemAudioTap`'s aggregate device with the new default output's UID. Test: start meeting with built-in speakers, connect AirPods, verify tap keeps producing audio without restart. Estimated effort: half a day.

2. **Self-capture exclusion** — Audit what MacParakeet plays through speakers (onboarding, beeps, meeting playback preview if any). If anything, add the app's process identifier to the tap description's exclusion list via `CATapDescription(stereoGlobalTapButExcludeProcesses: [Bundle.main.bundleIdentifier's pid])`. Estimated effort: 1–2 hours.

3. **Bluetooth HFP regression test** — Test dictation + meeting with AirPods Pro, AirPods Max, generic Bluetooth headset. Document any quality degradation. If HFP downgrade occurs, either accept it or investigate pinning to A2DP. Estimated effort: 2–3 hours of manual testing.

4. **Clock drift handling in `MeetingAudioPairJoiner`** — Investigate whether mic and system sample rates drift over long meetings. If yes, add periodic resync anchors using host time (`AVAudioTime.hostTime`) or use one stream's clock as master and resample the other. Estimated effort: 1–2 days including test fixtures.

5. **Enhanced diagnostic telemetry** — Beyond the minimum fix's start/stop logging, add periodic buffer-count telemetry emitted on timer (e.g., every 10s log "mic: N buffers, system: N buffers, pair-joiner: N pairs drained") so stuck captures can be diagnosed from production telemetry. Estimated effort: half a day.

6. **Transcript-layer suppression tuning** — Once minimum fix is shipped, test with realistic scenarios (laptop speakers at full volume, laptop speakers at normal volume, external speakers, headphones) and tune the dominance threshold in `shouldSuppressMicrophoneChunkTranscription`. Consider adding a normalized cross-correlation gate between mic and system chunks as a secondary signal. Estimated effort: 2–3 days including test corpora.

7. **Double-talk preservation** — Investigate whether transcript-layer suppression can be made smart enough to preserve user interjections during far-end speech. Options: (a) cross-correlation threshold tuning, (b) short-term energy envelope tracking with explicit "both speaking" detection, (c) accept the limitation and document it. Estimated effort: 1 week if pursued.

8. **WebRTC AEC3 integration** — Only if items 6 and 7 are insufficient after real-world user feedback. Vendor `webrtc-audio-processing` as universal static lib, C/Swift bridge, Settings toggle. Estimated effort: 3–5 days.

9. **Rip out dead VPIO code** — After the minimum fix has been in production for a release or two with no regressions, remove the `MeetingMicProcessingMode.vpioPreferred` / `.vpioRequired` enum cases, the `VPIOConditioner`, and the `setVoiceProcessingEnabled` call in `MicrophoneCapture`. Only do this if we're confident we'll never need VPIO again (e.g., ScreenCaptureKit / helper-process alternatives are also rejected). Estimated effort: half a day.

---

## Open questions / things not verified

1. **The exact HAL property or mechanism by which VPIO disturbs process taps.** Our best explanation is "VPIO creates private aggregate devices that alter default-output selection or device topology, and process taps clock off that state." The precise property-level mechanism is not documented by Apple. We have consistent symptoms and strong circumstantial evidence but no first-party confirmation.

2. **Whether ScreenCaptureKit audio capture is actually immune to same-process VPIO activation.** Architecturally it should be (audio is delivered by `replayd` out of process), but no public test report exists. If anyone tries it, filing a Feedback would help the next developer.

3. **The persistence lifetime of `CADefaultDeviceAggregate-<PID>-N` devices after VPIO teardown.** Observed to outlive engine deallocation; unclear whether they're eventually cleaned up or persist until process exit.

4. **Whether `kAudioHardwarePropertyDefaultOutputDevice` (apps) vs `kAudioHardwarePropertyDefaultSystemOutputDevice` (alerts) behave differently under VPIO activation.** Codex suggested the former might sidestep one dependency. Not investigated — moot if VPIO is dropped entirely.

5. **Whether a hardcoded hardware output UID captured at app launch (before any audio subsystem runs) would survive a later in-process VPIO activation.** Codex suggested this as a potential mitigation if we ever needed to re-enable VPIO. Not tested — moot for the chosen approach.

6. **Apple's official `setVoiceProcessingEnabled(_:)` and `CATapDescription` documentation pages.** These are JavaScript-rendered SPAs and could not be retrieved via plain HTTP during research. The information on them is, per developer reports, fairly thin on side effects regardless, but direct quotes would strengthen this document.

7. **Whether the failure modes observed here are macOS-version-specific** (macOS 15 observed; not yet tested on macOS 14.x, which is our minimum target). The minimum fix applies equally to both versions, but if Apple fixes the conflict in a future macOS release, we could potentially revisit.

---

## Sources (consolidated)

### Apple first-party

- Apple — Capturing system audio with Core Audio taps — https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
- Apple — Using voice processing — https://developer.apple.com/documentation/avfaudio/audio_engine/audio_units/using_voice_processing
- WWDC19 #510 — What's New in AVAudioEngine — https://developer.apple.com/videos/play/wwdc2019/510/
- WWDC22 #10156 — Meet ScreenCaptureKit — https://developer.apple.com/videos/play/wwdc2022/10156/
- WWDC23 #10235 — What's new in voice processing — https://developer.apple.com/videos/play/wwdc2023/10235/

### Apple Developer Forums

- Thread 71008 — macOS AVAudioEngine I/O nodes and system defaults — https://developer.apple.com/forums/thread/71008
- Thread 128518 — AVAudioEngine and Voice Processing Unit MacOS — https://developer.apple.com/forums/thread/128518
- Thread 710151 — Enabling Voice Processing changes input format — https://developer.apple.com/forums/thread/710151
- Thread 721535 — Volume issue when Voice Processing IO is used — https://developer.apple.com/forums/thread/721535
- Thread 733733 — macOS echo cancellation AUVoiceProcessingIO — https://developer.apple.com/forums/thread/733733
- Thread 747303 — mixing ScreenCaptureKit with AVAudioEngine — https://developer.apple.com/forums/thread/747303
- Thread 751100 — Voice Processing in multiple apps — https://developer.apple.com/forums/thread/751100
- Thread 756323 — Device Volume Changes After Setting Voice Processing — https://developer.apple.com/forums/thread/756323
- Thread 810129 — aggregate construction errors with VP — https://developer.apple.com/forums/thread/810129

### Open-source reference implementations

- Recap (production meeting recorder) — https://github.com/RecapAI/Recap
- AudioCap (canonical Core Audio taps sample, Guilherme Rambo) — https://github.com/insidegui/AudioCap
- VoiceInk (GPL dictation app) — https://github.com/Beingpax/VoiceInk
- AudioTee (system audio capture CLI) — https://github.com/makeusabrew/audiotee
- Azayaka (menu bar SCK recorder) — https://github.com/Mnpn/Azayaka
- AECAudioStream (VPIO Swift wrapper — avoid) — https://github.com/kasimok/AECAudioStream

### Engineering writeups

- Chris Liscio — It's over between us, AVAudioEngine — https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/
- Strongly Typed — AudioTee: capture system audio output on macOS — https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos
- From Core Audio to LLMs — https://dev.to/yingzhong_xu_20d6f4c5d4ce/from-core-audio-to-llms-native-macos-audio-capture-for-ai-powered-tools-dkg

### Related issues & GitHub

- AudioKit issue #2606 — Voice processing breaks graph — https://github.com/AudioKit/AudioKit/issues/2606
- AudioKit issue #2130 — macOS device selection limitations — https://github.com/AudioKit/AudioKit/issues/2130
- screenpipe issue #101 — system audio capture not working on macOS 14.5 — https://github.com/screenpipe/screenpipe/issues/101
- OBS issue #10401 — System Audio Recording permission insufficient — https://github.com/obsproject/obs-studio/issues/10401
- Electron issue #47490 — desktopCapturer ScreenCaptureKit loopback — https://github.com/electron/electron/issues/47490
- sudara gist — Core Audio Tap API in macOS 14.2 example — https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- Historical CoreAudio list: CADefaultDeviceAggregate report — https://www.mail-archive.com/coreaudio-api@lists.apple.com/msg00870.html

### Software AEC alternatives

- webrtc-audio-processing (freedesktop) — https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing
- Rust Speex AEC bridge (thewh1teagle) — https://github.com/thewh1teagle/aec

### Related MacParakeet files (verified by direct read)

- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift` — the only VPIO caller (line 226).
- `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` — VPIO default set in 3 init sites (lines 59, 73, 83).
- `Sources/MacParakeetCore/Audio/AudioRecorder.swift` — dictation path, no VPIO (confirmed raw tap at line 266).
- `Sources/MacParakeetCore/Audio/SystemAudioTap.swift` — Core Audio process tap implementation.
- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` — hosts `shouldSuppressMicrophoneChunkTranscription` (around line 487) and `shouldTranscribeChunk` (around line 544).
- `Sources/MacParakeetCore/Services/MicConditioner.swift` — `VPIOConditioner` (pass-through) and `SoftwareAECConditioner` (software AEC path).
- `Sources/MacParakeetCore/Services/CaptureOrchestrator.swift` — pair-joining pipeline.
- `Sources/MacParakeetCore/Services/MeetingAudioPairJoiner.swift` — mic/system sample pairing with bounded lag.

### Related MacParakeet git commits

- `118d7e6f` (2026-04-07) — "Stabilize meeting capture: remove VP and add joined dual-stream pipeline." Last known-working raw-mic meeting architecture.
- `a69ca23b` — "Fix system audio tap not capturing on macOS 15 (#75)." Changed to `stereoGlobalTapButExcludeProcesses`.
- `76475477` — "Fix meeting buffer copy for VPIO multichannel formats." Evidence of VPIO's channel-count mutation in practice.
- `97134e9b` (2026-04-10) — "Refactor meeting recording to VPIO-first pipeline." The regression commit this document responds to.
