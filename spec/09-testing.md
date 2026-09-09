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

### Dictation Flow Timing Tests

`DictationFlowCoordinatorLoadCaptionTests` uses intentionally compressed async
timing windows to keep first-install/model-load caption coverage fast. If one
of those tests fails once in CI, rerun it before calling it a product
regression; if it fails reproducibly or frequently, investigate the coordinator
timing instead of ignoring it.

### Meeting Recording Tests

**What:** Meeting recording flow, state machine transitions, chunk ordering, audio pipeline.

**How:** Protocol-based mocks for `MeetingAudioCapturing`, `MeetingMicrophoneCapturing` seams, and `MeetingRecordingServiceProtocol`. In-memory SQLite for persistence. No real audio capture in tests.

**Examples:**
- `MeetingRecordingFlowStateMachineTests`: All state transitions (idle → recording → stopping → transcribing → completed), generation guards, error paths
- `MeetingChunkResultBufferTests`: Chunk ordering, out-of-order completion, finalization guards
- `MeetingTranscriptAssemblerTests`: Preview line assembly from chunk results
- `MeetingRecordingPanelViewModelTests`: Live preview updates, elapsed time, audio levels
- `AudioChunkerTests`: Chunk boundary timing, overlap handling, flush on stop
- `FixedMeetingLiveAudioChunkerTests` and `SpeechBoundaryMeetingLiveAudioChunkerTests`: Fixed-cadence parity plus VAD speech-boundary chunking, silence drop, force emit, flush, reset, and fixed-fallback behavior
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
- VAD-guided meeting live chunking is covered as a live-preview strategy: deterministic chunker tests cover state transitions, `MeetingRecordingServiceTests` cover the flag gate/fallback decision, and `MeetingVADLaunchPrepTests` cover universal launch-time model prep without network-dependent assertions
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

**Tip:** For runtime smoke runs, use a throwaway database path (e.g. `--database /tmp/macparakeet-cli-test.db`) to avoid polluting the real app database. `scripts/dev/run_app.sh` uses an isolated Dev state root by default; set `MACPARAKEET_DEBUG_APP_STATE_DIR` to an absolute throwaway directory when a unique app-level smoke state is required. The override scopes the database, meeting artifacts, AppPaths-managed helper caches, the FluidAudio speech/speaker model cache, and logs away from real user state — including destructive `models delete`/`models clear` runs.

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
# Full suite: final gate, at most once per task (see AGENTS.md)
swift test

# Single test file
swift test --filter TextProcessingPipelineTests

# Speech-engine focused tests
swift test --filter STTClientTests
swift test --filter WhisperLanguageCatalogTests
```

**Note:** Normal `swift test` does not exercise a real in-process MLX model.
The app requires the Xcode app-build path; optional runtime build gates and
canonical commands are documented in [AGENTS.md](../AGENTS.md).

## Continuous Integration

The [CI workflow](../.github/workflows/ci.yml) validates PRs and the integrated
`main` branch. Its trigger policy avoids running the entire pipeline twice for
the same feature-branch update:

| Event | CI behavior |
|-------|-------------|
| PR opened, updated, or reopened, including fork PRs | Run against the PR merge ref, subject to GitHub approval requirements |
| Push to `main` | Run against the integrated commit |
| Push to another branch | No automatic push run; use the PR or manual dispatch |
| Tag push | Run; tag validation is retained explicitly |
| Manual dispatch | Run against the selected ref |

The existing `docs/**` and `plans/**` exclusions still apply to push and PR
path filtering. GitHub does not apply path filters to tag pushes. PR updates
cancel superseded runs for that PR; the `swift-test` check name and all build,
bundle, concurrency, language-mode, and test gates are retained. See GitHub's
[branch and tag filter semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore).

For a branch that needs hosted validation before a PR exists, select it under
Actions → CI → Run workflow, or use:

```bash
gh workflow run ci.yml --ref <branch>
```

### Timing baseline and optimization priorities

On 2026-09-08, six sampled successful jobs took approximately 40–52 minutes.
For PR #984, the [PR job](https://github.com/moona3k/macparakeet/actions/runs/34195968512)
took 40m 55s, and its redundant
[branch-push job](https://github.com/moona3k/macparakeet/actions/runs/34195965402)
took 46m 53s: nearly 88 runner-minutes combined. The PR job spent 9m 30s on
the release build, 13m on the app bundle, 5m 15s on concurrency compilation,
4m 17s on Swift 6 compilation, and 8m 9s on test compilation and execution.
These are historical measurements, not performance guarantees.

Removing the feature-branch push run saves duplicate runner work; it does not
halve the duration of the remaining job. Measure subsequent runs before
changing the pipeline further. Independent build jobs and compiled-output
reuse are follow-up candidates, but must preserve the Xcode bundle/resource
check and the separate Swift 6 compatibility gate. The current cache stores
dependencies, not compiled outputs. Compare both elapsed time and total
runner-minutes before adding parallel jobs or more caching.

## AI Agent Testing Loop

Follow [AGENTS.md](../AGENTS.md#commands), not a second full-suite loop here:
iterate with focused tests for the changed area, then run the full suite at
most once as the final gate unless the user specifies another scope. A reported
hardware failure is evidence; do not erase it with a passing mock-based suite.

For a bug fix, keep a focused reproduction that fails before the fix and passes
afterward when practical. Verify UI/capture changes on the real surface as
well, and distinguish fixture results, live hardware checks, and checks not run.
Never run destructive CLI smoke commands against the user's database or model
cache. Use the [integration isolation rules](../integrations/README.md#safe-automation-and-isolation);
`--database` alone is not full application-state isolation.

## Test Quality Rules

### Deterministic
- No `sleep()` or time-dependent assertions
- No dependency on system state (locale, timezone, disk contents)
- No random data without fixed seeds
- Same result on every run, every machine

### Fast
- Individual test: < 1 second
- Full-suite cost depends on DSP fixtures and model/cache state; avoid repeating it during iteration
- Repository unit tests use in-memory SQLite; persistence/recovery tests use test-owned temporary folders
- Keep external services mocked or fixture-backed; real model/hardware smoke runs are separate evidence

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
