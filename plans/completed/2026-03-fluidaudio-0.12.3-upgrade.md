# FluidAudio 0.12.3 Upgrade Plan

> Status: **COMPLETED** — 2026-03-14

## Overview

Upgrade FluidAudio from 0.12.1 to 0.12.3 and adopt three new APIs that solve existing problems in our codebase:

1. **Download progress callbacks** — replace our hacky 350ms filesystem-polling loop with FluidAudio's byte-level `DownloadProgress`
2. **Task cancellation** — let users cancel long file transcriptions mid-flight
3. **`clearAllModelCaches()`** — add a "Delete Models" button to Settings storage management

These are focused changes concentrated in `STTClient.swift` and their consuming ViewModels/Views.

## API Verification (Completed)

All APIs verified against compiled FluidAudio 0.12.3 source (resolved Mar 14, 2026):

| API | Status | Signature |
|-----|--------|-----------|
| Download progress | **Confirmed** | `AsrModels.downloadAndLoad(to:configuration:version:progressHandler:)` where `progressHandler: DownloadUtils.ProgressHandler?` (`@Sendable (DownloadProgress) -> Void`) |
| DownloadProgress type | **Confirmed** | `struct DownloadProgress { fractionCompleted: Double, phase: DownloadPhase }` |
| DownloadPhase enum | **Confirmed** | `.listing`, `.downloading(completedFiles:totalFiles:)`, `.compiling(modelName:)` |
| Task cancellation in ASR | **Confirmed** | `try Task.checkCancellation()` in `ChunkProcessor`, `AsrTranscription`, `TdtDecoderV3` inner loops |
| `clearAllModelCaches()` | **Confirmed** | `DownloadUtils.clearAllModelCaches()` — static, removes `~/Library/Application Support/FluidAudio/Models/` (ASR+VAD+Diarization) and `~/.cache/fluidaudio/Models/` (TTS) |
| Diarization progress | **NOT available** | `OfflineDiarizerManager.prepareModels(directory:configuration:forceRedownload:)` — no progress handler parameter |

Build verified: `swift build --target MacParakeetCore` passes. Tests verified: 786/786 pass on 0.12.3.

## Why Now

- 0.12.2 and 0.12.3 are stable (20+ production apps, 1-2 week release cadence)
- Our SPM constraint `.upToNextMinor(from: "0.12.1")` already resolves to 0.12.3
- The download progress polling hack is the most fragile code in STTClient
- Task cancellation is needed for non-blocking transcription progress UX

## What We're NOT Adopting (and why)

| Feature | Why Skip |
|---------|----------|
| ITN (text normalization) | Requires linking `libnemo_text_processing` Rust binary. UX decision needed (when to normalize). Post-launch. |
| Speaker pre-enrollment | No "teach my voice" feature exists. Post-launch. |
| Model directory override | No user reports of storage location issues. Unnecessary complexity. |
| Qwen3-ASR int8 | We use Parakeet TDT, not Qwen3. |
| Diarization download progress | `OfflineDiarizerManager.prepareModels()` has no progress handler in 0.12.3. Diarization models are ~130 MB (small, fast download). |

## Design Decisions

1. **Keep `STTClientProtocol` signature stable** — The protocol method signatures don't change. Only the concrete `STTClient` implementation changes internally.
2. **Progress callback stays `@Sendable (String) -> Void`** — We could switch to a structured type, but the string callback is simpler and the ViewModels already parse it. The new strings must preserve the existing format (`"... X%"`) so OnboardingViewModel regex parsing and CLI string matching continue to work.
3. **Cancellation via Swift cooperative cancellation** — FluidAudio 0.12.2 added `try Task.checkCancellation()` throughout the ASR pipeline (chunk processor, encoder, decoder loops). If the enclosing Swift Task is cancelled, transcription stops cooperatively. No new cancellation token types needed.
4. **Cache clearing as instance method** — Add `clearModelCache() async` to `STTClientProtocol` as an instance method (not static — static protocol requirements can't be called through existentials). Calls `shutdown()` first, then `DownloadUtils.clearAllModelCaches()`.
5. **`CancellationError` must not be swallowed** — `STTClient.mapTranscriptionError()` currently maps all unknown errors to `.transcriptionFailed(...)`. Must add an early return for `CancellationError` before the mapping logic, so it propagates through the whole stack.

## Implementation Steps

### Step 1: Upgrade dependency & verify build ✅

Already done during verification:
1. ~~Run `swift package update FluidAudio`~~ — resolved to 0.12.3
2. ~~Run `swift build --target MacParakeetCore`~~ — passes
3. ~~Run `swift test`~~ — 786/786 pass
4. Commit: "Upgrade FluidAudio to 0.12.3"

### Step 2: Fix CancellationError swallowing

**Problem:** `STTClient.mapCommonError()` catches any error and maps it to `STTError`. If FluidAudio throws `CancellationError` (which it will, via `Task.checkCancellation()`), the mapper destroys it and downstream code never sees a cancellation.

**Fix in `STTClient.swift`:**
- In `mapCommonError()`: add early return `nil` for `CancellationError` so it propagates as-is
- In `mapTranscriptionError()` and `mapWarmUpError()`: re-throw `CancellationError` directly instead of wrapping

**Fix in `STTClient.transcribe()`:**
- Add `try Task.checkCancellation()` before calling `manager.transcribe()` (catches cancellation before entering FluidAudio)

**Tests:**
- Add test in `STTClientTests` (or equivalent) verifying `CancellationError` is not wrapped

### Step 3: Adopt download progress callbacks

**Problem:** `STTClient.emitModelDownloadProgress()` polls the filesystem every 350ms checking if model files exist. This produces jumpy "45% (3/7)" progress during the 6 GB onboarding download.

**Solution:** Pass `progressHandler` to `AsrModels.downloadAndLoad()`.

**Architecture consideration:** The `ensureInitialized()` deduplication means multiple callers can share one initialization task. Only the first caller's progress callback would be wired. This is acceptable because:
- `warmUp()` is always called first (during onboarding or CLI `models warm-up`)
- `transcribe()` calls `ensureInitialized()` as a fallback, but by then models are usually cached
- If models ARE downloading during a `transcribe()` call, the user sees transcription progress (0%), not download progress — same as today

**Files changed:**

- `Sources/MacParakeetCore/STT/STTClient.swift`:
  - Add `private var warmUpProgressHandler: DownloadUtils.ProgressHandler?` stored property
  - In `warmUp()`: store the progress callback, then call `ensureInitialized()`
  - In `ensureInitialized()`: pass `warmUpProgressHandler` to `AsrModels.downloadAndLoad(version:progressHandler:)`
  - Map `DownloadProgress` phases to human-readable strings matching existing format:
    - `.listing` → "Preparing speech model download..."
    - `.downloading(done, total)` → "Downloading speech model... {percent}% ({done}/{total})"
    - `.compiling(name)` → "Compiling speech model..."
  - Delete `emitModelDownloadProgress()` (the polling method)
  - Delete `modelDownloadProgressMessage()` (the string builder)
  - **Throttle progress callbacks** — FluidAudio fires byte-level progress potentially thousands of times/sec. Throttle to max ~4 updates/sec (250ms interval) to avoid UI churn.
  - Clear `warmUpProgressHandler` after initialization completes

- **No DiarizationService changes** — API doesn't support progress handler. Current "Downloading speaker models..." / "Speaker models ready" messages stay as-is.

**Progress string format compatibility:**
- OnboardingViewModel regex: `/(\d+)%/` — new strings include `{percent}%`, compatible
- CLI `ModelsCommand`: checks for `"Ready"` and `"%"` substrings — new strings compatible
- Emit `"Ready"` at completion (same as today)

### Step 4: Add transcription cancellation (ViewModel + UI)

**Problem:** Once `TranscriptionService.transcribe()` starts, users can't cancel. The service layer already handles `CancellationError` (telemetry, status updates), but no mechanism exists to trigger it from UI.

**Files changed:**

- `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`:
  - Store `transcriptionTask: Task<Void, Never>?` (currently fire-and-forget `Task { ... }`)
  - Add `cancelTranscription()` method that calls `transcriptionTask?.cancel()`
  - In `transcribeFile()`, `transcribeURL()`, `retranscribe()`: assign the Task to `transcriptionTask`
  - Handle cancellation separately from errors: on `CancellationError`, reset to idle state (no error banner)
  - Define task ownership: new transcription cancels any in-flight one (only one active at a time)

- `Sources/MacParakeet/Views/Transcription/TranscribeView.swift` (or bottom bar):
  - Add cancel button (X icon or "Cancel" text) visible during `.processing` state
  - Wire to `viewModel.cancelTranscription()`

- `Sources/MacParakeetCore/Services/TranscriptionService.swift`:
  - Already handles `CancellationError` at lines 193-194, 246 (telemetry + status)
  - **Change needed:** On cancellation, set status to `.cancelled` (not `.error`) or delete the record entirely, so cancelled jobs don't appear as failed in history. Check if `TranscriptionStatus` has a `.cancelled` case; if not, add one.

**Dictation is unaffected:** `DictationService` uses the same `sttClient.transcribe()` but dictation recordings are short (<30s). The `CancellationError` fix in Step 2 ensures dictation still works correctly if a Task is cancelled externally.

### Step 5: Add model cache clearing to Settings

**Problem:** No way for users to reclaim ~6 GB of disk space. The "Repair" button only re-downloads.

**Solution:** Use `DownloadUtils.clearAllModelCaches()`.

**Scope note:** This clears ALL FluidAudio model caches (ASR + diarization + VAD + TTS). Since we use ASR and diarization, the confirmation dialog should mention both.

**Files changed:**

- `Sources/MacParakeetCore/STT/STTClientProtocol.swift`:
  - Add `func clearModelCache() async` to protocol (instance method)

- `Sources/MacParakeetCore/STT/STTClient.swift`:
  - Implement: call `shutdown()` first (release loaded models, cancel init task), then `DownloadUtils.clearAllModelCaches()`
  - Reset `modelsReady` state

- `Sources/MacParakeetViewModels/SettingsViewModel.swift`:
  - Add `clearModelCache()` method
  - Guard against clearing while transcription/dictation is active (check state, warn user)
  - Update model status to `.notDownloaded` after clearing
  - Show confirmation alert before clearing (destructive action)

- `Sources/MacParakeet/Views/Settings/SettingsView.swift`:
  - Add "Delete Models" button (destructive style) in the Speech Model card
  - Confirmation dialog: "This will delete ~6 GB of speech and speaker models. You'll need to re-download them before transcribing."
  - Disable button while transcription/dictation is active

- `Sources/CLI/Commands/ModelsCommand.swift`:
  - Add `models clear` subcommand for CLI parity
  - Calls `sttClient.clearModelCache()`

- `Tests/MacParakeetTests/STT/MockSTTClient.swift`:
  - Add `func clearModelCache() async` no-op stub

### Step 6: Verify & clean up

1. Run `swift test` — all tests pass (existing + new)
2. Build GUI app with `scripts/dev/run_app.sh` — manual verification:
   - File transcription works end-to-end
   - Cancel button appears during transcription and cancels cleanly (no error banner)
   - Settings "Delete Models" button shows confirmation, clears cache, updates status
   - Dictation still works (regression check)
3. If possible, test onboarding progress (requires clearing model cache first):
   - Progress should be smooth byte-level, not jumpy file-count

## Files Changed (Expected)

| File | Change |
|------|--------|
| `Package.resolved` | Updated to FluidAudio 0.12.3 |
| `Sources/MacParakeetCore/STT/STTClient.swift` | Fix CancellationError swallowing, replace polling with DownloadProgress callback (with throttle), add clearModelCache, add cancellation check |
| `Sources/MacParakeetCore/STT/STTClientProtocol.swift` | Add `clearModelCache() async` |
| `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Store Task reference, add cancelTranscription(), handle CancellationError separately |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Add clearModelCache() with confirmation guard |
| `Sources/MacParakeet/Views/Transcription/TranscribeView.swift` | Add cancel button |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Add "Delete Models" button with confirmation |
| `Sources/CLI/Commands/ModelsCommand.swift` | Add `models clear` subcommand |
| `Tests/MacParakeetTests/STT/MockSTTClient.swift` | Add clearModelCache() stub |

## Risks

| Risk | Mitigation |
|------|------------|
| Progress callback too chatty (thousands/sec) | Throttle to max 4 updates/sec (250ms) before forwarding to caller |
| `clearAllModelCaches()` clears diarization models too | Confirmation dialog mentions both speech and speaker models |
| Clearing cache while transcription/dictation active | Guard in SettingsViewModel: disable button during active operations |
| `CancellationError` thrown mid-database-write in TranscriptionService | Service already wraps DB writes in error handler; cancellation between stages is safe |
| Progress string format change breaks CLI | Preserve `"{percent}%"` and `"Ready"` substrings (verified compatible) |

## Out of Scope

- Non-blocking transcription progress bottom bar UX (separate item, builds on this)
- Streaming ASR for real-time dictation (v1.x)
- Custom vocabulary CTC boosting (v1.x)
- ITN text normalization (v1.x)
- Diarization download progress (API not available in 0.12.3)
