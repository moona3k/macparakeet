# FluidAudio Full Migration Implementation Plan

> Status: **ACTIVE** - 2026-02-13

## Overview

Migrate MacParakeet STT from Python/parakeet-mlx/JSON-RPC to native Swift FluidAudio/CoreML on ANE.

This is a hard-cut migration:
- No Python runtime in product.
- No dual backend or feature-flag fallback.
- One production STT path: `STTClientProtocol` -> FluidAudio.

## Scope

### In Scope

1. STT runtime replacement (`STTClient` implementation).
2. Python stack deletion (`python/`, `PythonBootstrap`, `JSONRPCTypes`, uv/venv references).
3. Standalone yt-dlp + FFmpeg path for YouTube and media conversion.
4. Onboarding warm-up/download flow updates.
5. CLI health/transcribe updates.
6. Build/sign/distribution script updates for Python-free packaging.
7. Test suite migration from daemon-era assumptions to FluidAudio-era behavior.

### Out of Scope

1. New product features (diarization UX, new command modes, etc.).
2. LLM architecture changes beyond required compile compatibility.
3. Kernel-spec rollout (`spec/kernel/*`) in this PR.
4. Broad UI redesign unrelated to migration.

## Current Code Hotspots (Must Change)

Core runtime:
- `Sources/MacParakeetCore/STT/STTClient.swift`
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift`
- `Sources/MacParakeetCore/STT/PythonBootstrap.swift` (delete)
- `Sources/MacParakeetCore/STT/JSONRPCTypes.swift` (delete)

Media/download pipeline:
- `Sources/MacParakeetCore/Services/YouTubeDownloader.swift`
- `Sources/MacParakeetCore/Audio/AudioFileConverter.swift`
- `Sources/MacParakeetCore/Services/AppPaths.swift`
- `Sources/MacParakeet/App/AppEnvironment.swift`

Onboarding:
- `Sources/MacParakeetViewModels/OnboardingViewModel.swift`
- `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift`
- `Sources/MacParakeet/Onboarding/OnboardingWindowController.swift`

CLI + scripts:
- `Sources/CLI/Commands/HealthCommand.swift`
- `Sources/CLI/Commands/TranscribeCommand.swift`
- `scripts/dist/build_app_bundle.sh`
- `scripts/dist/sign_notarize.sh`

Tests:
- `Tests/MacParakeetTests/STT/STTClientTests.swift`
- `Tests/MacParakeetTests/STT/JSONRPCTests.swift` (delete or replace)
- `Tests/MacParakeetTests/Services/AppPathsTests.swift`
- `Tests/MacParakeetTests/Services/YouTubeDownloaderTests.swift`

## Ordered Execution Checklist

### Phase 0: Branch + Baseline

1. Create migration branch from current `main`.
2. Run baseline tests:
   - `swift test`
3. Capture baseline references:
   - Current `Package.swift`
   - Current `scripts/dist/*`
   - Current STT tests and AppPaths behavior.

### Phase 1: Toolchain + Dependencies

1. Update `Package.swift` swift-tools-version if required by FluidAudio (it specifies 6.0; validate whether 5.9 can consume it).
2. Add FluidAudio SwiftPM dependency and wire `MacParakeetCore` target dependency.
3. Keep build green before deleting Python paths.

Exit criteria:
- `swift build --target MacParakeetCore` succeeds.
- No partial dependency state left in `Package.swift`.

### Phase 2: STT Runtime Swap (Core)

1. Rewrite `STTClient` to use FluidAudio APIs (`AsrModels`, `AsrManager`, converter path).
2. Keep `STTClientProtocol` surface stable where practical.
3. Replace daemon-specific error semantics (`daemonNotRunning`) with model/runtime-ready semantics.
4. Remove JSON-RPC request/response plumbing usage.

Exit criteria:
- `STTClient` compiles without Python/JSON-RPC types.
- `DictationService` and `TranscriptionService` compile against unchanged protocol contracts or intentional updates.

### Phase 3: Remove Python Stack

1. Delete:
   - `Sources/MacParakeetCore/STT/PythonBootstrap.swift`
   - `Sources/MacParakeetCore/STT/JSONRPCTypes.swift`
   - `python/` directory
2. Remove `PythonBootstrap` construction/injection from:
   - `AppEnvironment`
   - CLI commands
   - download/transcription services
3. Remove `pythonVenvDir` assumptions from app paths and tests.

Exit criteria:
- `rg -n \"PythonBootstrap|JSONRPC|pythonVenvDir|parakeet-mlx|uv\" Sources Tests scripts` has no runtime-path hits (historical comments excluded).

### Phase 4: Binary-Based Media Tooling

1. Introduce/finish binary bootstrap for yt-dlp and wire bundled FFmpeg path resolution.
2. Update `YouTubeDownloader` to standalone yt-dlp binary.
3. Update `AudioFileConverter` to use bundled FFmpeg only (no imageio-ffmpeg or system probing).
4. Update `HealthCommand` checks to binary/model readiness signals.

Exit criteria:
- URL transcription path no longer depends on Python or venv.
- Media conversion path no longer probes `site-packages/imageio_ffmpeg`.

### Phase 5: Onboarding + Lifecycle

1. Replace venv setup/warm-up steps with:
   - CoreML model download
   - Model initialization warm-up
   - helper readiness checks (yt-dlp binary + bundled FFmpeg availability)
2. Update onboarding copy/status messages accordingly.
3. Verify onboarding can complete fully without Python installed.

Exit criteria:
- Onboarding flow references CoreML/FluidAudio only.
- No user-visible Python terminology remains.

### Phase 6: Build + Distribution Scripts

1. Remove uv bundling/downloading from:
   - `scripts/dist/build_app_bundle.sh`
   - `scripts/dist/sign_notarize.sh`
2. Ensure signing logic covers actual shipped binaries only.
3. Keep notarization flow documentation aligned with packaged artifacts.

Exit criteria:
- Dist scripts do not bundle/sign uv artifacts.
- Build output includes only intended runtime dependencies.

### Phase 7: Test Migration

1. Replace/remove daemon-era tests:
   - `JSONRPCTests`
   - stderr progress parsing assumptions tied to daemon protocol
2. Update STT tests for FluidAudio behavior and error mapping.
3. Update AppPaths tests for Python path removals.
4. Run full suite and targeted smoke commands:
   - `swift test`
   - `swift run macparakeet health`
   - `swift run macparakeet transcribe <fixture>`

Exit criteria:
- Full test suite passes.
- No tests assert daemon/JSON-RPC behavior.

### Phase 8: Final Spec/Doc Sync (Post-Code)

1. Remove temporary migration-note banners after code lands.
2. Ensure docs describe current truth (no target/current mismatch).
3. Confirm no stale references in active docs:
   - Python daemon
   - uv bootstrap
   - JSON-RPC STT transport
   - outdated performance hard-gates

Exit criteria:
- `rg` sweep across `README.md`, `CLAUDE.md`, `spec/*.md`, `docs/distribution.md` is clean.

## Verification Commands

Core verification:
```bash
swift test
```

CLI smoke:
```bash
swift run macparakeet health
swift run macparakeet transcribe /path/to/audio.wav
```

Build smoke:
```bash
xcodebuild build -scheme MacParakeet -destination 'platform=OS X' -derivedDataPath .build/xcode
```

Static consistency sweep:
```bash
rg -n "PythonBootstrap|JSONRPC|pythonVenvDir|parakeet-mlx|uv|daemonNotRunning" Sources Tests scripts README.md CLAUDE.md spec docs
```

## PR Structure (Recommended)

1. Toolchain + dependency wiring.
2. STT runtime rewrite + Python deletion.
3. Media/download/binary bootstrap updates.
4. Onboarding + CLI + dist scripts.
5. Test migration + final doc sync.

This keeps each commit reviewable while still landing as one hard-cut migration PR.

## Definition of Done

1. Runtime: STT path is FluidAudio-only in shipped code.
2. Packaging: No Python/uv artifacts in app bundle workflow.
3. Tests: Full suite passing, daemon-era tests removed or replaced.
4. Docs/specs: Aligned to landed code, no migration caveats needed.
5. CLI: `health` and `transcribe` work without Python installed.
