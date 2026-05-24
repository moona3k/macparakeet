# 09 - Testing

> Status: **ACTIVE** - Authoritative, current

## Philosophy

> "Write tests. Not too many. Mostly integration."

Tests exist to catch regressions and validate behavior at service boundaries. We don't chase coverage numbers. Every test must be deterministic, fast, and produce clear error messages.

## Test Categories

### Unit Tests

**What:** Pure logic, models, data transformations.

**How:** XCTest, no external dependencies, no database, no network.

**Examples:**
- Transcript word merging logic
- Text processing pipeline stages (capitalization, punctuation, custom words)
- Dictation stop-decision logic (`proceed` / `defer` / `reject`)
- Model encoding/decoding
- Time formatting utilities

### Database Tests

**What:** CRUD operations, queries, migrations, schema integrity.

**How:** In-memory SQLite via GRDB. Each test gets a fresh database -- fast and fully isolated.

**Pattern:**
```swift
func testDictationCreation() async throws {
    let dbQueue = try DatabaseQueue()  // In-memory
    let manager = DatabaseManager(dbQueue: dbQueue)
    try await manager.migrate()

    let repo = DictationRepository(dbQueue: dbQueue)
    let dictation = try await repo.save(Dictation.fixture())
    XCTAssertNotNil(dictation.id)
}
```

**Examples:**
- Repository CRUD (create, read, update, delete)
- Search queries (LIKE-based substring search on dictations)
- Migration sequences (v1 -> v2 -> v3 apply cleanly)

### Integration Tests

**What:** Service boundaries, multi-component workflows.

**How:** Protocol-based dependency injection with mock implementations.

**Pattern:**
```swift
protocol TranscriptionService {
    func transcribe(_ audio: AudioBuffer) async throws -> [TranscriptWord]
}

struct MockTranscriptionService: TranscriptionService {
    var result: [TranscriptWord] = []
    func transcribe(_ audio: AudioBuffer) async throws -> [TranscriptWord] {
        return result
    }
}
```

**Examples:**
- Dictation flow (record -> STT -> pipeline -> paste)
- Import pipeline (file read -> convert -> transcribe -> store)
- YouTube URL pipeline (download -> convert -> transcribe -> store)
- Text processing pipeline (raw text -> clean text through all stages)
- Export pipeline (transcription -> format -> file)

### Progress Regression Coverage

The suite includes targeted regressions for progress behavior in URL transcription:

- `STTClientTests`: STT progress updates are parsed and forwarded correctly
- `YouTubeDownloaderTests`: yt-dlp download percent line parsing
- `TranscriptionServiceTests`: download-phase percentages are forwarded to `onProgress`
- `TranscriptionViewModelTests`: phase text percent parsing updates UI progress and resets on non-percent phases

### Meeting Recording Tests

**What:** Meeting recording flow, state machine transitions, chunk ordering, audio pipeline.

**How:** Protocol-based mocks for `MeetingAudioCapturing`, `MeetingMicrophoneCapturing` seams, and `MeetingRecordingServiceProtocol`. In-memory SQLite for persistence. No real audio capture in tests.

**Examples:**
- `MeetingRecordingFlowStateMachineTests`: All state transitions (idle → recording → stopping → transcribing → completed), generation guards, error paths
- `MeetingChunkResultBufferTests`: Chunk ordering, out-of-order completion, finalization guards
- `MeetingTranscriptAssemblerTests`: Preview line assembly from chunk results
- `MeetingRecordingPanelViewModelTests`: Live preview updates, elapsed time, audio levels
- `AudioChunkerTests`: Chunk boundary timing, overlap handling, flush on stop
- `MicrophoneCaptureTests`: Lightweight construction/lifecycle seam coverage for the mic capture wrapper
- `MeetingAudioCaptureServiceTests`: Interleaved-buffer deep-copy correctness, VPIO policy success/fallback/required-fail behavior, runtime error emission, and burst buffering retention for high-rate system-capture callbacks
- `MeetingAudioPairJoinerTests`: Pairing behavior, bounded-lag solo fallback, and overflow diagnostics
- `MeetingRecordingServiceTests`: Host-time alignment, live chunk backpressure behavior, dominant-system mic suppression guard behavior, and runtime capture error propagation to stopped capture mode
- `GlobalShortcutManagerTests`: Meeting hotkey registration, conflict detection
- `TranscriptionServiceTests`: Meeting transcription path (sourceType = .meeting)
- `DatabaseManagerTests`: sourceType migration, meeting transcription CRUD

### STT Scheduler Tests (ADR-016)

**What:** Shared runtime ownership, two-slot scheduling policy, request priority, backpressure, and progress isolation across concurrent producers.

**How:** Protocol-based mocks for the STT runtime plus deterministic scheduler tests that assert execution order and dropped work under backlog.

**Examples:**
- Dictation always uses the reserved interactive slot
- Meeting finalization runs ahead of queued live preview and file transcription on the background slot
- File transcription waits behind active meeting work without corrupting progress callbacks
- Meeting live chunks are dropped when queue thresholds are exceeded or when meeting stop promotes finalization
- Already-cancelled jobs never enter the scheduler
- Saved meeting retranscribes prefer the archived dual-source `meetingFinalize` path when metadata is present, and legacy rows without that metadata fall back to the low-priority file-transcription path
- App warm-up, shutdown, and cache-clearing hit one shared runtime only
- Onboarding readiness does not report success until required default-on speaker-detection assets are also ready

### CLI Tests

**What:** Command parsing and prompt construction behavior for CLI surfaces.

**How:** XCTest against the `CLI` module (`CLITests` target), plus manual/automation smoke runs for full binary execution.

**Examples:**
- `llm chat` prompt composition with and without transcript context
- `llm chat` argument parsing (`--transcript-file`, `--system`, `--stats`)
- transcript-file loader behavior (missing file, bounded context assembly)
- `transforms` saved-prompt CRUD/run JSON envelopes and local history commands
- `vocab` process/words/snippets command parsing and JSON output

**Tip:** For runtime smoke runs, use a throwaway database path (e.g. `--database /tmp/macparakeet-cli-test.db`) to avoid polluting the real app database.

### LLM Metadata + Transforms Tests

**What:** Local-only LLM run metadata, Transform dispatch/history, and prompt-category separation.

**How:** In-memory SQLite plus protocol mocks for LLM calls, selection capture/replacement, and hotkey dispatch. No real provider calls.

**Examples:**
- `LLMRunRepositoryTests`: schema constraints, source-link requirement, indexes, save/fetch/delete behavior
- `LLMServiceTests`: `formatTranscriptDetailed` returns provider/model/token/latency metadata without leaking prompt/output into `llm_runs`
- `DictationServiceTests` / `TranscriptionServiceTests`: persisted formatter rows record metadata only, while private/no-history/transient flows skip the ledger
- `TransformsHotkeyRegistryTests`: shortcut parsing, duplicate/collision guards, reserved hotkey conflicts
- `TransformExecutorTests`: AX/clipboard capture paths, replacement fallback, cancellation/error cleanup
- `TransformHistoryRepositoryTests`: local input/output/source-app/timing history persistence and deletion

## What We Skip

| Skip | Reason | Alternative |
|------|--------|-------------|
| SwiftUI view tests | Brittle, slow, low value | Test ViewModels and state logic |
| Audio capture tests | Hardware-dependent | Test processing logic with fixture data |
| Third-party internals | Trust GRDB, FluidAudio, ArgumentParser | Test our integration layer |
| Visual snapshot tests | Maintenance burden exceeds value | Manual QA for UI changes |
| Flaky tests | Any test that fails intermittently | Fix or delete -- no `@retry` hacks |

## Running Tests

```bash
# Full suite (deterministic; usually ~1-2 minutes depending on cache state)
swift test

# Parallel run when chasing wall-clock time
swift test --parallel

# Single test file
swift test --filter TextProcessingPipelineTests

# Speech-engine focused tests
swift test --filter STTClientTests
swift test --filter WhisperLanguageCatalogTests
```

**Note:** `swift test` works for all tests because tests don't need Metal shaders. The app itself requires `xcodebuild` (see CLAUDE.md).

## AI Agent Testing Loop

AI agents working on this codebase must follow this loop:

### Before Coding
```bash
swift test  # Establish baseline -- all tests must pass
```

### After Changes
```bash
swift test  # Verify no regressions
```

### Bug Fix Protocol
1. Write a test that reproduces the bug (must fail)
2. Run `swift test` to confirm failure
3. Fix the bug
4. Run `swift test` to confirm all pass
5. Commit test + fix together (never separately)

## Test Quality Rules

### Deterministic
- No `sleep()` or time-dependent assertions
- No dependency on system state (locale, timezone, disk contents)
- No random data without fixed seeds
- Same result on every run, every machine

### Fast
- Individual test: < 1 second
- Full suite: usually ~1-2 minutes on a warm Apple Silicon checkout; investigate large regressions
- Database tests use in-memory SQLite (no disk I/O)
- No network calls (mock everything external)

### Clear Errors
- Test names describe the scenario: `testImportVTTCreatesMemoryWithCorrectTimestamps`
- Assertion messages explain what went wrong
- One logical assertion per test (multiple XCTAssert calls are fine if testing one concept)

## Key Test Patterns

### In-Memory SQLite

Every database test creates its own in-memory database. No shared state, no cleanup needed, sub-millisecond setup.

```swift
let dbQueue = try DatabaseQueue()
let manager = DatabaseManager(dbQueue: dbQueue)
try await manager.migrate()
// Test against a fresh, migrated database
```

### Protocol-Based DI for Mocking

Services depend on protocols, not concrete types. Tests inject mocks.

```swift
// Production
let service = SearchService(db: realDB, embedder: realEmbedder)

// Test
let service = SearchService(db: inMemoryDB, embedder: mockEmbedder)
```

### Pipeline Tests as Pure Functions

Text processing pipeline stages are pure functions: input text in, output text out. No mocks needed.

```swift
func testCapitalizationStage() {
    let stage = CapitalizationStage()
    let result = stage.process("hello world. goodbye world.")
    XCTAssertEqual(result, "Hello world. Goodbye world.")
}
```

### Fixture Data

Audio and transcript fixtures live in `Tests/Fixtures/`:
- Sample transcripts (VTT, SRT, TXT)
- Sample audio files (short WAV clips for STT tests)
- Example LLM outputs (for refinement mode tests)

## Test File Organization

```
Tests/
  MacParakeetTests/      # Core + ViewModel tests
    Models/
    Database/
    Services/
    TextProcessing/
    LLM/
  CLITests/              # CLI parsing/prompt tests
```

## Manual QA Checklist — Dictation Overlay

These flows must be tested manually after any overlay or hotkey changes. Automated unit tests cover the state machine logic, but the full UX requires human verification.

> **Note:** The default dictation preset uses `Fn` for both roles: double-tap `Fn` for hands-free, and hold `Fn` for push-to-talk. `Fn+Space` is a supported custom hands-free chord and should remain recordable. Custom dictation shortcuts may be distinct, or both roles may share the exact same trigger for the shared hold/double-tap gesture. Settings should reject overlapping but non-identical triggers for the two roles. Test with at least two different trigger keys.

### Happy Path

| # | Flow | Steps | Expected |
|---|------|-------|----------|
| 1 | Persistent recording | Double-tap Fn → speak → tap Fn | Pill appears → waveform animates → checkmark → text pasted |
| 2 | Hold-to-talk | Hold Fn (>400ms) → speak → release Fn | Pill appears → waveform → checkmark → text pasted |

### Cancel & Undo Flows

| # | Flow | Steps | Expected |
|---|------|-------|----------|
| 3 | Cancel via Esc | Double-tap Fn → Esc | Pill shows countdown ring (5s) → auto-dismiss |
| 4 | Cancel via X button | Double-tap Fn → click X | Same as Esc cancel — countdown → auto-dismiss |
| 5 | Undo after Esc cancel | Double-tap Fn → Esc → click Undo | Recording restarts, pill shows waveform again |
| 6 | Undo after X cancel | Double-tap Fn → click X → click Undo | Recording restarts, pill shows waveform again |
| 7 | **Hands-free after undo** | Double-tap Fn → cancel → Undo → tap Fn | Recording stops, checkmark, text pasted |
| 8 | **New hands-free recording after undo** | Double-tap Fn → cancel → Undo → tap Fn → double-tap Fn | New recording starts |
| 9 | Hands-free blocked during cancel | Double-tap Fn → Esc → Fn (during countdown) | Nothing happens — shortcut is blocked |
| 10 | Cancel countdown expires | Double-tap Fn → Esc → wait 5s | Pill auto-dismisses, Fn works again |

### Configurable Hotkey

| # | Flow | Steps | Expected |
|---|------|-------|----------|
| 10a | Change hands-free shortcut | Settings → Shortcuts → Hands-free mode → select Control+Space | Menu bar shows "Tap Control+Space" for hands-free |
| 10b | New trigger works | Ctrl+Space → speak → Ctrl+Space | Recording starts/stops with new shortcut |
| 10c | Bare-tap filtering | Hold Ctrl → press C → release Ctrl | Does NOT trigger dictation (keyboard shortcut) |
| 10d | Single-tap modifier filtering | Ctrl → type "hello" → release Ctrl | Does NOT trigger dictation |
| 10e | Record Fn+Space custom chord | Settings → Shortcuts → Hands-free mode → record Fn+Space | Fn+Space works, Ctrl no longer triggers |
| 10f | Dynamic UI text | Change to Option+Space → check overlay/pill/history | All say "Option+Space" instead of "Fn" |
| 10g | Conflicting custom dictation shortcut blocked | Restore default so both roles use Fn, then try an overlapping custom pair such as Control and Control+Space | Default Fn preset is accepted; Settings rejects the custom conflict with a conflict message |

### State Transitions

| # | Flow | Steps | Expected |
|---|------|-------|----------|
| 11 | Recording → Processing | Double-tap Fn → speak → tap Fn | Pill smoothly transitions from waveform to spinner |
| 12 | Processing → Success | (after transcription completes) | Animated checkmark appears, then text pastes |
| 13 | Error display | (trigger STT error) | Error card (rounded rect, icon, title+subtitle, dismiss button) |
| 13a | Delayed first-stop race | Double-tap Fn, then immediately tap Fn while first start is still spinning up | Stop is deferred, then processing/paste completes once recording is active (no silent drop) |

### Hover Tooltips

| # | Flow | Steps | Expected |
|---|------|-------|----------|
| 14 | Hover X button | Move cursor over X during recording | "Cancel **Esc**" appears above pill (Esc in light blue) |
| 15 | Hover stop button | Move cursor over stop circle | "Stop & paste (**trigger key**)" appears (key name in light blue) |
| 16 | Hover middle area | Move cursor over waveform/timer | No tooltip shown |
| 17 | Mouse exits pill | Move cursor away from pill | Tooltip fades out |

### Visual Polish

| # | Check | Expected |
|---|-------|----------|
| 18 | Pill position | Just above the Dock (~12px gap) |
| 19 | No visible outline | No system shadow border around pill |
| 20 | Waveform bars | Visible bars (not dots) even at low audio |
| 21 | Smooth countdown | Ring drains smoothly, not in jumps |
| 22 | Smooth state transitions | Pill size changes animate (no jank) |
| 23 | Checkmark animation | Thin ring draws → thin check strokes in (Apple Pay style) |

## Adding a New Test

1. Identify the category (unit, database, integration, CLI)
2. Find the appropriate test file or create one following naming convention: `{Feature}Tests.swift`
3. Follow existing patterns in the same category
4. Run `swift test` to verify
5. Update test count in CLAUDE.md and README.md if applicable
