# LLM Settings State Refactor Plan

> Status: **ACTIVE**
> ADR: 011 (LLM cloud and local providers)
> Spec: spec/11-llm-integration.md

## Overview

Refactor the LLM settings flow so editable provider configuration, derived UI state, validation, and async actions are separated cleanly. The current code works, but it is carrying enough coupled state that UI regressions are starting to appear.

This refactor is about correctness and maintainability, not feature expansion.

## Current Problems

1. `LLMSettingsViewModel` owns too many responsibilities in one type.
2. Async connection-test results can race with later edits and show stale UI state.
3. Custom-model mode can enter invalid or stale states.
4. Save/test/clear validity is encoded indirectly in property observers.
5. The current tests are good, but they are protecting a state model that is harder to reason about than it needs to be.

## Goals

1. Make editable provider settings a clear, explicit draft state.
2. Make validation rules explicit instead of implicit in `didSet`.
3. Prevent stale async results from overwriting newer state.
4. Keep per-provider API key preservation behavior intact.
5. Make the view model easier to extend without adding more interdependent flags.

## Non-Goals

1. Reworking the underlying `LLMClient` or provider transport.
2. Reintroducing dynamic model fetching.
3. Changing where provider config is stored.
4. Expanding the settings UI beyond what is needed for the refactor.

## Invariants

1. Per-provider API keys remain preserved in Keychain.
2. Local providers still require no API key.
3. Curated model lists remain the default UX.
4. Power users can still enter a custom model ID.
5. Save, clear, and test flows remain available from the same screen.

## Proposed Design

### 1. Separate draft state from side effects

Introduce a pure draft model, likely something like:

```swift
public struct LLMSettingsDraft: Equatable, Sendable {
    var providerID: LLMProviderID
    var apiKeyInput: String
    var selectedSuggestedModel: String
    var usesCustomModel: Bool
    var customModelName: String
    var baseURLOverride: String
}
```

Responsibilities of the draft:

1. Hold only editable fields.
2. Expose derived values such as `effectiveModelName`.
3. Expose validation such as `isValid`, `saveDisabledReason`, and normalized config-building helpers.

This should be pure logic, with no Keychain access and no async work.

### 2. Move actions into a coordinator-style layer

Keep `LLMSettingsViewModel` as the UI-facing coordinator, but narrow it to:

1. current draft
2. connection test status
3. save status
4. methods for load/save/clear/test

The view model should orchestrate actions against:

1. `LLMConfigStoreProtocol`
2. `LLMClientProtocol`
3. optional helper for provider defaults/model suggestions

### 3. Make validation first-class

Validation should not rely on “save and hope” behavior.

Examples:

1. Custom-model mode with empty `customModelName` is invalid.
2. Invalid base URL override should be surfaced as invalid draft state, not silently collapsed into a placeholder URL.
3. Required API-key rules should be derived from provider type.

The UI can still choose how much to show, but the state model should know the answer.

### 4. Version async requests

Connection tests should capture a request token tied to the exact draft under test, not just the provider ID.

Two valid approaches:

1. monotonic generation counter
2. snapshot comparison against the tested draft

Either is fine as long as stale results cannot overwrite newer edits.

## Investigation And Review Plan

### Phase 0: State Inventory

Before editing code:

1. List every mutable property in `LLMSettingsViewModel`.
2. Classify each property as:
   - editable draft state
   - derived state
   - transient async status
   - dependency/service reference
3. Record every transition that currently resets save/test status.

Deliverable:

1. A transition table added to this plan before implementation begins.

### Phase 1: Failure-Mode Audit

Audit the current flow for edge cases:

1. switching providers mid-test
2. editing API key/model/base URL during test
3. toggling custom-model mode on and off
4. clearing after custom-model usage
5. loading stored configs that are no longer in the curated list

This audit should drive the final state-machine shape.

### Phase 2: Focused External Review

Use one external review pass after the draft/coordinator split is sketched out.

Questions for the reviewer:

1. Is the draft model scoped correctly?
2. Are any responsibilities still leaking across layers?
3. Is the validation model too strict or too loose for the current UX?
4. Is there a cleaner way to handle stale async test results?

## Proposed Structure

### Option A: Minimal Split

1. `LLMSettingsDraft`
2. `LLMSettingsViewModel`

This is likely enough if the draft absorbs validation and normalization cleanly.

### Option B: Stronger Split

1. `LLMSettingsDraft`
2. `LLMSettingsCoordinator` or service helper
3. `LLMSettingsViewModel` as thin UI wrapper

This is warranted only if load/save/test logic still feels too dense after Option A.

Default recommendation:

1. Start with Option A.
2. Escalate to Option B only if the view model remains crowded after the first extraction.

## Implementation Phases

### Phase 3: Extract Draft State

Files likely touched:

1. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
2. New draft type file in `Sources/MacParakeetViewModels/`

Tasks:

1. Move editable fields into a draft type.
2. Move effective-model and normalization logic into the draft.
3. Define validation rules explicitly.

### Phase 4: Tighten Save/Test/Clear Flows

Files likely touched:

1. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
2. `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`

Tasks:

1. Make `Save` disabled or guarded when the draft is invalid.
2. Make `Clear` fully reset custom-model state.
3. Make `Test Connection` operate on an immutable draft snapshot.
4. Discard stale async results if the draft changed before completion.

### Phase 5: Provider-Switch Behavior Cleanup

Files likely touched:

1. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
2. `Sources/MacParakeetCore/Services/LLMConfigStore.swift`
3. Existing tests if behavior changes

Tasks:

1. Keep per-provider key restoration behavior.
2. Make provider-default model resets explicit and centralized.
3. Make provider-specific local/cloud rules derive from one source of truth.

### Phase 6: UI Simplification

Files likely touched:

1. `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`

Tasks:

1. Bind the view to clearer derived properties from the draft/view model.
2. Remove UI logic that compensates for ambiguous state if no longer needed.
3. Keep the existing layout unless a small usability fix falls out naturally.

## Test Plan

### Unit Tests

Add or update tests for:

1. Draft validation for suggested vs custom model mode
2. Effective model name derivation
3. Base URL normalization/validation
4. Provider switch behavior and key restoration
5. Clear resetting all editable state
6. Save-status reset rules
7. Connection-test stale result suppression when fields change
8. Connection-test stale result suppression when provider changes

### Regression Tests

Specifically cover:

1. entering custom mode and saving with empty custom model should fail or be disabled
2. clearing after custom mode should restore default suggested mode
3. testing OpenAI config, editing API key, then receiving old success should not mark connected
4. loading a stored custom model still enters custom mode correctly

### UI Sanity Checks

Manual verification after implementation:

1. switch providers repeatedly and confirm keys restore correctly
2. toggle custom mode on/off and confirm state is intuitive
3. test connection while editing fields rapidly
4. save, clear, and reload settings with both cloud and local providers

## Risks

1. Breaking provider-switch persistence while simplifying state.
2. Over-abstracting a relatively small settings screen.
3. Introducing validation that is stricter than the current UX expects.

## Mitigations

1. Preserve behavior through targeted regression tests before structural edits.
2. Keep the first extraction small and reversible.
3. Prefer plain data structures over generalized state-machine machinery.

## Acceptance Criteria

1. Editable state is represented by a dedicated draft type.
2. Save/test validity is explicit and testable.
3. Stale async connection-test results cannot overwrite newer edits.
4. Clear fully resets custom-model state.
5. Per-provider key restoration still works.
6. `swift test` passes with stronger LLM settings regression coverage.
