# 0.8.5 crash card — Cluster A residual on Sonoma file STT

Date: 2026-09-17 (Pacific). Field queries through ~20:00Z.
Status: **diagnosis plus product follow-up**. Encoder `.cpuAndGPU` on macOS 14
is in `ParakeetTDTASRConfig.encoderComputeUnits()`. Not hardware-confirmed.
Question: what is the single 0.8.5 incident on the public crash-free card
(`1 / 48` sessions, 97.92%)?

> This is the death, not the dashboard ranking. Do not treat the 0.8.5 bar
> color as a new 0.8.5 regression.

## Verdict

**The 0.8.5 incident is Cluster A ([#997](https://github.com/moona3k/macparakeet/issues/997)),
still alive after the 0.8.1 concurrency fix.** It is not a wrapping-up-tile
bug, not Tahoe Cluster G, and not a 0.8.5-only crash.

One DE Apple M3 on macOS **14.8.9**, Parakeet **v3**, died twice in 50 minutes
while a long-form file job was in `ChunkProcessor`:

| Died (crash_ts) | Uploaded | Crashed version | Signal | Source that was running |
|---|---|---|---|---|
| 18:48:37Z | 18:49:56Z by 0.8.5 | **0.8.4** | SIGSEGV `si_code=2` (SEGV_ACCERR) | `transcription_started source=drag_drop` at 18:44:38Z (~4 min wall) |
| 19:39:30Z | 19:39:53Z by 0.8.5 | **0.8.5** | SIGBUS `si_code=1` (BUS_ADRALN) | `transcription_started source=file` at 19:29:27Z (~10 min wall) |

Stacks are **byte-identical after the handler**. Interrupted PC is the same
system instruction (`…360`, frame 1 `…584`, delta `0x224`). Mach-O UUID of
the 0.8.5 row is the shipped DMG:

`A17B0B6F-5D29-3103-9145-C696B7E19E61` (build `20260917153344`).

[#998](https://github.com/moona3k/macparakeet/pull/998)
(`ASRConfig(parallelChunkConcurrency: 1)` on macOS 14) **is in both
binaries**. `v0.8.5` is a descendant of `e43e9b1d`. FluidAudio is **0.15.7**.
The 4-wide inner pool is not what killed this user.

Serial Sonoma Core ML still SIGBUS/SIGSEGV during long-file Parakeet v3. That
is the residual [#997](https://github.com/moona3k/macparakeet/issues/997)
already flagged: if concurrency 1 still dies, the next lever is encoder
compute units, not another dashboard tweak. Related upstream:
FluidAudio [#661](https://github.com/FluidInference/FluidAudio/issues/661)
(concurrent) and [#320](https://github.com/FluidInference/FluidAudio/issues/320)
(later in a long sequential run).

Do not patch the dirty worktree. Do not ship a speculative SwiftUI / wrapping-up
fix for this stack. Needs a macOS 14 repro.

## Method

- Public snapshot `GET https://macparakeet.com/api/stats`
  `generated_at=2026-09-17T19:57:25.968Z` (`crash_free_by_version` 0.8.5 =
  1 incident / 48 sessions). 0.8.5 published `2026-09-17T16:57:36Z` (~3 h
  earlier).
- Read-only `wrangler d1 execute macparakeet-telemetry --remote` against D1
  `7372263e-6a0b-4c70-8188-8f1d6d16bf31`.
- Counting contract: website `docs/telemetry-crash-health.md`
  — sessions by event-row `app_ver`; incidents by `props.crash_app_ver`,
  `crash_ts`, and incident fingerprint. The 0.8.4 death uploaded after the
  Sparkle relaunch is attributed to 0.8.4, correctly. The card’s **one**
  0.8.5 incident is the 19:39Z row only.
- atos of unslid frame 0 against the **shipped** `v0.8.5` `MacParakeet.dmg`
  binary (`atos -arch arm64 -l 0x100000000`). No separate dSYM required for
  the C handler.
- `git show v0.8.5` for `ParakeetTDTASRConfig`, `STTRuntime` manager
  construction, `ANEInferenceGate`, Parakeet v3 live-dictation routing.
- FluidAudio 0.15.7 checkout: `ChunkProcessor.makeWorkerPool` at
  `count == 1`.
- Prior catalog:
  [0.8.0 Cluster A](../../docs/planning/2026-09-11-v0.8.0-crash-rootcause.md),
  [#997 report](2026-09-09-issue-997-coreml-long-file-stt/report.md),
  [0.8.1 residual](2026-09-14-081-residual-errors.md).

No Sentry. No Unblocked. No session identifiers in this note. Country+chip
are used only as the same-machine fingerprint the 0.8.0 catalog already uses.

## Incident 1 — 0.8.5 SIGBUS — DE M3 14.8.9 — Cluster A

| | |
|---|---|
| Crash time | 2026-09-17T19:39:30Z (`crash_ts=1789673970`) |
| Upload | 2026-09-17T19:39:53Z (`app_launched` + `crash_occurred` same second) |
| Reporter | 0.8.5 |
| Crashed version | 0.8.5 |
| UUID | `A17B0B6F-5D29-3103-9145-C696B7E19E61` = shipped 0.8.5 DMG |
| Slide | `0x24dc000` |
| Signal | 10 `SIGBUS`, `si_code=1`, `fault_addr=0x17ff83ffc` |
| Interrupted PC | `0x18c59b360` (system, not MacParakeet) |
| Stack | 18 frames / 215 bytes. 0 named app frames besides the handler |

Frame 0 actual `0x102b53e3c`. Unslid = `0x100677e3c`.

```text
atos -o MacParakeet.app/Contents/MacOS/MacParakeet -arch arm64 -l 0x100000000 0x100677e3c
# mpk_signal_handler (in MacParakeet) (MPKCrashSignalHandler.c:281)
```

Line 281 is `backtrace()`. That is the reporter walking the stack, not the
faulting instruction. The fault is `props.pc`.

System frames after the handler (identical to the 0.8.4 sibling):

```text
0x18c59b584
0x197c2d20c
0x1979ea524
0x197e284b8
0x197bc8d5c
0x1a48edf90
0x1a48ef808
0x1a492ed08
0x1a4924a24
0x18c3b8750
0x18c3ba3e8
0x18c3bd8ec
0x18c3bcf08
0x18c3cbea8
0x18c3cc6b8
0x18c566f78
0x18c565d18
```

Low-12-bit suffixes of the Core ML band (`20c`, `524`, `4b8`, `d5c`, `f90`)
match the 0.8.0 Cluster A catalog (`a20c`, `7524`, `54b8`, `5d5c`, `df90`).

### Dying-process timeline (14.8, Parakeet v3)

Relaunch events after `crash_occurred` are the **next** process. The previous
process:

1. `19:19:59Z` `model_loaded` Parakeet **v3** (warm-up success)
2. Several successful hold dictations (batch path)
3. `19:29:27Z` `transcription_started source=file` — no
   `audio_duration_seconds` on the breadcrumb
4. `19:30:20Z` `dictation_started` + `audio_engine_lifecycle` success
5. **No** `dictation_operation` / `dictation_completed` before death
6. `19:39:30Z` SIGBUS (~10 min after file start, ~9 min after the hold began)

Relaunch at 19:39:53Z warms Parakeet v3 in 2.5 s, then dictation works.

v3 has **no native live dictation**. `STTRuntime.beginLiveDictationTranscription`
throws `unsupportedEngine(.parakeet)` unless the variant is Unified.
Hold-to-talk inference is `transcribe(paddedSamples)` under
`ANEInferenceGate` at finalize. This hold never finalized, so it was capture
only. Tail preview for Unified is a no-op empty result; v3 preview is also
gated. **This death is the file job, not overlapping dictation ANE.**

## Incident 0 — 0.8.4 SIGSEGV — same machine, 50 minutes earlier

Same country+chip+OS (`DE` / `Apple M3` / `14.8.9`). Same interrupted PC.
Same 17 system frames. Signal flipped SIGSEGV → SIGBUS (normal for ANE mmap
weight corruption; the 0.8.0 catalog already saw this).

| | |
|---|---|
| Crash time | 2026-09-17T18:48:37Z |
| Upload | 2026-09-17T18:49:56Z by **0.8.5** |
| Crashed version | 0.8.4 (`crash_app_ver`) |
| UUID | `FAAAFBB7-C310-3D2C-9C12-27F8F4C00C6B` |
| Slide | `0x2cd4000` |
| Signal | 11 `SIGSEGV`, `si_code=2`, `fault_addr=0x32522bffc` |

Timeline:

1. `18:37:55Z` 0.8.4 `model_loaded` Parakeet v3
2. Successful dictations
3. `18:44:38Z` `transcription_started source=drag_drop`
4. `18:45:41Z` `dictation_started` — again **no** `dictation_operation` before death
5. `18:48:37Z` SIGSEGV (~4 min into drag-drop)

Then Sparkle relaunch as 0.8.5 uploads the 0.8.4 crash, warms v3, and the user
keeps working until the 19:29 file job dies the same way.

Public `/api/stats` attributes this row to 0.8.4. It is not the pink 0.8.5
bar. It is the same bug on the previous build.

## Why #998 does not explain this away

`v0.8.4` and `v0.8.5` both construct TDT managers with
`ParakeetTDTASRConfig.make()`:

```2346:2350:Sources/MacParakeetCore/STT/STTRuntime.swift
                // `ParakeetTDTASRConfig` drops long-file chunk concurrency to 1
                // on macOS 14 (issue #997); 15+ keeps FluidAudio's default of 4.
                let asrConfig = ParakeetTDTASRConfig.make()
                let loadedInteractiveManager = AsrManager(config: asrConfig)
                let loadedBackgroundManager = AsrManager(config: asrConfig)
```

On 14.8.9 that is `ASRConfig(parallelChunkConcurrency: 1)`. FluidAudio 0.15.7
`ChunkProcessor.makeWorkerPool` returns `[manager]` when `count == 1` (no
clones). The `ThrowingTaskGroup` still exists, but only one worker is in
flight.

`ANEInferenceGate` still wraps the **outer** `transcribe(audioURL:)`:

```734:736:Sources/MacParakeetCore/STT/STTRuntime.swift
            let result = try await inferenceGate.withExclusiveAccess {
                try await manager.transcribe(audioURL, decoderState: &decoderState)
            }
```

Inside that call, each 15 s window still does async Core ML
`compatPrediction` on preprocessor then encoder
(`AsrManager+Pipeline.executeMLInferenceWithTimings`). That is Apple’s
“asynchronous prediction using ML Program” path — the same API that threw in
8 s under 4-wide concurrency in the original #997 report, and that FluidAudio
#320 saw **later** in a long sequential run.

4–10 minute walls before SIGBUS match “got past the first window, died
mid-file,” not the original 8–13 s first-batch toast.

File jobs use the background `AsrManager`; v3 dictation finalize would use
the interactive one, both sharing one `AsrModels` bundle. Both outer calls
take the same process gate. Because this hold never reached finalize, the
gate-vs-dictation race is not in evidence. The remaining hole is **serial
async Core ML on Sonoma during long-form TDT**.

`dualDecodeArbitration` defaults to `false`. `seamGapRepair` defaults to
`true` but runs after all chunks merge; a mid-file death is the chunk loop,
not the repair pass.

## Fleet residual (Sonoma, 215-byte / 18-frame)

Lifetime `crash_occurred` with `crash_os_ver` like `14.%` and
`length(stack_trace) = 215`, crashed version `0.8.*`:

| crash_app_ver | n | Notes |
|---|---:|---|
| 0.8.0 | 8 | pre-#998; catalog Cluster A. No `pc` (CrashReporter predates #1021) |
| 0.8.1 | 2 | 14.6.0, 40 min apart, same UUID, `pc` `…a360` |
| 0.8.3 | 3 | 14.4.x, `pc` `…360`; Core ML 12-bit suffixes differ by OS patch |
| 0.8.4 | 1 | this DE M3 |
| 0.8.5 | 1 | this DE M3 |

Every 0.8.1+ row has interrupted PC ending in `360` and frame 1 ending in
`584` (delta `0x224`). That is a tighter Cluster A fingerprint than the
12-bit Core ML suffixes, which move with the macOS 14 patch.

#998 reduced the *easy* 4-wide first-batch deaths. It did not remove Cluster A.

## What this is not

- **Not 0.8.5’s wrapping-up tile.** [#1082](https://github.com/moona3k/macparakeet/pull/1082) is a status label after stop. This process died in Core ML during file STT.
- **Not Tahoe Cluster G.** Those are 11-frame / 131-byte `SIGSEGV` on macOS 26/27. This is 18-frame / 215-byte on macOS 14.
- **Not a 0.8.5 fleet crash rate.** 48 sessions in three hours plus one known Sonoma file-STT death. The honest current 24h version is 0.8.3 at 2/357. Ignore the ranking.
- **Not proven overlapping live ANE from dictation.** v3 cannot start native live dictation. Both holds started and never finalized.

0.8.5’s other 24h public rows (`STTSchedulerError.unavailable` ×3–4 on
drag-drop, `STTError.engineStartFailed` ×8 on `parakeet → whisper`) are
separate. They are not this stack.

## Next lever (encoder GPU follow-up)

The #997 report already ordered this:

1. Done: `parallelChunkConcurrency: 1` on macOS 14.
2. **Follow-up in product code:** `ParakeetTDTASRConfig.encoderComputeUnits()`
   passes `.cpuAndGPU` into `AsrModels.downloadAndLoad` on macOS 14. One
   shared model bundle, so Sonoma dictation leaves ANE too. 15+ passes `nil`.
3. If GPU still dies on 14: `.cpuOnly` for the encoder. Do not flip 15+.
4. Do not “fix” it by splitting files in the UI. The model already chunks.
5. Hardware confirm still needs a macOS 14 Apple Silicon Mac. A 20 s clip
   should succeed; an hour-class file on 14.8 must finish.

Re-open or extend [#997](https://github.com/moona3k/macparakeet/issues/997)
with this residual rather than filing a new 0.8.5 crash issue. The 0.8.4
sibling is the same user and should travel with it.

## Limits

- No `audio_duration_seconds` on either `transcription_started` breadcrumb, so the files are “long enough to run 4–10 minutes,” not proven hour-class.
- No Apple crash report, no named Core ML symbol (system frames only). Cluster membership is PC suffix + 18-frame/215-byte + Sonoma + leftover file STT.
- `atos` of system PCs was not done on a 14.8.9 dyld shared cache; `0x18c59b360` is classified system because it is outside the app slide.
- Same-machine is country+chip+OS, not a device id.
- Diarization was not observed on these sessions (`diarization_*` events absent in the window). A diarization ANE overlap is not in evidence here.
