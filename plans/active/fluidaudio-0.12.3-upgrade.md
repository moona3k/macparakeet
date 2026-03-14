# FluidAudio 0.12.3 Upgrade Plan

> Status: **ACTIVE**

## Overview

Upgrade FluidAudio from 0.12.1 to 0.12.3 and adopt three new APIs that solve existing problems in our codebase:

1. **Download progress callbacks** — replace our hacky 350ms filesystem-polling loop with FluidAudio's byte-level `DownloadProgress`
2. **Task cancellation** — let users cancel long file transcriptions mid-flight
3. **`clearAllModelCaches()`** — add a "Delete Models" button to Settings storage management

These are small, focused changes concentrated in `STTClient.swift`, `DiarizationService.swift`, and their consuming ViewModels/Views.

## Why Now

- 0.12.2 and 0.12.3 are stable (20+ production apps, 1-2 week release cadence)
- Our SPM constraint `.upToNextMinor(from: "0.12.1")` already resolves to 0.12.3
- The download progress polling hack is the most fragile code in STTClient
- Task cancellation is a prerequisite for the remaining v0.4 item (non-blocking transcription progress)

## What We're NOT Adopting (and why)

| Feature | Why Skip |
|---------|----------|
| ITN (text normalization) | Requires linking `libnemo_text_processing` Rust binary. UX decision needed (when to normalize). Post-launch. |
| Speaker pre-enrollment | No "teach my voice" feature exists. Post-launch. |
| Model directory override | No user reports of storage location issues. Unnecessary complexity. |
| Qwen3-ASR int8 | We use Parakeet TDT, not Qwen3. |

## Design Decisions

1. **Keep `STTClientProtocol` signature stable** — The protocol methods don't change. Only the concrete `STTClient` implementation changes internally.
2. **Progress callback stays `@Sendable (String) -> Void`** — We could switch to a structured type, but the string callback is simpler and the ViewModels already parse it. Enrich the strings instead.
3. **Cancellation via Swift cooperative cancellation** — `STTClient.transcribe()` will check `Task.isCancelled` and FluidAudio 0.12.2's internal cancellation support handles the rest. No new cancellation token types.
4. **Cache clearing is a protocol addition** — Add `clearModelCache()` to `STTClientProtocol` so tests can mock it.

## Implementation Steps

### Step 1: Upgrade dependency & verify build

1. Run `swift package resolve` (SPM will pick up 0.12.3 automatically)
2. Run `swift build --target MacParakeetCore` — verify no API breakage
3. Run `swift test` — all 786 tests must pass
4. Commit: "Upgrade FluidAudio to 0.12.3"

### Step 2: Adopt download progress callbacks

**Problem:** `STTClient.emitModelDownloadProgress()` polls the filesystem every 350ms checking if model files exist. This produces jumpy "45% (3/7)" progress during the 6 GB onboarding download.

**Solution:** Use FluidAudio 0.12.3's `DownloadProgress` callback on `AsrModels.downloadAndLoad()`.

**Files changed:**

- `Sources/MacParakeetCore/STT/STTClient.swift`:
  - In `ensureInitialized()`: pass a progress handler to `AsrModels.downloadAndLoad(version:onProgress:)`
  - Store a progress callback reference so `warmUp()` can pipe download progress to the caller
  - Delete `emitModelDownloadProgress()` and `modelDownloadProgressMessage()` (the polling methods)
  - Map `DownloadProgress` phases to human-readable strings:
    - `.listing` → "Preparing speech model download..."
    - `.downloading(done, total)` → "Downloading speech model... {fractionCompleted}%"
    - `.compiling(name)` → "Compiling speech model..."

- `Sources/MacParakeetCore/Services/DiarizationService.swift`:
  - In `prepareModels()`: pass progress handler to `manager.prepareModels(onProgress:)` if the API supports it (check 0.12.3 release notes — `OfflineDiarizerModels` was listed in the updated APIs)
  - Map download phases to "Downloading speaker models... X%"

**No ViewModel/View changes needed** — `OnboardingViewModel` already parses percentage from progress strings via regex. The new strings will have the same format but smoother values.

### Step 3: Add task cancellation to transcription

**Problem:** Once `TranscriptionService.transcribe()` starts, users can't cancel. For a 60-minute podcast, they're stuck waiting ~23 seconds (fine) but for files requiring FFmpeg conversion + STT, it can be longer. More importantly, this is a prerequisite for non-blocking transcription progress UX.

**Solution:** Thread Swift Task cancellation through the pipeline.

**Files changed:**

- `Sources/MacParakeetCore/STT/STTClient.swift`:
  - In `transcribe()`: check `try Task.checkCancellation()` before calling `manager.transcribe()`. FluidAudio 0.12.2 added internal cancellation support, so if the enclosing Task is cancelled, the transcription will stop.

- `Sources/MacParakeetCore/STT/STTClientProtocol.swift`:
  - No changes — `transcribe()` already throws, so `CancellationError` propagates naturally.

- `Sources/MacParakeetCore/Services/TranscriptionService.swift`:
  - Already handles `CancellationError` (lines 193-194, 246). No changes needed.

- `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`:
  - Store the transcription `Task` reference (currently fire-and-forget)
  - Add `cancelTranscription()` method that calls `task.cancel()`
  - Reset state on cancellation

- `Sources/MacParakeet/Views/Transcription/TranscribeView.swift` (or equivalent):
  - Add cancel button to the transcription progress UI (bottom bar or progress overlay)
  - Wire to `viewModel.cancelTranscription()`

### Step 4: Add model cache clearing to Settings

**Problem:** No way for users to reclaim ~6 GB of disk space if they want to uninstall or reset. The "Repair" button only re-downloads.

**Solution:** Use FluidAudio 0.12.2's `clearAllModelCaches()` API.

**Files changed:**

- `Sources/MacParakeetCore/STT/STTClientProtocol.swift`:
  - Add `static func clearModelCache() throws` to protocol

- `Sources/MacParakeetCore/STT/STTClient.swift`:
  - Implement using FluidAudio's API. Call `shutdown()` first (release loaded models), then clear caches.

- `Sources/MacParakeetViewModels/SettingsViewModel.swift`:
  - Add `clearModelCache()` method
  - Update model status to `.notDownloaded` after clearing
  - Show confirmation alert before clearing (destructive action, requires re-download)

- `Sources/MacParakeet/Views/Settings/SettingsView.swift`:
  - Add "Delete Models" button (destructive style) next to existing "Repair" button in the Speech Model card
  - Confirmation dialog: "This will delete ~6 GB of speech models. You'll need to re-download them before transcribing."

### Step 5: Verify & clean up

1. Run `swift test` — all tests pass
2. Build GUI app with `scripts/dev/run_app.sh` — verify:
   - Onboarding progress is smooth (if testing fresh install)
   - File transcription works
   - Cancel button appears during transcription and works
   - Settings "Delete Models" button works
3. Check MockSTTClient still compiles (add no-op `clearModelCache()`)

## Files Changed (Expected)

| File | Change |
|------|--------|
| `Package.swift` | No change needed (constraint already allows 0.12.3) |
| `Sources/MacParakeetCore/STT/STTClient.swift` | Replace polling with DownloadProgress callback, add cancellation check, add clearModelCache |
| `Sources/MacParakeetCore/STT/STTClientProtocol.swift` | Add `clearModelCache()` to protocol |
| `Sources/MacParakeetCore/Services/DiarizationService.swift` | Adopt progress callback if API available |
| `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Store Task reference, add cancelTranscription() |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Add clearModelCache() |
| `Sources/MacParakeet/Views/Transcription/TranscribeView.swift` | Add cancel button |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Add "Delete Models" button |
| `Tests/MacParakeetTests/STT/MockSTTClient.swift` | Add clearModelCache() stub |

## Risks

- **FluidAudio 0.12.3 API surface may differ from docs** — The `DownloadProgress` callback parameter name/signature needs to be verified against the actual Swift API (we read the PR description, not the compiled interface). Mitigate: check after `swift package resolve`.
- **`clearAllModelCaches()` scope** — May clear more than just ASR models (diarization models too). Need to verify. If so, the confirmation dialog should mention both.
- **Cancellation mid-transcription state** — Ensure partial results don't leave orphaned database records. TranscriptionService already handles this (sets status to error on failure).

## Out of Scope

- Non-blocking transcription progress bottom bar UX (separate v0.4 item, depends on this)
- Streaming ASR for real-time dictation (v1.x)
- Custom vocabulary CTC boosting (v1.x)
- ITN text normalization (v1.x)
