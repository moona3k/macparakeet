# Tech Debt Audit — Full Codebase Review

> Status: **IMPLEMENTED** (P0s and clear-cut fixes done; remaining items are tech debt, not bugs)
> Date: 2026-04-02
> Method: 20 independent AI review agents (10 Codex, 10 Gemini) across code quality, architecture, Swift best practices, concurrency, security, observability, testing, and documentation. All critical findings verified against source code.

## Executive Summary

The codebase is in **solid shape overall** — clean dependency graph, consistent GRDB patterns, good protocol usage, zero force-unwraps in production paths, and a well-implemented crash reporter.

**Total verified findings: 37** (5 P0, 8 P1, 12 P2, 12 P3)

### Fixes Applied (2026-04-02)

| Commit | Fix | Impact |
|--------|-----|--------|
| `71e1ee9` | P0-5: STTClient `initializationTask` not cleared on cancellation | Prevents stuck engine requiring restart |
| `cb21a5e` | P0-1: `retranscribe()` success path ran even when DB save failed | Prevents silent data loss |
| `9088bd8` | P1-1: `[weak self]` on LLM streaming tasks (chat + summary) | Prevents ViewModel retain during streaming |
| `9088bd8` | P1-2: `[weak self]` on DiscoverViewModel rotation loop | Prevents permanent retain cycle |
| `9088bd8` | P2-2: Pre-compile filler regexes as `static let` | Eliminates 4+ regex compilations per dictation |
| `9088bd8` | P2-10: Cache DateFormatter as `static let` | Eliminates per-call allocation |
| `33ceb4d` | P2-11: Remove duplicate regex/parser from OnboardingViewModel | Eliminates `try!` crash risk + duplication |
| `33ceb4d` | P3-7: Remove dead `runProcess` from BinaryBootstrap | 45 lines of unused code removed |
| `33ceb4d` | Doc drift: Updated test counts in CLAUDE.md, README.md, MEMORY.md | 976 → 1020 tests, 143 → 147 source files |

### Downgraded After Review

| Original | Disposition | Reason |
|----------|-------------|--------|
| P0-2: cancelRecording reentrancy race | Cosmetic, not worth fixing | Near-impossible trigger; result is harmless UI flash; state self-recovers |
| P0-3: Cancel during processing is no-op | By design | Protects user intent; processing is near-instant; undo path exists post-paste |
| P0-4: 500ms success window drops dictation | Not reproducible | Window too short for human reaction; serves real UX purpose (success feedback) |

---

## P0 — Production Bugs (Fix Now)

### P0-1. `retranscribe()` silently loses data on DB save failure
**File:** `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:250-257`
**Confirmed by:** 7/20 agents | **Verified against source:** Yes

**What happens:** When re-transcribing a file, `save(result)` is wrapped in a do/catch, but `completeSuccessfulTranscription(taskID:result:)` at line 257 is called **unconditionally after the catch block**. If the DB write fails, the user sees a successful retranscription in the UI — but nothing was persisted. On next app launch, the transcript vanishes. The original record was already deleted at line 253.

**Code:**
```swift
// TranscriptionViewModel.swift:250-257
do {
    try transcriptionRepo?.save(result)
    _ = try? transcriptionRepo?.delete(id: originalID)
} catch {
    logger.error("Failed to save transcription result error=\(error.localizedDescription, privacy: .public)")
}
completeSuccessfulTranscription(taskID: taskID, result: result)  // ← runs even if save failed
```

**Fix:** Move `completeSuccessfulTranscription` inside the `do` block (after delete). In the `catch`, call `completeFailedTranscription(taskID:error:)` instead. Ideally wrap the delete+save in a single GRDB transaction so they're atomic.

---

### ~~P0-2. `DictationService.cancelRecording()` races with `stopRecording()` via actor reentrancy~~ → Cosmetic, not worth fixing
**File:** `Sources/MacParakeetCore/Services/DictationService.swift:185-206`
**Confirmed by:** 8/20 agents | **Verified against source:** Yes | **Disposition:** Nearly impossible to trigger; cosmetic impact only

Requires simultaneous hotkey release + Escape press within microseconds, plus specific actor scheduling. If triggered: text pastes successfully but overlay briefly shows "cancelled." No data loss, no memory leak, state resets to `.idle` via `cancelResetTask`. The fix (adding `.cancelling` state) would touch the state machine, coordinator, overlay, and tests — high regression risk for a cosmetic edge case. Existing `cancelGeneration` token already partially mitigates.

---

### ~~P0-3. Cancel during `.processing` is a silent no-op~~ → Not a bug (by design)
**File:** `Sources/MacParakeetCore/Services/DictationService.swift:186`
**Confirmed by:** 8/20 agents | **Verified against source:** Yes | **Disposition:** Intentional behavior

Once `stopRecording()` sets `_state = .processing`, `cancelRecording()` is rejected. This is actually **correct behavior**: (1) the user committed by speaking and releasing the hotkey, (2) Parakeet processes at 155x realtime so the window is near-zero, (3) accidental Escape during processing would be worse than preserving the dictation, (4) there's already an undo path after paste via the cancel overlay. No fix needed.

---

### ~~P0-4. 500ms `.success` window silently drops the next dictation start~~ → Not a bug (by design)
**File:** `Sources/MacParakeetCore/Services/DictationService.swift:157-167`
**Confirmed by:** 8/20 agents | **Verified against source:** Yes | **Disposition:** Not reproducible in practice

The 500ms sleep holds `.success` state so the overlay can display a brief success indicator before dismissing. During this window, `startRecording()` silently returns. However, the window is too short to hit in normal use — users naturally take 1+ seconds between dictations to read the pasted text, move cursor, and think. Cannot be reproduced even when intentionally trying. The 500ms serves a real UX purpose (success feedback). No fix needed.

---

### P0-5. `STTClient` stuck after initialization cancellation — requires app restart
**File:** `Sources/MacParakeetCore/STT/STTClient.swift:254-262`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

**What happens:** If `initializationTask` is cancelled mid-flight, `completeInitialization` checks `Task.isCancelled`, cleans up the manager, and returns **without setting `initializationTask = nil`** (line 255-258). The task body completes normally (no throw), so the `catch` block at line 249 (which DOES nil out `initializationTask`) never runs. Subsequent calls to `ensureInitialized()` await the already-completed task, which returns instantly, but `manager` is nil. Every `transcribe` call throws `modelNotLoaded` until app restart.

**Code:**
```swift
// STTClient.swift:254-262
private func completeInitialization(models: AsrModels, manager: AsrManager) {
    guard !Task.isCancelled else {
        manager.cleanup()
        return  // ← initializationTask NOT cleared
    }
    self.models = models
    self.manager = manager
    self.initializationTask = nil  // ← only reached if not cancelled
}
```

**Fix:** Add `self.initializationTask = nil` inside the `guard !Task.isCancelled` early return. This ensures subsequent calls re-attempt initialization.

---

## P1 — Reliability & Resource Issues (Fix Soon)

### P1-1. Retain cycles in LLM streaming Tasks
**Files:** `Sources/MacParakeetViewModels/TranscriptChatViewModel.swift:159`, `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:334`
**Confirmed by:** 5/20 agents | **Verified against source:** Yes

`streamingTask = Task { @MainActor in }` and `summaryTask` strongly capture `self` through property access (`messages`, `isStreaming`, etc.) while `self` holds the Task. If the view is dismissed during LLM streaming, the ViewModel stays alive for the full generation duration (potentially 30+ seconds), consuming CPU and API tokens.

**Fix:** Add `[weak self]` to all long-running Task closures:
```swift
streamingTask = Task { @MainActor [weak self] in
    guard let self else { return }
    ...
}
```

---

### P1-2. `DiscoverViewModel` infinite rotation loop leaks ViewModel
**File:** `Sources/MacParakeetViewModels/DiscoverViewModel.swift:49-55`
**Confirmed by:** 4/20 agents | **Verified against source:** Yes

`startRotation()` creates a `Task` with `while !Task.isCancelled` that captures `self` strongly. There's no `deinit` cancellation. The Task holds `self`, and `self.rotationTask` holds the Task — a retain cycle that prevents deallocation.

**Practical impact:** Currently low, since `DiscoverViewModel` is likely held for the app's lifetime via `AppEnvironment`. But the pattern is fragile and will cause real leaks if the ViewModel lifecycle ever changes.

**Fix:** Add `[weak self]` + `guard let self` inside the loop, or use `.task` modifier in the View.

---

### P1-3. LLM streaming accepts truncated responses as complete
**Files:** `Sources/MacParakeetCore/Services/LLMClient.swift:148,259,408`
**Confirmed by:** 5/20 agents | **Verified against source:** Yes

All three streaming paths (OpenAI line 148, Ollama line 259, Anthropic line 408) call `continuation.finish()` after the `for try await line in bytes.lines` loop exits. A clean TCP close mid-stream (network blip) produces a partial LLM response that is silently accepted.

**Nuance:** The `validateStreamCompletion(sawDone:)` at line 668-671 is intentionally a no-op because "Many OpenAI-compatible providers (Gemini, Ollama) don't send `[DONE]`." This was a deliberate design decision, not an oversight. However, for OpenAI and Anthropic (which DO send terminators), this means truncated streams are indistinguishable from complete ones.

**Fix:** Track `sawDone` for OpenAI and `sawMessageStop` for Anthropic. If the provider is known to send a terminator and it wasn't seen, log a warning. Don't hard-fail since the user already has partial content.

---

### P1-4. `AppDelegate.applicationWillTerminate` blocks main thread with semaphore
**File:** `Sources/MacParakeet/AppDelegate.swift:100-109`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

Uses `DispatchSemaphore.wait(timeout: .now() + 2.0)` to block the main thread while `Task.detached { await sttClient?.shutdown() }` runs. The code correctly uses `Task.detached` (not `Task`) to avoid MainActor inheritance, and has a 2-second timeout.

**Practical impact:** Low — `STTClient` is an actor (not `@MainActor`), so `shutdown()` runs on the actor's executor, not the main thread. The timeout prevents indefinite hangs. But if `shutdown()` ever internally needs MainActor access, this would deadlock.

**Fix:** Use `NSApplication.replyToApplicationShouldTerminate(_:)` for clean async termination, or accept the current pattern with a comment documenting the MainActor constraint.

---

### P1-5. `OnboardingViewModel` swallows `CancellationError` in retry loop
**File:** `Sources/MacParakeetViewModels/OnboardingViewModel.swift` (in `runWithRetry`)
**Confirmed by:** 2/20 agents | **Verified against source:** Partial (identified `try!` regex at line 65)

`runWithRetry` catches ALL errors, including `CancellationError`. When the user leaves onboarding mid-download, the retry loop catches the cancellation and immediately retries instead of propagating it.

**Fix:** Check for `CancellationError` (or `is CancellationError`) before the retry logic and re-throw immediately.

---

### P1-6. Sequential pipe reads in `VideoStreamService` can delay extraction
**File:** `Sources/MacParakeetCore/Services/VideoStreamService.swift:92-101`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

Stdout and stderr are read sequentially. If yt-dlp produces enough stderr output to fill the OS pipe buffer (~64KB) before stdout closes, the process blocks on stderr writes, stdout never closes, and the extraction hangs until the timeout fires.

**Mitigating factor:** The entire operation is inside a `withThrowingTaskGroup` with a timeout task, so it won't hang forever. But it degrades from completing in seconds to waiting for the full timeout duration (30s).

**Fix:** Use `async let` to read both pipes concurrently:
```swift
async let stdoutData = readPipe(stdoutPipe)
async let stderrData = readPipe(stderrPipe)
return (stdout: await stdoutData, stderr: await stderrData)
```

---

### P1-7. HTTP allowed for remote LLM endpoints — API keys sent in plaintext
**Files:** `Sources/MacParakeetViewModels/LLMSettingsDraft.swift:72`, `Sources/MacParakeetCore/Services/LLMClient.swift:433,491`
**Confirmed by:** 1/20 agents (security audit) | **Verified against source:** Not yet

The endpoint validator accepts both `http://` and `https://` for any host. If a user misconfigures a remote endpoint as `http://`, their API key and transcript content are sent in plaintext.

**Fix:** Allow `http://` only when the host resolves to localhost (`localhost`, `127.0.0.1`, `::1`). Reject plaintext for all other hosts.

---

### P1-8. Orphaned files on transcription/dictation deletion
**Files:** `Sources/MacParakeetCore/Database/DictationRepository.swift:62-85`, `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:279`, `Sources/MacParakeetCore/Services/ThumbnailCacheService.swift`
**Confirmed by:** 4/20 agents | **Verified against source:** Partial

Both repositories delete DB records but never clean up corresponding files on disk (audio files, thumbnail cache). `DictationRepository` already uses `FileManager` in `clearMissingAudioPaths` — the infrastructure exists.

**Fix:** In `deleteTranscription()`, also evict the thumbnail cache entry and delete any app-owned audio files. In `DictationRepository.delete()`, delete the corresponding audio file if it exists.

---

## P2 — Performance & Quality (Address This Sprint)

### P2-1. `TranscriptionLibraryViewModel` loads unbounded data into memory
**File:** `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift:64-70`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

`loadTranscriptions()` calls `fetchAll(limit: nil)` — loading every transcription's full row including large `rawTranscript`, `cleanTranscript`, and `wordTimestamps` blobs. Additionally, `recomputeFiltered()` fires on every keystroke via `searchText`'s `didSet` with no debounce, doing `String.contains` across all those blobs.

**Fix:** Add a limit (e.g., 200), implement pagination if needed. Add a 300ms debounce for search (same pattern as `DictationHistoryViewModel`). Consider loading only summary fields for the grid view.

---

### P2-2. Regex recompilation on every dictation in `TextProcessingPipeline`
**File:** `Sources/MacParakeetCore/TextProcessing/TextProcessingPipeline.swift:66-81`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

`removeFillers()` compiles a fresh `NSRegularExpression` per filler word per call. All patterns are constant strings derived from `alwaysSafeFillers`. This means 4+ regex compilations per `process()` call at minimum.

**Fix:** Pre-compile all filler patterns as `static let` constants. Same for whitespace normalization patterns later in the pipeline.

---

### P2-3. Full read-modify-write for single-column DB updates
**File:** `Sources/MacParakeetCore/Database/TranscriptionRepository.swift:64-130`
**Confirmed by:** 3/20 agents | **Verified against source:** Partial

`updateStatus`, `updateSummary`, `updateChatMessages`, `updateSpeakers` each fetch the entire row (including potentially large JSON blobs) to change one field. `updateFavorite` already does it correctly with targeted SQL at line 141.

**Fix:** Use targeted `UPDATE ... SET column = ? WHERE id = ?` for all single-field updates, following the `updateFavorite` pattern.

---

### P2-4. Three near-duplicate LLM streaming implementations
**File:** `Sources/MacParakeetCore/Services/LLMClient.swift` (~700 lines)
**Confirmed by:** 5/20 agents | **Verified against source:** Yes

OpenAI, Anthropic, and Ollama streaming paths are structurally identical (build request → get bytes → check status → process lines → finish). The Anthropic path additionally uses `JSONSerialization` while others use typed `Decodable` structs. Bug fixes in one path (e.g., stream completion validation) are easy to miss in the others.

**Fix:** Extract a shared `streamSSE(request:chunkParser:)` driver with per-provider strategy for request construction, auth headers, and chunk parsing.

---

### P2-5. Swift 6 strict concurrency blockers
**Files:** Various
**Confirmed by:** 3/20 agents | **Verified against source:** Partial

These will become hard compiler errors when migrating to Swift 6 strict concurrency mode:

| Issue | File | Line |
|-------|------|------|
| `RecordingMode` missing `Sendable` | `FnKeyStateMachine.swift` | 23 |
| `ExportService` `@MainActor` isolation mismatch with protocol | `ExportService.swift` | 4, 21 |
| `AsyncStream` build closure accesses actor state | `STTClient.swift` | 67-74 |
| Non-Sendable `Process` in `onCancel` closure | `YouTubeDownloader.swift` | 570-572 |
| Non-Sendable `AVAudioFile` crosses isolation to tap callback | `AudioRecorder.swift` | 209, 282 |

**Fix:** Each has a targeted fix — add `Sendable` conformance, use `AsyncStream.makeStream()`, extract PIDs before `onCancel`, etc.

---

### P2-6. `TranscriptResultView` is a ~900+ line monolith
**File:** `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
**Confirmed by:** 4/20 agents | **Verified against source:** Partial

Contains: adaptive layout logic, video/audio split-pane, result header card, tab bar, transcript pane with synced auto-scroll, summary pane with streaming state, chat pane with conversation switcher, speaker diarization, export actions, clipboard ops, and 16 `@State` vars. Binary search logic (`autoScrollTarget(for:)`) and segment caching live in the view.

**Fix:** Split into `TranscriptPaneView`, `SummaryPaneView`, `ChatPaneView`, `TranscriptHeaderCard`. Move scroll-sync and segment cache logic to `MediaPlayerViewModel` or a dedicated coordinator.

---

### P2-7. Missing logging in critical paths
**Files:** `Sources/MacParakeetCore/Services/YouTubeDownloader.swift`, `Sources/MacParakeetCore/Services/BinaryBootstrap.swift`, `Sources/MacParakeetCore/Services/LLMService.swift`
**Confirmed by:** 1/20 agents (observability audit) | **Verified against source:** Partial

The entire YouTube download pipeline (`YouTubeDownloader`) produces zero log entries. `BinaryBootstrap` (yt-dlp/FFmpeg binary download) is silent on both success and failure. `LLMService` has no Logger — LLM failures only go to telemetry, making them undiagnosable via `log stream`.

**Fix:** Add `Logger` instances to all three services. Log at minimum: process invocation, exit codes, and errors.

---

### P2-8. Telemetry spec gaps
**File:** `Sources/MacParakeetCore/Services/TelemetryService.swift`
**Confirmed by:** 1/20 agents (observability audit) | **Verified against source:** Partial

| Event | Status |
|-------|--------|
| `app_updated` | Defined in spec, never fired — can't track update adoption |
| `model_download_cancelled` | Defined in spec, never fired — onboarding funnel gap |
| `model_loaded` | In enum, never fired — can't benchmark warm-up per chip |
| `permission_denied(.accessibility)` | Only microphone fires — accessibility funnel incomplete |
| `NSWorkspace.willSleep` flush | Spec requires it, not registered — events lost on lid close |

**Fix:** Implement each missing event. Add `willSleepNotification` observer to `registerLifecycleObservers()`.

---

### P2-9. GCD timeout closure retained after process exits in `YouTubeDownloader`
**File:** `Sources/MacParakeetCore/Services/YouTubeDownloader.swift:531-572`
**Confirmed by:** 4/20 agents | **Verified against source:** Yes

`waitForProcess()` schedules a `DispatchQueue.global().asyncAfter(deadline: .now() + timeout)` closure that is never cancelled when the process exits successfully. The atomic `resumed` flag prevents double-resume, but the closure and its captures (`process`, `continuation`) are retained for up to 600s.

**Fix:** Use a structured `Task.sleep` with cancellation, or explicitly cancel the DispatchWorkItem when the process exits.

---

### P2-10. `DateFormatter` created per-call
**File:** `Sources/MacParakeetViewModels/DictationHistoryViewModel.swift:275` (formatDateHeader)
**Confirmed by:** 2/20 agents

`DateFormatter` is expensive to initialize. Created fresh on every call during `loadDictations()`.

**Fix:** `private static let` cached formatter.

---

### P2-11. `OnboardingViewModel` duplicates `OnboardingProgressParser` regex
**File:** `Sources/MacParakeetViewModels/OnboardingViewModel.swift:65`
**Confirmed by:** 2/20 agents | **Verified against source:** Yes

`private static let progressPercentRegex = try! NSRegularExpression(...)` duplicates the exact pattern already centralized in `Sources/MacParakeetCore/STT/OnboardingProgressParser.swift`. Two maintenance sites for the same logic, plus a `try!` crash risk.

**Fix:** Delete the duplicate in `OnboardingViewModel` and use `OnboardingProgressParser` instead.

---

### P2-12. N+1 queries in `TextSnippetRepository.incrementUseCount`
**File:** `Sources/MacParakeetCore/Database/TextSnippetRepository.swift:62-73`
**Confirmed by:** 2/20 agents

One `SELECT` + one `UPDATE` per snippet ID inside a loop. Degrades linearly with snippet count.

**Fix:** Single `UPDATE text_snippets SET useCount = useCount + 1, updatedAt = ? WHERE id IN (?,?,...)`.

---

## P3 — Tech Debt (Backlog)

### Architecture & Design

| # | Finding | File(s) |
|---|---------|---------|
| P3-1 | `DictationFlowCoordinator.executeEffect` is 372-line mega-switch | `DictationFlowCoordinator.swift:157` |
| P3-2 | `SettingsViewModel` ~400-line god object (login, UI, stats, licensing, model repair) | `SettingsViewModel.swift` |
| P3-3 | AppKit panels (`NSSavePanel`, `NSOpenPanel`) inside ViewModels — untestable | `DictationHistoryViewModel.swift:119,127`, `FeedbackViewModel.swift:49` |
| P3-4 | Notification names raw strings across target boundaries | `SettingsViewModel.swift:30,37,55` vs `Notifications.swift:3` |
| P3-5 | `OnboardingViewModel` downcasts `STTClientProtocol` to concrete `STTClient` | `OnboardingViewModel.swift:73,227` |
| P3-6 | Dead code: `updateChatMessages` + `Transcription.chatMessages` from v0.5 migration | `TranscriptionRepository.swift:13,24,114`, `Transcription.swift:19` |
| P3-7 | Dead code: `runProcess` in `BinaryBootstrap` | `BinaryBootstrap.swift` |
| P3-8 | `ClipboardService` imports AppKit in Core — undocumented exception | `ClipboardService.swift:1` |
| P3-9 | Views instantiate services directly, bypassing composition root | `TranscriptResultView.swift:1753`, `TranscriptionThumbnailCard.swift:48` |

### Test Suite

| # | Finding | File(s) |
|---|---------|---------|
| P3-10 | `Task.sleep`-based async synchronization — flakiness risk in all VM tests | `TranscriptionViewModelTests.swift`, `DictationFlowTests.swift`, etc. |
| P3-11 | `@unchecked Sendable` mocks with unprotected mutable state — TSan violations | `ViewModelMocks.swift`, `LLMServiceTests.swift` |
| P3-12 | Global static state in URLProtocol mocks — cross-test contamination | `FeedbackServiceTests.swift`, `BinaryBootstrapTests.swift`, `TelemetryServiceTests.swift` |

### Documentation

| Item | Issue | Correct Value |
|------|-------|---------------|
| `CLAUDE.md` test count | "976 tests (963 XCTest + 13 Swift Testing)" | 1020 tests (1007 + 13) |
| `CLAUDE.md` file counts | "~143 source files, ~70 test files" | 147 source, 72 test |
| `README.md` test badge | Shows 976 | 1020 |
| `MEMORY.md` test count | "976 tests (963 XCTest + 13 Swift Testing)" | 1020 |

---

## What's Working Well

Agents consistently praised these areas — no changes needed:

- **Clean Package.swift dependency graph** — no circular deps, correct layering
- **`DictationFlowStateMachine`** — pure value types, all enums `Sendable`, exemplary Swift 6 pattern
- **GRDB repository patterns** — consistent CRUD, in-memory SQLite for tests
- **Crash reporter** — async-signal-safe, pre-allocated buffers, Mach-O UUID capture
- **Zero `try!`/`fatalError` in production paths** (except one static regex in OnboardingVM)
- **`AppEnvironment`** — clean composition root, all concrete types wired in one place
- **Design system adoption** — consistent tokens across views (only 2 hardcoded colors found)
- **Telemetry implementation** — strong spec match, good batching, privacy-respecting
- **Protocol-based services** — most services have well-defined protocols

---

## Remaining Items (Tech Debt — Not Bugs)

These are improvements, not bugs. Address when relevant or when working in the affected area.

### Performance improvements
- **P2-1** Library loads unbounded data — add limit/pagination if library grows large
- **P2-3** DB read-modify-write for single columns — use targeted SQL like `updateFavorite` pattern
- **P2-12** N+1 queries in `incrementUseCount` — batch into single UPDATE (needs GRDB API work)

### Code cleanliness
- **P2-4** Three duplicate LLM streaming implementations — extract shared driver
- **P2-6** TranscriptResultView 900-line monolith — split into sub-views
- **P3-1** DictationFlowCoordinator 372-line mega-switch
- **P3-2** SettingsViewModel god object
- **P3-4** Notification names as raw strings across targets
- **P3-6** Dead `chatMessages` code from v0.5 migration (touches protocol/model/tests)

### Safety hardening
- **P1-7** HTTP allowed for remote LLM endpoints — restrict to localhost only
- **P2-5** Swift 6 strict concurrency blockers (5 issues) — needed for Swift 6 migration
- **P2-9** GCD timeout closure retained in YouTubeDownloader

### Observability
- **P2-7** Add Logger to YouTubeDownloader, BinaryBootstrap, LLMService
- **P2-8** Fire missing telemetry events (app_updated, model_loaded, etc.)

### Test infrastructure
- **P3-10** Replace `Task.sleep` with proper async expectations
- **P3-11** Convert `@unchecked Sendable` mocks to actors
- **P3-12** Consolidate URLProtocol mocks

---

*Generated by 20-agent parallel review (10 Codex + 10 Gemini), 2026-04-02. All P0 and most P1 findings verified against source code. Bugs fixed in 4 commits; remaining items are tech debt.*
