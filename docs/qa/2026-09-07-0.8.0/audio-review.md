# Audio, STT, and capture release review

Candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`; comparison: `v0.7.3`.

Status: source review and fixture inventory complete for the selected paths below. This reviewer ran no builds, tests, desktop interaction, or audio playback. Root owns runtime checks and the final release verdict. No personal meeting content was inspected.

## Method and limitations

Read the Audio and STT subsystem READMEs, meeting artifact contract, distribution guide, changed production sources, and corresponding regression tests. Trace lifecycle generations, cancellation, source loss, recording retention, diarizer manager ownership, and selected-track conversion. Inspect only named public corpus files and cache directory names. `ffprobe` metadata and SHA-256 were executed for five public samples; model directory existence is not model-load proof.

This was a risk-directed review of a large release delta, not a claim that every changed line or hardware combination was verified. Historical CI and committed benchmark scores do not prove the candidate's runtime behavior. The recipe below intentionally keeps user history and saved settings out of the experiment. It does not publish or delete recordings.

## Finding: discard bypasses active finalization ownership

Fix status: implemented in the QA worktree; root's green validation is pending. Root first ran the two regression tests against unchanged production code. Both failed with eight assertions, confirming that same-process and other-live-process source files and locks were removed. Evidence: [original regression log](evidence/recovery-discard-red.log). Only disposable generated test recordings were involved.

The fix claims the current on-disk ownership before discard and restores the prior lock on failure while the folder remains. Added coverage also pins missing-folder idempotence and retry after an injected folder-removal failure; the existing failed-settlement test now checks the exact restored lock. The narrow guarantee is documented in `spec/contracts/meeting-recovery-retention.md`. Source locations below describe the original candidate.

Priority: P1 (data-loss consequence), confidence 75. Location: `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift:413` through the folder removal at line 430. This is an adjacent gap in the release's new ownership mechanism; the unconditional discard path predates this release.

Concrete trace:

1. App A discovers an orphan and keeps its recovery dialog open.
2. App B, or another admitted retry operation, calls `recover`/`enqueueClaimingFinalizationOwnership` for that folder. The new lock now identifies a live finalizer.
3. App A chooses Discard using its previously discovered lock.
4. `discard` only checks `MeetingAudioWriterFinalizationRegistry`, which is process-local and covers writer callbacks rather than STT/recovery ownership. With no completed row yet, it removes the entire folder even though a live finalizer owns it.

Evidence: `recover` claims ownership at lines 202–204; the lock store rejects another live PID and an active same-process lease in `MeetingRecordingLockFileStore.swift:365`; `discard` does not use either guard. `MeetingRecoveryCoordinator.swift:103` passes the originally discovered locks after the asynchronous alert response. The behavior is directly traceable from source; no real user files were used to reproduce it.

Proposed narrow fix: protect discard with the same finalization ownership claim/mutex and reject a live owner. Restore the prior lock if an attempted discard fails and the folder still exists. Add deterministic tests passing a stale discovered lock while the on-disk lock belongs to another live process and while a same-process lease is active; assert all source files and the live lock remain. Preserve the existing completed-transcription cleanup behavior for genuinely unowned sessions.

Test anchors: `MeetingRecordingRecoveryServiceTests` owns the existing `testDiscardRemovesEverything`, `testDiscardKeepsCompletedTranscriptAudioAndDeletesOnlyLock`, and `testDiscardSurfacesFailedLockDeleteAndStaysRetryable`. `MeetingRecordingLockFileStoreTests.testFinalizationOwnershipClaimRefusesLiveOwner` already proves the live-PID rejection primitive. A same-process active lease can be established deterministically by calling the injected lock store’s `claimFinalizationOwnership` before `discard`, without clocks or subprocesses. For another process, use `RecoveryProcessChecker(alivePIDs:)` and a lock with that PID. Preserve successful unowned discard, pending-writer rejection, completed-row settlement, and retry after filesystem failure. Root owns execution.

## Source-supported checks

- Meeting capture startup/stop uses attempt ownership, retires event sinks before async teardown, and waits for startup settlement. System stream replacement uses a fresh instance and generation-gated callbacks; first-buffer/failure promotion is locked. Regression tests specifically cover Stop during startup/recovery, failure after the replacement's first buffer, stale callbacks, duplicate recovery signals, and retry exhaustion. These are source/test-design observations, not executed results.
- AVFoundation writer finalization is bounded to five seconds. A single coordinator arbitrates deadline versus both callbacks. Timed-out writers retain their registry ownership and source folder; cancellation, failed-start cleanup, and empty Stop preserve pending artifacts. Real frames in a timed-out source produce a storage failure rather than a false successful recording.
- Playback fallback probes media duration, chooses the source with the latest playable endpoint, preserves its start offset, and atomically installs the derived artifact. Source media remains authoritative. The fallback is visibly marked as partial capture; it does not prove both sources were captured.
- `.deleteImmediately` no longer sweeps historical saved audio. Both `MeetingAudioRetentionPolicy` and `MeetingAudioRetentionSweeper` require `.deleteAfterDays` before age-based deletion. Do not exercise retention using the user's real library.
- Selected file-track conversion uses zero-based `-map 0:a:<ordinal>`; the public CLI accepts one-based `--audio-track`. Discovery parses FFmpeg's input streams and stops before output mappings. Test actual multi-track media because FFmpeg metadata varies by container.
- FluidAudio 0.15.6 model API migration preserves per-request diarizer managers over an immutable shared model bundle. Concurrent preparation is shared; cancellation releases a waiter without invalidating another request. macOS 14's ANE gate encloses diarization inference and Nemotron English's newly inference-bearing load health probe. Download normally stays outside that gate.
- Diarization now uses a one-second embedding hop, retains short turns, and re-embeds zero-vote spans. Calendar hints cap the system-track count at remote attendees + 1 with minimum 1; explicit CLI count wins. This configuration needs real two-speaker runtime evidence. The historical DER values in source comments explicitly belong to FluidAudio 0.15.4 and were not remeasured here.
- Raw multichannel downmix preserves the ordinary mean and falls back to the greatest-energy channel for whole-buffer destructive cancellation. VPIO still extracts microphone channel zero. Float32, Int16, Int32, interleaved, and planar cases have tests; actual USB and Bluetooth profile transitions still need device coverage.

## Public prerecorded fixture inventory (observed)

`<PUBLIC_CORPUS>` identifies the local public-corpus root with its workstation prefix redacted. These fixtures contain public research audio, not the user's meetings. All five are mono, 16 kHz according to `ffprobe`. Curated JSON receipts also use `<QA_WORKTREE>` and `<QA_RUN>` for the owning checkout and temporary run root; only path strings were changed, preserving results, hashes, and candidate identifiers.

| Sample | Local file | Duration | SHA-256 |
|---|---|---:|---|
| LibriSpeech English | `<PUBLIC_CORPUS>/LibriSpeech/test-clean/1089/134686/1089-134686-0000.flac` | 10.435 s | `30885601173f96b0d8ddd020dc959b055c6c1582b85a33e3fcab8c4b08ed94c2` |
| FLEURS English | `<PUBLIC_CORPUS>/fleurs-data/en_us/en_us_0000.wav` | 10.560 s | `7835bd6ffb54ce38a2a9bcde3905ba424faed94d50a474f21a9cbe9209b869df` |
| FLEURS Korean | `<PUBLIC_CORPUS>/fleurs-data/ko_kr/ko_kr_0000.wav` | 12.480 s | `b1f6cf6dde1647ea71e564d0e3efd4bbeb573674dec13f977625fd94ca1b5147` |
| FLEURS Japanese | `<PUBLIC_CORPUS>/fleurs-data/ja_jp/ja_jp_0000.wav` | 10.440 s | `26b6cd491b5d52cf05d89207cb88499cdaba89749aebc29c8f216e834e3d9071` |
| FLEURS Mandarin | `<PUBLIC_CORPUS>/fleurs-data/cmn_hans_cn/cmn_hans_cn_0000.wav` | 10.380 s | `5214e16584b6498ddbd22f321738c0f62b19117ab1880b21e405fba983986b6a` |

English reference: `1089/134686/1089-134686.trans.txt`, matching utterance ID. FLEURS references: each language folder's `<language>.trans.txt`, matching WAV stem. Observed WAV counts: en_us 647, ko_kr 382, ja_jp 650, cmn_hans_cn 945. Public speaker corpus/RTTM availability was not established; concatenate two known LibriSpeech speakers for a smoke check, but do not call that a DER benchmark.

Observed directory names under `~/Library/Application Support/FluidAudio/Models`: Parakeet v2/v3/Unified, Nemotron multilingual, Cohere, Silero VAD, speaker diarization. English Nemotron and Whisper readiness must come from `models list/status`, not an inferred directory name.

## Ordered runtime matrix (root to execute)

| Order | Surface and trigger | Expected evidence | Coverage boundary |
|---:|---|---|---|
| 1 | Candidate bundle assets, `models list/status` | Exact SHA/build, selected and cached models, AEC symbols/checksum | File presence is not inference proof |
| 2 | English file via each installed engine/build | Nonempty expected text, correct engine/variant, duration, timings or documented absence, no crash/hang | One sample is a smoke, not accuracy ranking |
| 3 | Korean/Japanese/Mandarin through installed multilingual engine | Script/language preserved; score CER from matching reference | Parakeet v3's known CJK limits are not a new guarantee |
| 4 | Two-track MKA/MKV fixture, select each track in GUI and CLI | Track 1/2 give different known references; invalid track is a visible failure | Tests file demux/selection, not source capture |
| 5 | Two different voices concatenated with a known gap; speaker detection auto and exact 2 | Two stable speaker identities, sensible turn transitions, no crash under 0.15.6 | Synthetic turn boundaries do not replace labeled overlap corpus |
| 6 | Real microphone cold start, repeated stop/start, VPIO→raw, prepared→active | Usable buffers within deadline; no silent stale engine | Built-in/connected hardware only |
| 7 | Meeting system-only while public WAV is played | System level, nonempty live/final text, retained playback and correct duration | ScreenCaptureKit permission must be granted; player output must be audible to system capture |
| 8 | Dual-source meeting plus dictation; mute mic; pause/resume; stop then immediately start next | Source isolation, mute excludes local speech, pause excludes paused interval, queue completes the original row without stealing current session UI | Acoustic speaker playback may echo; record setup |
| 9 | Cancel while starting, while previewing, and while final file STT runs | Prompt idle/next job usable; no resurrection, duplicate row, or lost stopped audio | Use only QA-created recordings |
| 10 | Restart with deliberately interrupted owned QA recording | Recovery available; sources retained; finalization lease prevents duplicate/reentrant processing | Never kill the user's real active recording |
| 11 | AEC runtime and bounded synthetic pipeline | Asset load success, cleaned-mic artifact or explicit fallback reason, stage timings | Tones quantify plumbing, not human speech quality |
| 12 | Hardware route switch/unplug and Bluetooth profile transition | Bounded recovery, warning if source cannot recover, captured timeline preserved | Requires the actual hardware; leave untested devices explicitly open |

### Exact commands and inputs

Run from the owning QA worktree after root's candidate build. Set `QA_WORKTREE` to that checkout, `QA_FIXTURE_ROOT` to the public-corpus root, and `QA_RUN` to a new owned temporary root. Set `QA_CLI` to that exact built CLI and `QA_OUT` to its owned output directory. These variables deliberately do not replace system environment variables.

```sh
: "${QA_WORKTREE:?Set the owning QA checkout}"
: "${QA_FIXTURE_ROOT:?Set the public-corpus root}"
: "${QA_RUN:?Set a new owned temporary root}"
QA_CLI="$QA_WORKTREE/.build/arm64-apple-macosx/release/macparakeet-cli"
QA_OUT="$QA_RUN/audio-runtime"
mkdir -p "$QA_OUT"
MACPARAKEET_TELEMETRY=0 "$QA_CLI" models list --json > "$QA_OUT/models-list.json"
MACPARAKEET_TELEMETRY=0 "$QA_CLI" models status --json > "$QA_OUT/models-status.json"
MACPARAKEET_TELEMETRY=0 "$QA_CLI" transcribe \
  "$QA_FIXTURE_ROOT/LibriSpeech/test-clean/1089/134686/1089-134686-0000.flac" \
  --engine parakeet --parakeet-model v3 --mode raw \
  --speaker-detection off --no-history --database "$QA_OUT/history.sqlite" \
  --format json > "$QA_OUT/parakeet-v3-en.json" 2> "$QA_OUT/parakeet-v3-en.log"
```

Repeat sequentially for installed variants: `--engine parakeet --parakeet-model v2`, `--engine parakeet --parakeet-model unified`, `--engine nemotron --nemotron-model english-1120ms`, `--engine nemotron --nemotron-model multilingual-1120ms --language en`, `--engine whisper --language en`, and `--engine cohere --language en`. Do not change persisted model selection. For FLEURS, substitute the corresponding named WAV and `--language ko`, `ja`, or `zh` on a supported engine. Capture stderr/exit status and enforce a root-owned bounded process timeout; a successful process exit alone is insufficient.

For embedded-track QA, first create two private derived files with different public reference content. A Matroska fixture works without re-encoding:

```sh
ffmpeg -nostdin \
  -i "$QA_FIXTURE_ROOT/fleurs-data/en_us/en_us_0000.wav" \
  -i "$QA_FIXTURE_ROOT/fleurs-data/ja_jp/ja_jp_0000.wav" \
  -map 0:a:0 -map 1:a:0 -c:a pcm_s16le \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  "$QA_OUT/two-tracks.mkv"
```

Run the explicit CLI recipe with `--audio-track 1` and `--audio-track 2`, then choose each in the GUI's local-file track picker. A real container with one video stream before both audio streams is a useful second demux check.

The root-owned hardware suite:

```sh
MACPARAKEET_TELEMETRY=0 MACPARAKEET_HARDWARE_TESTS=1 \
  swift test --filter MicrophoneEngineRealPlatformTests
```

Leave `MACPARAKEET_HAL_MUTATION_TESTS`, `MACPARAKEET_STRESS_HARDWARE_TESTS`, and `MACPARAKEET_SLOW_HARDWARE_TESTS` unset initially. The first changes the macOS default input; the others extend runtime. Do not run hardware tests alongside a real app recording.

AEC bundle verification and tests, with actual candidate asset paths:

```sh
REQUIRE_MEETING_ECHO_ASSETS=1 scripts/dist/verify_meeting_echo_assets.sh /path/to/candidate/MacParakeet.app
MACPARAKEET_TELEMETRY=0 \
  MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/candidate/MacParakeet.app/Contents/Frameworks/liblocalvqe.dylib \
  MACPARAKEET_TEST_LOCALVQE_MODEL=/path/to/candidate/MacParakeet.app/Contents/Resources/MeetingEchoSuppression/localvqe-v1.4-aec-200K-f32.gguf \
  MACPARAKEET_TEST_LOCALVQE_MODEL_SHA256=b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731 \
  swift test --filter 'MeetingEchoSuppressionRuntimeTests|MeetingAecRenderThroughputTests'
```

`LongMeetingPipelineBenchmarkTests` supports `MACPARAKEET_LONG_MEETING_PIPELINE_BENCH=1` plus `MACPARAKEET_LONG_MEETING_SYNTHETIC_SECONDS=30`, the same two LocalVQE asset variables, `MACPARAKEET_LONG_MEETING_WORK_DIR` and `MACPARAKEET_LONG_MEETING_RESULTS_FILE` pointed into the owned QA directory. It requires cached speech and diarization models; preflight may reject missing ones. Its synthetic waveform does not establish WER/DER. Do not set `MACPARAKEET_LONG_MEETING_SESSION` to personal recordings without separate deliberate scope.

The repository's `benchmarks/asr/score.py` and `score_multi.py` are the canonical scorers, with pinned Python requirements. Use English WER and CJK CER with matching references; retain utterance ID, hypothesis, engine/variant, language hint, candidate SHA, model/runtime versions, wall time, and exit status. `run_macparakeet.py`/`run_macparakeet_fleurs.py` pass `--no-history` but omit `--mode raw` and `--database`; use explicit CLI commands above or adjust a temporary runner copy so saved processing settings cannot enter the experiment. An owned `--work-dir` matters: the LibriSpeech runner removes its `transcripts` child before a run.

## What worked and what did not

- Worked: exact-name Spotlight queries located existing public corpora quickly; bounded metadata probes established duration, format, and hashes without playing or transcribing audio. The repository already supplies public-reference scorers and meaningful hardware/AEC test gates.
- Worked: source/test cross-reading established that timeout handling preserves writer-owned artifacts, selected-track indices stay explicit, and late async completion is generation-scoped.
- Did not establish: any actual candidate inference, microphone/capture behavior, diarization accuracy, AEC quality, hardware switching, or GUI behavior. Root must record observed outcomes separately.
- Pitfall found: committed benchmark runners are convenient but inherit processing mode; file-existence cache checks and historical scores cannot stand in for current model loading. Synthetic AEC tests and an inactive/offscreen UI render have narrower meanings than real playback/capture or desktop interaction.
