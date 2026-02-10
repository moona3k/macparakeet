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
│  │  ┌─────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐  │  │
│  │  │ DictationService│  │ TranscriptionService │  │ CommandModeService  │  │  │
│  │  └────────┬────────┘  └──────────┬───────────┘  └──────────┬──────────┘  │  │
│  │           │                      │                         │              │  │
│  │  ┌────────▼────────────────────────────────────────────────▼───────────┐  │  │
│  │  │                        AudioProcessor                               │  │  │
│  │  │            (Format conversion, resampling, buffering)               │  │  │
│  │  └────────────────────────────┬────────────────────────────────────────┘  │  │
│  │                               │                                           │  │
│  │  ┌──────────────┐  ┌─────────▼─────────┐  ┌────────────────────────────┐ │  │
│  │  │  AIService   │  │    STTClient      │  │  TextProcessingPipeline   │ │  │
│  │  │  (MLX-Swift) │  │  (JSON-RPC IPC)   │  │  (Deterministic cleanup)  │ │  │
│  │  └──────┬───────┘  └─────────┬─────────┘  └────────────────────────────┘ │  │
│  │         │                    │                                             │  │
│  │  ┌──────▼───────┐  ┌────────▼──────────────────────────────────────────┐ │  │
│  │  │ExportService │  │               Data Layer                          │ │  │
│  │  │(TXT)         │  │  Models: Dictation, Transcription,               │ │  │
│  │  └──────────────┘  │          CustomWord, TextSnippet                  │ │  │
│  │                     │  Repos:  DictationRepository,                     │ │  │
│  │                     │          TranscriptionRepository,                 │ │  │
│  │                     │          CustomWordRepository,                    │ │  │
│  │                     │          TextSnippetRepository                    │ │  │
│  │                     │  DB:     GRDB (SQLite, single file)              │ │  │
│  │                     └──────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          EXTERNAL PROCESSES                                      │
│                                                                                  │
│  ┌──────────────────────────────┐   ┌──────────────────────────────────────────┐ │
│  │   Parakeet STT Daemon        │   │   MLX-Swift LLM (In-Process)             │ │
│  │   (Python, JSON-RPC over     │   │   Qwen3-4B (4-bit quantized)             │ │
│  │    stdin/stdout)              │   │   ~2.5 GB RAM                            │ │
│  │   parakeet-mlx ~1.5 GB       │   │   Command mode + AI refinement           │ │
│  └──────────────────────────────┘   └──────────────────────────────────────────┘ │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          SYSTEM INTEGRATIONS                                     │
│                                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌──────────────┐               │
│  │AVAudio   │  │ CGEvent  │  │NSPasteboard │  │Accessibility │               │
│  │Engine    │  │(Global   │  │(Clipboard   │  │(Permission   │               │
│  │(Mic)     │  │ Hotkey)  │  │ Paste)      │  │ Control)     │               │
│  └──────────┘  └──────────┘  └─────────────┘  └──────────────┘               │
│                                                                                  │
│  Total AI Memory: ~4 GB peak (Parakeet ~1.5 GB + LLM ~2.5 GB)                  │
│  Recommended: 16 GB RAM (Apple Silicon only)                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**All AI runs on-device.** No network, no API keys, no cloud costs. Privacy is the brand.

---

## Components Detail

### 1. MacParakeet App (GUI — SwiftUI)

The UI layer. Thin shell over MacParakeetCore. No business logic lives here.

#### Main Window

**Responsibility:** Primary interface for file transcription. Accepts drag-and-drop, displays transcripts, provides export controls.

**Key Types:**
- `MainWindowView` — Drop zone + transcript display + recent files list
- `TranscriptView` — Scrollable text with optional word-level timestamps
- `ProgressView` — Transcription progress indicator with cancel

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

**Responsibility:** User preferences. Dictation hotkey, processing mode, custom words, text snippets, general preferences.

**Key Types:**
- `SettingsView` — TabView container
- `GeneralSettingsView` — Launch at login, menu bar mode, default language
- `DictationSettingsView` — Hotkey config, stop mode, processing mode
- `CustomWordsManageView` — CRUD for vocabulary corrections
- `TextSnippetsManageView` — CRUD for trigger/expansion pairs

**Dependencies:** `UserDefaults`, `CustomWordRepository`, `TextSnippetRepository`

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

**Dependencies:** `AudioProcessor`, `STTClient`, `DictationRepository`, `ClipboardService`

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
    │ ── Sends to STTClient
    │ ── Receives raw transcript
    │ ── Runs TextProcessingPipeline (if mode == .clean)
    │ ── Saves to DictationRepository
    │ ── Pastes via NSPasteboard + CGEvent (Cmd+V)
    │
    ▼
DictationResult returned
```

#### 2.2 TranscriptionService

**Responsibility:** Orchestrates file-based transcription: audio preprocessing, STT, optional AI refinement, progress reporting.

**Key Types/Protocols:**
```swift
protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> Transcription
}
```

**Dependencies:** `AudioProcessor`, `STTClient`, `TranscriptionRepository`

**Data Flow:**
```
File URL
    │
    ▼
AudioProcessor.convert(fileURL:) → 16kHz mono WAV in temp dir
    │
    ▼
STTClient.transcribe(audioPath:) → raw transcript + word timestamps
    │
    ▼
TranscriptionRepository.save() → persisted to database
    │
    ▼
Transcription returned to UI
```

#### 2.3 TextProcessingPipeline

**Responsibility:** Deterministic, rule-based text cleanup. Runs after STT, before display. No LLM involved — fast, predictable, repeatable.

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
- Separate from `AIService` refinement: pipeline is deterministic rules, AI is probabilistic

#### 2.4 CommandModeService

**Responsibility:** Select-and-replace workflow. User selects text, triggers hotkey, speaks a command (e.g., "make this more formal"), and the LLM transforms the selected text.

**Key Types/Protocols:**
```swift
protocol CommandModeServiceProtocol {
    func execute(selectedText: String, command: String) async throws -> String
}
```

**Dependencies:** `AIService`, Accessibility API (to read selection), `NSPasteboard` (to replace)

**Data Flow:**
```
User selects text in any app
    │
    ▼
Command hotkey pressed → DictationService records command
    │
    ▼
Accessibility reads selected text (AXUIElement)
    │
    ▼
CommandModeService.execute(selectedText:, command:)
    │ ── Constructs prompt: "Given this text: {selection}\nDo: {command}"
    │ ── Sends to AIService (non-thinking mode)
    │ ── Receives transformed text
    │
    ▼
Replace selection via NSPasteboard + CGEvent (Cmd+V)
```

#### 2.5 AudioProcessor

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

#### 2.6 STTClient

**Responsibility:** JSON-RPC client that communicates with the Parakeet Python daemon. Manages daemon lifecycle (start, health check, restart).

**Key Types/Protocols:**
```swift
protocol STTClientProtocol: Sendable {
    func transcribe(audioPath: String) async throws -> STTResult
    func isReady() async -> Bool
    func warmUp() async throws
    func shutdown() async
}

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

**Dependencies:** Foundation (`Process`, `Pipe` for stdin/stdout IPC)

**Protocol (JSON-RPC 2.0 over stdin/stdout):**
```
┌─────────────────┐    stdin (JSON-RPC request)     ┌─────────────────┐
│                  │ ──────────────────────────────> │                  │
│    STTClient     │                                 │  Parakeet Daemon │
│    (Swift)       │ <────────────────────────────── │  (Python)        │
│                  │    stdout (JSON-RPC response)   │                  │
└─────────────────┘                                  └─────────────────┘
```

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/tmp/macparakeet/recording.wav",
    "language": "en"
  },
  "id": 1
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "text": "Hello world",
    "words": [
      {"word": "Hello", "start_ms": 0, "end_ms": 500, "confidence": 0.98},
      {"word": "world", "start_ms": 600, "end_ms": 1000, "confidence": 0.97}
    ]
  },
  "id": 1
}
```

**Daemon Lifecycle:**
```
App Launch
    │
    ▼
STTClient.warmUp() called (lazy, on first use)
    │
    ├── Check: Is daemon process alive?
    │     │
    │     ├── Yes → Send "ping" health check → Ready
    │     │
    │     └── No ──► Check: Does Python venv exist?
    │                  │
    │                  ├── No ──► Run bundled `uv` to create venv
    │                  │          Install parakeet-mlx + dependencies
    │                  │
    │                  └── Yes ─► Start daemon: `python -m macparakeet_stt`
    │                              Wait for "ready" message on stdout
    │
    ▼
Daemon ready — STTClient accepts transcribe() calls
```

#### 2.7 AIService

**Responsibility:** Local LLM inference via MLX-Swift. Handles text refinement, command mode transformations, and summarization.

**Key Types/Protocols:**
```swift
protocol AIServiceProtocol {
    func refine(text: String, level: RefinementLevel) async throws -> String
    func transform(text: String, command: String) async throws -> String
    func summarize(text: String) async throws -> String
    func isModelLoaded() -> Bool
    func loadModel() async throws
    func unloadModel()
}

enum RefinementLevel {
    case none       // passthrough
    case clean      // remove fillers, fix punctuation
    case formal     // professional tone, grammar fixes
}
```

**Dependencies:** MLX-Swift framework

**Model Details:**

| Property | Value |
|----------|-------|
| Model | Qwen3-4B |
| HuggingFace ID | `mlx-community/Qwen3-4B-4bit` |
| Quantization | 4-bit |
| RAM | ~2.5 GB |
| Framework | MLX-Swift (Apple Silicon Metal) |

**Dual-Mode Operation (same model, different settings):**

| Mode | Use Case | Settings |
|------|----------|----------|
| Non-thinking | Refinement, cleanup, short commands | `temp=0.7, topP=0.8` |
| Thinking | Complex transforms, summarization | `temp=0.6, topP=0.95` |

**Memory Management:**
- Model loaded on-demand (first AI request)
- Unloaded after configurable idle timeout (default: 5 minutes)
- Loading takes ~2-3 seconds on M1; subsequent calls are instant
- Never loaded concurrently with Parakeet warm-up (stagger to avoid memory spike)

#### 2.8 ExportService

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

#### 2.9 Models

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
    var trigger: String             // e.g., "addr"
    var expansion: String           // e.g., "123 Main St, Springfield, IL"
    var isEnabled: Bool
    var useCount: Int
    let createdAt: Date
    var updatedAt: Date
}
```

#### 2.10 Repositories

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

### 3. Parakeet STT Daemon (Python)

External Python process managed by `STTClient`.

**Responsibility:** Speech-to-text transcription using Parakeet TDT 0.6B-v3.

**Key Details:**

| Property | Value |
|----------|-------|
| Model | Parakeet TDT 0.6B-v3 |
| WER | ~6.3% |
| Speed | ~300x realtime on M1+ |
| RAM | ~1.5 GB |
| Input | 16kHz mono WAV |
| Output | Text + word-level timestamps + confidence |
| IPC | JSON-RPC 2.0 over stdin/stdout |

**Bootstrap:** Bundled `uv` binary creates an isolated Python environment on first run. No system Python dependency.

```
~/Library/Application Support/MacParakeet/python/
    └── .venv/              # Isolated Python environment (created by uv)

# Daemon source lives in the app repo at python/macparakeet_stt/
# Bundled with the app, run via: python -m macparakeet_stt
```

**Methods:**

| Method | Description |
|--------|-------------|
| `transcribe` | Transcribe audio file → text + timestamps |
| `ping` | Health check (returns `"pong"`) |

---

### 4. MLX-Swift LLM (In-Process)

Runs in the Swift process via MLX-Swift framework. Not a separate daemon.

**Responsibility:** AI text refinement and command mode transformations.

**Why In-Process (Not Daemon)?**
- MLX-Swift provides native Swift API — no IPC overhead
- Metal shader compilation needs to happen in the app process
- Simpler lifecycle: load model into memory, call, unload
- Unlike Parakeet (Python), the LLM is pure Swift/Metal

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
     │                     │      ┌─────────┐       │
     │                     │ ───> │STTClient│       │
     │                     │      └────┬────┘       │
     │                     │           │            │
     │                     │           │  transcribe(wav)
     │                     │           │ ────────────────────┐
     │                     │           │                     │
     │                     │           │    ┌────────────────▼───┐
     │                     │           │    │  Parakeet Daemon   │
     │                     │           │    └────────────────┬───┘
     │                     │           │                     │
     │                     │           │  raw transcript     │
     │                     │           │ <───────────────────┘
     │                     │           │
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
       │                       │     ┌──────────┐
       │                       │ ──> │STTClient │ ──> Parakeet Daemon
       │                       │     └─────┬────┘
       │                       │           │
       │                       │  STTResult (text + timestamps)
       │                       │ <──────── │
       │                       │
       │                       │     ┌──────────┐
       │                       │ ──> │AIService │  (optional: refine)
       │                       │     └─────┬────┘
       │                       │           │
       │                       │  refined text
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

### 3. Command Mode Flow: Select Text -> Hotkey -> Record -> LLM -> Replace

```
┌──────┐   ┌──────────────────┐   ┌────────────────┐   ┌───────────┐
│ User │   │CommandModeService│   │DictationService│   │ AIService │
└──┬───┘   └────────┬─────────┘   └───────┬────────┘   └─────┬─────┘
   │                │                      │                  │
   │ Select text    │                      │                  │
   │ in any app     │                      │                  │
   │                │                      │                  │
   │ Command hotkey │                      │                  │
   │ ─────────────> │                      │                  │
   │                │  Record voice command│                  │
   │                │ ──────────────────── │                  │
   │                │                      │                  │
   │  (user speaks: │                      │                  │
   │  "make formal")│                      │                  │
   │                │                      │                  │
   │                │  command transcript  │                  │
   │                │ <─────────────────── │                  │
   │                │                      │                  │
   │                │  Read selected text via Accessibility   │
   │                │  (AXUIElement focused element → value)  │
   │                │                                         │
   │                │  transform(selectedText, command)       │
   │                │ ──────────────────────────────────────> │
   │                │                                         │
   │                │         ┌──────────────────────────┐    │
   │                │         │ Prompt:                  │    │
   │                │         │ "Given text: {selection} │    │
   │                │         │  Command: make formal    │    │
   │                │         │  Return transformed text"│    │
   │                │         └──────────────────────────┘    │
   │                │                                         │
   │                │  transformed text                       │
   │                │ <────────────────────────────────────── │
   │                │                                         │
   │                │  Replace via NSPasteboard + Cmd+V       │
   │                │                                         │
   │ Text replaced  │                                         │
   │ <───────────── │                                         │
   │                │                                         │
```

### 4. Export Flow: Transcription -> Format -> File

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
    processingMode  TEXT NOT NULL DEFAULT 'raw', -- 'raw' | 'clean'
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
| Python venv | `~/Library/Application Support/MacParakeet/python/` |
| ML models | `~/Library/Application Support/MacParakeet/models/` |
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
    ├── python/                     # Parakeet STT daemon
    │   └── .venv/                  # Isolated Python env (created by uv)
    └── models/                     # Downloaded ML models (v0.2+)
        └── Qwen3-4B-4bit/          # LLM model files
```

---

## Dependencies

### Swift Packages

| Package | SPM ID | Purpose | Notes |
|---------|--------|---------|-------|
| mlx-swift-lm | `MLXLLM`, `MLXLMCommon` | LLM inference (Qwen3-4B) | v2.29.0+, Apple Silicon Metal acceleration |
| GRDB.swift | `GRDB` | SQLite database | v6.29.0+, single-file storage, migrations, Codable records |
| swift-argument-parser | `ArgumentParser` | CLI (implemented) | `macparakeet transcribe`, `history`, `health` |

### Python (Daemon)

| Package | Purpose | Notes |
|---------|---------|-------|
| parakeet-mlx | STT engine (Parakeet TDT 0.6B-v3) | MLX-accelerated inference |
| mlx | ML framework | Apple Silicon backend |

### Bundled Binaries

| Tool | Purpose | Notes |
|------|---------|-------|
| uv | Python environment management | Creates isolated venv, no system Python needed |
| FFmpeg | Audio format conversion | Any format to 16kHz mono WAV for Parakeet |

### System Frameworks

| Framework | Purpose |
|-----------|---------|
| AVFoundation / AVAudioEngine | Microphone capture |
| CoreGraphics (CGEvent) | Global hotkey detection, simulated keystrokes (Cmd+V) |
| AppKit (NSPasteboard) | Clipboard read/write for paste |
| Accessibility (AXUIElement) | Read selected text for command mode |
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

1. **No network by default** — App works fully offline. No API calls, no telemetry, no analytics
2. **Temp files cleaned** — Audio files in `$TMPDIR` deleted immediately after transcription
3. **No accounts** — No login, no email, no user tracking
4. **No analytics** — Zero telemetry. Not even crash reporting (unless user opts in)
5. **Audio storage is opt-in** — Dictation audio only saved if user enables "Keep audio" in settings
6. **Local AI only** — All ML inference happens on-device via Metal GPU

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
- Spawning Python subprocess (`Process`) works in sandbox but with restricted file access
- FFmpeg subprocess similarly needs careful path handling within the sandbox container
- Direct distribution (notarized DMG) avoids most sandbox restrictions

---

## Performance

### Memory Budget

```
┌────────────────────────────────────────────────────────────┐
│                    Memory at Peak                           │
├────────────────────────────────────────────────────────────┤
│  Parakeet model (loaded)         ~1.5 GB                   │
│  Qwen3-4B LLM (loaded)          ~2.5 GB                   │
│  App process (UI + services)     ~100 MB                   │
│  Audio buffers                   ~50 MB                    │
│  ──────────────────────────────────────                    │
│  Total peak                      ~4.2 GB                   │
│                                                            │
│  Recommended system RAM: 16 GB (Apple Silicon)             │
│  Minimum: 8 GB (LLM features disabled)                     │
└────────────────────────────────────────────────────────────┘
```

### Startup Performance

| Phase | Target | Strategy |
|-------|--------|----------|
| App window visible | <1 second | SwiftUI, no heavy init |
| Dictation ready | <2 seconds | Daemon started lazily, not at launch |
| First STT result | <3 seconds | Model warm-up on first transcribe call |
| LLM ready | <3 seconds | Loaded on-demand, not at launch |

**Lazy Loading Strategy:**
```
App Launch ──────────> Window shown (fast, no ML loaded)
                           │
                           │ User triggers dictation
                           ▼
                       Start Parakeet daemon (background)
                           │ ~2s
                           ▼
                       Daemon ready → recording starts
                           │
                           │ User stops recording
                           ▼
                       Transcribe (Parakeet: 300x realtime)
                           │
                           │ If AI refinement needed:
                           ▼
                       Load Qwen3-4B (background, ~2-3s)
                           │
                           ▼
                       Refine text (~1-2s)
                           │
                           ▼
                       Paste result
```

After initial warm-up, subsequent dictations are near-instant (daemon stays alive, model stays loaded with idle timeout).

### Transcription Speed

| Audio Length | Transcription Time (M1) | Transcription Time (M1 Pro+) |
|-------------|------------------------|-------------------------------|
| 1 minute | ~0.2 seconds | ~0.1 seconds |
| 10 minutes | ~2 seconds | ~1 second |
| 1 hour | ~12 seconds | ~6 seconds |
| 4 hours (max) | ~48 seconds | ~24 seconds |

Parakeet TDT 0.6B-v3 achieves approximately 300x realtime on Apple Silicon.

### Memory Management

- **Parakeet daemon:** Stays alive after first use. Terminated after app idle for 10 minutes (configurable). Restarted on next request.
- **LLM model:** Loaded into Metal GPU memory on first AI request. Unloaded after 5 minutes idle. Loading is async and does not block UI.
- **Audio buffers:** Ring buffer during recording, flushed to temp file on stop. No recording duration limit — local processing means no artificial caps.
- **Database:** GRDB uses WAL mode by default. No connection pooling needed (single-user app).

### Background Model Pre-warming

After the user's first dictation session, pre-warm models in the background:

```
First dictation completes
    │
    ▼
Schedule background task (low priority):
    ├── If Parakeet daemon not running → start it
    └── If LLM not loaded AND user uses AI refinement → load model
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
- **STTClient** — JSON-RPC serialization/deserialization (mock the daemon)
- **AudioProcessor** — Format detection, conversion parameter correctness (mock FFmpeg)

### What We Skip

- **SwiftUI views** — Test ViewModels, not views
- **AVAudioEngine** — Requires real hardware microphone
- **CGEvent / Accessibility** — Requires system permissions, not testable in CI
- **Parakeet model accuracy** — That is the model's problem, not ours
- **MLX-Swift internals** — Trust the framework

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

    func transcribe(audioPath: String) async throws -> STTResult {
        if let error = transcribeError { throw error }
        guard let result = transcribeResult else { throw STTError.daemonNotRunning }
        return result
    }
    func warmUp() async throws {}
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

Note: `swift test` works for tests (no Metal shaders needed). Use `xcodebuild` only for building the GUI app.

---

## Build & Run

### Why xcodebuild?

MLX-Swift requires Metal shaders. `swift build` compiles Swift code but **cannot compile Metal shaders** — the app builds but crashes at runtime with "Failed to load the default metallib." Use `xcodebuild` for app builds.

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

3. **Local-only by default.** No network calls. No API keys. No cloud fallback. Privacy is the product.

4. **Lazy everything.** Python daemon, LLM model, and audio engine are all started on-demand. Cold launch is <1 second.

5. **Single database file.** All persistent state in one SQLite file. Easy to backup, easy to debug, easy to reset.

6. **Deterministic pipeline, probabilistic AI.** `TextProcessingPipeline` is rule-based and repeatable. `AIService` is LLM-based and optional. Users can choose either or both.

7. **Crash gracefully.** If Parakeet daemon dies, restart it. If LLM fails to load, skip refinement. If paste fails, copy to clipboard and notify. Never lose the transcript.

---

*Last updated: 2026-02-08*
