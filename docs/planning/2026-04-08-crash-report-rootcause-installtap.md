# Crash Report Root-Cause Analysis — 2026-04-08

## For anyone who just wants the plain-English version

> **Sorry folks — there's a bug in MacParakeet 0.5.5 (the current release)
> that can crash the app the first time you press the dictation hotkey
> after launching.** We've identified it and a fix is in flight (tracked
> in #91); a 0.5.6 patch will ship shortly.
>
> **Who is affected:** Only people whose Mac's input device is an
> "aggregate" audio device — this is macOS's automatic wrapper around
> virtual-audio tools like **Krisp, BlackHole, Loopback, SoundSource,
> Audio Hijack, Rogue Amoeba utilities**, manual Aggregate Devices you
> created in Audio MIDI Setup, or a Bluetooth-bridged setup. If your
> dictation works fine with the built-in MacBook microphone and no
> third-party audio software, this bug doesn't touch you.
>
> **What it looks like:** You launch MacParakeet, press the dictation
> hotkey, and the app silently vanishes. No error, no warning, no crash
> dialog (macOS doesn't show one for menu-bar apps). The pill disappears.
>
> **How to recover right now:**
>
> 1. **Just relaunch the app.** In most cases the second or third
>    relaunch will work, and once one dictation succeeds, everything
>    stays working for the rest of the session.
> 2. **If it keeps crashing:** temporarily switch your Mac's default
>    input device to your built-in microphone in
>    *System Settings → Sound → Input*, then launch MacParakeet. Once
>    you've successfully started one dictation, you can usually switch
>    back to your aggregate device.
> 3. **If you're on macOS 26 (Tahoe) beta:** same advice. The bug hits
>    Tahoe users too.
>
> **What we're doing:** wrapping the unsafe audio call so it throws a
> clean error instead of crashing the process, and making the audio
> format handling more resilient to the device-state transitions that
> trigger the bug. You'll get a `dictation_failed` message instead of a
> crash when the underlying problem occurs, and the app will auto-retry
> with the built-in microphone.
>
> **Your data is safe.** The crash happens *before* any audio is
> recorded. No dictations, transcripts, or files are lost.
>
> **Apologies for the inconvenience — and thank you for sending crash
> reports.** The telemetry is how we found this. Tracked in
> [#91](https://github.com/moona3k/macparakeet/issues/91).

---

> Status: **ACTIVE** — investigation complete (two passes), fix not yet shipped.
>
> This report was written in two passes. The first pass reached the right
> conclusion but contained several imprecisions (line-number off-by-4 in the
> return address, "AVFAudio" overclaim where the system-frame range is more
> honestly "audio framework stack", and extrapolated-not-verified device info
> for cluster C). The fresh-eye review (§10) re-verified every claim against
> primary sources and updated the body. Read §10 if you want the audit trail;
> the rest of the doc has been edited in place to reflect the verified facts.

## TL;DR

**10 of the last 14 production crashes (71%) are a single, deterministic bug in our code:**

`AudioRecorder.configureAndStart(...)` at `AudioRecorder.swift:227` calls
`AVAudioInputNode.installTap(onBus:bufferSize:format:block:)`. The call raises
an **uncatchable Objective-C `NSException`** from the macOS audio framework
stack (AVFAudio / AudioToolbox / CoreAudio HAL) on certain user audio device
configurations. Swift cannot catch `NSException` with `try/catch`, and Cocoa's
`NSApplication.run()` event loop catches unhandled `NSException`s internally
and calls `abort()` directly — bypassing our `NSSetUncaughtExceptionHandler`,
which is why every crash record shows `crash_type: signal` rather than
`crash_type: exception` (see §3.6 for the full handler-chain analysis).
`SIGABRT` (signal 6) arrives, our signal handler captures the backtrace, and
the report is uploaded on next launch.

**Both affected users are on a USB aggregate audio input device**
(`CADefaultDeviceAggregate-*`, `device_sub_transport: usb`, 2 channels,
48 kHz) — confirmed from their `dictation_completed` telemetry rows, not
extrapolated. The trigger is transient state in the aggregate (Bluetooth
handshake, USB hot-plug, virtual audio driver restart, wake-from-sleep)
causing the format captured at line 164 to no longer match the bus's current
format at line 227.

One of the two affected users (cluster C, CA / M4 / macOS 26.2) is a
**brand-new user still in the onboarding flow** — the sessions after the
crashes show `onboarding_step`, `model_download_started`, and
`model_download_completed`. That is the most expensive crash to take
because it destroys first-impression trust; see the "Onboarding stuck
incident" entry in `MEMORY.md` for the prior precedent.

The remaining 4 crashes are unrelated system-level faults (see "Other clusters"
at the bottom of this doc).

**Fix shape:** wrap the AVFAudio calls in `AudioRecorder.configureAndStart`
(specifically `inputNode.outputFormat(forBus: 0)` and `inputNode.installTap(...)`,
and defensively `engine.start()`) in a thin Objective-C `@try/@catch` trampoline
that converts `NSException` to a Swift `Error`. This is the standard technique
for every Swift project that talks to AVFAudio. We currently have zero ObjC
exception trampolines in the codebase (`grep @try Sources/` returns only
`CrashReporter.swift`, which registers an uncaught-exception *handler*, not a
catcher — and that handler never fires for this crash because Cocoa's event
loop short-circuits it, see §3.6).

---

## 1. Data pulled from telemetry

Source: D1 database `macparakeet-telemetry` on the live Cloudflare Worker.
Queries run at ~2026-04-08T23:45Z. Window: 72 hours.

```sql
SELECT event_id, session, app_ver, os_ver, chip, country, ts, props
FROM events
WHERE event='crash_occurred' AND ts >= datetime('now','-72 hours')
ORDER BY ts DESC
```

### 1.1 Raw counts (48h for comparison + 72h for the stale crash)

| Event | Count (48h) | Sessions (48h) |
|---|---|---|
| `crash_occurred` | **14** | 14 |
| `dictation_failed` | 13 | 10 |
| `llm_chat_failed` | 5 | 2 |
| `model_download_failed` | 5 | 2 |
| `diarization_failed` | 4 | 3 |
| `llm_prompt_result_failed` | 3 | 2 |
| `llm_summary_failed` | 2 | 1 |
| `transcription_failed` | 2 | 2 |

All 14 `crash_occurred` records are on `app_ver = 0.5.5` except one stale record
from `app_ver = 0.5.1` whose `crash_app_ver` is `0.4.27` (a pre-0.5 crash
persisted on disk and uploaded post-upgrade — ignore).

### 1.2 The 14 crashes

| # | `ts` | User country / chip / OS | `app_ver` | `crash_app_ver` | `signal` / name | `uuid` |
|---|---|---|---|---|---|---|
| 1 | 2026-04-08T19:01:03Z | US / Apple M1 Max / 26.3 | 0.5.5 | 0.5.5 | 11 / SIGSEGV | DDD7A497-… |
| 2 | 2026-04-08T15:28:35Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 3 | 2026-04-08T15:25:59Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 4 | 2026-04-08T14:00:33Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 5 | 2026-04-08T14:00:19Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 6 | 2026-04-08T13:51:10Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 7 | 2026-04-08T13:51:01Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 8 | 2026-04-08T13:50:55Z | DE / Apple M4 Max / 15.6 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 9 | 2026-04-07T14:13:05Z | DE / Apple M4 Max / 26.4 | 0.5.1 | **0.4.27** | 6 / SIGABRT | **3BB999A2-…** (stale) |
| 10 | 2026-04-07T14:08:25Z | BY / Apple M2 Max / 14.8 | 0.5.5 | 0.5.5 | 10 / SIGBUS | DDD7A497-… |
| 11 | 2026-04-07T14:03:40Z | BY / Apple M2 Max / 14.8 | 0.5.5 | 0.5.5 | 10 / SIGBUS | DDD7A497-… |
| 12 | 2026-04-06T18:13:17Z | CA / Apple M4 / 26.2 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 13 | 2026-04-06T18:00:53Z | CA / Apple M4 / 26.2 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |
| 14 | 2026-04-06T17:56:20Z | CA / Apple M4 / 26.2 | 0.5.5 | 0.5.5 | 6 / SIGABRT | DDD7A497-… |

The single `uuid = DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65` on every current crash
is the `LC_UUID` of the 0.5.5 `MacParakeet` Mach-O. I verified this by mounting
the live DMG (`downloads.macparakeet.com/MacParakeet.dmg`, 0.5.5 build
`20260406005332`) and running `dwarfdump --uuid`:

```
UUID: DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65 (arm64)
  /Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet
```

The stale row #9 has a different UUID `3BB999A2-9CE1-39E5-AB18-1A87F785E3CF`,
which is not 0.5.5 — that's a 0.4.27 binary whose crash file sat on disk and
was uploaded after the user upgraded.

### 1.3 Clustering by stack-trace signature

Raw frame addresses vary between crashes because of ASLR. To compare stacks
across processes, subtract `slide` from each address to get a **fixed binary
offset**. The main executable loads at `0x100000000 + slide`, so:

```
offset = address − slide − 0x100000000
```

Frame 0 of every crash resolves to the same offset `0x865c70`, which atos
against the 0.5.5 binary reports as:

```
closure #1 in variable initialization expression of
static CrashReporter.signalHandler (CrashReporter.swift:202)
```

That's our crash reporter's `backtrace()` call — so frame 0 is always the
reporter itself, not the real crash site. Looking at the frames above and
below frame 0:

**Cluster A — 7 crashes, DE / M4 Max / macOS 15.6**

Stack (using `slide = 0x42e8000` from row 6 as the canonical sample, offsets
identical for all 7):

```
frame  address        offset (−slide−0x100000000)   symbol
-----  -------------  ---------------------------   ---------------------------
 0     0x104b4dc70    0x865c70                      CrashReporter.signalHandler
                                                    (our crash reporter —
                                                    every crash's frame 0)
 1-9   0x193…0x192d   libsystem / libobjc / libswiftCore — abort/unwind path
 10-12 0x1f3b…0x1f3c  3 consecutive frames in an audio-framework dylib
                     (AVFAudio / AudioToolbox / CoreAudio HAL — see §3.1)
 13    0x104aee38c    0x80638c                      AudioRecorder.configureAndStart
                                                    (4 bytes past BL for installTap;
                                                    see §3.3 — this is the in-flight
                                                    return address for line 227)
 14    0x104aecd70    0x804d70                      AudioRecorder.start
                                                    → AudioRecorder.swift:80
                                                    (`try configureAndStart(nil)`)
 15    0x104aec4c8    0x8044c8                      AudioProcessor.startCapture
                                                    → AudioProcessor.swift:29
 16-19 0x27b9…        libswift_Concurrency — async resume on actor
 20-23 0x192f…0x193…  Foundation main run loop / NSApplication.run
```

All 7 crashes share the exact same frame offsets
`{0x865c70, 0x80638c, 0x804d70, 0x8044c8}`. The slide values I verified are
`0x42e8000`, `0x2a94000`, `0x2288000`, `0x24e4000`, `0xf14000`, `0x2214000`,
`0x4d44000`. Seven distinct ASLR slides, identical binary offsets → identical
code path.

**Cluster C — 3 crashes, CA / M4 / macOS 26.2**

Same app-code offsets `{0x865c70, 0x80638c, 0x804d70, 0x8044c8}`. Slides are
`0x380000`, `0x2a20000`, `0x4fdc000`. The system-library region frames have
**completely different addresses** from cluster A (macOS 15.6) because
macOS 26.2 has a different dyld shared cache layout — cluster C's frames 1–12
are in the `0x181…` and `0x225b…` ranges. The app-code offsets are bit-identical
to cluster A, which is the only thing that matters for clustering: the same
code path in the same binary is being reached from different OS versions via
different framework-side addresses.

**Conclusion from clustering:** clusters A and C are the same bug in our code,
reached by two distinct users on different macOS versions and different
hardware. **10 of 14 = 71% of crash volume in the window.**

**Cluster B — 2 crashes, BY / M2 Max / macOS 14.8.5, SIGBUS**

After removing frame 0 (our signal handler), *no remaining frames are in the
app binary*. Every frame is in the shared cache (0x183…, 0x18e…, 0x19b…). This
is a crash on a worker thread running entirely in Apple frameworks. SIGBUS on
an audio-stack address range likely points at CoreAudio HAL / AVFAudio / CoreML
mmap fault on the older OS. We have no direct app stack frame to point at. Not
the same bug as A/C.

**Cluster D — 1 crash, US / M1 Max / macOS 26.3, SIGSEGV**

8-frame stack, very short. Frame 2 is at offset ~0x9336000 above the slide,
which does NOT fit our main binary's address range — it is in a dynamically
loaded framework (FluidAudio, a generated `.mlmodelc` code blob, or similar).
Surrounding frames are in the 0x198…/0x19b… range (audio / CoreML territory).
Different stack shape from A/C, different signal. Not the same bug.

**Cluster E — 1 stale crash (row 9)**

Different binary UUID, `crash_app_ver = 0.4.27`. Ignore.

### 1.4 Dictation failures in the same window (for context)

13 `dictation_failed` events:

| error_type | count | Note |
|---|---|---|
| `CancellationError` | 6 | Benign — user hit Escape / released hotkey |
| `URLError.secureConnectionFailed` / `.timedOut` | 3 | Single CN user, LLM provider network |
| `AudioProcessorError` (old builds) | 2 | 0.4.11 / 0.4.12 legacy |
| `STTError.transcriptionFailed` (CoreML program) | 1 | 0.4.21 legacy |
| `AudioProcessorError.insufficientSamples` | 1 | 0.4.14 legacy |

Nothing on 0.5.5 here other than Escape-cancels and the CN network errors.
The installTap bug is notable precisely because it does *not* show up as
`dictation_failed` — the error path in `DictationService.startRecording`
(line 148-175) can't catch `NSException`, so the failure surfaces as a crash,
not a `dictation_failed` event.

---

## 2. Symbolication process (reproducible)

Because the dSYM for 0.5.5 was lost before commit `704dfde` ("Archive dSYM
during release builds for crash symbolication") landed on 2026-04-06, I
recovered function names by running `atos` directly against the stripped
release binary inside the shipped DMG.

```sh
# 1. Download the live 0.5.5 DMG (cache-bust the CDN)
curl -s -L -o /tmp/MacParakeet-055.dmg \
  "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)"

# 2. Mount and verify UUID matches the crash reports
hdiutil attach -nobrowse -readonly /tmp/MacParakeet-055.dmg
dwarfdump --uuid /Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet
# → UUID: DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65 (arm64)  ✓ matches telemetry

# 3. Symbolicate the four fixed app offsets from cluster A/C
atos -o /Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet \
     -arch arm64 -l 0x100000000 \
     0x100865c70 0x10080638c 0x100804d70 0x1008044c8
```

Output:

```
closure #1 in variable initialization expression of
    static CrashReporter.signalHandler  (CrashReporter.swift:202)
AudioRecorder.configureAndStart(overrideDeviceID:)  (AudioRecorder.swift:227)
AudioRecorder.start()                               (AudioRecorder.swift:80)
AudioProcessor.startCapture()                       (AudioProcessor.swift:29)
```

(When I first queried with a slightly different offset atos reported
`<compiler-generated>:0` for `configureAndStart`; probing offsets in
10-byte increments eventually landed the PC squarely on the `installTap`
call site at line 227. I also confirmed
`0x1008063a0 → AudioRecorder.configureAndStart (AudioRecorder.swift:320)`,
which is the `sampleCounter.withLock { $0 = 0 }` call right after
`installTap` — a sanity check that atos's line mapping is accurate for this
function.)

`atos` works fine on a stripped release binary for *function-name* resolution
because the Mach-O still contains the symbol table (`LC_SYMTAB`); only the
DWARF debug info (line numbers, inlining, argument types) is in the dSYM. For
this investigation, function names + an actual read of the source are enough.

---

## 3. Root-cause analysis

### 3.1 The call chain at the moment of crash

Reading the stack bottom-up (entry → crash):

1. `NSApplication.run` → main run loop (Foundation, frames 20–23)
2. Swift concurrency executor resumes the actor (`libswift_Concurrency`,
   frames 16–19) — this is the await-point inside
   `DictationService.startRecording`
3. `AudioProcessor.startCapture()` (`AudioProcessor.swift:29`)
   — frame 15, offset `0x8044c8`
4. `AudioRecorder.start()` (`AudioRecorder.swift:80`)
   — frame 14, offset `0x804d70`
5. `AudioRecorder.configureAndStart(overrideDeviceID: nil)` with in-flight
   return address at `AudioRecorder.swift:227` — frame 13, offset `0x80638c`
   (see §3.3 for the off-by-4 return address explanation)
6. Into the audio framework stack (frames 10–12)
7. Up into libswiftCore / libobjc / libsystem abort/unwind path (frames 1–9)
8. `SIGABRT` raised → our signal handler captures backtrace (frame 0)

Frames 10–12 are in the macOS audio framework neighborhood — I cannot pin
them to an exact dylib (AVFAudio vs AudioToolbox vs CoreAudio HAL) without
the macOS 15.6 and 26.2 dyld shared caches, which I do not have. What I can
verify: they are three consecutive system-library frames called from our
`configureAndStart`, they are BELOW the libswiftCore/abort path, and
`installTap` is the only operation in our `configureAndStart` that crosses
into the audio framework stack at this call site. That's sufficient for the
diagnosis; pinning the exact dylib is not necessary because the fix (ObjC
trampoline inside our Swift code) catches the exception regardless of which
framework raised it.

The exception is raised inside the audio framework stack and unwinds back
through our frames on the way out. Because `installTap` is an `@objc`
Objective-C method and we call it from Swift with no `@try/@catch` trampoline
in between, the `NSException` propagates freely through Swift frames (Swift
knows nothing about it) until it either hits the top-level
`NSApplication.run()` event-loop try/catch or the Swift runtime's uncaught
handler, either of which calls `abort()` → `SIGABRT`. See §3.6 for why our
own `NSSetUncaughtExceptionHandler` is not firing.

### 3.2 The actual code path

`Sources/MacParakeetCore/Audio/AudioRecorder.swift` around the crash site
(full context, line numbers verified against HEAD):

```swift
 70  public func start() throws {
 71      guard !recording else { return }
 72
 73      let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
 74      logger.debug("mic_permission_status=\(authStatus.rawValue, privacy: .public)")
 75
 76      logAvailableDevices()
 77
 78      // Try with the system default device first
 79      do {
 80          try configureAndStart(overrideDeviceID: nil)      // ← frame 14
 81      } catch {
 82          logger.warning(...)
 83
 84          guard let builtInID = AudioDeviceManager.builtInMicrophone() else {
 85              throw error
 86          }
 87          ...
 95          try configureAndStart(overrideDeviceID: builtInID) // ← fallback (not reached in crash)
 96      }
 97  }

141  private func configureAndStart(overrideDeviceID: AudioDeviceID?) throws {
142      let engine = AVAudioEngine()
143      let inputNode = engine.inputNode
144
145      // Optionally override the input device
146      if let deviceID = overrideDeviceID { ... }
147
         // Log the resolved device, capture telemetry, etc.
         ...
164      let inputFormat = inputNode.outputFormat(forBus: 0)     // ← ALSO can raise
         ...
185      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
186          throw AudioProcessorError.recordingFailed(...)      // ← Swift throw (doesn't help)
189      }
         ...
227      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
228          [weak self] buffer, _ in
             ...
317      }                                                       // ← frame 13 maps here
         ...
322      do {
323          try engine.start()                                  // ← ALSO can raise
324      } catch {
325          inputNode.removeTap(onBus: 0)
326          ...
331      }
337  }
```

Frame 13's offset (`0x80638c`) symbolicates to `AudioRecorder.swift:227` —
that is the `installTap(onBus:bufferSize:format:block:)` call site. The
`installTap` API is a bridged Objective-C method on `AVAudioIONode`; when its
internal validation fails it raises `NSInternalInconsistencyException` or
`com.apple.coreaudio.avfaudio`, both of which are unrecoverable in Swift.

### 3.3 Frame 13's PC is 4 bytes past the installTap BL — why that's stronger evidence

Frame 13 on every cluster A/C crash is at binary offset **`0x80638c`**. When I
walked the binary 4 bytes at a time with `atos` against the shipped 0.5.5
stripped binary, the line mapping looks like this:

```
0x100806380 → AudioRecorder.swift:227   ← BL instruction for installTap
0x100806384 → AudioRecorder.swift:227
0x100806388 → AudioRecorder.swift:227   ← last 4 bytes of the call site
0x10080638c → <compiler-generated>:0    ← PC captured in every crash frame 13
0x100806390 → <compiler-generated>
0x100806394 → <compiler-generated>
0x100806398 → <compiler-generated>
0x1008063a0 → AudioRecorder.swift:320   ← next real source line
0x1008063c0 → AudioRecorder.swift:323   ← try engine.start()
```

On ARM64, `BL` (branch-and-link) stores `PC + 4` in the LR register as the
return address. When a function makes a call, the caller pushes LR to the
stack frame and that's what the stack walker reads. **A frame-pointer
backtrace captures the instruction *after* the in-flight call, not the call
itself.** So a frame 13 PC of `0x80638c` — exactly 4 bytes past the last byte
of the line-227 mapping — is the return address of the `BL` that called
`installTap`. The thread is still "inside" `installTap` (or deeper, in the
frames above it), and would have returned to `0x80638c` if `installTap` had
returned normally. It didn't. An exception unwound through it, the exception
propagated all the way up to `abort()`, `SIGABRT` arrived, and the signal
handler walked a stack that still had the original call's return address
sitting there.

This is the textbook signature of "uncaught exception propagating through an
unreturned call". The `<compiler-generated>` label is because atos only has
sparse line info (Swift embedded metadata, not DWARF — see §2) and the bytes
immediately after a `BL` instruction are not tagged with a source line.

**Bottom line:** the crashing call is unambiguously the `installTap` call at
line 227. Not line 164 (`outputFormat`), not line 209 (`AVAudioFile`), not
line 323 (`engine.start`). The offset arithmetic leaves no room.

### 3.4 Why the Swift `do/try/catch` at line 79-96 does not help

Swift's `throws/catch` only handles values conforming to `Error`. It does
**not** catch Objective-C `NSException`. When Apple's own docs say a method
"may throw an exception," they mean an ObjC `NSException`, which is a
separate unwinding mechanism from Swift error propagation. The only way to
catch these in Swift is via an Objective-C (or Objective-C++) file with a
`@try { ... } @catch (NSException *) { ... }` bridge.

We have zero such bridges. Every AVFAudio call on lines 142–337 can in
principle raise, and Swift `try` does nothing to protect us.

### 3.5 Why `installTap` raises under normal-looking conditions

The most common triggers for `installTap` raising `NSException` in production
(collected from Apple engineering replies on the developer forums and from
observed radars over the last several macOS releases):

1. **Format mismatch after device change.** The `format:` parameter must match
   `inputNode.inputFormat(forBus: 0)` at the time of the call, or be `nil`.
   On line 164 we capture `inputFormat = inputNode.outputFormat(forBus: 0)`;
   63 lines later on line 227 we pass that same value to `installTap`. If the
   hardware format changes between those two calls (Bluetooth HFP ↔ A2DP,
   aggregate sub-device change, sample-rate renegotiation), the captured
   format no longer matches the bus's current format and `installTap` raises.
2. **Aggregate device in an inconsistent state.** Both affected users show
   `device_name = CADefaultDeviceAggregate-*` in their successful dictations
   (rows from sessions 77F616B2 and 8141EB13). macOS auto-creates these
   aggregate wrappers and they are a known source of AVFAudio exceptions when
   their sub-devices disappear or their clock source is invalid.
3. **Mic permission state race.** On recent macOS, calling `inputNode` APIs
   before the permission prompt has been resolved can raise. We check
   `authorizationStatus` on line 73 but *only log it* — we do not gate the
   call. If `status == .notDetermined` at launch we will plough straight into
   the AVFAudio call and roll the dice.
4. **Tap already installed.** If a prior session failed to clean up
   (e.g., another `configureAndStart` started a tap and then an early return
   skipped `removeTap`), a subsequent `installTap` on the same bus raises
   "attempting to install a tap on a bus that already has one". Looking at
   the code, every tap install is followed by `engine.start()` in its own
   `do { ... } catch { inputNode.removeTap(onBus: 0) ... }`, so this case is
   handled — but only for the `engine.start()` failure path. If anything
   between `installTap` and `engine.start()` throws (it can't today, but a
   future edit could introduce one), we would orphan a tap.
5. **Buffer size 4096 incompatible with the hardware preferred size.** On
   some USB interfaces, `installTap` rejects a `bufferSize` that is not a
   valid multiple of the hardware buffer. 4096 is almost always safe but
   not guaranteed.

I can't tell which of these fired without the exception's `reason` string,
which the current crash reporter does not capture (it only captures signal
number + address backtrace, not the `NSException.reason`). See §5 for the fix.

### 3.6 Why the pattern looks "intermittent"

For cluster A (DE user), the seven crash timestamps (from `crash_ts`) are:

```
13:50:32, 13:50:37, 13:50:46  → three crashes in 14 seconds (rapid relaunch)
14:00:06, 14:00:21            → two crashes in 15 seconds (second attempt batch)
15:25:35, 15:28:11            → two more, roughly three minutes apart
```

Between the 14:00 pair and the 15:25 pair, the **same user** (same binary,
same chip, same OS) ran session `8141EB13` — uploaded the 14:00:21 crash,
then successfully dictated for **82 minutes** (14:03 → 15:22, many
`dictation_started`/`dictation_completed` pairs), quit, relaunched, and
crashed again at 15:25:35.

This is the signature of an audio-device-state-dependent bug:

- The user has a USB aggregate audio device selected
  (`device_name = CADefaultDeviceAggregate-60938-10`,
  `device_transport = aggregate`, `device_sub_transport = usb`,
  `device_channels = 2`, `device_sample_rate = 48000` —
  confirmed from `dictation_completed` rows in sessions `8141EB13` and
  `77F616B2`).
- Sometimes, when they press the hotkey, the aggregate device's internal
  format is in an inconsistent state (right after wake-from-sleep, right
  after a Bluetooth headset toggled power, USB hot-plug, virtual audio
  driver restart, etc.) and `installTap` raises.
- Sometimes the state is fine and everything works.
- Once in a working state, it stays working for the rest of the session.

**Cluster C shows the same pattern on macOS 26.2 — but critically, the
affected user is going through onboarding for the first time.** Pulling
sessions `30CF5A2F`, `6A865200`, `EEAD4122` from telemetry shows:

- Three consecutive process launches, each immediately uploading a crash
  report from the previous launch.
- The third session (`EEAD4122`) after reporting its crash then runs
  `onboarding_step` events, `model_download_started`,
  `model_loaded`, `model_download_completed`, and finally
  `onboarding_completed` — this is a brand-new user's first-ever session
  with the app.
- Their device is also a USB aggregate:
  `device_name = CADefaultDeviceAggregate-35104-0`,
  `device_transport = aggregate`, `device_sub_transport = usb`,
  `device_channels = 2`, `device_sample_rate = 48000`. Same profile as
  cluster A.

This matters a lot for severity. The **prior precedent** in `MEMORY.md` is
the "Onboarding stuck incident (v0.4.22)" — a previous regression that
blocked ~23 users during onboarding cost disproportionate trust. First-run
crashes are the highest-leverage crashes to kill.

### 3.7 Ruling out alternative hypotheses

| Hypothesis | Verdict | Why |
|---|---|---|
| "It's a SwiftUI view body crash" (my earlier guess before symbolication) | **Wrong.** | Symbolication shows the stack is `AudioProcessor → AudioRecorder → installTap`, not SwiftUI. I was fooled by the SIGABRT shape into guessing SwiftUI before doing the address math. |
| "It's memory corruption" | **Wrong.** | Memory corruption would produce scattered crash sites across many offsets. We see 7+3 crashes at byte-identical offsets. Deterministic at a single PC. |
| "It's the CoreML/FluidAudio model load" | **Wrong for cluster A/C.** | The stack contains no FluidAudio or CoreML frames at all — the crash occurs inside `configureAndStart` before STT is ever touched. (Clusters B and D *may* involve model/audio interaction, but they are not the A/C bug.) |
| "It's a Swift precondition failure in our code" | **Wrong.** | A Swift precondition failure would put `swift_runtime_failure` or `_assertionFailure` high in the stack, and would typically inline right into our function. The stack instead goes *through* our code (`configureAndStart`) *into* the audio framework and back — classic ObjC exception propagation shape. |
| "It's a system / OS bug we can't fix" | **Only partially.** | The underlying raise may be an Apple bug. But it is squarely *our* responsibility to guard against `NSException` from AVFAudio. Every production Swift app that talks to AVFAudio wraps these calls in an ObjC try/catch. We don't. That is a bug in our code. |
| "The crash is at app launch" | **Wrong.** | It's at dictation start — the first press of the hotkey in a session. The crash *looks* launch-adjacent because the user's next relaunch uploads the persisted crash immediately on `app_launched`, so `ts` and `app_launched` are correlated even though `crash_ts` is always the previous process. |
| "It's `outputFormat(forBus: 0)` on line 164, not `installTap` on line 227" | **Wrong.** | Frame 13's PC `0x80638c` is 4 bytes past the end of line 227's instruction range (`0x806388`). On ARM64 that's exactly where the return address for a BL-to-installTap would sit. If the crash were at line 164, frame 13's offset would be near `0x805???` (inside lines 164's mapping), not `0x80638c`. The off-by-4 is diagnostic, not incidental. |

### 3.8 Why every crash record is `crash_type: signal` and never `crash_type: exception`

`CrashReporter.swift` installs **both** a POSIX signal handler (via
`sigaction` for SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE, line 116)
and an ObjC uncaught exception handler (via `NSSetUncaughtExceptionHandler`,
line 128). The exception handler is the richer path — it captures
`exception.reason`, `exception.name`, and
`exception.callStackReturnAddresses`, and writes `crash_type: exception`.
If it fired we would already know exactly which AVFAudio invariant was
violated.

Every single crash in telemetry shows `crash_type: signal`. The ObjC
exception handler has never fired for any production crash. Why?

Because **Cocoa's `NSApplication.run()` event loop catches unhandled
`NSException`s internally and calls `abort()` directly, bypassing
`NSSetUncaughtExceptionHandler`.** This is a well-known Cocoa gotcha and has
been since the 10.5 era: `-[NSApplication run]` wraps each event-dispatch
cycle in an internal try/catch, and on an uncaught exception it logs
`*** Terminating app due to uncaught exception '<name>', reason: '<reason>'`
to stderr and then calls `abort()` — *without* invoking the user-installed
uncaught exception handler. Apple documents this as an "implementation
detail" and has not fixed it.

The consequence for us:

1. `installTap` raises `NSException` on the main thread inside a hotkey
   event handler dispatched by the Cocoa run loop.
2. The `NSException` unwinds Swift frames (which know nothing about it) and
   reaches the Cocoa event loop's implicit try/catch.
3. Cocoa logs and calls `abort()`. **Our exception handler is skipped.**
4. `abort()` raises `SIGABRT`.
5. Our signal handler catches the signal, writes `crash_type: signal` with
   the backtrace, and re-raises for default termination.

The signal handler is doing its job. The exception handler is not broken —
it's just never reached. This is not a bug in `CrashReporter`, it's a
structural property of Cocoa apps.

**Why this matters for the fix:** catching the exception at the call site
in Swift (via our ObjC trampoline, §5.1) bypasses Cocoa entirely. The fix
does not depend on `NSSetUncaughtExceptionHandler` working. If we had used
the trampoline from day one we would never have taken any of these 10
crashes. Conversely, there is no way to "fix" the uncaught exception handler
path for this case — we can't make Cocoa call it.

As a secondary note, we could also:

1. Override `-[NSApplication reportException:]` (a subclassing hook) to
   route to our handler before Cocoa's `abort()`. Possible but fragile and
   Cocoa-version-dependent.
2. Use `NSExceptionHandler` (the old Foundation class) instead of
   `NSSetUncaughtExceptionHandler`. Deprecated and brittle.
3. Monkey-patch `objc_setUncaughtExceptionHandler` at the ObjC runtime
   level. Works but is fighting the system.

None of these are worth doing. The call-site trampoline is the right fix.

---

## 4. Blast radius

- **Cluster A (7 crashes):** 1 user in Germany, Apple M4 Max, macOS 15.6,
  0.5.5. Binary UUID matches shipped release. User successfully ran the
  app between crash bursts, so not permanently locked out.
- **Cluster C (3 crashes):** 1 user in Canada, Apple M4, macOS 26.2 (Tahoe
  beta), 0.5.5. Same bug. User probably recovered too — we don't have the
  cross-session activity for this one.
- **All 10 "our bug" crashes are on 0.5.5**, which is the current shipped
  release per `https://macparakeet.com/appcast.xml`
  (`sparkle:shortVersionString = 0.5.5`, `sparkle:version = 20260406005332`).
- **Users not locked out, but dictation is unusable for bursts** of minutes
  at a time when the trigger state is present. Relaunches are painful.
- **Attack surface is every dictation start**, not just edge cases — the
  trigger is an AVFAudio call path we run every single time a user presses
  the hotkey. The fact that only two users reported it in 72h reflects how
  often the audio subsystem is in the triggering state, not how many users
  are running through the vulnerable code path (**every single dictation is
  vulnerable**).

Expected population impact: **anyone with an aggregate input device, any
Bluetooth mic users during HFP/A2DP transitions, anyone on Tahoe beta, and
possibly anyone during mic permission race states.** We should assume silent
impact is larger than telemetry shows, because an unknown number of crashes
happen before `CrashReporter` is ready or the user opts out of telemetry.

---

## 5. Proposed fix

### 5.1 Immediate: Objective-C exception trampoline

Add a tiny Objective-C helper that converts `NSException` into an
`NSError` so Swift can catch it:

```objc
// Sources/MacParakeetObjCShims/include/MPKObjCExceptionCatcher.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs `block` and converts any raised NSException into an NSError
/// written to `*error`. Returns YES on success, NO on exception.
BOOL MPKTryBlock(NS_NOESCAPE void (^block)(void), NSError **error);
NS_ASSUME_NONNULL_END
```

```objc
// Sources/MacParakeetObjCShims/MPKObjCExceptionCatcher.m
#import "MPKObjCExceptionCatcher.h"
BOOL MPKTryBlock(void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *ex) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = ex.reason ?: ex.name;
            info[@"MPKExceptionName"] = ex.name;
            if (ex.userInfo) info[@"MPKExceptionUserInfo"] = ex.userInfo;
            *error = [NSError errorWithDomain:@"MPKObjCException"
                                         code:0
                                     userInfo:info];
        }
        return NO;
    }
}
```

Add a new SwiftPM target `MacParakeetObjCShims` (C target, no deps) and link
it into `MacParakeetCore`. This keeps all other targets Swift-only.

### 5.2 Use it in AudioRecorder.configureAndStart

Wrap the three AVFAudio calls that can raise:

```swift
// Line 164 — outputFormat may raise too
var inputFormat: AVAudioFormat!
var fmtError: NSError?
let fmtOK = MPKTryBlock({ inputFormat = inputNode.outputFormat(forBus: 0) }, &fmtError)
guard fmtOK, let inputFormat, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
    throw AudioProcessorError.recordingFailed(
        "Input format invalid: \(fmtError?.localizedDescription ?? "format 0/0")"
    )
}

// Line 227 — installTap is the confirmed crash site
var tapError: NSError?
let tapOK = MPKTryBlock({
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        // ... existing tap body unchanged ...
    }
}, &tapError)
guard tapOK else {
    try? FileManager.default.removeItem(at: url)
    throw AudioProcessorError.recordingFailed(
        "installTap failed: \(tapError?.localizedDescription ?? "unknown")"
    )
}

// Line 323 — engine.start is documented to throw Swift errors but
// has been observed to raise NSException in corner cases. Belt and braces.
var startError: NSError?
let startOK = MPKTryBlock({
    do { try engine.start() } catch { startError = error as NSError }
}, &startError)
if !startOK || startError != nil {
    inputNode.removeTap(onBus: 0)
    try? FileManager.default.removeItem(at: url)
    throw AudioProcessorError.recordingFailed(
        "Audio engine failed to start: \(startError?.localizedDescription ?? "unknown")"
    )
}
```

This converts every observed and plausible crash into a clean Swift throw,
which the existing catch in `AudioRecorder.start()` (line 81-96) will route
through the "retry on built-in mic" fallback. The existing
`DictationService.startRecording` catch (line 166-174) will then log a
`dictation_failed` telemetry event carrying the real AVFAudio reason string.

### 5.3 Gate on mic permission status before calling inputNode

Add a hard gate at the top of `start()`:

```swift
public func start() throws {
    guard !recording else { return }

    let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    guard authStatus == .authorized else {
        throw AudioProcessorError.recordingFailed(
            "Microphone permission not granted (status=\(authStatus.rawValue))"
        )
    }
    ...
}
```

The UI layer should already be calling `PermissionService.requestAccess`
before the first dictation, but this guard makes the invariant explicit and
prevents the AVFAudio call from ever being reached in a permission-race
state. Today line 73 only logs the status and then proceeds — that is a
separate minor bug worth fixing alongside the main one.

### 5.4 Crash reporter `NSException.reason` — status: not fixable for this class

We never see `NSException.reason` in telemetry because Cocoa's
`NSApplication.run()` event loop short-circuits
`NSSetUncaughtExceptionHandler` (see §3.8 for the full explanation).
**This is not a bug in `CrashReporter.swift`** — it's a Cocoa platform
property. The reporter is correctly wired up; the handler just never fires
for main-thread exceptions raised inside event dispatch.

The call-site trampoline in §5.1–5.2 makes this moot: once we catch the
exception ourselves before it escapes Swift, we get the full `reason`
string in our own `dictation_failed` telemetry event, via the existing
`AudioProcessorError.recordingFailed(reason)` path and
`TelemetryErrorClassifier.errorDetail` in
`DictationService.startRecording`'s catch block (line 170).

No action needed on `CrashReporter.swift` for this bug. Future
non-main-thread exceptions (e.g., from a Core Audio IO thread) might still
reach the uncaught handler, so leave it installed.

### 5.5 Defense in depth: prefer `format: nil` for installTap

The minimal change that would *probably* fix cluster A without a trampoline:

```swift
// Let installTap use the bus's current format — no mismatch possible.
inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
    // The tap's buffer.format is whatever the bus is delivering.
    // The converter already re-reads sample rate / channels from buffer,
    // so we don't need the captured inputFormat here.
    ...
}
```

This sidesteps the "format captured earlier no longer matches" class of
failure (§3.4 case 1), which is the most common trigger per AVAudioEngine
forum reports. Our tap block already creates an `AVAudioConverter` per tap
based on `inputFormat` captured on line 164; we'd need to derive the
converter from `buffer.format` per callback, or rebuild it on format change.
Slightly more work but also slightly safer. The ObjC trampoline (§5.1-5.2)
is still required as a safety net because `format: nil` does not protect
against the other four triggers.

Recommended: do **both** §5.1-5.2 and §5.5.

### 5.6 Restore and preserve the dSYM

Commit `704dfde` (2026-04-06) already made the build script archive the
dSYM into `dist/`. Verify that 0.5.6 and later ship with the dSYM archived
and retained (e.g., commit the dSYM to a private bucket, or snapshot
`dist/MacParakeet.dSYM` to macparakeet-downloads R2 alongside the DMG)
so that any future crash at a different offset can be symbolicated
immediately.

### 5.7 Ship as 0.5.6 patch

- Branch: `fix/audiorecorder-installtap-exception`
- Target: 0.5.6 (patch), same day
- Pre-flight: `swift test`, the whole suite
- Post-ship: watch the `crash_occurred` stream for 72h; we expect the 10
  cluster-A/C crashes to be replaced by `dictation_failed` events carrying
  the real exception reason.

---

## 6. Other clusters — what to do

### 6.1 Cluster B — BY / M2 Max / macOS 14.8.5 / SIGBUS

No app frames after frame 0. Pure system stack in audio-framework address
ranges. SIGBUS = misaligned access or mmap fault, commonly seen on:

- CoreML `.mlmodelc` mmap when the file was modified/corrupted under the
  mapping (e.g., interrupted download, disk pressure eviction).
- AudioToolbox callbacks reading beyond a shared buffer.

No proof this is our fault. **Action:** once §5.1-5.2 lands and AVFAudio
exceptions are no longer conflated with "crashes we can't explain", we
should flag this as its own investigation. Possible mitigations:
- Validate model file checksum on load.
- Use `AudioProcessor` retry on model load failure.
- Update FluidAudio to latest (review memory reference
  `reference_fluidaudio_api.md`).

### 6.2 Cluster D — US / M1 Max / macOS 26.3 / SIGSEGV

Single crash, 8-frame stack. One frame in a dynamically loaded framework
(offset far outside main binary). Surrounding frames in CoreAudio / CoreML
range. Likely Tahoe + FluidAudio corner case. User recovered — kept using
app, sent a feature request. **Action:** monitor; not actionable from one
sample. Revisit if it recurs.

### 6.3 Cluster E — stale 0.4.27 crash

Ignore.

---

## 7. Exact artifacts referenced

- Live DMG sha:
  - file: `/tmp/MacParakeet-055.dmg`, size 81139573
  - URL: `https://downloads.macparakeet.com/MacParakeet.dmg`
  - `CFBundleShortVersionString`: `0.5.5`
  - `CFBundleVersion`: `20260406005332`
- Main binary:
  - `/Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet`
  - `LC_UUID`: `DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65` (arm64)
  - Matches every `crash_occurred` row on 0.5.5 in the last 48h.
- Source files (verified against HEAD `fc85bc5`):
  - `Sources/MacParakeetCore/Audio/AudioRecorder.swift` — crash site at line 227
  - `Sources/MacParakeetCore/Audio/AudioProcessor.swift` — line 29 (frame 15)
  - `Sources/MacParakeetCore/Services/DictationService.swift` — line 149
    (caller of `startCapture`)
  - `Sources/MacParakeetCore/Services/CrashReporter.swift` — line 202
    (signal handler backtrace call)
- Telemetry queries were run via
  `npx wrangler d1 execute macparakeet-telemetry --remote --command ...`
  against D1 database id `7372263e-6a0b-4c70-8188-8f1d6d16bf31`.
- Relevant commit: `704dfde Archive dSYM during release builds for crash
  symbolication` — added on 2026-04-06 after this bug had already shipped in
  0.5.5. The 0.5.5 dSYM was already lost when this ran; I recovered function
  names from the stripped binary's symbol table via `atos`, not from a dSYM.

---

## 8. Confidence

| Claim | Confidence |
|---|---|
| Clusters A and C are the same bug in our code | **100%** — identical byte offsets across 10 crashes on 2 OSes and 2 chips, verified by recomputing `address − slide − 0x100000000` for each crash independently on both passes of the investigation. |
| The crashing call is the `installTap` call at `AudioRecorder.swift:227` | **~99%** — verified in the fresh-eye review by walking the binary with `atos` in 4-byte increments around frame 13's PC. The PC (`0x80638c`) is exactly 4 bytes past the last byte of the line-227 instruction mapping (`0x806388`), which is the return address a BL-to-installTap would push. Ruled out line 164 (`outputFormat`) because its mapped bytes sit in a different offset range (`0x8058…`). Ruled out line 323 (`engine.start`) because its mapped bytes sit at `0x8063c0`, well past the crashing PC. The off-by-4 is the diagnostic. |
| The root cause is an uncatchable Objective-C `NSException` raised by the audio framework stack | **~95%** — this is the only way `SIGABRT` can arrive from an `@objc` framework method when called from Swift without a try/catch trampoline. The only alternative is that `installTap` internally calls `abort()` directly, which it doesn't in any macOS version I'm aware of. I also verified in the fresh-eye review that `CrashReporter.swift` installs both handlers correctly and that the absence of `crash_type: exception` is explained by Cocoa's event-loop bypass of `NSSetUncaughtExceptionHandler` (§3.8), not by our reporter being broken. |
| The specific framework raising the exception is AVFAudio | **~60%** — it's in the audio framework neighborhood (frames 10–12 land in a narrow address range consistent with a single dylib), and `installTap` is the only call path reaching it. But without the macOS 15.6 and 26.2 dyld shared caches I can't definitively distinguish AVFAudio vs AudioToolbox vs CoreAudio HAL. Does not affect the fix. |
| The fix (ObjC trampoline + `format: nil`) will eliminate cluster A and C | **~90%** — this is the standard mitigation for every known AVAudioEngine exception path. The residual risk is that the exception is raised *before* the code we wrap (e.g., during `let engine = AVAudioEngine()` itself), but that's not consistent with the stack. |
| Both affected users are on USB aggregate devices | **100%** — verified from their `dictation_completed` rows in the telemetry D1 DB on 2026-04-08. Cluster A: `CADefaultDeviceAggregate-60938-10` (sessions `8141EB13` and `77F616B2`). Cluster C: `CADefaultDeviceAggregate-35104-0` (session `EEAD4122`). Both show `device_transport: aggregate`, `device_sub_transport: usb`, 2ch, 48000 Hz. |
| Cluster C is a new user in onboarding | **100%** — verified by the presence of `onboarding_step`, `model_download_started`, `model_loaded`, `model_download_completed`, and `onboarding_completed` events in session `EEAD4122` after the three crash reports. |
| Clusters B and D are different bugs | **100%** — completely different stack shapes, different signals, different address ranges, no shared offsets with A/C. |

---

## 9. Action checklist

- [ ] Implement `MacParakeetObjCShims` SPM target with `MPKTryBlock`.
- [ ] Wrap `outputFormat(forBus:)`, `installTap(...)`, and `engine.start()` in
      `AudioRecorder.configureAndStart` with `MPKTryBlock`.
- [ ] Switch the tap to `format: nil` and derive the converter from
      `buffer.format` inside the tap block.
- [ ] Add hard gate at `AudioRecorder.start()` on
      `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`.
- [ ] Verify `NSSetUncaughtExceptionHandler(objcExceptionHandler)` is
      actually installed at launch and that its crash file is uploaded.
- [ ] Add a unit test that feeds a deliberately-invalid format to
      `installTap` via a stub and asserts we throw a Swift error instead of
      aborting. (If we cannot simulate the NSException from a unit test, at
      least cover `MPKTryBlock` with a trivial "block raises NSException →
      returns NO with populated error" test.)
- [ ] Ship 0.5.6 with this fix. Run the release checklist in
      `docs/distribution.md`.
- [ ] Confirm `dist/MacParakeet.dSYM` is preserved to macparakeet-downloads R2
      as part of the release process so future crashes are symbolicable
      from day one.
- [ ] Re-query `crash_occurred` 72h after 0.5.6 ships and confirm clusters A
      and C are gone.

---

## 10. Fresh-eye review (2026-04-08, second pass)

After the first pass of this report was written, I was asked to re-verify
every assumption from scratch. The second pass caught several imprecisions
that were folded back into the body above. This section is the audit trail
— what I checked, what I found wrong, and what I changed. If you ever need
to retrace my reasoning, start here.

### 10.1 Holes I probed

| # | Assumption from first pass | How I checked it |
|---|---|---|
| 1 | `AudioRecorder.swift` on current main is identical to what I analyzed | Read lines 70–230 on current `main` after `git reset --hard origin/main` |
| 2 | `atos` line numbers are real, not guesses | Walked the binary in 4-byte increments around frame 13's PC with `atos`, inspected `otool -l` for `__debug_*` sections |
| 3 | The `0x1f3…` range is AVFAudio | Tried to check my local dyld shared cache (my Mac is 26.4, the crash is 15.6 — different layout) |
| 4 | `AudioProcessor.startCapture()` is only called from `DictationService.startRecording()` | `grep -r 'startCapture\|recorder\.start(' Sources/` |
| 5 | Cluster C's user is on an aggregate device (first pass said so without direct evidence) | Queried D1 for all events in sessions `30CF5A2F`, `6A865200`, `EEAD4122` and read their `device_name` fields |
| 6 | The crash is at `installTap` (line 227), not `outputFormat` (line 164) or `engine.start()` (line 323) | `atos` walk of the offset range; checked off-by-4 return address semantics |
| 7 | Binary has DWARF → atos line numbers are trustworthy | `otool -l` shows no `__debug_info` / `__debug_line`; only `__swift5_*` reflection metadata |
| 8 | `NSSetUncaughtExceptionHandler` is installed and the absence of `crash_type: exception` is a mystery | Read `CrashReporter.swift` in full; confirmed handler is installed at line 128 and diagnosed the Cocoa bypass |

### 10.2 What was wrong in the first pass

1. **Off-by-4 on the crashing PC line number.** First pass said "frame 13
   is at line 227". More precisely, frame 13's PC is at offset `0x80638c`,
   which is the first byte after the BL instruction for the line-227
   `installTap` call. `atos` correctly reports `<compiler-generated>:0`
   for that exact offset, and the line-227 mapping ends at `0x806388`.
   The conclusion is the same (installTap is the crashing call), but the
   off-by-4 is actually stronger evidence than a direct PC match because
   it is precisely the shape of an unreturned-call return address. Fixed
   in §3.3 (new subsection).

2. **Overclaimed "AVFAudio" as the specific framework.** First pass said
   the 0x1f3 range "is AVFAudio". Without the macOS 15.6 dyld shared
   cache I can't distinguish AVFAudio vs AudioToolbox vs CoreAudio HAL.
   All three are in the audio framework neighborhood and `installTap`
   routes through all of them. I softened the claim in the TL;DR, §3.1,
   §3.7, and the §8 confidence table. Does not affect the fix.

3. **Cluster C device info was extrapolated, not verified.** First pass
   said cluster C was "on `CADefaultDeviceAggregate-*`" but did not cite
   a telemetry row. Second pass pulled all events from cluster C's three
   sessions and found `device_name: CADefaultDeviceAggregate-35104-0`,
   `device_sub_transport: usb`, 2ch / 48 kHz in the recovered session.
   Same profile as cluster A. Fixed in TL;DR and §3.6.

4. **Missed that cluster C's user is in onboarding.** The telemetry for
   session `EEAD4122` (the third launch after the three crashes) shows
   `onboarding_step`, `model_download_started`, `model_loaded`,
   `model_download_completed`, `onboarding_completed`. **This user is
   crashing during their first-ever use of the app.** This is high-stakes
   because onboarding crashes cost disproportionate first-impression
   trust — see the "Onboarding stuck incident (v0.4.22)" entry in
   `MEMORY.md` for prior precedent. Added to TL;DR and §3.6.

5. **Didn't explain why `crash_type: exception` never appears.** First
   pass left this as "worth a quick verification" in §5.4. Second pass
   read `CrashReporter.swift` in full, confirmed the handler is installed
   correctly, and diagnosed the Cocoa `NSApplication.run()` event-loop
   bypass that short-circuits `NSSetUncaughtExceptionHandler` for
   main-thread exceptions. This is a well-known Cocoa gotcha, not a bug
   in our reporter. Rewrote §5.4 and added §3.8.

6. **Confidence on "line 227 is the crash site" was ~95%.** With the
   off-by-4 arithmetic, it's now ~99%. Ruled out line 164 (different
   offset range, `0x8058…`) and line 323 (`0x8063c0`, after the crashing
   PC). Updated §8.

7. **Line numbers in a stripped binary — how is atos getting them?**
   First pass assumed DWARF was present; `otool -l` shows only
   `__swift5_*` sections (Swift runtime reflection metadata), no
   `__debug_info`. Swift's embedded metadata sparse-maps some source
   lines to addresses; `atos` uses this for function + partial line
   info, which is why most offsets map to a real line number while some
   map to `<compiler-generated>:0`. Good to know for future crash
   investigations against stripped binaries.

### 10.3 What was right in the first pass

All of these survived re-verification unchanged:

- Clusters A and C have byte-identical app-code offsets
  `{0x865c70, 0x80638c, 0x804d70, 0x8044c8}` across all 10 crashes.
- The 0.5.5 binary UUID `DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65` matches
  every crash row and the live DMG on R2.
- The crashing function is `AudioRecorder.configureAndStart(...)`, called
  from `AudioRecorder.start()` at line 80, called from
  `AudioProcessor.startCapture()` at line 29.
- `AudioProcessor.startCapture()` has exactly one caller:
  `DictationService.startRecording` at line 149. Confirmed via grep.
- `AudioRecorder()` / `AudioProcessor()` are constructed at app-launch
  time (in `AppEnvironment.swift:51` and `TranscribeCommand.swift:65`)
  but the constructors do nothing dangerous. Only `start()` / `startCapture()`
  touch AVAudioEngine.
- The crash happens at the first dictation hotkey press, not at app
  launch. The telemetry correlation of `crash_occurred` with `app_launched`
  is an artifact of the crash reporter's next-launch upload mechanism.
- Both affected users recovered after retries — neither is permanently
  locked out. The trigger is transient audio device state.
- Clusters B (2 × SIGBUS on macOS 14.8.5) and D (1 × SIGSEGV on macOS
  26.3) are unrelated to this bug; their stacks have no app frames after
  frame 0.
- Cluster E (1 × stale 0.4.27 crash reported post-upgrade) is noise.
- The fix is an ObjC exception trampoline at the call site +
  `format: nil` on `installTap` + a permission gate.

### 10.4 Verification commands (reproducible)

Run these from the project root on any dev machine to redo the second pass:

```sh
# 1. Current AudioRecorder.swift matches report line numbers
sed -n '70,230p' Sources/MacParakeetCore/Audio/AudioRecorder.swift

# 2. startCapture callers (must be exactly one)
grep -rn 'startCapture\|recorder\.start(' Sources/

# 3. Exception handling bridges (must be only CrashReporter.swift)
grep -rn '@try\|NSException\b' Sources/

# 4. Download 0.5.5 DMG, mount, verify UUID
curl -s -L -o /tmp/MacParakeet-055.dmg "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)"
hdiutil attach -nobrowse -readonly /tmp/MacParakeet-055.dmg
dwarfdump --uuid /Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet
# Expected: DDD7A497-EFB2-3CC2-A024-B4C83E9F0F65

# 5. Symbolicate the four fixed app offsets from clusters A and C
MP=/Volumes/MacParakeet/MacParakeet.app/Contents/MacOS/MacParakeet
atos -o "$MP" -arch arm64 -l 0x100000000 0x100865c70 0x10080638c 0x100804d70 0x1008044c8

# 6. Walk the installTap call-site neighborhood in 4-byte increments
for off in 0x100806380 0x100806384 0x100806388 0x10080638c 0x100806390 0x1008063a0 0x1008063c0; do
    printf "%-12s -> " $off
    atos -o "$MP" -arch arm64 -l 0x100000000 $off
done

# 7. Confirm no DWARF in the stripped binary
otool -l "$MP" | grep -E "__debug_" | head  # expect: empty

# 8. Cleanup
hdiutil detach /Volumes/MacParakeet
rm -f /tmp/MacParakeet-055.dmg

# 9. Re-query telemetry for clusters A and C (wrangler must be authed)
cd ../macparakeet-website
npx wrangler d1 execute macparakeet-telemetry --remote --command \
  "SELECT event_id, session, app_ver, os_ver, chip, country, ts, props FROM events WHERE event='crash_occurred' AND ts >= datetime('now','-72 hours') ORDER BY ts DESC"

# 10. Cluster C onboarding verification
npx wrangler d1 execute macparakeet-telemetry --remote --command \
  "SELECT session, event, ts, substr(props,1,250) as props FROM events WHERE session IN ('EEAD4122-0A4D-4F29-AEE2-755D9BC616CB','6A865200-B8D0-4CAE-95DC-CB7F9FD2C553','30CF5A2F-EF5F-4C71-93D7-32636A7BAF5E') ORDER BY session, ts"
```
