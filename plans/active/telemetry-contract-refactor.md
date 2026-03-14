# Telemetry Contract Refactor Plan

> Status: **ACTIVE**
> ADR: 012 (Self-hosted telemetry via Cloudflare)
> Spec: docs/telemetry.md

## Overview

Refactor telemetry from scattered string literals into a typed, contract-driven system that keeps the client implementation aligned with the documented event catalog and the Cloudflare Worker schema.

This is not a feature expansion. The goal is to make the existing telemetry system safer to evolve, harder to break, and easier to audit.

## Current Problems

1. Event names and props are defined ad hoc across services and view models.
2. The implementation already drifts from the documented schema in `docs/telemetry.md`.
3. Contract errors are hard to catch at compile time because everything is stringly typed.
4. Termination flush behavior is separate from regular batching logic and can violate the worker batch limit.
5. Tests validate queueing/serialization behavior, but not full event-catalog conformance.

## Goals

1. Make event names and required props compile-time constructs, not freeform strings.
2. Encode the documented event catalog once and reuse it everywhere.
3. Keep batching behavior consistent across normal and termination flush paths.
4. Add tests that fail when the implementation drifts from the telemetry contract.
5. Preserve the current privacy model and fire-and-forget behavior.

## Non-Goals

1. Changing the backend storage schema.
2. Adding new telemetry categories beyond the current documented catalog.
3. Building a dashboard in this refactor.
4. Turning telemetry into guaranteed delivery or durable local persistence.

## Invariants

1. No transcription content, file names, URLs, prompts, or personal identifiers are sent.
2. Telemetry remains opt-out and defaults to enabled.
3. Session-scoped UUID behavior remains unchanged.
4. Unknown or malformed events should be prevented at the call site, not handled by best-effort string cleanup.
5. Worker batch size remains capped at 100 events per request.

## Proposed Design

### 1. Introduce a typed event layer

Create a dedicated type in `MacParakeetCore`, likely one of:

```swift
public enum TelemetryEventSpec: Sendable {
    case appLaunched
    case dictationStarted(trigger: DictationTrigger?)
    case dictationCompleted(durationSeconds: Double, wordCount: Int, mode: DictationMode)
    case dictationCancelled(durationSeconds: Double?, reason: DictationCancelReason?)
    case dictationEmpty(durationSeconds: Double?)
    case dictationFailed(errorType: String)
    ...
}
```

or an equivalent namespaced builder API if that reads better in call sites.

Requirements:

1. One typed case per documented event.
2. Each case knows its canonical event name.
3. Each case knows how to serialize its own props.
4. Optional props are explicit; undocumented props are not allowed.

### 2. Narrow the send surface

Change the public convenience API from:

```swift
Telemetry.send("dictation_completed", ["word_count": "42"])
```

to:

```swift
Telemetry.send(.dictationCompleted(durationSeconds: 12.5, wordCount: 42, mode: .raw))
```

This should remove raw event-name strings from service and view-model call sites.

### 3. Keep transport generic, keep contract specific

Retain `TelemetryService` as the queue/flush transport layer, but feed it a typed event object that converts to the wire model in one place.

Possible structure:

1. `TelemetryEventSpec`: typed contract-facing event
2. `TelemetryEvent`: wire/persisted payload model
3. `TelemetryService`: queueing, batching, lifecycle flush

This keeps the transport simple while moving schema correctness earlier.

### 4. Unify batching rules

Refactor flush code so both async flush and termination flush share the same chunking logic. No special-case path should be able to emit >100 events in a single request.

Possible extraction:

1. `drainQueue() -> [TelemetryEvent]`
2. `chunkedBatches(from:) -> [[TelemetryEvent]]`
3. `sendBatch(_:)` used by both `flush()` and `flushSync()`

## Investigation And Review Plan

### Phase 0: Contract Audit

Before editing code:

1. Enumerate every documented event in `docs/telemetry.md`.
2. Enumerate every current `Telemetry.send(...)` call site.
3. Diff the two lists and classify:
   - missing event
   - missing prop
   - undocumented prop
   - wrong prop semantics
4. Confirm which documented events are intentionally not yet implemented.

Deliverable:

1. A short audit section added to this plan before implementation begins.

### Phase 1: Design Review

Pressure-test the typed API before code changes:

1. Review the proposed event type surface for ergonomics.
2. Review whether prop values should remain strings at the wire boundary only.
3. Review whether enum cases should model event categories or stay flat.
4. Confirm how much of `docs/telemetry.md` should be treated as a strict contract.

External review is useful here because the design tradeoff is API ergonomics vs future maintainability, not raw implementation difficulty.

### Phase 2: Focused External Review

Use one external review pass after the contract audit and proposed event type are concrete.

Questions for the reviewer:

1. Is the typed event API too rigid or about right?
2. Are there any missing invariants around privacy or event evolution?
3. Is transport separation sufficient, or should `TelemetryService` be split further now?
4. Are the proposed tests enough to keep the schema honest?

## Implementation Phases

### Phase 3: Typed Contract Foundation

Files likely touched:

1. `Sources/MacParakeetCore/Services/TelemetryEvent.swift`
2. `Sources/MacParakeetCore/Services/TelemetryService.swift`
3. New contract type file if needed

Tasks:

1. Add typed event definitions.
2. Add serialization from typed event to wire payload.
3. Keep the wire format exactly compatible with the worker contract.

### Phase 4: Call Site Migration

Files likely touched:

1. `Sources/MacParakeetCore/Services/DictationService.swift`
2. `Sources/MacParakeetCore/Services/TranscriptionService.swift`
3. `Sources/MacParakeetCore/Services/LLMService.swift`
4. `Sources/MacParakeetViewModels/SettingsViewModel.swift`
5. `Sources/MacParakeetViewModels/DictationHistoryViewModel.swift`
6. `Sources/MacParakeetViewModels/CustomWordsViewModel.swift`
7. `Sources/MacParakeetViewModels/TextSnippetsViewModel.swift`
8. `Sources/MacParakeet/App/AppEnvironment.swift`
9. `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`

Tasks:

1. Replace raw strings with typed events.
2. Fill in documented props that are currently missing where the source data exists.
3. Make any intentionally unsupported props explicit and documented.

### Phase 5: Flush-Path Cleanup

Files likely touched:

1. `Sources/MacParakeetCore/Services/TelemetryService.swift`
2. `Tests/MacParakeetTests/TelemetryServiceTests.swift`

Tasks:

1. Share batching logic across async and sync flush.
2. Add a regression test for termination flush with >100 events queued.
3. Preserve deadlock-safe termination behavior.

### Phase 6: Documentation Sync

Files likely touched:

1. `docs/telemetry.md`
2. `spec/adr/012-telemetry-system.md`

Tasks:

1. Update docs if any event semantics changed.
2. Remove ambiguity between “documented future event” and “implemented event”.
3. Document the typed event layer so future contributors do not reintroduce string literals.

## Test Plan

### Unit Tests

Add or update tests to cover:

1. Each typed event serializes to the expected event name and props.
2. Required props are present for all implemented events.
3. Optional props are absent when not provided.
4. `flush()` chunks at 100 events.
5. `flushSync()` chunks at 100 events.
6. Opt-out behavior still allows the final `telemetry_opted_out` event.

### Contract Tests

Add one catalog-level test that compares the implemented event list against a canonical list in test code. This should fail when:

1. A documented implemented event is missing
2. An event name changes accidentally
3. A required prop key changes accidentally

### Regression Tests

Specifically cover:

1. Dictation completion includes all expected props
2. Transcription completion/failure/cancelled preserve source semantics
3. LLM failure events keep provider and error type
4. Settings events only send allowed setting keys

## Risks

1. Overengineering the typed API and making call sites painful.
2. Freezing event evolution too early.
3. Accidentally changing the wire format while cleaning up internal types.

## Mitigations

1. Keep the typed API small and direct.
2. Keep wire-model serialization in one place.
3. Review sample emitted payloads before merging.
4. Avoid transport rewrites beyond what is needed for correctness in this pass.

## Acceptance Criteria

1. No production call site uses raw telemetry event-name strings.
2. All implemented events serialize through one typed contract layer.
3. Async and termination flush respect the same batch limit.
4. The event catalog and implementation are synchronized and test-enforced.
5. `swift test` passes with new telemetry regression coverage.
