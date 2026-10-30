# Saved-Audio Auto-Prompt Completion

> Status: ACTIVE — implemented Core helper, used by `MeetingSplitService`.

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
- `MeetingSplitService.processAll` calls `completeAutoPrompts(for:)` after
  each child's saved-audio transcription succeeds, before moving to the next
  child. Its durable automation stage supports retry without splitting again
  or repeating successful transcription.

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
- The transcript text and `sourceCorrectionRevision` receipt come from the
  same effective-attribution read before card generation or provider calls.
  The result also stores `sourceTranscriptHash` from the supplied saved
  transcription before those calls. For an unedited transcript with timed
  cues, it hashes joined cue words without timestamps or speaker labels;
  otherwise it uses automatic clean/raw text.
  A correction made while those calls run leaves the saved result tied to its
  original input revision, so the app can mark it stale. If no attribution
  projection is available, the service uses the supplied transcript and
  revision zero.
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
- `cardGenerator` (if configured) runs best-effort and is awaited so callers
  retain ownership through its provider call. Its ordinary failure or absence
  never fails prompt completion; cancellation still propagates.

## Non-stable fields

- `SavedAudioAutoPromptCompletionProgress` reporting cadence/content.
- Ordering of `outcomes` beyond "one entry per selected auto-run prompt,
  in selection order."
- Exact `PromptOutcome.failed(message:)` text (mirrors the underlying
  error's `localizedDescription`).

## Versioning and compatibility

This boundary was introduced as an additive Core type, without changing
existing CLI flags. `PromptResultsViewModel` delegates its private selection
implementation to the shared `PromptAutoRunSelector`. Migration v0.48 later
adds a nullable `sourceTranscriptHash` receipt to persisted `PromptResult`s;
older results retain an unknown source.

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
  as-is and awaits its completion. The result remains best effort and is not
  represented in `SavedAudioAutoPromptCompletionResult`.

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
- `testCompletionDoesNotReturnWhileKnowledgeCardProviderIsRunning`
- `testCancellationDuringKnowledgeCardGenerationPropagatesWithoutAutoPrompts`
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

### Bounded knowledge-card recovery

The shared card generator retains its source/speaker/correction fingerprint
checks and atomic conditional save. Failure or cancellation leaves a previous
valid card untouched; changed or deleted sources cannot receive the late
result. Fresh cards still skip generation.

The LLM stage waits only for temporary AI configuration contention: four reads
at most, with cancellable waits of 100, 300 and 600 ms. It never writes settings.
After resolving the analysis route, at most two LLM client requests use that
same context. Cloud and other unknown-window routes preserve the 700-token
initial allowance, with 4,096 only on an explicit output-limit finish reason.
This also preserves requests to manually named models and overridden endpoints.
Native Ollama uses 2,048/4,096; LM Studio uses 1,024/1,536 to leave input room
in its smaller configured window. Custom OpenAI-compatible endpoints retain
700 initially and permit 2,048 only after explicit truncation, since their
model context window is unknown. Recovery can still fail at that endpoint's
limit; no context capacity is inferred. Input is budgeted with the output reserve,
including Ollama's native 8,192-token window. LocalCLI does not expose a token
limit or usage and remains unknown where unsupported.

A malformed or empty-synopsis response gets one fresh request with corrective
JSON instructions; partial model output is not replayed. An explicit truncated
finish is rejected even when its JSON parses. Timeouts, rate limits, provider
rejections (including unsupported schemas) and cancellation are terminal rather
than blind replays. Generic formatter/chat/prompt retry behavior is unchanged.
The stored card retains its approximately 350-token text budget. These recovery
changes do not invalidate fresh cards or change schema/prompt provenance versions.

Tests: KnowledgeCardRecoveryTests, CardGenerationServiceTests, LLMServiceTests,
LLMHTTPAdapterTests, LLMConfigStoreTests.
