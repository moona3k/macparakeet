# Saved-Audio Auto-Prompt Completion

> Status: ACTIVE — implemented Core helper; not yet wired to a coordinator.

## Purpose

Give a saved, already-transcribed `Transcription` (for example, one part of
a [split-and-transcribe](meeting-splitting.md) operation) the same normal
enabled auto-run prompt results (summaries) that GUI and CLI completion
already produce, without duplicating prompt selection, assembly, provider
routing, or persistence logic. This boundary is intentionally narrow: it
does not transcribe, format text, generate a title, manage audio, or apply
retention. Callers own those effects.

## Producers

- `SavedAudioAutoPromptCompletionService.completeAutoPrompts(for:onProgress:)`
  in `MacParakeetCore/Services/SavedAudioAutoPromptCompletionService.swift`.
- `PromptAutoRunSelector.resolve` / `.autoRunPrompts` in
  `MacParakeetCore/Services/PromptAutoRunSelector.swift` — the shared
  selection precedence (label policy → meeting-type policy → per-prompt
  `appliesToSources`) extracted from `PromptResultsViewModel` so the GUI
  auto-generation path and this service resolve identically.

## Consumers

- `PromptResultsViewModel.resolveAvailablePrompts` (GUI prompt picker and
  `autoGeneratePromptResults`) now delegates to `PromptAutoRunSelector`
  instead of keeping a second copy of the same precedence.
- A future split-and-transcribe processing coordinator (not yet built) is
  the intended caller of `SavedAudioAutoPromptCompletionService` for each
  newly saved, newly transcribed child meeting.

## Stable behavior

- Auto-run prompt selection matches the existing GUI/CLI precedence:
  label policy repository (if configured) → meeting-type applicability
  resolver (if configured, meeting sources only) → each prompt's own
  `appliesToSources`/`isAutoRun`.
- A blank transcript (`transcription.cleanTranscript`/`rawTranscript` both
  empty or whitespace-only) short-circuits to no prompts run and no LLM
  call, matching `PromptResultsViewModel.autoGeneratePromptResults`.
- Each generated `PromptResult` is saved with `transcriptionId` equal to
  the supplied `transcription.id`. No parent/original content is read or
  copied; the caller is responsible for passing the correct saved child.
- **First-processing retry dedup**: before generating a prompt, the service
  checks existing `PromptResult`s for the supplied transcription. If one
  already exists for that `promptId`, the prompt is skipped
  (`.alreadyCompleted`) instead of regenerated. This is scoped to the
  first-processing completion pass for a newly saved child — it is not a
  general "never resummarize" rule for meetings a user explicitly asks to
  regenerate elsewhere (those callers use `PromptResultsViewModel.regeneratePromptResult`,
  which is unaffected).
- Failures are isolated per prompt: one prompt failing (`.failed(message:)`)
  does not prevent other prompts in the same call from running, and does
  not delete or replace an earlier prompt's already-saved result.
- `CancellationError` (including from the injected `LLMServiceProtocol`)
  propagates out of `completeAutoPrompts` instead of being recorded as a
  `.failed` outcome — cancellation must never be presented as fake success
  or as an ordinary retryable failure.
- An empty/whitespace-only LLM response is treated as a failure for that
  prompt, not a fake saved success.
- `meetingArtifactStore` (if configured) is refreshed once after the loop
  using the final saved `PromptResult`s; a refresh failure is logged and
  never un-saves a successful `PromptResult`.
- `cardGenerator` (if configured) runs best-effort and detached; its
  failure or absence never blocks or fails prompt completion.

## Non-stable fields

- `SavedAudioAutoPromptCompletionProgress` reporting cadence/content.
- Ordering of `outcomes` beyond "one entry per selected auto-run prompt,
  in selection order."
- Exact `PromptOutcome.failed(message:)` text (mirrors the underlying
  error's `localizedDescription`).

## Versioning and compatibility

This is a new, additive Core type. No existing public API, CLI flag, or
persisted field changes shape. `PromptResultsViewModel`'s public API and
observable behavior are unchanged; only its private selection
implementation now calls into the shared `PromptAutoRunSelector`.

## Known residual limitations (reported, not solved here)

- No exactly-once delivery guarantee across a crash between the provider
  accepting a request and this service saving the `PromptResult` — this
  matches existing GUI/CLI/hook behavior and is not newly introduced or
  newly fixed here. A coordinator that retries after a crash may cause a
  provider to run an equivalent prompt again if the local save never
  landed; it will not duplicate a *saved* result.
- This service does not call `MeetingAutomationHookRunning` (the detached,
  at-most-effort completion hook `TranscriptionService` fires after
  `completeTranscription`). A split coordinator that wants that hook must
  invoke it explicitly; re-deriving "did transcription succeed" from this
  service's output is out of scope here.
- Knowledge-card generation reuses `CardGenerating.generate(transcriptionId:force:)`
  as-is (fire-and-forget); this service adds no new observability for
  whether that background generation actually completed.

## Tests that enforce this

`Tests/MacParakeetTests/Services/SavedAudioAutoPromptCompletionServiceTests.swift`:

- `testNoAutoRunPromptsProducesNoLLMCallAndNoOutcomes`
- `testSourceScopedAutoRunPromptOnlyRunsForItsApplicableSource`
- `testGeneratesAndSavesResultAgainstTheSuppliedChildTranscription`
- `testRepeatedFirstProcessingCompletionSkipsAlreadySavedResultWithoutDuplicating`
- `testProviderFailureRecordsFailureWithoutSavingThenRetrySucceeds`
- `testCancellationPropagatesWithoutSavingOrRecordingAFailedOutcome`
- `testSuccessfulPriorPromptRetainedWhenALaterPromptFails`
- `testExistingParentPromptResultIsNeverConsideredForTheChild`
- `testInjectedCardGeneratorIsInvokedForConfiguredMeeting`
- `testWithoutInjectedCardGeneratorNoCardGenerationIsAttempted`
- `testInjectedMeetingArtifactStoreIsRefreshedAfterCompletion`

`Tests/MacParakeetTests/ViewModels/PromptResultsViewModelTests.swift` continues
to cover the GUI-facing selection/auto-generation behavior end to end and
passed unmodified against the extracted `PromptAutoRunSelector`.

## When this changes

Update this contract and the tests above together. If a future split
coordinator wraps or renames this service's call site, update
[Split and Transcribe](meeting-splitting.md) and this document in the same
change, and record any newly discovered exactly-once or hook-ordering
requirement here rather than silently working around it.
