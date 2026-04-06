# MacParakeet: Architecture

> Status: **ACTIVE** - Authoritative, current
> The definitive technical stack and system design for MacParakeet.

---

## System Overview

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              MACPARAKEET                                          │
│                          macOS Native App                                         │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                             UI LAYER                                       │  │
│  │                           (SwiftUI)                                        │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────┐  │  │
│  │  │  Main Window  │  │   Menu Bar    │  │   Dictation   │  │ Settings  │  │  │
│  │  │  (Drop Zone + │  │   (Status +   │  │   Overlay     │  │   View    │  │  │
│  │  │  Transcripts) │  │    Quick      │  │  (Recording   │  │           │  │  │
│  │  │               │  │    Actions)   │  │   Indicator)  │  │           │  │  │
│  │  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘  └─────┬─────┘  │  │
│  │          └──────────────────┴──────────────────┴─────────────────┘         │  │
│  └──────────────────────────────────────┬─────────────────────────────────────┘  │
│                                         │                                        │
│                                         ▼                                        │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                        MacParakeetCore                                     │  │
│  │                     (Library — No UI Deps)                                 │  │
│  │                                                                            │  │
│  │  ┌─────────────────┐  ┌────────────────────┐  ┌──────────────────┐      │  │
│  │  │ DictationService│  │TranscriptionService│  │MeetingRecording  │      │  │
│  │  └────────┬────────┘  └─────────┬──────────┘  │   Service        │      │  │
│  │           │                     │              └────────┬─────────┘      │  │
│  │           │                     │                       │                │  │
│  │  ┌────────▼─────────────────────▼──────┐  ┌────────────▼────────────┐   │  │
│  │  │         AudioProcessor              │  │  MeetingAudioCapture    │   │  │
│  │  │  (Format conversion, resampling)    │  │  (Core Audio Taps +    │   │  │
│  │  │                                     │  │   AVAudioEngine)       │   │  │
│  │  └──────────────────┬──────────────────┘  └────────────┬────────────┘   │  │
│  │                               │                                           │  │
│  │                     ┌─────────▼─────────┐  ┌────────────────────────────┐ │  │
│  │                     │   STT Scheduler   │  │  TextProcessingPipeline   │ │  │
│  │                     │   + Runtime       │  │  (Deterministic cleanup)  │ │  │
│  │                     └─────────┬─────────┘  └────────────────────────────┘ │  │
│  │                               │                                           │  │
│  │  ┌──────────────┐  ┌────────▼──────────────────────────────────────────┐ │  │
│  │  │ExportService │  │               Data Layer                          │ │  │
│  │  │(TXT)         │  │  Models: Dictation, Transcription, Prompt,       │ │  │
│  │  └──────────────┘  │          Summary, ChatConversation,              │ │  │
│  │                     │          CustomWord, TextSnippet                 │ │  │
│  │                     │  Repos:  DictationRepository,                    │ │  │
│  │                     │          TranscriptionRepository,                │ │  │
│  │                     │          PromptRepository, SummaryRepository,    │ │  │
│  │                     │          ChatConversationRepository,             │ │  │
│  │                     │          CustomWordRepository,                   │ │  │
│  │                     │          TextSnippetRepository                   │ │  │
│  │                     │  DB:     GRDB (SQLite, single file)             │ │  │
│  │                     └──────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          EXTERNAL PROCESSES                                      │
│                                                                                  │
│  ┌──────────────────────────────┐                                                │
│  │   Parakeet STT (In-Process)  │                                                │
│  │   FluidAudio CoreML on ANE   │                                                │
│  │   ~66 MB working RAM         │                                                │
│  │   ~2.5% WER, 155x realtime   │                                                │
│  └──────────────────────────────┘                                                │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          SYSTEM INTEGRATIONS                                     │
│                                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌──────────────┐  ┌─────────┐│
│  │AVAudio   │  │ CGEvent  │  │NSPasteboard │  │Accessibility │  │Core     ││
│  │Engine    │  │(Global   │  │(Clipboard   │  │(Permission   │  │Audio    ││
│  │(Mic)     │  │ Hotkey)  │  │ Paste)      │  │ Control)     │  │Taps     ││
│  └──────────┘  └──────────┘  └─────────────┘  └──────────────┘  └─────────┘│
│                                                                                  │
│  Total AI Memory: ~66 MB peak (Parakeet on ANE)                                │
│  Recommended: 8 GB RAM (Apple Silicon only).                                    │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Core STT runs on-device.** Optional LLM features use configured providers or Local CLI tools, and telemetry/crash reporting are opt-out. The app supports a fully local setup, but it is not network-free in every configuration.

### Concurrency Model (ADR-015 + ADR-016)

Dictation and meeting recording run concurrently as independent audio pipelines, but all STT work routes through one scheduler and one shared runtime owner:

```
┌─ Dictation Pipeline ──────────────────────┐
│ AudioRecorder (own AVAudioEngine)         │
│ → DictationService                        │
└───────────────────────────────────────────┘

┌─ Meeting Pipeline ────────────────────────┐
│ MicrophoneCapture (own AVAudioEngine)     │
│ + SystemAudioTap (Core Audio Taps)        │
│ → MeetingRecordingService                 │
└───────────────────────────────────────────┘

┌─ File / URL Pipeline ─────────────────────┐
│ FFmpeg / AudioConverter / yt-dlp          │
│ → TranscriptionService                    │
└───────────────────────────────────────────┘

                │
                ▼
      STT Scheduler / Control Plane
      ├── Interactive slot  → dictation
      └── Background slot   → meeting + file transcription
                │
                ▼
     STT Runtime (slot-scoped AsrManagers on CoreML / ANE)
```

- **No shared audio engine** — dictation and meeting capture remain independent. macOS HAL multiplexes mic access.
- **No mutual exclusion** — dictation and meeting recording can both be active.
- **Centralized STT ownership** — one runtime owns model lifecycle, warm-up, and shutdown.
- **Explicit scheduling** — a reserved dictation slot plus a shared background slot; within the background slot, finalize beats live preview, and file transcription waits.
- **Menu bar icon priority** — meeting > dictation > file-transcription > idle.

---

## Components Detail

### 1. MacParakeet App (GUI — SwiftUI)

The UI layer. Thin shell over MacParakeetCore. No business logic lives here.

#### Main Window

**Responsibility:** Primary interface for file transcription. Accepts drag-and-drop, displays transcripts, provides export controls.

**Key Types:**
- `MainWindowView` — Sidebar (Transcribe / Dictations / Vocabulary / Settings) + content pane
- `TranscribeView` — Drop zone + recent transcriptions list
- `TranscriptResultView` — Scrollable text with optional word-level timestamps
- `DictationHistoryView` — Flat chronological list with bottom bar audio player

**Shared Components** (`Views/Components/`):
- `DesignSystem` — Centralized design tokens (Colors, Typography, Spacing, Layout, Animation)
- `SacredGeometry` — Shared sacred geometry components:
  - `TriangleShape` — Equilateral triangle Shape
  - `SpinnerRingView` — Compact merkaba spinner
  - `MeditativeMerkabaView` — Large, slow merkaba for empty states
  - `SacredGeometryDivider` — Thin line with centered diamond ornament

**Dependencies:** `TranscriptionService`, `ExportService`

**Data Flow:**
```
File dropped → MainWindowView → TranscriptionService.transcribe(fileURL:)
                                       │
                                       ▼
                              Transcript displayed
```

#### Menu Bar

**Responsibility:** Always-visible status indicator. Quick access to dictation, recent files, and settings.

**Key Types:**
- `AppDelegate` — NSStatusItem setup + NSMenu, main window lifecycle (NSWindow + NSHostingView)

**Dependencies:** `DictationService`, app state

#### Dictation Overlay

**Responsibility:** Floating, non-activating panel that shows recording state. Appears near the cursor or in a fixed position. Does not steal focus from the active app.

**Key Types:**
- `DictationOverlayView` — Waveform visualization + status text
- `DictationOverlayController` — NSPanel (non-activating) lifecycle

**Dependencies:** `DictationService` (observes state)

**Design Notes:**
- Uses `NSPanel` with `.nonactivatingPanel` collection behavior so it never steals keyboard focus
- Subclass `NSPanel` as `KeylessPanel` with `canBecomeKey → false` (overlay should never steal focus)
- Audio level visualization driven by `DictationService` publishing amplitude values

#### Settings View

**Responsibility:** User preferences and diagnostics. Dictation hotkey, processing mode, custom words, text snippets, general preferences.

**Key Types:**
- `SettingsView` — Card-based scrollable container
- `SettingsViewModel` — Manages all settings state, permissions, model status, licensing

**Dependencies:** `UserDefaults`, `CustomWordRepository`, `TextSnippetRepository`

#### Feedback View

**Responsibility:** User feedback submission and community link.

**Key Types:**
- `FeedbackView` — Card-based scrollable container with category selection, form, and community link
- `FeedbackViewModel` — Form state, submission lifecycle, screenshot attachment
- `FeedbackService` — POSTs feedback JSON to `macparakeet.com/api/feedback` (Cloudflare Worker → GitHub Issues)

**Dependencies:** `FeedbackService`

---

### 2. MacParakeetCore (Library — No UI Dependencies)

The shared core. All business logic, all data access, all service orchestration. Imported by the GUI app (and optionally by a future CLI).

#### 2.1 DictationService

**Responsibility:** Orchestrates the full dictation lifecycle: hotkey detection, audio capture, STT, text processing, and clipboard paste.

**Key Types/Protocols:**
```swift
protocol DictationServiceProtocol: Sendable {
    var state: DictationState { get async }     // .idle, .recording, .processing, .success, .error
    var audioLevel: Float { get async }         // 0.0–1.0, published for overlay waveform
    func startRecording() async throws
    func stopRecording() async throws -> Dictation
    func cancelRecording() async
}

enum DictationState: Sendable {
    case idle
    case recording
    case processing
    case success(Dictation)
    case cancelled
    case error(String)
}
```

**Dependencies:** `AudioProcessor`, shared `STTManaging` scheduler/runtime path, `DictationRepository`, `ClipboardService`

**Data Flow:**
```
Hotkey pressed
    │
    ▼
DictationService.startRecording()
    │ ── AVAudioEngine installs tap on input node
    │ ── Audio buffer accumulates in memory
    │ ── Publishes audioLevel for overlay
    │
Hotkey released (or toggle stop)
    │
    ▼
DictationService.stopRecording()
    │ ── Writes buffer to temp WAV (16kHz mono)
    │ ── Submits a `dictation` job to the shared STT scheduler
    │ ── Receives raw transcript
    │ ── Runs TextProcessingPipeline (if mode == .clean)
    │ ── Saves to DictationRepository
    │ ── Pastes via NSPasteboard + CGEvent (Cmd+V)
    │
    ▼
DictationResult returned
```

#### 2.2 TranscriptionService

**Responsibility:** Orchestrates file and URL transcription: download/convert audio, run STT, apply optional deterministic cleanup, persist results, emit UI progress phases, and retranscribe saved library items.

**Key Types/Protocols:**
```swift
protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> Transcription
}
```

**Dependencies:** `AudioProcessor`, shared `STTManaging` scheduler/runtime path, `TranscriptionRepository`, `YouTubeDownloader`, storage prefs (`saveTranscriptionAudio`)

**Data Flow:**
```
File transcription:
File URL
    │
    ▼
AudioProcessor.convert(fileURL:) → 16kHz mono WAV in temp dir
    │
    ▼
STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → raw transcript + word timestamps
    │
    ▼
TranscriptionRepository.save() → persisted to database
    │
    ▼
Transcription returned to UI

Saved meeting retranscription from the library:
Saved meeting audio file
    │
    ▼
AudioProcessor.convert(fileURL:) → 16kHz mono WAV in temp dir
    │
    ▼
STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → queued background-slot work
    │
    ▼
Updated Transcription persisted with sourceType still = .meeting

YouTube URL transcription:
YouTube URL
    │
    ▼
YouTubeDownloader.download(url:, onProgress:) → emits download %
    │
    ▼
AudioProcessor.convert(fileURL:) → 16kHz mono WAV in temp dir
    │
    ▼
STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → emits chunk %
    │
    ▼
TranscriptionRepository.save() with sourceURL (+ filePath when retention enabled)
    │
    ▼
Transcription returned to UI
```

#### 2.3 TextProcessingPipeline

**Responsibility:** Deterministic, rule-based text cleanup. Runs after STT, before display. Fast, predictable, repeatable.

**Key Types/Protocols:**
```swift
protocol TextProcessingPipelineProtocol {
    func process(_ text: String) -> String
}

// Pipeline stages (executed in order):
// 1. Filler removal (verbal fillers: um, uh, you know, etc.)
// 2. Custom word replacements (vocabulary anchors + corrections)
// 3. Snippet expansion (trigger → expansion)
// 4. Whitespace cleanup (collapse spaces, fix punctuation, capitalize)
```

**Dependencies:** `CustomWordRepository`, `TextSnippetRepository`

**Design Notes:**
- All stages are pure functions over strings — trivially testable
- Custom words loaded once and cached; refreshed on repository change
- Pipeline is synchronous — no async overhead for a few hundred microseconds of work

#### 2.4 AudioProcessor

**Responsibility:** Audio format conversion and resampling. Converts any supported input format to 16kHz mono WAV for Parakeet. Also handles microphone audio buffer management for dictation.

**Key Types/Protocols:**
```swift
protocol AudioProcessorProtocol: Sendable {
    func convert(fileURL: URL) async throws -> URL   // → 16kHz mono WAV
    func startCapture() async throws                  // mic recording
    func stopCapture() async throws -> URL            // → saved WAV
    var audioLevel: Float { get async }               // current amplitude (0.0–1.0)
    var isRecording: Bool { get async }               // capture state
}
```

**Dependencies:** AVFoundation (mic capture), FFmpeg (file conversion — via bundled binary)

**Design Notes:**
- FFmpeg invoked as a subprocess (`Process`), not linked as a library
- Temp files written to app-scoped temp directory, cleaned after use
- Microphone capture uses `AVAudioEngine` with a tap on the input node
- Audio buffer stored in memory during recording, flushed to disk on stop
- Supports: MP3, WAV, M4A, FLAC, OGG, OPUS, MP4, MOV, MKV, WebM, AVI

#### 2.5 STT Runtime + Scheduler

**Responsibility:** The shared STT stack owns one process-wide Parakeet runtime actor plus one explicit scheduler. `STTRuntime` owns FluidAudio model lifecycle and the slot-scoped `AsrManager` set used by the interactive and background execution slots. `STTScheduler` owns admission, slot assignment, in-slot priority, backpressure, cancellation, and request-scoped progress. `STTClient` remains as a compatibility facade, not as an app-owned second runtime.

**Key Types/Protocols:**
```swift
public enum STTJobKind: Sendable, Equatable {
    case dictation
    case meetingFinalize
    case meetingLiveChunk
    case fileTranscription
}

public enum STTWarmUpState: Sendable, Equatable {
    case idle
    case working(message: String, progress: Double?)
    case ready
    case failed(message: String)
}

public protocol STTTranscribing: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
}

public protocol STTRuntimeManaging: Sendable {
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func clearModelCache() async
    func isReady() async -> Bool
    func shutdown() async
}

public typealias STTManaging = STTTranscribing & STTRuntimeManaging
public typealias STTClientProtocol = STTManaging

struct STTResult: Sendable {
    let text: String
    let words: [TimestampedWord]
}

struct TimestampedWord: Sendable {
    let word: String
    let startMs: Int          // milliseconds
    let endMs: Int            // milliseconds
    let confidence: Double
}
```

**Dependencies:** FluidAudio SDK (CoreML, runs on ANE)

**Architecture:**
```
CPU:  MacParakeet app (UI, hotkeys, clipboard, history)
ANE:  Parakeet STT (via FluidAudio/CoreML) — dedicated ML accelerator
```

**API:**
```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(samples, source: .system)
// result.text, result.tokenTimings (word-level timestamps + confidence)
```

**Ownership Model:**
```
Feature services (Dictation / Meeting / File / URL)
    │
    ▼
STTScheduler
    ├── interactive slot → dictation
    └── background slot  → meetingFinalize > meetingLiveChunk > fileTranscription
    │
    ▼
STTRuntime
    ├── interactive slot → AsrManager
    └── background slot  → AsrManager
```

**Model Lifecycle:**
```
App Launch
    │
    ▼
STTRuntime.warmUp() called (lazy, on first use or from onboarding)
    │
    ├── Check: Are CoreML models downloaded?
    │     │
    │     ├── Yes → initialize slot managers → Runtime ready (~162ms warm load)
    │     │
    │     └── No ──► AsrModels.downloadAndLoad() (~6 GB download)
    │                  CoreML compilation (~3.4s first time)
    │                  initialize slot managers
    │
    ▼
Slot managers ready — scheduler admits transcription jobs
```

#### 2.6 ExportService

**Responsibility:** Convert transcription results into various output formats.

**Key Types/Protocols:**
```swift
protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func formatForClipboard(transcription: Transcription) -> String
}

// v0.1: .txt only. SRT/VTT/JSON added in v0.3.
```

**Dependencies:** Foundation (file I/O), `NSPasteboard` (clipboard)

**Data Flow:**
```
Transcription (from DB or in-memory)
    │
    ▼
ExportService.exportToTxt(transcription:, url: outputURL)
    │ ── Formats header (filename, duration)
    │ ── Appends transcript text
    │ ── Writes to file
    │
    ▼
File saved at outputURL
```

#### 2.7 Models

All models conform to GRDB's `Codable` + `FetchableRecord` + `PersistableRecord` protocols.

```swift
struct Dictation: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var durationMs: Int
    var rawTranscript: String
    var cleanTranscript: String?
    var audioPath: String?
    var pastedToApp: String?        // bundle ID of target app
    var processingMode: ProcessingMode  // .raw, .clean
    var status: DictationStatus     // .recording, .processing, .completed, .error
    var errorMessage: String?
    var updatedAt: Date
}

struct Transcription: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var fileName: String
    var filePath: String?
    var fileSizeBytes: Int?
    var durationMs: Int?
    var rawTranscript: String?
    var cleanTranscript: String?
    var wordTimestamps: [WordTimestamp]?  // JSON-encoded in DB
    var language: String?
    var speakerCount: Int?
    var speakers: [String]?
    var status: TranscriptionStatus  // .processing, .completed, .error, .cancelled
    var errorMessage: String?
    var exportPath: String?
    var sourceURL: String?           // YouTube/web URL (v0.3)
    var updatedAt: Date
}

// CustomWord and TextSnippet models are v0.2+
struct CustomWord: Codable, Identifiable {
    let id: UUID
    var word: String                // what to match (case-insensitive)
    var replacement: String?        // what to replace with (nil = vocabulary anchor)
    var source: Source              // .manual, .learned
    var isEnabled: Bool
    let createdAt: Date
    var updatedAt: Date
}

struct TextSnippet: Codable, Identifiable {
    let id: UUID
    var trigger: String             // e.g., "my address" (natural phrase, not abbreviation)
    var expansion: String           // e.g., "123 Main St, Springfield, IL"
    var isEnabled: Bool
    var useCount: Int
    let createdAt: Date
    var updatedAt: Date
}
```

#### 2.8 Repositories

One repository per table. All use GRDB and follow the same pattern.

```swift
// Canonical pattern (DictationRepository shown):
protocol DictationRepositoryProtocol: Sendable {
    func save(_ dictation: Dictation) throws
    func fetch(id: UUID) throws -> Dictation?
    func fetchAll(limit: Int?) throws -> [Dictation]
    func search(query: String, limit: Int?) throws -> [Dictation]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func stats() throws -> DictationStats
}

protocol TranscriptionRepositoryProtocol: Sendable {
    func save(_ transcription: Transcription) throws
    func fetch(id: UUID) throws -> Transcription?
    func fetchAll(limit: Int?) throws -> [Transcription]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws
}

// CustomWordRepository and TextSnippetRepository follow the same pattern (v0.2+)
```

**Dependencies:** GRDB (`DatabaseQueue`)

**Design Notes:**
- All repositories take a `DatabaseQueue` via init (dependency injection)
- Tests use in-memory SQLite: `DatabaseQueue()` with no path
- Repositories are `final class` (synchronous GRDB calls, thread safety via DatabaseQueue)
- Migrations run inline on app startup (no migration files)

---

### 3. Parakeet STT (In-Process via FluidAudio)

Native Swift, runs in the app process via FluidAudio CoreML on the Neural Engine (ANE).

**Responsibility:** Speech-to-text transcription using Parakeet TDT 0.6B-v3.

**Key Details:**

| Property | Value |
|----------|-------|
| Model | Parakeet TDT 0.6B-v3 |
| WER | ~2.5% |
| Speed | ~155x realtime on Apple Silicon |
| Working RAM | ~66 MB (~130 MB with vocab boosting) |
| Runs on | Neural Engine (ANE) via CoreML |
| Input | 16kHz mono Float32 samples |
| Output | Text + word-level timestamps + confidence |
| Model download | ~6 GB CoreML bundle (one-time) |

**Why In-Process (Not Daemon)?**
- FluidAudio provides native Swift async/await API — no IPC overhead
- CoreML models run on the ANE, leaving GPU free for the rest of macOS
- Simpler lifecycle: download models once, initialize, call transcribe()
- No Python, no subprocess, no JSON-RPC — pure Swift

```
~/Library/Application Support/MacParakeet/
    └── models/
        └── stt/                # CoreML model cache (~6 GB)
```

---

## Data Flow Diagrams

### 1. Dictation Flow: Hotkey -> Record -> STT -> Pipeline -> Paste

```
┌─────────┐      ┌─────────────────┐      ┌────────────────┐
│  User    │      │  DictationService│      │  AudioProcessor │
│ (Hotkey) │      │                  │      │                 │
└────┬─────┘      └────────┬────────┘      └────────┬────────┘
     │                     │                        │
     │  Press hotkey       │                        │
     │ ──────────────────> │                        │
     │                     │  startCapture()        │
     │                     │ ─────────────────────> │
     │                     │                        │ ── AVAudioEngine
     │                     │                        │    tap on input
     │                     │    audioLevel updates  │
     │                     │ <───────────────────── │
     │   overlay updates   │                        │
     │ <────────────────── │                        │
     │                     │                        │
     │  Release hotkey     │                        │
     │ ──────────────────> │                        │
     │                     │  stopCapture() → WAV   │
     │                     │ ─────────────────────> │
     │                     │                        │
     │                     │      ┌──────────────┐   │
     │                     │ ───> │STTScheduler  │   │
     │                     │      └──────┬───────┘   │
     │                     │             │           │
     │                     │             │  transcribe(wav, .dictation)
     │                     │             │ ────────────────────┐
     │                     │           │                     │
     │                     │             │    ┌──────────────▼──────┐
     │                     │             │    │ STTRuntime +        │
     │                     │             │    │ Parakeet (ANE)      │
     │                     │             │    └─────────────────────┘
     │                     │           │                     │
     │                     │             │  raw transcript     │
     │                     │             │ <───────────────────┘
     │                     │             │
     │                     │  raw text │
     │                     │ <──────── │
     │                     │
     │                     │      ┌──────────────────────┐
     │                     │ ───> │TextProcessingPipeline│
     │                     │      └──────────┬───────────┘
     │                     │                 │
     │                     │  clean text     │
     │                     │ <───────────────┘
     │                     │
     │                     │  Save to DictationRepository
     │                     │  Copy to NSPasteboard
     │                     │  Simulate Cmd+V via CGEvent
     │                     │
     │   text pasted       │
     │ <────────────────── │
     │                     │
```

### 2. File Transcription Flow: File -> AudioProcessor -> STT -> Display

```
┌──────────────┐    ┌──────────────────────┐    ┌────────────────┐
│  MainWindow  │    │ TranscriptionService │    │ AudioProcessor │
│  (Drop Zone) │    │                      │    │                │
└──────┬───────┘    └──────────┬───────────┘    └───────┬────────┘
       │                       │                        │
       │  File dropped         │                        │
       │ ────────────────────> │                        │
       │                       │  convert(fileURL:)      │
       │                       │ ─────────────────────> │
       │                       │                        │ ── FFmpeg subprocess
       │                       │  16kHz mono WAV        │    input → WAV
       │                       │ <───────────────────── │
       │                       │
       │                       │     ┌──────────────┐
       │                       │ ──> │STTScheduler  │ ──> STTRuntime + Parakeet (ANE)
       │                       │     └─────┬────────┘
       │                       │           │
       │                       │  STTResult (text + timestamps)
       │                       │ <──────── │
       │                       │
       │                       │  Save to TranscriptionRepository
       │                       │
       │  TranscriptionResult  │
       │ <──────────────────── │
       │                       │
       │  Display transcript   │
       │  in TranscriptView    │
       │                       │
```

### 3. Export Flow: Transcription -> Format -> File

```
┌──────────────┐    ┌───────────────┐    ┌───────────────┐
│  MainWindow  │    │ ExportService │    │  File System  │
└──────┬───────┘    └───────┬───────┘    └───────┬───────┘
       │                    │                    │
       │ User clicks Export │                    │
       │ Selects format     │                    │
       │ (e.g., .srt)      │                    │
       │                    │                    │
       │ export(transcription, .srt, outputURL)  │
       │ ─────────────────> │                    │
       │                    │                    │
       │                    │  Read word timestamps
       │                    │  from transcription
       │                    │                    │
       │                    │  Format as SRT:    │
       │                    │  ┌───────────────┐ │
       │                    │  │ 1             │ │
       │                    │  │ 00:00:00,000  │ │
       │                    │  │ --> 00:00:00, │ │
       │                    │  │ 500           │ │
       │                    │  │ Hello world   │ │
       │                    │  └───────────────┘ │
       │                    │                    │
       │                    │  Write to file     │
       │                    │ ─────────────────> │
       │                    │                    │
       │  Success           │                    │
       │ <───────────────── │                    │
       │                    │                    │
```

---

## Database Architecture

Single SQLite file via GRDB. All data in one place. No external database processes.

**Location:** `~/Library/Application Support/MacParakeet/macparakeet.db`

### Schema

```sql
-- Dictation history (voice-to-text sessions)
-- Note: GRDB Codable uses camelCase column names by default
CREATE TABLE dictations (
    id              TEXT PRIMARY KEY,       -- UUID
    createdAt       TEXT NOT NULL,          -- ISO 8601
    durationMs      INTEGER NOT NULL,       -- recording duration in milliseconds
    rawTranscript   TEXT NOT NULL,          -- exact STT output
    cleanTranscript TEXT,                   -- after TextProcessingPipeline (v0.2+)
    audioPath       TEXT,                   -- relative path to saved audio (nullable)
    pastedToApp     TEXT,                   -- bundle ID of target app
    processingMode  TEXT NOT NULL DEFAULT 'raw', -- 'raw' (v0.1) or 'clean' (v0.2 default via UserDefaults)
    status          TEXT NOT NULL DEFAULT 'completed', -- 'recording' | 'processing' | 'completed' | 'error'
    errorMessage    TEXT,                   -- non-null if status == 'error'
    updatedAt       TEXT NOT NULL
);
CREATE INDEX idx_dictations_created_at ON dictations(createdAt);

-- FTS5 external content table for full-text search
CREATE VIRTUAL TABLE dictations_fts USING fts5(
    rawTranscript, cleanTranscript,
    content='dictations', content_rowid='rowid'
);
-- + sync triggers (INSERT, DELETE, UPDATE)

-- File transcription history
CREATE TABLE transcriptions (
    id              TEXT PRIMARY KEY,       -- UUID
    createdAt       TEXT NOT NULL,          -- ISO 8601
    fileName        TEXT NOT NULL,          -- original file name
    filePath        TEXT,                   -- original file path
    fileSizeBytes   INTEGER,               -- original file size
    durationMs      INTEGER,               -- audio duration in milliseconds
    rawTranscript   TEXT,                   -- exact STT output
    cleanTranscript TEXT,                   -- after TextProcessingPipeline (v0.2+)
    wordTimestamps  TEXT,                   -- JSON: [{"word":...,"startMs":...,"endMs":...,"confidence":...}]
    language        TEXT DEFAULT 'en',      -- detected language
    speakerCount    INTEGER,               -- number of speakers (v0.4+)
    speakers        TEXT,                   -- JSON: ["Speaker 1", ...] (v0.4+)
    status          TEXT NOT NULL DEFAULT 'processing', -- 'processing' | 'completed' | 'error' | 'cancelled'
    errorMessage    TEXT,                   -- non-null if status == 'error'
    exportPath      TEXT,                   -- path to exported file
    sourceURL       TEXT,                   -- YouTube/web URL (v0.3)
    updatedAt       TEXT NOT NULL
);
CREATE INDEX idx_transcriptions_created_at ON transcriptions(createdAt);

-- Custom word corrections (v0.2+ — table not yet created)
-- CREATE TABLE custom_words ( ... )

-- Text snippet expansion (v0.2+ — table not yet created)
-- CREATE TABLE text_snippets ( ... )
```

### Migrations

Migrations run inline on app startup (not separate files). Pattern:

```swift
var migrator = DatabaseMigrator()

migrator.registerMigration("v0.1-dictations") { db in
    try db.create(table: "dictations") { t in
        t.column("id", .text).primaryKey()
        t.column("createdAt", .text).notNull()
        t.column("durationMs", .integer).notNull()
        t.column("rawTranscript", .text).notNull()
        t.column("cleanTranscript", .text)
        t.column("audioPath", .text)
        t.column("pastedToApp", .text)
        t.column("processingMode", .text).notNull().defaults(to: "raw")
        t.column("status", .text).notNull().defaults(to: "completed")
        t.column("errorMessage", .text)
        t.column("updatedAt", .text).notNull()
    }
    // + FTS5 table + sync triggers
}

migrator.registerMigration("v0.1-transcriptions") { db in
    try db.create(table: "transcriptions") { ... }
}

try migrator.migrate(dbQueue)
```

### Entity-Relationship Diagram

```
┌─────────────────┐
│   dictations    │     (standalone — no foreign keys)
├─────────────────┤
│ id              │
│ createdAt       │
│ durationMs      │
│ rawTranscript   │
│ cleanTranscript │
│ audioPath       │
│ pastedToApp     │
│ processingMode  │
│ status          │
│ errorMessage    │
│ updatedAt       │
└─────────────────┘

┌─────────────────┐
│ transcriptions  │     (standalone — no foreign keys)
├─────────────────┤
│ id              │
│ createdAt       │
│ fileName        │
│ filePath        │
│ fileSizeBytes   │
│ durationMs      │
│ rawTranscript   │
│ cleanTranscript │
│ wordTimestamps  │
│ language        │
│ speakerCount    │
│ speakers        │
│ status          │
│ errorMessage    │
│ exportPath      │
│ sourceURL       │
│ updatedAt       │
└─────────────────┘

┌─────────────────┐
│  custom_words   │     (standalone — user vocabulary)
├─────────────────┤
│ id              │
│ word            │──── unique index
│ replacement     │
│ source          │
│ isEnabled       │
│ createdAt       │
│ updatedAt       │
└─────────────────┘

┌─────────────────┐
│ text_snippets   │     (standalone — user shortcuts)
├─────────────────┤
│ id              │
│ trigger         │──── unique index
│ expansion       │
│ isEnabled       │
│ useCount        │
│ createdAt       │
│ updatedAt       │
└─────────────────┘
```

All four tables are independent. No foreign key relationships. This keeps the schema simple and each repository self-contained.

---

## File Locations

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Database | `~/Library/Application Support/MacParakeet/macparakeet.db` |
| Dictation audio | `~/Library/Application Support/MacParakeet/dictations/` |
| Transcription exports | `~/Library/Application Support/MacParakeet/transcriptions/` |
| STT models | `~/Library/Application Support/MacParakeet/models/stt/` (CoreML, ~6 GB) |
| yt-dlp binary | `~/Library/Application Support/MacParakeet/bin/yt-dlp` |
| FFmpeg binary | `~/Library/Application Support/MacParakeet/bin/ffmpeg` |
| Logs | `~/Library/Logs/MacParakeet/` |
| Temp audio | `$TMPDIR/macparakeet/` (cleaned after use) |
| Settings | `UserDefaults` (standard `com.macparakeet.MacParakeet.plist`) |

### Directory Layout

```
~/Library/Application Support/MacParakeet/
    ├── macparakeet.db              # SQLite database (all app data)
    ├── dictations/                 # Saved dictation audio files
    │   ├── {uuid}.wav              # Flat storage, no date subdirectories
    │   └── ...
    ├── models/                     # Downloaded ML models
    │   └── stt/                    # CoreML Parakeet models (~6 GB)
    └── bin/                        # Standalone binaries
        ├── yt-dlp                  # YouTube downloader (~35 MB, self-updating)
        └── ffmpeg                  # Video demuxing (~80 MB)
```

---

## Dependencies

### Swift Packages

| Package | SPM ID | Purpose | Notes |
|---------|--------|---------|-------|
| FluidAudio | `FluidAudio` | STT engine (Parakeet TDT via CoreML/ANE) | Apache 2.0. Use `FluidAudio` product only — NOT `FluidAudioEspeak` (GPL-3.0, would require open-sourcing). |
| GRDB.swift | `GRDB` | SQLite database | v6.29.0+, single-file storage, migrations, Codable records |
| swift-argument-parser | `ArgumentParser` | CLI (implemented) | `macparakeet-cli transcribe`, `history`, `health`, `models`, `flow` |

### Bundled / Downloaded Binaries

| Tool | Purpose | Notes |
|------|---------|-------|
| yt-dlp | YouTube audio download | Standalone macOS binary (~35 MB), self-updates via `--update` |
| FFmpeg | Video file demuxing | Extracts audio from video containers (mp4/mov/mkv/webm/avi) |

### System Frameworks

| Framework | Purpose |
|-----------|---------|
| AVFoundation / AVAudioEngine | Microphone capture |
| CoreGraphics (CGEvent) | Global hotkey detection, simulated keystrokes (Cmd+V) |
| AppKit (NSPasteboard) | Clipboard read/write for paste |
| Accessibility (AXUIElement) | Global hotkey, paste simulation |
| SwiftUI | All UI |
| UniformTypeIdentifiers | File type detection for drag-and-drop |

---

## Security & Privacy

### Permissions Required

| Permission | Reason | When Requested | Required? |
|------------|--------|----------------|-----------|
| Microphone | Dictation recording | First dictation attempt | Yes (for dictation) |
| Accessibility | Global hotkey + simulated paste + read selection | First dictation attempt | Yes (for dictation) |

### Permission Flow

```
First Launch
    │
    ▼
Show onboarding: explain what permissions are needed and why
    │
    ▼
User triggers first dictation
    │
    ├── Microphone permission dialog (system)
    │     ├── Granted → continue
    │     └── Denied → show "enable in System Settings" guidance
    │
    ├── Accessibility permission dialog (system)
    │     ├── Granted → continue
    │     └── Denied → show guidance (hotkey + paste won't work)
    │
    ▼
Dictation ready
```

### Privacy Guarantees

1. **No cloud STT** — Speech recognition stays local. Network is used only for explicit surfaces such as model downloads, update checks, optional LLM providers, optional telemetry/crash reporting, licensing, and user-initiated YouTube downloads.
2. **Temp files cleaned** — Audio files in `$TMPDIR` deleted immediately after transcription
3. **No accounts** — No login, no email, no user tracking
4. **Telemetry is opt-out** — Self-hosted usage analytics and crash reporting run only while telemetry is enabled
5. **Audio storage is opt-in** — Dictation audio only saved if user enables "Keep audio" in settings
6. **Local AI only** — All ML inference happens on-device: STT on the ANE via CoreML

### Runtime Permissions

| Permission | Required For | User Flow |
|------------|--------------|-----------|
| Microphone | Dictation, onboarding mic test, meeting recording mic capture | Requested on first dictation/meeting use |
| Accessibility | Global hotkey paste simulation | Requested on first dictation use |
| Screen & System Audio Recording | Core Audio Taps system-audio capture for meeting recording | Requested on first meeting recording attempt; recording stays blocked until granted |

### Sandboxing (App Store)

For App Store distribution, the app needs:

| Entitlement | Required For |
|-------------|-------------|
| `com.apple.security.device.audio-input` | Microphone access |
| `com.apple.security.temporary-exception.apple-events` | Accessibility (paste simulation) |
| `com.apple.security.files.user-selected.read-write` | File drag-and-drop |
| `com.apple.security.files.downloads.read-write` | Export to Downloads |
| Hardened Runtime | Code signing requirement |

**Sandboxing Challenges:**
- Accessibility API (`AXUIElement`) requires the app to be in the Accessibility allow-list, which is a system-level permission, not an entitlement
- FFmpeg and yt-dlp subprocesses need careful path handling within the sandbox container
- CoreML runs in-process — no subprocess restrictions apply to STT
- Direct distribution (notarized DMG) avoids most sandbox restrictions

---

## Performance

### Memory Budget

```
┌────────────────────────────────────────────────────────────┐
│                    Memory at Peak                           │
├────────────────────────────────────────────────────────────┤
│  Parakeet STT (CoreML/ANE)       ~66 MB working RAM        │
│  App process (UI + services)     ~100 MB                   │
│  Audio buffers                   ~50 MB                    │
│  ──────────────────────────────────────                    │
│  Total peak                      ~300 MB                   │
│                                                            │
│  Minimum system RAM: 8 GB (Apple Silicon)                  │
└────────────────────────────────────────────────────────────┘
```

### Startup Performance

| Phase | Target | Strategy |
|-------|--------|----------|
| App window visible | <1 second | SwiftUI, no heavy init |
| Dictation ready | <2 seconds | Post-onboarding (models pre-warmed) |
| First STT result | <3 seconds | CoreML model warm-up on first transcribe call |

**Model Readiness Strategy:**
```
First Launch ────────> Onboarding model setup step
                           └── Download + warm Parakeet STT
                           ▼
                       Ready state unlocked
                           │
Subsequent Launches ──> Window shown (fast)
                           │
                           ▼
                       Dictation runs immediately
```

After initial warm-up, subsequent dictations are near-instant because the shared runtime keeps its slot managers initialized and ready between requests.

### Transcription Speed

| Audio Length | Transcription Time (M1) | Transcription Time (M1 Pro+) |
|-------------|------------------------|-------------------------------|
| 1 minute | ~0.4 seconds | ~0.2 seconds |
| 10 minutes | ~4 seconds | ~2 seconds |
| 1 hour | ~23 seconds | ~12 seconds |
| 4 hours (max) | ~93 seconds | ~46 seconds |

Parakeet TDT 0.6B-v3 throughput varies by device class: approximately 155x realtime on baseline M1 and up to ~300x on M1 Pro+ hardware via FluidAudio CoreML/ANE.

### Memory Management

- **Parakeet model:** One shared runtime keeps its slot managers initialized after first use. Uses ~66 MB working RAM per active inference slot on the ANE path and is released when the app quits.
- **Audio buffers:** Ring buffer during recording, flushed to temp file on stop. No recording duration limit — local processing means no artificial caps.
- **Database:** GRDB uses WAL mode by default. No connection pooling needed (single-user app).

### Background Model Pre-warming

After the user's first dictation session, pre-warm models in the background:

```
First dictation completes
    │
    ▼
Schedule background task (low priority):
    └── If Parakeet model not loaded → initialize the shared runtime's slot managers
```

This ensures subsequent interactions feel instant without bloating initial startup.

---

## Testing Strategy

### Philosophy

"Write tests. Not too many. Mostly integration."

MacParakeet has a small surface area compared to Oatmeal. Focus testing on the core pipeline, not on UI chrome.

### Test Categories

| Category | What | How | Example |
|----------|------|-----|---------|
| Unit | Pure logic, models, pipeline stages | XCTest, fast, no I/O | `TextProcessingPipelineTests` |
| Database | CRUD, queries, migrations | In-memory SQLite via GRDB | `DictationRepositoryTests` |
| Integration | Service boundaries, multi-step flows | Protocol mocks, DI | `TranscriptionServiceTests` |
| Manual | Audio capture, paste, hotkeys | Real hardware | Checklist-based |

### What We Test

- **TextProcessingPipeline** — Every stage, edge cases, custom word matching, snippet expansion
- **Models** — Codable round-trip, validation, edge cases
- **Repositories** — CRUD operations, search queries, migration correctness
- **ExportService** — Format generation (TXT in v0.1; SRT, VTT, JSON in v0.3)
- **STT scheduler/runtime boundary** — mock the `STTClientProtocol` interface (`STTManaging`) rather than real FluidAudio
- **AudioProcessor** — Format detection, conversion parameter correctness (mock FFmpeg)

### What We Skip

- **SwiftUI views** — Test ViewModels, not views
- **AVAudioEngine** — Requires real hardware microphone
- **CGEvent / Accessibility** — Requires system permissions, not testable in CI
- **Parakeet model accuracy** — That is the model's problem, not ours

### Test Infrastructure

```swift
// In-memory database for tests (canonical pattern):
func makeTestDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    // Register all migrations
    registerMigrations(&migrator)
    try migrator.migrate(dbQueue)
    return dbQueue
}

// Protocol-based mocking:
actor MockSTTClient: STTClientProtocol {
    var transcribeResult: STTResult?
    var transcribeError: Error?
    var ready = true

    func configure(result: STTResult) { transcribeResult = result; transcribeError = nil }
    func configure(error: Error) { transcribeError = error; transcribeResult = nil }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        if let error = transcribeError { throw error }
        guard let result = transcribeResult else { throw STTError.modelNotLoaded }
        return result
    }
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}
    func backgroundWarmUp() async {}
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        (UUID(), AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        })
    }
    func removeWarmUpObserver(id: UUID) async {}
    func clearModelCache() async {}
    func isReady() async -> Bool { ready }
    func shutdown() async {}
}
```

### Running Tests

```bash
# All tests (unit + database + integration)
swift test

# Parallel execution
swift test --parallel

# Filter to specific test class
swift test --filter TextProcessingPipelineTests
```

Note: `swift test` works for all tests. Use `xcodebuild` for building the GUI app.

---

## Build & Run

### Commands

```bash
# Build GUI app
xcodebuild build \
    -scheme MacParakeet \
    -destination 'platform=OS X' \
    -derivedDataPath .build/xcode

# Run GUI app
.build/xcode/Build/Products/Debug/MacParakeet.app/Contents/MacOS/MacParakeet

# Run tests (swift test works fine for tests)
swift test

# Open in Xcode
open Package.swift
```

---

## Architecture Principles

1. **MacParakeetCore has zero UI dependencies.** Import Foundation, never SwiftUI. This enables future CLI and keeps business logic testable.

2. **Protocol-first services.** Every service has a protocol. Tests inject mocks. No singletons.

3. **Local-only for user data.** No cloud inference and no API-key dependency. Network is only for model artifacts, optional license activation/validation, and user-initiated media downloads.

4. **Fast launch + onboarding pre-warm.** App launch stays lightweight; first-run onboarding prepares STT model so core features feel ready immediately afterward.

5. **Single database file.** All persistent state in one SQLite file. Easy to backup, easy to debug, easy to reset.

6. **Deterministic pipeline.** `TextProcessingPipeline` is rule-based and repeatable. Users choose raw or clean mode.

7. **Crash gracefully.** If CoreML fails, retry. If paste fails, copy to clipboard and notify. Never lose the transcript.

---

*Last updated: 2026-02-23*
