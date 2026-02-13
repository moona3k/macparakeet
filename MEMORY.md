# MEMORY

Last updated: 2026-02-13

## Current Baseline
- Branch strategy: direct commits to `main` are in use; keep commits small and reversible.
- STT runtime is FluidAudio/CoreML/ANE (native Swift). Python runtime is fully removed from tracked files.
- CLI executable name is `macparakeet-cli` (not `macparakeet`).

## Locked Decisions (Operational)
- `mlx-swift-lm` is pinned to `2.29.2` in `Package.swift`.
  - Reason: avoids known upstream compile windows on CI toolchains:
    - `2.29.3` Jamba parser break (#67)
    - `2.30.3` Swift 6.1 LoRA regression (#94)
- Onboarding performance copy is aligned to FluidAudio numbers:
  - `155x realtime`
  - `~23 seconds for 60 minutes`

## CI / Verification
- CI workflow now prints toolchain versions (`xcodebuild -version`, `swift --version`).
- Local CI-parity helper exists: `scripts/dev/ci_local.sh`
  - Runs: `swift package clean && swift test --parallel`
- CI is configured to skip docs/spec-only changes:
  - `docs/**`, `spec/**`, `**/*.md`
  - Manual trigger remains available via `workflow_dispatch`.

## Test Stability Pattern
- Avoid shared-state test flakiness from `UserDefaults.standard`.
- Preferred pattern:
  - add injectable defaults API in production code where needed.
  - use `UserDefaults(suiteName:)` per test + teardown cleanup.
- TriggerKey tests were stabilized using this pattern.

## Docs/Spec Consistency Rules
- Keep runnable command examples aligned with actual binary names (`macparakeet-cli`).
- Historical mentions of Python/daemon are acceptable only when clearly labeled as historical/migration context.
