# Open Source Meeting Recorder Review

> Status: research and product/architecture recommendation
> Date: 2026-07-04
> Scope: Muesli repos, Granola-style open source meeting recorders, local
> meeting-memory apps, and diarization foundations relevant to MacParakeet.
> Related: [ADR-010](../../spec/adr/010-speaker-diarization.md),
> [ADR-014](../../spec/adr/014-meeting-recording.md),
> [meeting artifacts v1](../../spec/contracts/meeting-artifacts-v1.md),
> [meeting dual-stream pipeline](meeting-dual-stream-transcription-pipeline.md),
> [speaker diarization frontier](speaker-diarization-frontier-2026-06.md),
> [meeting AEC prior art](2026-06-meeting-aec-open-issues-prior-art.md).

## Executive Takeaway

The open source market is converging on the same basic shape:

- source-separated meeting capture, usually mic plus system/app audio
- local ASR, commonly Parakeet, Whisper/WhisperKit/whisper.cpp, or WhisperX
- post-meeting cleanup and summarization
- optional speaker diarization
- local artifacts, Markdown, search, CLI, API, or MCP surfaces

MacParakeet is already on the right core architecture: source-separated
capture, raw mic/system artifacts, `meeting.m4a` as playback/export rather than
authoritative STT input, crash recovery, and a local-first default. The
highest-value lesson is not "add more models." It is to make meeting recording
feel more trustworthy at the product boundary:

1. Finish the AEC/source-trust work with real no-headset call QA.
2. Add visible mic/system capture-health states and recovery paths.
3. Separate speaker semantics into honest tiers: channel labels, anonymous
   diarization, user-confirmed names, and opt-in returning-speaker profiles.
4. Make meeting artifacts agent-native: stable JSON, Markdown, write-back, CLI
   commands, and eventually MCP/local search.
5. Keep the surface narrower than OpenWhispr, Natively, or Screenpipe. Trust is
   a stronger differentiator than a wider AI copilot menu.

## Method

I reviewed live GitHub state on 2026-07-04 and cloned high-signal repositories
under `/tmp/mp-oss-review-20260704`. The exact inspected SHAs are listed in the
appendix. This was a code/documentation review, not a runtime benchmark.

The review used parallel subagents for:

- direct Swift/macOS meeting recorder repos
- Granola-style open source alternatives
- diarization foundations and model stacks
- MacParakeet baseline verification against the current checkout
- discovery of additional high-signal projects

## MacParakeet Baseline

MacParakeet meeting recording is currently a first-class mode beside dictation
and file/media transcription. It creates durable session folders, writes source
audio separately, writes `meeting.m4a` for playback/export, persists a lock for
crash recovery, and finalizes STT in the background. ADR-014 defines the
durable stop boundary as source audio plus `meeting.m4a`, a lock state, and a
library row awaiting final transcription ([ADR-014](../../spec/adr/014-meeting-recording.md)).

Strengths to preserve:

- Raw source artifacts are authoritative: `microphone.m4a`, `system.m4a`, and
  optional `microphone-cleaned.m4a` live beside `meeting.m4a`.
- Final STT transcribes source files separately and merges by source alignment,
  instead of feeding the mixed playback file into ASR.
- Diarization is additive and nonfatal. FluidAudio offline diarization can add
  speaker IDs when the selected engine produces usable word timing.
- Crash recovery and retention are explicit product surfaces, not incidental
  implementation details.
- The product posture is simpler than most peers: no account requirement and
  local-first core capture/transcription.

Current gaps exposed by the comparison:

- AEC is not product-closed until real no-headset Zoom/Meet/Teams QA passes.
  Synthetic short-horizon tests are useful but not enough for "meeting trust."
- Normal-stop cleaned-mic rendering can race final STT: the cleaned path may be
  returned before a decodable file exists, so finalization can silently fall
  back to raw mic.
- Capture health is mostly logs/tests today. Peers make health visible with
  per-channel levels, silent-source warnings, record-only modes, and recovery
  badges.
- Meeting diarization is anonymous and system-side only. There is no persistent
  speaker identity layer, speaker enrollment, or cross-meeting recognition.
- Local meeting memory is still early: DB-backed folders/projects, FTS, and
  cross-meeting Ask are planned, while several peers make Markdown/search/MCP
  the primary surface.

## Repo Reviews

### 1. Muesli-HQ/muesli

Verdict: closest direct MacParakeet peer.

Muesli-HQ is a native Swift/AppKit/SwiftUI macOS app with FluidAudio,
WhisperKit, LocalVQE/DTLN AEC, SQLite, Sparkle, TelemetryDeck, and a CLI. The
README positions it as local meeting transcription plus dictation, with mic
captured as "You," system audio as "Others," VAD chunking, remote speaker
diarization, meeting templates, exports, and optional cloud/local summary
providers ([README](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/README.md#L21-L57)).

Architecture and capture:

- CoreAudio process tap is the default system-audio path, with
  ScreenCaptureKit fallback. The CoreAudio recorder claims lower permission and
  sync advantages, but MacParakeet already moved away from this as the default
  because of VPIO/process-tap conflict risk ([CoreAudio recorder](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift#L21-L28),
  [tap creation](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift#L176-L230)).
- MeetingSession preloads AEC, starts system before mic, rotates mic/system VAD
  chunks, runs final system diarization, and writes retained mixed recordings
  when configured ([MeetingSession](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift#L228-L249)).
- LocalVQE is the primary AEC path with DTLN fallback
  ([MeetingNeuralAec](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/MeetingNeuralAec.swift#L142-L170)).

Transcription and diarization:

- TranscriptionRuntime routes across several local engines and loads Silero VAD
  and FluidAudio diarization helpers for meeting work
  ([TranscriptionRuntime](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift#L169-L217)).
- Diarization is real for system audio, but it remains anonymous speaker
  segmentation formatted by overlap. It is not a durable speaker identity
  system ([diarizeSystemAudio](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift#L372-L384),
  [TranscriptFormatter](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/TranscriptFormatter.swift#L11-L40)).

Artifacts and product:

- The data model is strong: meetings store raw transcript, formatted notes,
  manual notes, template metadata, mic/system/saved audio paths, search fields,
  live transcript checkpoints, and resume snapshots
  ([schema](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliCore/DictationStore.swift#L84-L137),
  [MeetingRecord](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliCore/StorageModels.swift#L212-L334)).
- The CLI exposes meeting list/get/update-notes style primitives and a JSON
  contract for agents
  ([README CLI](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/README.md#L107-L214)).
- Meeting detection is richer than window-title polling, but some camera state
  detection uses private KVC on `_connectionID`, which is a distribution risk
  ([CameraActivityMonitor](https://github.com/Muesli-HQ/muesli/blob/17a013a12964cb3c8545cdeb466466d91ef02113/native/MuesliNative/Sources/MuesliNativeApp/CameraActivityMonitor.swift#L149-L159)).

MacParakeet lessons:

- Copy the shape of the agent CLI and notes write-back, not the broad model
  menu.
- Continue remote/system-side diarization after source separation.
- Consider VAD over cleaned mic once AEC is genuinely ready.
- Do not default to CoreAudio process tap unless MacParakeet reopens and
  resolves the VPIO/tap conflict.
- Keep privacy copy explicit about every cloud escape hatch. Muesli is
  local-first for audio/STT, but summaries, iCloud text sync, OAuth, and
  telemetry complicate the story.

### 2. noncuro/muesli

Verdict: prototype, useful only for the "grab recent audio into notes" wedge.

The noncuro repo is a Python menu-bar prototype using `rumps`, PyAudio, OpenAI,
pydub, keyboard/clipboard automation, and py2app
([README](https://github.com/noncuro/muesli/blob/70ad99398b10756f774d02e82b7ff671ae6600c1/README.md#L1-L20),
[main imports](https://github.com/noncuro/muesli/blob/70ad99398b10756f774d02e82b7ff671ae6600c1/main.py#L1-L39)).
It records a short mic/input-device ring buffer and sends temp MP3 audio to
OpenAI Whisper, then sends transcript text to GPT-4o for rewriting
([record loop](https://github.com/noncuro/muesli/blob/70ad99398b10756f774d02e82b7ff671ae6600c1/main.py#L145-L158),
[OpenAI STT](https://github.com/noncuro/muesli/blob/70ad99398b10756f774d02e82b7ff671ae6600c1/main.py#L112-L143)).

There is no serious meeting lifecycle, local STT, system audio tap,
diarization, persistence, recovery, search, or local-first privacy. The durable
idea is interaction-level: a lightweight "rewind the last 30 seconds into my
notes" action may be valuable for MacParakeet outside the full meeting mode.

### 3. pasrom/meeting-transcriber

Verdict: strongest operational reference for capture health and speaker
identity.

Meeting Transcriber is a native SwiftUI menu-bar app, Swift 6.2, macOS 14.2+,
with WhisperKit, Parakeet, FluidAudio, a custom `tools/audiotap`, strong docs,
tests, Homebrew/App Store release paths, and a local automation/debug API
([Package](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Package.swift#L1-L14),
[architecture](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/docs/architecture-macos.md#L56-L75)).

Architecture and capture:

- It captures app audio through CATapDescription plus mic through AVAudioEngine,
  writes app/mic/mix WAVs, resamples to 16 kHz, supports child-PID capture for
  Electron apps, and includes crash recovery
  ([DualSourceRecorder](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/DualSourceRecorder.swift#L60-L99),
  [crash recovery](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/DualSourceRecorder.swift#L133-L246)).
- It uses record-only sidecars and explicit channel-health monitoring
  ([sidecar](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/RecordingSidecar.swift#L3-L65),
  [channel health](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/ChannelHealthMonitor.swift#L20-L47)).
- Detection is narrower than Muesli: CGWindowList/window-title regexes for
  Zoom/Teams/Webex and similar, requiring Screen Recording
  ([MeetingDetector](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/MeetingDetector.swift#L55-L160)).

Transcription, diarization, identity:

- Dual source tracks are transcribed separately and merged
  ([pipeline transcribe](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/PipelineQueue.swift#L784-L863)).
- FluidAudio diarization supports offline and Sortformer modes, including
  dual-track diarization and re-run controls
  ([diarization loop](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/PipelineQueue.swift#L865-L943),
  [dual-track diarization](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/PipelineQueue.swift#L966-L1035),
  [FluidDiarizer](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/FluidDiarizer.swift#L44-L90)).
- Speaker identity is materially stronger than Muesli: `speakers.json`,
  centroids, cosine/margin thresholds, recency/use counts, rename/delete/merge,
  and owner-only file permissions
  ([SpeakerMatcher constants](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/SpeakerMatcher.swift#L31-L35),
  [matching](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/SpeakerMatcher.swift#L96-L147),
  [save](https://github.com/pasrom/meeting-transcriber/blob/9b514970c5a77e9764381eaec52312a2427c7786/app/MeetingTranscriber/Sources/SpeakerMatcher.swift#L407-L451)).

MacParakeet lessons:

- Copy the capture-health product surface: per-source live/silent indicators,
  permission-broken state, record-only mode, and recoverable finalization
  language.
- Copy the speaker identity taxonomy: anonymous diarization is not the same as
  named returning speakers.
- Consider a debug/local automation API only if it remains behind explicit local
  trust boundaries.
- Be cautious about adopting app-PID tap by default; MacParakeet's current
  ScreenCaptureKit system-audio path is simpler for broad compatibility.

### 4. fastrepl/anarlog

Verdict: best "meeting is a file" product lesson.

Anarlog describes itself as an open source local-first meeting notetaker and
"Granola, rearranged." It explicitly saves each meeting as Markdown on disk,
runs local transcription, and lets users bring OpenAI, Anthropic, Gemini,
OpenRouter, Ollama, LM Studio, or compatible providers
([README](https://github.com/fastrepl/anarlog/blob/2ea8c825c6649d0667c4470c8d0ca5a9d20b58f3/README.md#L1-L29)).

The repo is a broad Tauri/React/Rust workspace with local audio capture,
provider abstractions, sync/API surfaces, Markdown-first notes, and transcript
rendering. Speaker support is mostly provider hints/simple assignment, with
pyannote as a possible provider path; it does not read as a clean local
speaker-recognition loop.

MacParakeet lessons:

- A plain local file can be the primary user trust surface. MacParakeet already
  has artifact folders; it should make `notes.md`, `transcript.json`, and
  exportable Markdown more central.
- "Bring your own LLM" is useful, but a broad provider and sync monorepo can
  dilute a privacy-first story. MacParakeet should add provider surfaces only
  when the local/default boundary stays obvious.

### 5. OpenWhispr/openwhispr

Verdict: strongest cross-platform breadth, but too broad to copy wholesale.

OpenWhispr is Electron 41 plus React/TypeScript with better-sqlite3,
whisper.cpp, sherpa-onnx, and public API/MCP surfaces. Its README claims
meeting transcription with live speaker diarization, voice fingerprinting,
local/cloud engines, notes, semantic search, API, and MCP
([README](https://github.com/OpenWhispr/openwhispr/blob/01f8557b0cce141afa3a607a65bd5195ea8fa40c/README.md#L15-L50)).

Architecture:

- System audio is handled through a matrix of native helpers: macOS audio tap,
  Windows WASAPI helper, Linux PipeWire helper, plus fallbacks.
- Diarization uses sherpa-onnx style assets: pyannote segmentation ONNX,
  3D-Speaker embeddings, and Silero VAD
  ([diarization models](https://github.com/OpenWhispr/openwhispr/blob/01f8557b0cce141afa3a607a65bd5195ea8fa40c/src/helpers/diarization.js#L49-L59)).
- Speaker embeddings support 16 kHz samples, a 512-dimensional embedding, min
  segment length, capped extraction window, centroid computation, and cosine
  similarity
  ([speakerEmbeddings](https://github.com/OpenWhispr/openwhispr/blob/01f8557b0cce141afa3a607a65bd5195ea8fa40c/src/helpers/speakerEmbeddings.js#L7-L15),
  [centroid/cosine](https://github.com/OpenWhispr/openwhispr/blob/01f8557b0cce141afa3a607a65bd5195ea8fa40c/src/helpers/speakerEmbeddings.js#L129-L155)).

MacParakeet lessons:

- Provisional live labels plus post-call refinement is a good UX if labels are
  clearly tentative.
- Local speaker profiles can be implemented with small embeddings and
  conservative matching, but they need explicit confirmation UI.
- Avoid copying the huge native/download/cloud surface unless MacParakeet wants
  to become a platform rather than a focused Mac app.

### 6. Zackriya-Solutions/meetily

Verdict: strong adoption signal, weaker diarization reality in Community
Edition.

Meetily is a Tauri/Rust/Next app with local Whisper/Parakeet transcription,
Ollama-first summaries, optional cloud LLM providers, SQLite/sqlx, and broad
privacy-first positioning. The README says it runs locally and captures,
transcribes, and summarizes meetings
([README](https://github.com/Zackriya-Solutions/meetily/blob/0281737d87d26352fb0adc78c8c0975f691b23d1/README.md#L67-L102)).

Important caveat: the current README says speaker diarization is planned for
PRO, not clearly implemented in Community Edition
([README](https://github.com/Zackriya-Solutions/meetily/blob/0281737d87d26352fb0adc78c8c0975f691b23d1/README.md#L47-L48)).
The codebase has substantial audio modules, VAD/noise processing, capture
backends, transcription workers, import/retranscription paths, and database
repositories, but it reads as churny with backup/old files still present.

MacParakeet lessons:

- Simple local setup and import/retranscribe flows matter.
- Do not let marketing copy outrun the actual diarization implementation.
- Optional cloud providers are fine when framed plainly; "no data leaves your
  computer" becomes false once cloud LLMs are configured.

### 7. Gremble-io/Detto

Verdict: best vault-native / pre-call context reference.

Detto is a native Swift macOS app for Apple Silicon and macOS 26+ with BSL
source-available licensing. Its README explicitly rejects cloud meeting tools
because they do not output plain Markdown and do not feed agent workflows
([README](https://github.com/Gremble-io/Detto/blob/10384c357714a136f7e1d7127a76351668524d94/README.md#L17-L43)).

Capture and artifacts:

- Call capture grabs mic plus system audio, labels the mic as "You" and system
  as "Them," detects conferencing apps, and writes structured Markdown with YAML
  frontmatter into the user's vault
  ([README call capture](https://github.com/Gremble-io/Detto/blob/10384c357714a136f7e1d7127a76351668524d94/README.md#L49-L53)).
- System audio capture uses ScreenCaptureKit, optional per-app filtering, and
  excludes current process audio
  ([SystemAudioCapture](https://github.com/Gremble-io/Detto/blob/10384c357714a136f7e1d7127a76351668524d94/Detto/Sources/Detto/Audio/SystemAudioCapture.swift#L18-L60)).
- TranscriptLogger writes YAML frontmatter, context, attendees, tags, and
  timestamped speaker turns directly to Markdown
  ([TranscriptLogger](https://github.com/Gremble-io/Detto/blob/10384c357714a136f7e1d7127a76351668524d94/Detto/Sources/Detto/Storage/TranscriptLogger.swift#L104-L136),
  [append](https://github.com/Gremble-io/Detto/blob/10384c357714a136f7e1d7127a76351668524d94/Detto/Sources/Detto/Storage/TranscriptLogger.swift#L144-L174)).

MacParakeet lessons:

- Pre-call context and vault-native output are sharper than generic meeting
  notes. MacParakeet's Meetings workspace should support context fields and
  artifact export that downstream agents can consume directly.
- Detto's no-server/no-account/no-analytics posture is a useful bar for
  MacParakeet privacy copy.
- The app is a narrower platform target than MacParakeet, so treat it as a UX
  reference more than a deployment model.

### 8. michaelwilhelmsen/humla

Verdict: good Granola-style macOS product reference, especially for
provider/retention clarity.

Humla is a Tauri 2 + React/Rust app with Swift audio-capture and
speaker-diarize sidecars. It records mic and computer audio as separate streams,
supports local Whisper and hosted STT providers, runs local FluidAudio speaker
identification, and lets the user summarize with notes plus transcript
([README](https://github.com/michaelwilhelmsen/humla/blob/d8968067d0483763b078d40974403861ce2293ed/README.md#L35-L77)).

Notable details:

- The privacy section names where notes, transcripts, audio, keys, and models
  live, and explains raw per-source stream retention as a setting
  ([privacy](https://github.com/michaelwilhelmsen/humla/blob/d8968067d0483763b078d40974403861ce2293ed/README.md#L88-L101)).
- The diarization sidecar exposes Community-1 and Sortformer modes and notes
  the tradeoff: Community-1 has auto speaker count, while Sortformer has a
  fixed 4-speaker cap but better rapid turn changes
  ([speaker-diarize](https://github.com/michaelwilhelmsen/humla/blob/d8968067d0483763b078d40974403861ce2293ed/speaker-diarize/Sources/speaker-diarize/main.swift#L8-L36)).

MacParakeet lessons:

- Borrow the product language around audio retention and provider choice.
- Consider exposing diarization engine tradeoffs only when users can make a
  meaningful choice. Otherwise, hide it behind "Speaker detection" and use sane
  defaults.
- Humla's self-host sync/PocketBase path is outside MacParakeet's current
  trust-first wedge.

### 9. silverstein/minutes

Verdict: best agent-memory and consent/artifact model reference.

Minutes is explicitly "open-source conversation memory" for agents. It writes
meetings to `~/meetings/` as Markdown, exposes CLI and MCP surfaces, and treats
meetings as relationship/provenance data that agents can query
([README](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/README.md#L7-L15)).

Architecture:

- The pipeline is described as Audio -> Transcribe -> Diarize -> Summarize ->
  Structured Markdown -> Relationship Graph, with local whisper/parakeet,
  pyannote-rs, and optional LLMs
  ([pipeline](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/README.md#L88-L99)).
- Desktop call recording captures mic and call audio natively on macOS 15+,
  while CLI call recording requires a routed system-audio setup
  ([call recording](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/README.md#L102-L112)).
- The diarization model distinguishes engines, degraded capture evidence,
  source-aware outputs, and speaker embeddings
  ([diarize.rs](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/crates/core/src/diarize.rs#L1-L45)).
- The native call helper reports source health for mic and call audio
  ([call_capture](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/tauri/src-tauri/src/call_capture.rs#L17-L32)).
- Consent reminder/disclosure stamps can be embedded into artifacts
  ([consent](https://github.com/silverstein/minutes/blob/d59d1d178bf594ae3b9193467a387830e18d71be/README.md#L114-L138)).

MacParakeet lessons:

- Add first-class agent surfaces after the artifact contract is stable: CLI,
  local file schema, and possibly MCP.
- Add optional consent/disclosure metadata as a practical meeting trust
  feature.
- Make degraded capture explicit in the data model instead of only hiding it in
  logs.

### 10. lukasbach/pensieve

Verdict: useful local knowledge-base reference, weak capture reference.

Pensieve is Electron/React/TypeScript with local recordings, chat, MCP, search,
tags, summaries, screenshots, and datahooks. Capture uses Chromium
`getUserMedia` and `MediaRecorder` for desktop audio plus optional mic, saved as
webm tracks. STT is offline batch whisper.cpp after post-processing. Speaker
handling is source/channel attribution and whisper.cpp diarization markers, not
durable speaker identity.

MacParakeet lessons:

- Good ideas: recordings become a searchable local knowledge base; chat/MCP,
  screenshots, tags, semantic search, and datahooks are compelling.
- Do not copy the capture path for a native Mac app. MacParakeet's
  ScreenCaptureKit/Core Audio architecture is stronger.

### 11. paberr/ownscribe

Verdict: good compact CLI pipeline reference, not a ship-in-app stack.

ownscribe is a Python CLI that records system audio via Core Audio taps, can
also record mic, transcribes through WhisperX, optionally diarizes through
pyannote, summarizes locally, and supports "ask your meetings"
([README](https://github.com/paberr/ownscribe/blob/367f6c92300541af40c2b62a065fa96a5fb82d07/README.md#L8-L54)).

Its default command records, transcribes, summarizes, and saves a per-session
folder, with model warmup and resume paths
([usage](https://github.com/paberr/ownscribe/blob/367f6c92300541af40c2b62a065fa96a5fb82d07/README.md#L122-L136),
[options](https://github.com/paberr/ownscribe/blob/367f6c92300541af40c2b62a065fa96a5fb82d07/README.md#L140-L176)).

MacParakeet lessons:

- Pipeline progress should name each stage: capture, transcription,
  diarization, summary, artifact write.
- `resume` and `warmup` are useful automation commands.
- Do not embed a Python/WhisperX/pyannote runtime in MacParakeet; keep those as
  research/debug references.

### 12. pretyflaco/millet

Verdict: useful output/voiceprint reference, not a Mac capture reference.

Millet is a Python pipeline for dual-channel Linux recording, WhisperX,
pyannote, voiceprint speaker recognition, summaries, PDF output, structured
YAML frontmatter, git sync, and CLI commands
([README](https://github.com/pretyflaco/millet/blob/544e6d6b4a29da5dd6af7076bcb47c9c8afe6f3a/README.md#L21-L101)).

It explicitly says macOS supports post-capture transcription/label/sync, but
recording requires Linux
([requirements](https://github.com/pretyflaco/millet/blob/544e6d6b4a29da5dd6af7076bcb47c9c8afe6f3a/README.md#L117-L138)).

MacParakeet lessons:

- Voiceprint enrollment and labeling workflows are worth studying.
- Structured summary frontmatter, sidecar JSON, and multiple exports are useful
  for artifact interoperability.
- The capture architecture does not transfer to MacParakeet.

### 13. screenpipe/screenpipe

Verdict: adjacent memory layer, not meeting-recorder product shape.

Screenpipe is source-available and positions itself as 24/7 local screen/audio
memory: record, search, automate, all local/private, with MCP and SDK surfaces
([README](https://github.com/screenpipe/screenpipe/blob/4ea35c39052f7b8de2305b26c47c2ad5759b40d59/README.md#L62-L80)).
It captures screen, audio, accessibility tree, OCR fallback, transcription,
speakers, keyboard inputs, and app switches, with local storage and optional
encryption
([specs](https://github.com/screenpipe/screenpipe/blob/4ea35c39052f7b8de2305b26c47c2ad5759b40d59/README.md#L107-L119)).

MacParakeet lessons:

- Event-driven capture, search, local APIs, and evaluation tooling are useful
  references for long-term meeting memory.
- Source-available licensing and 24/7 screen capture are not aligned with
  MacParakeet's current trust wedge.

### 14. homelab-00/TranscriptionSuite

Verdict: model-runtime and transcript-workspace reference.

TranscriptionSuite is a local/private STT app with Electron dashboard, Python
backend, multi-backend STT, speaker diarization, audio notebook mode, AI
assistant, longform, and live transcription
([docs README](https://github.com/homelab-00/TranscriptionSuite/blob/ad7cd95619b4efc1a6c9f60626c3564851431ce6/docs/README.md#L12-L21)).
It supports many backends, including WhisperX/faster-whisper, NVIDIA
Parakeet/Canary, VibeVoice, whisper.cpp, MLX Whisper, MLX Parakeet/Canary, and
Sortformer on Apple Silicon
([features](https://github.com/homelab-00/TranscriptionSuite/blob/ad7cd95619b4efc1a6c9f60626c3564851431ce6/docs/README.md#L84-L102)).

MacParakeet lessons:

- Good model/runtime UX reference for model preparation, profile selection,
  audio notebook, and OpenAI-compatible local assistant.
- Too broad and server-shaped for MacParakeet's native app foundation.

### 15. rishikanthc/Scriberr

Verdict: self-hosted transcript UX reference, not botless meeting capture.

Scriberr is a self-hosted local transcription application. It emphasizes
offline transcription, speaker detection, chat with audio, APIs/folder watcher,
notes/highlights, recorder, and a polished transcript UI
([README](https://github.com/rishikanthc/Scriberr/blob/bdb8838b8b9e4a58e74297f6ed2d0acb4c341c4f/README.md#L46-L61)).
It includes adapters for Parakeet, Canary, WhisperX, pyannote, Sortformer, and
Voxtral, but it is not a botless native Mac meeting recorder.

MacParakeet lessons:

- Study transcript-reader UX: seek from text, notes/highlights, summaries, chat,
  exports, and speaker rename dialogs.
- The project status notes active development is paused, so do not over-weight
  it for architecture direction
  ([status](https://github.com/rishikanthc/Scriberr/blob/bdb8838b8b9e4a58e74297f6ed2d0acb4c341c4f/README.md#L25-L35)).

### 16. QuentinFuxa/WhisperLiveKit

Verdict: best live ASR/diarization server reference, not an app architecture to
ship directly.

WhisperLiveKit is an Apache-2 Python live STT server focused on ultra-low
latency. It cites Simul-Whisper, WhisperStreaming, Streaming Sortformer, Diart,
Voxtral, and Silero VAD as foundations
([README](https://github.com/QuentinFuxa/WhisperLiveKit/blob/a99d8d725485e73561b04efe67ae6ba83975283f/README.md#L23-L34)).
It exposes OpenAI-compatible REST, Deepgram-compatible WebSocket, and native
WebSocket APIs
([API](https://github.com/QuentinFuxa/WhisperLiveKit/blob/a99d8d725485e73561b04efe67ae6ba83975283f/README.md#L75-L91)).
Speaker diarization extras include Sortformer/NeMo and Diart
([extras](https://github.com/QuentinFuxa/WhisperLiveKit/blob/a99d8d725485e73561b04efe67ae6ba83975283f/README.md#L102-L117)).

MacParakeet lessons:

- Live streaming should use intelligent buffering and stability policies, not
  naive tiny Whisper chunks.
- Use this as a reference harness for live preview behavior, not as a native
  dependency.

### 17. Natively-AI-assistant/natively-cluely-ai-assistant

Verdict: useful as a positioning warning.

Natively is source-available/personal-use and markets itself as an interview
copilot and meeting assistant with native audio capture, local Whisper STT,
dual-channel intelligence, local RAG, screenshots, and stealth mode
([README](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/blob/875fd2aacf58a5fb3283a03e9f72e043b251c6b0/README.md#L102-L117)).
It is not a good trust model for MacParakeet because the product positioning is
explicitly about hidden interview assistance and "stealth mode"
([README](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant/blob/875fd2aacf58a5fb3283a03e9f72e043b251c6b0/README.md#L106-L113)).

MacParakeet lessons:

- Local RAG and provider data-scope gates are worth borrowing.
- Avoid anything that makes MacParakeet feel hidden, proctor-evasive, or
  consent-hostile.

### 18. Low-Priority Watchlist

OpenScriber is an early Electron/Next app that claims a macOS botless
Granola alternative but has little architecture visible beyond basic project
structure ([README](https://github.com/moinulmoin/openscriber/blob/7c37e1f2735c7c8d62ce77dd1bebc1f0ee235ef1/README.md#L1-L52)).
It is not a meaningful architecture reference today.

Other watchlist repos discovered but not deeply reviewed here: OpenOats,
project-raven, note67, DeLive, heed, kleoth, VoiceFlow, Whishper, and aTrain.
They may be useful for live-assist UI, AEC experiments, or generic
transcription UX, but they are lower value than the primary set for
MacParakeet meeting architecture.

## Diarization Foundations

### FluidAudio / FluidInference

Verdict: best production fit for MacParakeet.

FluidAudio is already the right Swift/CoreML foundation. Its diarization docs
now describe multiple workflow-specific options: LS-EEND, Sortformer,
DiarizerManager, and offline VBx. Offline VBx is positioned as the best
full-file batch option, while LS-EEND and Sortformer are streaming options with
different speaker-count, stability, and overlap tradeoffs
([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/82aed2ab25ea6dca0e5b3a96d2c79b3499063c7d/Documentation/Diarization/GettingStarted.md#L5-L28)).

Most relevant for MacParakeet:

- Source layout separates orchestration, segmentation, embedding extraction,
  clustering, and offline processing
  ([source layout](https://github.com/FluidInference/FluidAudio/blob/82aed2ab25ea6dca0e5b3a96d2c79b3499063c7d/Documentation/Diarization/GettingStarted.md#L71-L113)).
- Offline model loading can be staged for air-gapped/offline environments
  ([manual loading](https://github.com/FluidInference/FluidAudio/blob/82aed2ab25ea6dca0e5b3a96d2c79b3499063c7d/Documentation/Diarization/GettingStarted.md#L115-L176)).
- `OfflineDiarizerManager` handles segmentation, WeSpeaker embeddings,
  PLDA/VBx clustering, timeline reconstruction, file-based memory-mapped
  processing, and progress callbacks
  ([offline VBx](https://github.com/FluidInference/FluidAudio/blob/82aed2ab25ea6dca0e5b3a96d2c79b3499063c7d/Documentation/Diarization/GettingStarted.md#L190-L229)).

Recommendation: use FluidAudio offline VBx for production final diarization and
FluidAudio streaming diarizers only for tentative live hints after the final
data contract exists.

### pyannote.audio

Verdict: best Python reference/oracle, not a Mac app dependency.

pyannote.audio is the canonical Python/PyTorch diarization toolkit. The
Community-1 pipeline requires accepting Hugging Face user conditions and using a
token, then runs locally
([README](https://github.com/pyannote/pyannote-audio/blob/b749285c5cdd9766cc03e4a73fc787813778cdfb/README.md#L24-L56)).
Its README benchmarks Community-1 and Precision-2 across standard datasets and
notes improved speaker counting/assignment versus the older 3.1 pipeline
([benchmarks](https://github.com/pyannote/pyannote-audio/blob/b749285c5cdd9766cc03e4a73fc787813778cdfb/README.md#L83-L103)).

Recommendation: keep pyannote as a research oracle for fixtures and DER/JER
evaluation, not as an embedded runtime.

### WhisperX

Verdict: best conceptual STT+diarization data-flow reference.

WhisperX combines batched Whisper/faster-whisper transcription, VAD batching,
wav2vec2 forced alignment for word timestamps, and pyannote speaker diarization
([README](https://github.com/m-bain/whisperX/blob/8dcdec18039f15e1412d83a60ba7be3728d0c1c7/README.md#L36-L42)).
It documents Hugging Face token requirements for diarization and CPU mode for
Mac use
([README](https://github.com/m-bain/whisperX/blob/8dcdec18039f15e1412d83a60ba7be3728d0c1c7/README.md#L114-L144)).

Recommendation: copy the pipeline concept, not the dependency. MacParakeet's
version should be:

1. final source-separated ASR
2. word timestamps
3. source-specific diarization
4. interval-overlap word attribution
5. speaker confidence/provenance persisted

### NVIDIA NeMo / Sortformer

Verdict: high-value reference for low-latency identity stability, but a weak
direct dependency for MacParakeet.

Sortformer is attractive for streaming and rapid turn changes, but model
variants commonly have a 4-speaker cap and Python/PyTorch/NeMo shaped
deployment. FluidAudio's Sortformer/CoreML path is the relevant Mac-native
route if MacParakeet uses it.

Recommendation: treat Sortformer as an optional experiment for known-small
meetings or tentative live hints, not the default final diarizer for general
meetings.

### diart

Verdict: best real-time diarization architecture reference.

diart is a Python framework for real-time speaker diarization. Its pipeline
combines segmentation, embeddings, and incremental clustering that improves as
the conversation progresses
([README](https://github.com/juanmc2005/diart/blob/392d53a1b0cd0c3fbe46aeef1792e9cf390eaac3/README.md#L56-L70)).
It depends on pyannote models and requires accepting model terms
([model access](https://github.com/juanmc2005/diart/blob/392d53a1b0cd0c3fbe46aeef1792e9cf390eaac3/README.md#L101-L109)).
The API shows `StreamingInference` over a mic source with RTTM writer
([streaming API](https://github.com/juanmc2005/diart/blob/392d53a1b0cd0c3fbe46aeef1792e9cf390eaac3/README.md#L132-L147)).

Recommendation: use diart as a mental model: live diarization should be
stateful, provisional, and later corrected by a post-meeting batch pass.

### sherpa-onnx / 3D-Speaker / WeSpeaker / SpeechBrain

Verdict: useful embeddable building blocks.

OpenWhispr's implementation shows a practical ONNX route: pyannote
segmentation, 3D-Speaker embeddings, Silero VAD, centroiding, and cosine
similarity. This is portable and cross-platform, but less native to
MacParakeet than FluidAudio/CoreML.

Recommendation: keep these as fallback or evaluation references if FluidAudio
speaker enrollment proves insufficient.

### whisper.cpp tinydiarize

Verdict: not enough for MacParakeet diarization.

tinydiarize can mark speaker turns, but it does not provide durable speaker
identity, enrollment, verification, confidence, or cross-meeting profiles. It
is useful only as a tiny baseline.

## Product Lessons For MacParakeet

### 1. Capture Trust Is The Moat

The strongest competitors do not just record; they show whether recording is
healthy. Meeting Transcriber exposes channel silence/health. Minutes has
source-health structs. Muesli and Humla describe source retention and recovery.

MacParakeet should add:

- live mic/system health in the meeting surface
- "system audio missing" and "mic silent" warnings with exact recovery steps
- a record-only degraded mode when STT/finalization is blocked
- finalization progress that names stages: capture finalizing, cleaning mic,
  transcribing mic, transcribing system, diarizing, writing artifacts
- artifact-level degraded-capture metadata, not only logs

### 2. Speaker Claims Need Honest Tiers

Most projects blur "speaker diarization" and "speaker identity." MacParakeet
should not.

Recommended product taxonomy:

| Tier | User-facing meaning | Implementation |
| --- | --- | --- |
| Level 0 | Channel labels | `Me` from mic, `Them`/`System` from remote source |
| Level 1 | Anonymous diarization | `Speaker 1`, `Speaker 2` from diarization segments |
| Level 2 | Confirmed meeting names | user renames anonymous speakers for this transcript |
| Level 3 | Returning speaker memory | opt-in embeddings and conservative cross-meeting match |

Do not show real names from embeddings without confirmation, confidence, and a
clear correction path.

### 3. Build The Data Contract Before Live Diarization

Before adding streaming diarization, define persistent objects:

- `DiarizationRun(id, modelVersion, sourceTrack, startedAt, completedAt,
  status, error, metrics)`
- `SpeakerSegment(startMs, endMs, sourceTrack, speakerId, confidence,
  isTentative, overlapScore, runId)`
- `WordSpeakerAttribution(wordId, speakerId, method, confidence, runId)`
- `SpeakerProfile(id, displayName, embeddings, threshold, lastMatchedAt,
  confirmationState)`

Word attribution should use exclusive diarization interval overlap first, then
word midpoint, then nearest segment, then source prior, then ambiguous.

### 4. Preserve MacParakeet's Source-Aware Final Truth

Several repos still rely on mixed audio, provider diarization, or post-hoc
dedupe. MacParakeet's design is better: source-separated source files are the
truth, `meeting.m4a` is playback/export, and final STT transcribes source files
separately. Keep this invariant.

The next improvement is not to simplify into mixed-audio STT; it is to make
cleaned-mic finalization deterministic and visibly trustworthy.

### 5. Make Artifacts The Product Surface

The best product references are artifact-first:

- Anarlog: every meeting is a `.md` file.
- Detto: vault-native Markdown with frontmatter and context.
- Minutes: Markdown, CLI, MCP, relationship graph.
- Muesli: JSON CLI and notes write-back.
- Millet: summary Markdown plus frontmatter/JSON/PDF.

MacParakeet already has artifact folders. It should promote them:

- make `notes.md` and `transcript.json` first-class in the Meetings UI
- include `microphone-cleaned.m4a` in the manifest when present
- add CLI `meetings list/get/update-notes/export/spec`
- add a stable Markdown export with YAML frontmatter
- later add local FTS and MCP over the same artifact contract

### 6. Context Is A Real Meeting Feature

Detto's client briefing and Humla's "typed notes plus transcript" summary model
are high-value. MacParakeet should treat pre-call context and live notes as
summary steering data, not an afterthought.

Recommended shape:

- meeting context fields: title, attendees, project/folder, agenda, source app,
  calendar event, consent basis
- summary prompt sees user notes separately from transcript
- artifact frontmatter records context and provenance

### 7. Keep The Privacy Story Concrete

"Local-first" is credible only when every exception is named:

- STT engine locality
- summary provider choices
- cloud LLM prompts
- OAuth/calendar access
- iCloud/sync text surfaces
- telemetry
- model download hosts
- artifact retention and deletion behavior

MacParakeet should keep default capture/STT local and explain optional cloud
features in product copy and artifact metadata.

## Recommended MacParakeet Roadmap

### Now

1. Close AEC/source trust before adding more meeting AI.
   - Real no-headset Zoom/Meet/Teams QA.
   - Ensure final STT can reliably wait for or explicitly skip
     `microphone-cleaned.m4a`.
   - Surface when raw mic was used because cleaning failed or was unavailable.

2. Add visible capture health.
   - Per-source level/silence indicators.
   - Permission and degraded-recording warnings.
   - Recovery/record-only messaging.

3. Promote the artifact contract.
   - Include cleaned mic in manifest snapshots when present.
   - Add a stable Markdown export with frontmatter.
   - Add CLI meeting JSON/spec/get/update-notes commands.

4. Define speaker data contracts.
   - Persist diarization run provenance and attribution confidence.
   - Keep anonymous diarization separate from named speaker profiles.

### Next

1. Add project/folder organization and local FTS for meetings.
2. Add confirmed speaker rename UX and per-meeting speaker labels.
3. Add opt-in speaker profile memory after rename UX is solid.
4. Add pre-call context and better summary templates.
5. Add consent/disclosure metadata.

### Later

1. Live provisional diarization hints using FluidAudio streaming diarizers.
2. MCP/local agent server over stable artifact/search APIs.
3. Relationship graph and cross-meeting Ask.
4. Evaluation harness using pyannote/WhisperX/diart as offline references.

### Do Not Copy

- A giant model/provider menu as the core differentiator.
- A Python pyannote/WhisperX runtime inside the shipped Mac app.
- CoreAudio global tap as the default without reopening the VPIO/tap conflict.
- Stealth/interview-copilot positioning.
- Source-available/enterprise capture creep that weakens the local-first user
  trust story.

## Inspected Repositories

| Repo | SHA | License | Stars on 2026-07-04 | Main relevance |
| --- | --- | --- | ---: | --- |
| Muesli-HQ/muesli | `17a013a12964` | MIT | 656 | closest Swift/macOS peer |
| noncuro/muesli | `70ad99398b10` | none detected | 24 | prototype recent-buffer notes |
| pasrom/meeting-transcriber | `9b514970c5a7` | MIT | 69 | capture health and speaker identity |
| fastrepl/anarlog | `2ea8c825c664` | MIT | 8,769 | Markdown-first Granola alternative |
| OpenWhispr/openwhispr | `01f8557b0cce` | MIT | 4,234 | cross-platform breadth, local profiles |
| Zackriya-Solutions/meetily | `0281737d87d2` | MIT | 14,286 | high-adoption local meeting assistant |
| Gremble-io/Detto | `10384c357714` | Other / BSL | 504 | vault-native Swift meeting capture |
| michaelwilhelmsen/humla | `d8968067d048` | MIT | 78 | Granola-style macOS app |
| silverstein/minutes | `d59d1d178bf5` | MIT | 1,316 | agent memory, MCP, consent |
| lukasbach/pensieve | `996ac7f681dd` | none detected | 114 | local recording knowledge base |
| paberr/ownscribe | `367f6c923005` | MIT | 79 | compact Python CLI pipeline |
| pretyflaco/millet | `544e6d6b4a29` | GPL-3.0 | 351 | voiceprints and structured outputs |
| screenpipe/screenpipe | `4ea35c39052f` | source-available | 19,631 | 24/7 local memory layer |
| homelab-00/TranscriptionSuite | `ad7cd95619b4` | GPL-3.0 | 533 | model/runtime workspace |
| rishikanthc/Scriberr | `bdb8838b8b9e` | MIT | 2,818 | self-hosted transcript UX |
| QuentinFuxa/WhisperLiveKit | `a99d8d725485` | Apache-2.0 | 10,513 | live STT/diarization server |
| Natively-AI-assistant/natively-cluely-ai-assistant | `875fd2aacf58` | source-available / other | 1,746 | positioning warning, local RAG ideas |
| moinulmoin/openscriber | `7c37e1f2735c` | Other | 6 | early watchlist |
| FluidInference/FluidAudio | `82aed2ab25ea` | Apache-2.0 | 2,377 | Swift/CoreML diarization foundation |
| pyannote/pyannote-audio | `b749285c5cdd` | MIT | 10,219 | diarization reference |
| m-bain/whisperX | `8dcdec18039f` | BSD-2-Clause | 22,874 | STT + alignment + diarization reference |
| juanmc2005/diart | `392d53a1b0cd` | MIT | 1,996 | streaming diarization reference |

## Bottom Line

MacParakeet's advantage should be trust, not surface area. The strongest path is
to double down on native, local, source-separated, recoverable meeting capture;
make artifacts and health visible; then add speaker intelligence in honest,
opt-in layers. Muesli-HQ proves MacParakeet's direction is competitive.
Meeting Transcriber shows the capture-health and speaker-identity bar.
Detto/Minutes/Anarlog show the artifact/agent-native bar. FluidAudio remains
the right foundation for a Mac-native speaker roadmap.
