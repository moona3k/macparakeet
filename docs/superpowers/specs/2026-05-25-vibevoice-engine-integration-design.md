# VibeVoice Engine Integration — Design Spec

**Phase:** 2.2 of the VibeVoice integration (follows Phase 2.1 Swift wrapper).
**Status:** APPROVED — ready for implementation planning.
**Date:** 2026-05-25.

## Goal

Make Microsoft VibeVoice-ASR a real, user-selectable speech engine in MacParakeet — alongside Parakeet (default) and WhisperKit. The user can pick it per-feature (dictation, file transcription, meeting recording) with sensible defaults, download the ~10 GB model from inside Settings, and run it via the existing `STTScheduler` / `STTRuntime` path established by ADR-016 and ADR-021.

## Non-Goals

These are explicitly out of scope and are deferred to later phases. Don't expand the design to cover them:

- **Diarization handoff** — using VibeVoice's native speaker labels for meeting recordings instead of running the FluidAudio diarizer separately. Phase 2.3.
- **LLM subtitle refinement on VibeVoice output** — the refinement pipeline needs word-level timing; VibeVoice returns segment-level only. Phase 2.3 (with forced alignment or a different refinement path).
- **Production library bundling** — `libvibevoice.a` and `libggml*.dylib` still live at the spike path via hard-coded `unsafeFlags` from Phase 2.1. Replacing this with proper bundling into `MacParakeet.app/Contents/Frameworks/` is Phase 2.5.
- **Hardware compatibility detection** — the ggml-Metal PAD kernel isn't implemented for Apple7 (M1 Max). A separate session is fixing this upstream; we assume it lands. No runtime detection in this phase.
- **Language hint forwarding** — VibeVoice auto-detects internally; the `--language` CLI flag is accepted-but-ignored with a warning when paired with `--engine vibevoice`.

## Architecture Overview

```
┌─ User-facing ──────────────────────────────────────────┐
│  Settings (Modes tab)        macparakeet-cli           │
│  4 engine selectors          --engine vibevoice        │
│  Download button             stt download-model        │
└──────────────────┬─────────────────────┬───────────────┘
                   │                     │
                   ▼                     ▼
┌─ Persistence ──────────────────────────────────────────┐
│  SpeechEnginePreferences (UserDefaults)                │
│  - global: SpeechEnginePreference                      │
│  - dictation/fileTranscription/meetingRecording:       │
│    FeatureEngineSelection (.global | .specific(…))     │
└──────────────────┬─────────────────────────────────────┘
                   │ engine(for: STTJobKind)
                   ▼
┌─ Control plane (existing, extended) ───────────────────┐
│  STTScheduler                                          │
│  - resolves engine per job from preferences            │
│  - routes to per-engine slot                           │
│  - NEW: VibeVoice never claims the dictation slot      │
│  - NEW: only one VibeVoice job in flight at a time     │
├────────────────────────────────────────────────────────┤
│  STTRuntime                                            │
│  - owns AsrManager(s) for Parakeet (existing)          │
│  - owns WhisperEngine (existing)                       │
│  - NEW: owns VibeVoiceEngine                           │
└──────────────────┬─────────────────────────────────────┘
                   │
                   ▼
┌─ Engine wrappers ──────────────────────────────────────┐
│  Parakeet path   Whisper path   NEW: VibeVoiceEngine   │
│  (FluidAudio)    (WhisperKit)   (wraps VibeVoiceASR    │
│                                  from Phase 2.1)       │
└────────────────────────────────────────────────────────┘
```

## Type System

### Extend `SpeechEnginePreference`

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
    case vibevoice  // NEW
}
```

### New: `FeatureEngineSelection`

Either "follow global" or "override with this specific engine."

```swift
public enum FeatureEngineSelection: Codable, Sendable, Equatable {
    case global                              // resolve to whatever `global` is
    case specific(SpeechEnginePreference)
}
```

### New: `SpeechEnginePreferences`

The persisted blob in UserDefaults. Replaces the old single `SpeechEnginePreference` value with one container holding global + three per-feature overrides.

```swift
public struct SpeechEnginePreferences: Codable, Sendable, Equatable {
    public var global: SpeechEnginePreference            // default .parakeet
    public var dictation: FeatureEngineSelection         // default .global
    public var fileTranscription: FeatureEngineSelection // default .global
    public var meetingRecording: FeatureEngineSelection  // default .global

    public func engine(for jobKind: STTJobKind) -> SpeechEnginePreference {
        switch jobKind {
        case .dictation:           return resolve(dictation)
        case .fileTranscription:   return resolve(fileTranscription)
        case .meetingFinalize, .meetingLiveChunk: return resolve(meetingRecording)
        }
    }
    private func resolve(_ s: FeatureEngineSelection) -> SpeechEnginePreference {
        switch s { case .global: return global; case .specific(let e): return e }
    }
}
```

### Migration

Existing users have a single `SpeechEnginePreference` in UserDefaults. The implementer should grep for the existing storage key and migrate from it. On first launch after the update:

1. Load the old value (or `.parakeet` if absent).
2. Construct `SpeechEnginePreferences(global: oldValue, dictation: .global, fileTranscription: .global, meetingRecording: .global)`.
3. Save the new blob; delete the old key.

Behavior is identical for any existing user — all features follow global by default, and global keeps whatever they had before.

## Result Type

Extend `STTResult` with one optional field:

```swift
public struct STTResult: Sendable, Equatable {
    public let text: String
    public let words: [WordTimestamp]?
    public let language: String?
    public let engine: SpeechEnginePreference?
    public let modelVariant: String?
    public let segments: [DiarizedSegment]?  // NEW — populated by VibeVoice only
}
```

**Population by engine:**

| Field | Parakeet / Whisper | VibeVoice |
|---|---|---|
| `text` | flat text | segments joined with `\n` |
| `words` | word-level timestamps | `nil` (VibeVoice doesn't expose them) |
| `language` | detected or hint-set | `nil` (not exposed via C ABI) |
| `engine` | `.parakeet` / `.whisper` | `.vibevoice` |
| `modelVariant` | engine-specific | `"vibevoice-asr-q4_k"` |
| `segments` | `nil` | the actual `[DiarizedSegment]` |

## VibeVoiceEngine

New file: `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift`.

Wraps `VibeVoiceCore.VibeVoiceASR` (from Phase 2.1) behind the same shape `STTRuntime` already manages for Parakeet and Whisper.

```swift
public actor VibeVoiceEngine {
    private let asr: VibeVoiceASR
    private var isLoaded = false

    public init() { self.asr = VibeVoiceASR() }

    public func warmUp() async throws { ... }  // calls asr.loadModel
    public func transcribe(audioPath: String, job: STTJobKind) async throws -> STTResult { ... }
    public func unload() async { ... }

    // Resolves model files from ~/Library/Application Support/MacParakeet/models/stt/vibevoice/
    // Throws .modelNotLoaded if either file is missing.
    private static func modelPaths() throws -> (model: URL, tokenizer: URL) { ... }

    // VibeVoice requires 24 kHz mono WAV. If audioPath is mp3/m4a/etc., convert
    // via the bundled FFmpeg into a temp file first. Returns the path that the
    // ASR should actually open.
    private static func ensureWAV(_ path: String) async throws -> String { ... }
}
```

The transcribe flow:

1. Warm up if not loaded (calls `vv_capi_load` — 13s on M1 Max).
2. Convert input to 24 kHz mono WAV if needed (FFmpeg available at `/Applications/MacParakeet.app/Contents/Resources/ffmpeg`).
3. Call `asr.transcribe(wavPath:)` → `[DiarizedSegment]`.
4. Wrap into `STTResult` per the table above.

## STTRuntime Changes

`STTRuntime` is the sole owner of engine model lifecycle. It gets a new lazy slot:

```swift
public actor STTRuntime {
    // existing
    private var asrManagers: [AsrManager]
    private var whisperEngine: WhisperEngine?
    // NEW
    private var vibevoiceEngine: VibeVoiceEngine?

    // Constructed lazily — only when VibeVoice is selected for some feature.
    // Saves the ~10 MB working memory and the load time for users who never enable it.
    private func ensureVibeVoice() async throws -> VibeVoiceEngine {
        if let existing = vibevoiceEngine { return existing }
        let engine = VibeVoiceEngine()
        try await engine.warmUp()
        vibevoiceEngine = engine
        return engine
    }

    // Engine-switch availability check now also considers VibeVoice load progress
    // — same lease semantics as Whisper (blocked while a meeting is recording).
}
```

`STTRuntime.observeWarmUpProgress()` extends to surface VibeVoice load progress (the 13s window) so the UI can show a spinner when a user first runs VibeVoice after picking it.

## STTScheduler Changes

`STTScheduler` is the job broker. Two new behaviors:

### 1. Engine resolution per job

```swift
// Pseudocode in the dispatch path:
func dispatch(_ job: STTJob) async throws -> STTResult {
    let prefs = SpeechEnginePreferencesStore.shared.current
    let engine = prefs.engine(for: job.kind)
    return try await dispatch(job, to: engine)
}
```

`SpeechEngineRoutedTranscribing.transcribe(audioPath:job:speechEngine:onProgress:)` already exists. The scheduler internally calls this with the resolved engine.

### 2. VibeVoice never claims the dictation slot

```swift
// Slot assignment:
if job.kind == .dictation && resolvedEngine == .vibevoice {
    // VibeVoice on dictation: still allowed (user explicit choice) but goes to
    // the shared/background slot, not the reserved dictation slot.
    return shared.dispatch(job, to: .vibevoice)
}
```

Rationale: the reserved dictation slot exists to guarantee interactive latency. VibeVoice's 13s load + 2-4s inference per dictation breaks that guarantee — but a user who explicitly picks VibeVoice for dictation has opted into it. The slot-routing guardrail prevents VibeVoice from blocking a fast Parakeet dictation that's queued behind it.

### 3. Only one VibeVoice job at a time

The C library has a single global engine. The `VibeVoiceEngine` actor serializes calls naturally, but if the scheduler dispatches a second VibeVoice job to the shared slot while one is already running, that slot is wasted blocking inside the actor instead of being available for a Parakeet or Whisper job that could run concurrently. The scheduler tracks VibeVoice in-flight explicitly so it can route around that:

```swift
private var vibevoiceInFlight = false

func dispatch(_ job: STTJob, to: .vibevoice) async throws -> STTResult {
    while vibevoiceInFlight { try await sleep(checkInterval) }
    vibevoiceInFlight = true
    defer { vibevoiceInFlight = false }
    // ... dispatch to engine ...
}
```

This is a simplification — real implementation should use a proper queue/semaphore.

## Settings UI

Extend the existing engine picker on the Modes tab (where the current Parakeet/Whisper selector lives).

### Layout

```
┌─ Speech Engines ─────────────────────────────────────┐
│                                                       │
│  Default engine            [Parakeet ▼]              │
│  Used when a feature is set to "Use default"         │
│                                                       │
│  Dictation                 [Use default ▼]           │
│  ⚠ Latency warning shown when set to VibeVoice       │
│                                                       │
│  File transcription        [Use default ▼]           │
│                                                       │
│  Meeting recording         [Use default ▼]           │
│  ✨ Hint shown when set to VibeVoice: native diarize │
│                                                       │
│  ─────────────────────────────────────────────────   │
│                                                       │
│  Engine models                                        │
│  • Parakeet     installed                            │
│  • Whisper      installed                            │
│  • VibeVoice    9.7 GB needed     [Download]         │
│                                                       │
└───────────────────────────────────────────────────────┘
```

### Behavior

- Each per-feature picker: `[Use default | Parakeet | Whisper | VibeVoice]` — 4 options
- "Use default" is the leftmost option and is the default value
- When a per-feature picker is set to anything other than "Use default", a small "Override" pill or chip appears
- Per-feature contextual hints (shown only when relevant):
  - "Dictation" set to VibeVoice (or to "Use default" while global = VibeVoice): `"⚠ VibeVoice has ~13s startup latency on first use. Dictation may feel slow."`
  - "Meeting recording" set to VibeVoice: `"✨ VibeVoice provides native speaker labels — no separate diarization pass needed."`
- Engine switching is **disabled** for all four pickers when:
  - A meeting is actively recording (existing lease behavior — applies to all engines)
  - Any STT job is in flight (existing behavior)
  - **Any** model download is in progress, not just the one being switched to (prevents the user from changing preferences mid-download and ending up pointed at a half-downloaded model)
- A model that's selected but not installed shows: `"⚠ Model not installed — transcription will fail until you download it."` near the picker

### Engine Models Section

Lists all three engines with status badges:
- `installed` (green) — model files present
- `<size> needed` + `[Download]` button (amber)
- `Downloading… 3.2 GB / 9.7 GB` + progress bar + Cancel button (during download)
- `Download failed` + retry button + error message (after a failure)

Clicking `[Download]` for VibeVoice fetches both files (`vibevoice-asr-q4_k.gguf` 9.7 GB + `tokenizer.gguf` 5.6 MB) from `https://huggingface.co/mudler/vibevoice.cpp-models/resolve/main/...`.

## Model Download

### Storage

`~/Library/Application Support/MacParakeet/models/stt/vibevoice/`
- `vibevoice-asr-q4_k.gguf` (9.7 GB)
- `tokenizer.gguf` (5.6 MB)

Mirrors the Whisper convention (`models/stt/whisper/`).

### Triggers

1. **Settings button** (primary): user clicks `[Download]` in the Engine Models section.
2. **CLI command**: `macparakeet-cli stt download-model --engine vibevoice`.
3. **NOT** auto-download during transcription — matches Whisper's "refuses to auto-download during transcription" guard from ADR-021.

### UX

- Foreground download with progress (`3.2 GB of 9.7 GB · 70 MB/s · 1m 33s remaining`)
- Resumable via HTTP Range requests so a dropped connection doesn't waste prior bytes
- SHA-256 verification of both files after download — fail with clear error if mismatched
- Cancel button stops the transfer and removes the partial file

### Failure Modes

| Cause | UI text |
|---|---|
| No network | `"Couldn't reach huggingface.co — check your connection and try again."` |
| Disk full / quota | `"Not enough disk space (10 GB needed)."` |
| Hash mismatch | `"Downloaded file is corrupted — please retry."` |
| Cancelled by user | (no error, partial file deleted, button returns to `[Download]`) |

All failures logged via anonymous telemetry (per ADR-012). Transcription remains blocked until the model is present with valid hashes.

## CLI

Extend the existing `transcribe` command (per ADR-021's `--engine` pattern):

```bash
# Existing
macparakeet-cli transcribe --engine parakeet /path/audio.mp3
macparakeet-cli transcribe --engine whisper --language ja /path/audio.m4a

# New
macparakeet-cli transcribe --engine vibevoice /path/audio.mp3
macparakeet-cli transcribe --engine vibevoice --language ja /path/audio.m4a
# (--language ignored for VibeVoice with a one-line warning to stderr)
```

New subcommand for explicit model management:

```bash
macparakeet-cli stt download-model --engine vibevoice
macparakeet-cli stt download-model --engine vibevoice --force   # re-download
```

If a Whisper model download command doesn't exist yet, add `--engine whisper` to the same new subcommand for consistency.

`macparakeet-cli health` now reports VibeVoice availability alongside the existing engines:

```
Engine status:
  Parakeet     ready (model: parakeet-tdt-0.6b-v3, slot 1 available)
  Whisper      ready (model: large-v3-v20240930_turbo_632MB)
  VibeVoice    model missing (run `stt download-model --engine vibevoice`)
```

`Sources/CLI/CHANGELOG.md` gets an entry per CLI public-contract policy.

## File Inventory

### New files

- `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift`
- `Sources/MacParakeetCore/STT/SpeechEnginePreferences.swift` (the new container + migration helper)
- `Sources/MacParakeetCore/STT/VibeVoiceModelDownloader.swift` (download + hash verification + progress reporting)
- `Sources/MacParakeet/Views/Settings/SpeechEngineCard.swift` (the 4-picker UI)
- `Sources/MacParakeet/Views/Settings/EngineModelStatusRow.swift` (per-engine model status + Download button)
- `Sources/CLI/Commands/STTDownloadModelCommand.swift`
- New Swift target test files mirroring each of the above

### Modified files

- The file containing the `SpeechEnginePreference` enum declaration (grep `enum SpeechEnginePreference` to find it) — add `.vibevoice` case
- `Sources/MacParakeetCore/STT/STTResult.swift` — add `segments` optional field
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — add `vibevoiceEngine` slot + warm-up plumbing
- `Sources/MacParakeetCore/STT/STTScheduler.swift` — engine resolution per job + VibeVoice slot/queue guardrails
- `Sources/MacParakeetCore/Models/SpeechEngineSelection.swift` (if it exists) — update for the new enum case
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` (or the Modes-tab VM) — bind 4 pickers to `SpeechEnginePreferences`
- The existing Modes-tab Settings view containing the current single engine picker (grep for `SpeechEnginePreference` usage in `Sources/MacParakeet/Views/Settings/` to locate it) — replace single picker with the new `SpeechEngineCard`
- `Sources/CLI/Commands/TranscribeCommand.swift` — accept `--engine vibevoice`
- `Sources/CLI/Commands/HealthCommand.swift` — report VibeVoice availability
- `Sources/CLI/CHANGELOG.md` — semver entry
- `spec/06-stt-engine.md` — extend narrative to cover the third engine + per-feature selectors
- `spec/adr/021-whisperkit-multilingual-stt.md` — amendment cross-reference noting VibeVoice as a sibling case (or new ADR if scope warrants)

## Testing Strategy

| Layer | Tests |
|---|---|
| `SpeechEnginePreferences` | Encoding round-trip, migration from old single-pref, `engine(for:)` resolution for each `STTJobKind` and each combination of global / per-feature |
| `VibeVoiceEngine` | Warm-up success/failure paths, transcribe on WAV (uses Phase 2.1's 15s fixture), non-WAV input triggers conversion, unload |
| `STTRuntime` | Lazy construction of `vibevoiceEngine`, warm-up progress fan-out, engine-switch availability |
| `STTScheduler` | Engine resolution per job kind, VibeVoice → shared slot routing (not dictation slot), only one VibeVoice job in flight at a time, lease guard blocks switching during meetings |
| `VibeVoiceModelDownloader` | Hash verification (pass + fail), partial-file resume, cancel removes partial file, network-error surface |
| CLI | `--engine vibevoice` accepted, `--language` warning emitted, `stt download-model` subcommand, `health` output includes VibeVoice |
| End-to-end | Pick VibeVoice in Settings → download model → transcribe a fixture → result has `segments` populated and `words` nil |

Integration tests that require the model file gracefully skip via `XCTSkip` when the model isn't installed at the expected path (matches the Phase 2.1 pattern).

## Open Questions

None that block implementation. The following are explicit Phase 2.3 / 2.5 deferrals (already noted in Non-Goals):

- Diarization handoff for meetings (Phase 2.3)
- Subtitle LLM refinement on VibeVoice output (Phase 2.3, needs word alignment)
- Production library bundling (Phase 2.5)
- Hardware compatibility detection for ggml-Metal kernel gaps (waiting on upstream fix in flight)
