# Delete downloaded speech models

> Status: **ACTIVE** — implemented on `feat/delete-downloaded-models`, pending PR merge.

## Why

Issue #311 follow-up (Du7chManiac): after we exposed Parakeet v2 alongside v3,
users who tried both builds have ~465 MB stranded on disk with no way to reclaim
it short of `models clear`, which nukes *everything* (including the build they
use, forcing a re-download). Whisper (~632 MB) has the same problem once a user
switches back to Parakeet. Per-model delete is table stakes for local-model apps
(MacWhisper, LM Studio, Ollama, Superwhisper, VoiceInk all have it).

## Scope

In scope: delete one downloaded model at a time — either Parakeet build, or the
Whisper variant — from the GUI and CLI, protecting the model currently in use.

Out of scope: changing selection/download flows, multi-Whisper-variant UI,
on-disk size measurement (we keep the existing approximate size copy), and any
change to `models clear`.

## Invariants

- The active model and Parakeet's configured build are never deletable without
  `--force` (CLI) and are never offered in the GUI — deleting either would
  silently force a re-download after current or future engine use.
- Deleting one Parakeet build never touches the sibling build (independent
  cache dirs) or the diarization / Whisper models.
- `models clear` behaviour is unchanged.

## Design

**Placement (chosen with owner):** in-context, reusing shipped patterns.
- Parakeet: a `⋯` menu on each *downloaded, non-selected* build row in the
  existing **Parakeet Model** card (where each build already shows a "Downloaded"
  badge + size). The selected build has no menu.
- Whisper: a "Delete download…" item added to the existing `⋯` overflow on the
  **Local Models** Whisper row, shown only when Whisper is not the active engine.
- Shared destructive confirmation `.alert` on the Engine tab.

## Layers

- **Core** (`MacParakeetCore`)
  - `STTRuntime.deleteParakeetModel(version:)` → removes the leaf cache dir
    `AsrModels.defaultCacheDirectory(for:)`; emits `model_operation`/`delete_model`
    telemetry. Pure `removeParakeetModelFiles(at:)` underneath for tests.
  - `WhisperEngine.deleteModel(model:downloadBase:defaults:)` → removes the
    variant folder + clears the optimized flag (pure, injectable).
  - `STTRuntime.deleteWhisperModel(variant:defaults:)` → telemetry wrapper.
  - `SpeechEnginePreference.clearWhisperOptimized(variant:)`.
  - `TelemetryModelOperationAction.deleteModel` + `.stage.delete` (prop value on
    the already-allowlisted `model_operation` event — no website change).
- **CLI**: `models delete <id> [--force]`; testable `resolveModelDeletionTarget`
  + `isModelInUse`. CLI bumped to 2.6.0.
- **ViewModels**: `SettingsViewModel.deleteParakeetVariant(_:)` /
  `deleteWhisperModel()` with in-use + switching guards, optimistic state, and a
  disk refresh. Deleters injected as closures for tests.
- **GUI**: per-build `⋯` in the Parakeet Model card; multi-action overflow on the
  Local Models rows; shared confirmation alert.

## Tests

- Core: Parakeet file removal (incl. sibling-intact), Whisper folder removal +
  optimized-flag clearing + no-op, `clearWhisperOptimized`.
- VM: delete dispatch + active-build / active-engine / switching guards.
- CLI: id resolution, in-use guard for both engines, `--force` parsing.
