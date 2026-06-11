# Issue #474 — Instant Dictation × Pause Media: media audio bleeds into transcript head

> Status: **IMPLEMENTED** — Tiers 0 + 1 shipped via PR #482; Tier 2 deferred. Archived 2026-06-11.
> Date: 2026-06-09 (tiering 2026-06-10; implementation 2026-06-10)
> Issue: https://github.com/moona3k/macparakeet/issues/474
> Investigated by: Claude (full code + diagnostic-log review, 2026-06-09)
> Decision (owner, 2026-06-10): proceed with **Tier 0 + Tier 1**; Tier 2
> stays deferred pending instrumentation data and a second report.
>
> **Implemented (2026-06-10):**
> - Tier 0a — `media_pause_*` / `media_resume_*` outcomes (+ `snapshot_ms`)
>   mirrored into `dictation-audio.log` from `SystemMediaController` and the
>   `meeting_active` skip from `DictationMediaPauseCoordinator`. Window 2 is
>   now measurable in uploaded logs as
>   `timestamp(media_pause_sent) − timestamp(dictation_capture_start)`.
> - Tier 0b — speakers caveat added to the Pause Media settings caption.
> - Tier 1 — `onMediaPaused` callback on the pause coordinator →
>   `DictationServiceSession.discardPreRollForActiveCapture(sessionID:)` →
>   `AudioRecorder.discardPreRollForActiveRecording()`; `stop()` trims the
>   prepended pre-roll from the WAV (atomic temp-file rewrite) and applies
>   the minimum-sample gate to the post-trim count. Best-effort semantics as
>   designed. Log lines: `dictation_capture_preroll_discarded`,
>   `dictation_capture_preroll_discard_failed`,
>   `discarded_preroll_frames` on insufficient captures.
> - Remaining for a future agent: Tier 2 (see revisit criteria below) and
>   archiving this plan once Tier 2 is either built or formally rejected.

## TL;DR for the implementing agent

Valid bug, mechanism fully confirmed in code. With **Instant Dictation**
(`instantDictationEnabled`) and **Pause Media** (`pauseMediaDuringDictation`)
both on — both opt-in, default `false` — and media playing through
**speakers**, the head of the dictation WAV contains media audio that the ASR
engine faithfully transcribes. Two windows produce the bleed, both by design:

1. **Pre-roll window (0.45 s, entirely pre-press)** — Instant Dictation
   prepends the last 0.45 s of the warm-mic ring buffer, i.e. audio recorded
   *before* the hotkey press. No pause, however fast, can silence audio that
   already happened.
2. **Pause-latency window (~0.3–1.5 s, post-press)** — the media-pause IPC is
   deliberately fire-and-forget (PR #384) and is slow by construction: an
   osascript subprocess snapshots now-playing state (1.25 s timeout) *before*
   the pause command is sent. The warm engine meanwhile delivers its first
   live buffer in as little as 7 ms.

There is **no AEC** in the dictation path (raw capture, `wantsVPIO: false`),
so speaker output enters the mic at full level. Headphone users can never hit
this.

**Recommended path (2026-06-10): Tier 0 (guidance + instrumentation) and
Tier 1 (drop pre-roll when media was confirmed playing) now; Tier 2 (warm
now-playing snapshot) explicitly deferred pending instrumentation data and a
second report.** Do NOT make the two toggles mutually exclusive — the
conflict is speakers-only, not inherent to the feature pair. See "Fix tiers"
below for the full reasoning and the traps.

## The report

Filed via in-app feedback (moonpi-bot) on v0.6.22 (build 20260609180743,
commit `92c3dfdfbade`), macOS 26.5.1, M1 Max. Reporter is the same engaged
user ("Mustard") behind #383, #421, and #450 — their reports already drove
two fixes in this exact area. They enabled Instant Dictation for the first
time ~1 h before filing (first-ever `dictation_warm_capture_started` in their
log at 18:53 UTC; issue filed 19:54 UTC).

Reporter's observations, all consistent with the confirmed mechanism:

- Bleed is **content-dependent**: happens when the media has voice-like audio
  at press time; clean when the media is in a natural pause.
- **Speak immediately → clean** (near-field voice dominates the SNR).
- **Press, wait for media to pause, then speak → dirty** (the head of the WAV
  is pure media speech followed by a silence gap — maximally transcribable).
- Reporter hypothesized "VAD is picking up the voice-like media audio."
  **Mostly right, one detail wrong:** there is no VAD anywhere in the
  dictation path. The entire WAV (pre-roll + live) goes to Parakeet/Nemotron;
  the engine transcribes whatever speech is in it. VAD exists only in meeting
  live-preview chunking. Correct this gently if replying on the issue.

Cruel irony worth understanding: the Pause Media feature *trains* the exact
timing that maximizes the bleed — it teaches users to wait for silence before
speaking, which hands the pipeline a clean run of media-only speech.

## Confirmed mechanism, with code references

Press-time sequence (`DictationFlowCoordinator.startRecordingTask`,
`Sources/MacParakeet/App/DictationFlowCoordinator.swift:878-901`):

1. `mediaPauseCoordinator.requestPauseBeforeDictationCapture()` — explicitly
   fire-and-forget (`DictationFlowCoordinator.swift:888-893`; comment explains
   why: awaiting the round-trip clipped first words — that was issue #383 →
   PR #384 "Decouple media pause from dictation capture start", `b25eb0a47`).
2. `serviceSession.startRecording(...)` → `AudioRecorder.start()`.

The pause path (`Sources/MacParakeet/App/DictationMediaPauseCoordinator.swift:53-91`
→ `Sources/MacParakeetCore/Services/System/SystemMediaController.swift:53-79`):

- `pauseIfPlaying()` first runs `OsaScriptNowPlayingSnapshotReader.snapshot()`
  — spawns `/usr/bin/osascript -l JavaScript` which loads the private
  MediaRemote framework and reads `MRNowPlayingRequest`
  (`SystemMediaController.swift:132-210`, timeout 1.25 s). The osascript
  subprocess exists because Apple-signed `osascript` carries the MediaRemote
  entitlements the app lacks on modern macOS — **do not** "optimize" the
  snapshot into an in-process call without re-checking entitlement reality.
- Only after the snapshot returns does it send pause via in-process
  `MRMediaRemoteSendCommand` (`MediaRemoteCommandSender`, `:242-291`).
- Then the media app reacts (some players fade out over 100–500 ms), plus
  output-device latency.

The capture path (`Sources/MacParakeetCore/Audio/AudioRecorder.swift`):

- `preRollPrependSamples = 0.45 s` at 16 kHz (`AudioRecorder.swift:187`).
- `start()` snapshots the ring's suffix and writes it to the WAV head
  (`AudioRecorder.swift:340-350`) before the live tap appends.
- The warm subscriber keeps the engine hot; first live buffer arrives in
  ~7–100 ms (vs ~250 ms cold).
- Capture is raw: `wantsVPIO: false`, so no echo cancellation. With built-in
  mic + built-in speakers (the reporter's setup per the log), bleed is
  acoustic and unavoidable at the capture layer.

Net result with media on speakers: WAV head = 0.45 s pre-press media
+ ~0.3–1.5 s post-press media-until-silence + user speech.

Tail bleed is **not** possible: resume runs after capture stop
(`resumeAfterDictationCapture`).

Note: window 2 exists **even without Instant Dictation** — cold capture
(~250 ms to first buffer) still beats the osascript round-trip, so plain
Pause-Media-on-speakers has always had a smaller version of this. Pre-roll
made the bleed guaranteed and visible.

## Evidence from the uploaded diagnostic log

`diagnostics/1781034873191-dictation-audio.log` (committed `8822ccfc3`,
trimmed `978dc1d97`):

- Line 26071: `2026-06-09T18:53:13.067Z dictation_warm_capture_started
  preroll_s=0.450` — first warm capture ever for this user (only `warm` line
  in 26 631 lines).
- Lines 26073/26084/26094/…: `dictation_capture_preroll_prepend
  sample_count=7200 duration_s=0.450` on every press — ring always full.
- Throughout: `vpio=false`, `transport=built-in` (raw capture, built-in mic).
- Warm-start latency: `engine_started` 19:02:32.291 → `first_buffer`
  19:02:32.298 (7 ms). Cold sessions earlier in the log: ~150 ms engine start
  + ~100 ms first buffer.
- **Gap:** media-pause events (`media_pause_skipped/sent/failed`,
  `media_resume_*`) go to OSLog only (`Logger`, categories
  `DictationMediaPause` and `SystemMediaController`) — they never appear in
  `dictation-audio.log`, so uploaded diagnostics cannot quantify the pause
  window. No telemetry events exist for media pause either
  (grep `TelemetryEvent.swift` — nothing).

## Why pre-roll exists (don't "fix" by deleting it)

Commit `07d16a327` / PR #418, motivated by issue #414 (Hex-style hot mic):
users begin speaking at/before the press and lose the first syllable. Issue
#450's test data shows it plainly — "one two three four five six seven eight"
spoken at press transcribed as "Four five six seven eight" on the cold path.
The 1 s ring / 0.45 s prepend numbers were lifted from Hex's design. ADR-015
amendment covers the passive warm subscriber (`blocksVPIOPromotion=false`).

The design-tension triangle, for orientation:

- Gate capture on pause → clipped first words (#383).
- Don't gate (PR #384) → post-press bleed window.
- Add pre-roll (#418) → guaranteed pre-press bleed window.

You cannot satisfy "no first-word loss" and "no media bleed" simultaneously
without either AEC or knowledge-based suppression. Neither the media-pause
plan (`plans/active/2026-05-dictation-media-pause.md`) nor the 2026-06-09
audit analyzed this interaction — it's a genuinely new finding.

## Severity

P3. Opt-in × opt-in × speakers-only, so small blast radius — but it is a
*wrong text inserted into the user's document* defect, which costs more trust
than missing text. Reporter is technical, repeat, and high-signal.

## Fix tiers (assessed 2026-06-10)

Framing question the owner asked: *fixable, or just recommend not combining
the features?* Answer: **mostly fixable, and "don't combine" is the wrong
rec.** The conflict is conditional, not inherent — on **headphones** both
features work together perfectly (no acoustic path from media to mic). The
incompatibility is specifically *speakers + wait-to-speak*. Do **not** make
the toggles mutually exclusive in the UI; that punishes headphone users who
legitimately want both. The honest guidance is "with speakers, speak as you
press — or use headphones."

**Tier 0 — guidance + instrumentation (free; do now).**
- Reply on #474: confirm the mechanism, credit the hypothesis, correct the
  VAD detail (no VAD in the dictation path — the whole WAV is transcribed),
  give the speakers guidance above.
- Settings caption note on one or both toggles ("with speakers, media speech
  may appear at the start of the transcript; use headphones or speak right
  away").
- Instrumentation: mirror `media_pause_requested` / `media_pause_sent` /
  `media_pause_skipped` (+ ms-since-press) into
  `AudioCaptureDiagnostics.append(...)` so uploaded logs quantify the real
  pause window in the wild. Optionally a telemetry counter (remember:
  telemetry allowlist is a two-repo change — Worker `ALLOWED_EVENTS` in
  macparakeet-website).

**Tier 1 — drop pre-roll when media was confirmed playing (cheap; do now;
~halves the bleed).**
When `pauseIfPlaying()` confirms media *was* playing at press, exclude the
0.45 s pre-roll from transcription. No new IPC, no polling: the confirmation
arrives ~300 ms into capture and transcription only happens at stop, so the
decision is always available in time. This is principled, not a hack — for
the wait-to-speak user the pre-roll is *pure media* (their voice cannot be in
it), so dropping it is a pure win; for the speak-over-media user the pre-roll
was contaminated anyway.
Implementation notes:
- Pre-roll is already written to the WAV head at `start()`. Either remember
  the pre-roll byte/frame count and skip it at transcribe time, or restructure
  to decide inclusion at stop. The trim decision naturally lives where the
  dictation service hands the WAV to the scheduler.
- Wiring crosses targets: `DictationMediaPauseCoordinator` (app target,
  MainActor) learns "media was playing"; `AudioRecorder` (Core, actor) owns
  the WAV. Capture "media_was_playing_at_press" as a fact **independent of
  token retention** — for very short dictations the token can be acquired and
  immediately resumed by the generation guard, but the playing-at-press fact
  still holds and must still trigger the pre-roll drop.
- Caveat to set expectations: Tier 1 alone kills only window 1. The
  ~0.3–1.5 s pause-latency window still bleeds, so the reporter's
  wait-to-speak symptom shrinks but does not vanish.

**Tier 2 — warm/cached now-playing snapshot (real fix for window 2;
DEFERRED).**
Keep a cached now-playing snapshot while pause-media is enabled so the press
path can send `MRMediaRemoteSendCommand(pause)` within milliseconds and build
the resume token from the cache. Combined with Tier 1, residual bleed shrinks
to maybe a stray word during the media app's own fade-out.
Why deferred (decision context, 2026-06-10):
- The cache requires **idle osascript polling** — the app cannot read
  now-playing state in-process (entitlement gap; that is why osascript exists
  here at all), and one-shot osascript can't push notifications. Periodic
  subprocess spawns + battery cost to serve an opt-in × opt-in niche, on the
  strength of one report. Complexity ahead of evidence.
- Not provably zero even then: media-app fade-out (~100–500 ms in some
  players) and snapshot staleness leave a residual.
- Revisit when Tier 0 instrumentation shows real-world pause latency
  (is window 2 ~300 ms or ~1.5 s?) **and** a second report exists.
- Staleness analysis if/when built: poll-every-~5 s is tolerable. Stale
  "playing" (user manually paused seconds ago) → redundant pause command
  (pause is not a toggle; harmless) + unnecessary pre-roll drop (minor).
  Stale "not playing" (media started seconds before press) → fall back to
  today's behavior. Neither corrupts resume correctness if the token is still
  built from a confirmed snapshot.

⚠ **Trap — do not do "optimistic pause, snapshot after":** pausing first
poisons the snapshot needed for a sound resume token. The post-pause snapshot
reads `isPlaying=false`, you cannot distinguish "we paused it" from "user had
paused it," and either media gets stuck paused (no token) or you wrongly
auto-resume something the user paused themselves. The snapshot-first ordering
in `pauseIfPlaying()` is load-bearing; the only sound speedup is making the
snapshot *already available* at press time (Tier 2), not reordering it.

**Tier 3 — AEC / VPIO: rejected (provably-zero requires this; not worth it).**
VPIO is deliberately not the dictation default (PR #189 duplex-channel
regression, call-safety; see `Sources/MacParakeetCore/Audio/README.md` — VPIO
is sticky process-wide once engaged). The neural echo-suppression plan
(`plans/active/2026-05-meeting-neural-echo-suppression.md`) is meeting-scoped
and needs a far-end system-audio reference; dictation doesn't capture system
audio and shouldn't (it would drag Screen Recording permission into the
dictation flow — onboarding funnel data already shows a −21 pt cliff at the
screen-recording step).

**Also rejected — timestamp-based head trimming.**
Dropping ASR words whose timestamps predate the estimated pause-effective
moment is heuristic, risks eating real first words (the speak-immediately
user's speech lives inside window 2 — there is no reliable discriminator
between their voice and media speech without diarization), and violates
"Simplicity is the product."

## Implementation notes / constraints for the fix

- `AudioRecorder` pre-roll state is guarded by per-call/lifecycle
  **generation counters** (`preRollCaptureGeneration`,
  `warmCaptureLifecycleGeneration`, `startCallGeneration`) — read the long
  comments in `AudioRecorder.swift:160-300` and the Audio README before
  touching start/stop/refresh ordering. Audit item R-6 already covers a
  benign warm-retry race; don't reintroduce a real one.
- Tap closures run on the audio render thread: no allocation, no actor hops
  (`OSAllocatedUnfairLock` fields only).
- `DictationMediaPauseCoordinator` has its own generation guard so a fast
  capture-stop correctly releases an in-flight pause token. A cached-snapshot
  redesign must preserve that resume correctness (tests exist:
  `pauseTask` is `private(set)` specifically so tests can await the IPC).
- Settings keys: `pauseMediaDuringDictation`, `instantDictationEnabled`
  (`AppRuntimePreferences.swift:197-198`), both default `false`. Both rows
  show Beta badges in `SettingsView`.
- Meeting recordings already skip media pause
  (`media_pause_skipped reason=meeting_active`).
- Relevant tests to extend: `DictationMediaPauseCoordinator` tests,
  `AudioRecorderFormatChangeTests`, `SharedMicrophoneStreamTests`.
  Run `swift test --filter Audio` then full `swift test`.

## Verification / repro guidance

Repro (needs speakers, not headphones): enable both toggles, play a video
with continuous dialogue at moderate volume on built-in speakers, press the
dictation hotkey, **wait** for the media to pause, then speak. Expect the
video's dialogue at the transcript head. Control: same flow but speak
immediately → mostly clean; same flow on headphones → always clean.

After a fix, the uploaded-log signature to look for (post-instrumentation):
`dictation_capture_start` → `media_pause_sent` delta in the tens of ms, and
no `dictation_capture_preroll_prepend` (or a trimmed one) when media was
playing.

## Suggested sequencing

1. **Tier 0a:** land instrumentation (`media_pause_*` lines into
   `AudioCaptureDiagnostics` with ms-since-press) — independently shippable,
   improves every future report of this class.
2. **Tier 0b:** reply on #474 — confirm the mechanism, credit the hypothesis,
   correct the VAD detail, give the speakers/speak-promptly/headphones
   guidance, link this plan. Add the settings caption note.
3. **Tier 1:** drop pre-roll from transcription when media was confirmed
   playing at press. Behind the existing settings, no new flags. Tests:
   the cross-target "media_was_playing_at_press" plumbing, the
   short-dictation case where the token is acquired-then-immediately-resumed,
   and pre-roll inclusion unchanged when media was not playing / pause-media
   is off.
4. **Stop here.** Tier 2 only when instrumentation shows window 2 is large in
   the wild AND a second report arrives. If/when built: warm snapshot cache,
   tests for the optimistic-pause trap and staleness cases.
5. On completion of Tiers 0–1: update
   `plans/active/2026-05-dictation-media-pause.md` (or fold it into this doc)
   and the Audio README's Instant Dictation paragraph with the interaction
   note; archive completed plans to `plans/completed/`.
