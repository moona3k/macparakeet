# Boundary Contracts

> Status: ACTIVE - canonical home for tested boundary contracts.

Boundary contracts describe repo surfaces that other code, the CLI, local
automation, support workflows, or future agents depend on. They sit between
ADRs and tests: ADRs explain why a design exists, while these files define the
stable shape that must not drift accidentally.

## Format

Each contract document should include:

- Purpose: what boundary is being protected.
- Producers: code paths that create or mutate the boundary.
- Consumers: code paths, tools, or workflows that read it.
- Stable fields: names, filenames, states, exit codes, or semantics tests must
  protect.
- Non-stable fields: timestamps, generated paths, ordering, copy, or other
  values that may change without breaking the contract.
- Versioning and compatibility: how additive and breaking changes are handled.
- Tests that enforce this: exact XCTest classes or focused test names.
- When this changes: docs, changelog, tests, or migration work required in the
  same PR.

## Rules

- A PR that changes a listed boundary updates the matching contract doc and
  focused tests in the same change.
- Tests should pin semantic stability, not incidental formatting. Do not freeze
  generated timestamps, absolute user paths, or unrelated pretty-print details.
- Additive fields are allowed when existing consumers continue to work. Removing
  or renaming stable fields requires an explicit version bump and migration or
  compatibility story.

## Current Contracts

- [Meeting Artifacts v1](meeting-artifacts-v1.md)
- [Meeting Recovery and Retention Safety](meeting-recovery-retention.md)
- [CLI JSON v1](cli-json-v1.md)
- [DAPT Export v1](dapt-export-v1.md)
- [File Transcription Audio Tracks](file-transcription-audio-tracks.md)
