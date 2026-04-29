# ADR-021: WhisperKit as Optional Multilingual STT Engine

> Status: IMPLEMENTED
> Date: 2026-04-28
> Related: ADR-001 (Parakeet primary STT), ADR-007 (FluidAudio CoreML migration), ADR-014 (meeting recording), ADR-016 (centralized STT runtime + scheduler), ADR-019 (crash-resilient meeting recording)

## Context

ADR-001 chose Parakeet TDT 0.6B-v3 as MacParakeet's primary speech model because it is extremely fast, accurate for English and supported European languages, and well suited to Apple Silicon through FluidAudio CoreML. That decision still holds for the default path.

The gap is language coverage. Parakeet v3 covers 25 European languages and does not cover Korean, Japanese, Chinese, Hindi, Arabic, and many other languages that users reasonably expect from a local transcription app. The old docs described this as a hard limitation. Main now includes Whisper support so MacParakeet can remain local-first while covering those languages.

The product requirement is not "replace Parakeet." It is:

- keep Parakeet as the default fast path,
- add a local secondary engine for unsupported languages,
- make engine selection explicit and predictable,
- keep meeting recordings stable even if settings change mid-session,
- expose the same capability through the versioned CLI.

## Decision

### 1. Parakeet remains default and primary

Parakeet TDT via FluidAudio CoreML stays the default STT engine for the GUI and CLI. It remains the engine to optimize first for dictation latency, memory use, and release messaging.

WhisperKit is added as an optional second engine for broader multilingual recognition.

### 2. Add `SpeechEnginePreference` and `SpeechEngineSelection`

The persisted GUI preference is:

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
}
```

`SpeechEngineSelection` pairs the engine with an optional Whisper language hint:

```swift
public struct SpeechEngineSelection: Codable, Equatable, Sendable {
    public let engine: SpeechEnginePreference
    public let language: String?
}
```

Language hints are normalized to canonical Whisper language codes. Region-style aliases such as `ko-KR`/`KO_kr` collapse to the primary Whisper code (`ko`). `"auto"` and `"auto-detect"` are stored as `nil`, which tells WhisperKit to detect language.

### 3. Add `WhisperEngine`

`WhisperEngine` wraps WhisperKit behind the same `STTTranscribing` shape used by the rest of the app. It:

- uses `large-v3-v20240930_turbo_632MB` by default,
- stores models under `~/Library/Application Support/MacParakeet/models/stt/whisper/`,
- refuses to auto-download during transcription,
- exposes an explicit model download path through the CLI and Settings,
- returns `STTResult(text:words:language:)` where WhisperKit reports language.

The default SPM dependency includes WhisperKit. CI and syntax/concurrency checks may set `MACPARAKEET_SKIP_WHISPERKIT=1` while upstream packages catch up with Swift 6 language-mode strictness.

### 4. Extend, do not fork, the scheduler architecture

ADR-016's centralized control plane remains the app architecture. The scheduler still owns job admission, slot choice, priority, backpressure, and cancellation.

This ADR adds speech-engine routing:

- unrouted jobs use the runtime's current engine preference,
- routed jobs pass a `SpeechEngineSelection`,
- `STTRuntime` dispatches `.parakeet` to FluidAudio and `.whisper` to `WhisperEngine`,
- `STTScheduler.setSpeechEngine(_:)` is rejected while jobs are queued/running,
- active meeting sessions hold a speech-engine lease, which also blocks engine switching.

The two-slot scheduler policy is unchanged:

1. interactive slot: dictation
2. background slot: meeting finalization, live meeting chunks, file/URL transcription

Whisper does not get its own third lane in this implementation.

### 5. Pin meeting recordings to the engine active at start

Meeting recording is long-lived. Changing speech settings mid-call must not produce a session where early live chunks use one engine, finalization uses another, and crash recovery has to guess.

`MeetingRecordingService.startRecording` captures a `SpeechEngineLease` from the scheduler. The selected engine/language is written into:

- in-memory session state,
- `MeetingRecordingOutput`,
- `meeting-recording-metadata.json`,
- `recording.lock`.

Final transcription and crash recovery use that captured selection. The settings UI refuses engine switches while the lease is active.

### 6. Expose CLI per-invocation engine selection

The CLI keeps Parakeet as default:

```bash
macparakeet-cli transcribe file.mp3 --format json
```

Whisper is explicit:

```bash
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
macparakeet-cli transcribe korean.mp3 --engine whisper --language ko --format json
```

`--language` is ignored by Parakeet. JSON output may include an additive top-level `language` field when the selected engine reports it.

## Rationale

### Why WhisperKit

WhisperKit gives broad language coverage while staying local. It is a better fit than a cloud STT fallback because MacParakeet's core promise is that audio never leaves the Mac.

### Why not auto-fallback

Automatic fallback would be surprising and hard to debug: the same file could use different engines depending on detection confidence, installed models, and transient failures. The current design is explicit. Users choose Whisper in Settings or pass `--engine whisper` in the CLI.

### Why not replace Parakeet

Parakeet remains much faster and lighter for supported languages, especially dictation. Whisper solves coverage, not the default latency target.

### Why pin meetings

Meeting recordings span minutes or hours and have recovery semantics. Pinning gives one durable answer to "which engine produced this meeting?" even across crashes and app restarts.

## Consequences

### Positive

- MacParakeet covers Korean, Japanese, Chinese, and many other languages locally.
- Parakeet's performance remains the default path.
- CLI callers can choose an engine per job without mutating GUI settings.
- Meeting recording remains deterministic under settings changes and crash recovery.
- Existing Parakeet-only workflows remain compatible.

### Negative

- A second model cache increases disk use.
- WhisperKit adds another SwiftPM dependency and upstream compatibility surface.
- Whisper is slower than Parakeet for supported languages.
- Users must download the Whisper model explicitly before first use.
- Documentation must distinguish "fully local speech" from "always Parakeet."

## Implementation Notes

- `Package.swift`: optional WhisperKit dependency from `argmax-oss-swift`, skipped by `MACPARAKEET_SKIP_WHISPERKIT=1`.
- `SpeechEnginePreference.swift`: persisted engine, language, model-variant normalization.
- `WhisperLanguageCatalog.swift`: user-facing language list/search.
- `WhisperEngine.swift`: WhisperKit loading, local model discovery, download, decoding options, word timing mapping.
- `STTRuntime.swift`: engine dispatch and lifecycle.
- `STTScheduler.swift`: switching guards, routed jobs, active speech-engine leases.
- `SettingsViewModel.swift` / `SettingsView.swift`: Speech Recognition card, engine picker, Whisper language picker, model download status.
- `TranscribeCommand.swift` / `ModelsCommand.swift`: `--engine`, `--language`, and `models download whisper-*`.
- `MeetingRecordingService`, `MeetingRecordingMetadata`, `MeetingRecordingLockFileStore`, and `MeetingRecordingRecoveryService`: captured engine/language persistence.

## References

- [ADR-001: Parakeet TDT 0.6B-v3 as Primary STT Engine](001-parakeet-stt.md)
- [ADR-016: Centralized STT Runtime and Scheduler](016-centralized-stt-runtime-scheduler.md)
- `Sources/MacParakeetCore/STT/WhisperEngine.swift`
- `Sources/MacParakeetCore/SpeechEnginePreference.swift`
- `Sources/CLI/CHANGELOG.md`
