# Capture, speech runtime, calendar and system integration review

Date: 2026-10-31. Source baseline: `79cf1ca928b53c3853a99f6832c197d664dcdd78`.
Change lens: `v0.8.10..79cf1ca92`. This is one bounded lane of the
[app/CLI parity audit](README.md), not a whole-app certification.

## Verdict and evidence boundary

One confirmed parity gap remains: CLI meeting retranscription cannot resume a
source-only meeting whose canonical playback is missing. The app's finalization
Retry can. No additional high-confidence runtime defect was established in the
selected capture/lifecycle paths below. This is a source-review result, not a
claim that every inventoried implementation is correct.

No builds, tests, app launches, physical recording, provider calls, user-state
reads or mutations, or publishing were performed for this lane. Existing test
assertions were inspected in selected files; their presence is not a passing
result. Model-specific inference, Bluetooth/Teams/device switching, microphone
quality, native focus, OS event delivery and packaged URL handling remain
unverified. No Jev calls were used; this lane is source reasoning.

## Confirmed finding

### P2 — CLI cannot perform the app's source-only finalization Retry

**Trigger:** an error/cancelled meeting retains its source tracks and
`awaitingTranscription` lock, but has not produced canonical playback. This is a
supported state after Stop settles capture independently of preparation.

**Evidence:** [CLI retranscription](../../../Sources/CLI/Commands/RetranscribeCommand.swift)
line 528 calls `retainedAudioURL(original.filePath)` before inspecting archived
meeting sources. Its lines 678–685 reject absent/missing playback. In contrast,
[app Retry](../../../Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift)
lines 1872–1919 loads `MeetingRecordingCapture` when duration is unknown or
playback is not viable. [Audio state](../../../Sources/MacParakeetCore/Services/MeetingRecording/MeetingAudioFile.swift)
lines 114 and 136–140 exposes `sourcesSaved` as retryable. The missing-playback
case is sufficient to establish the gap; no claim is made that every corrupt
playback case behaves identically in the CLI.

**Impact:** an agent can inspect the failed row but cannot finish the same local
recovery action available to the user without a GUI handoff. This is a recovery
capability gap, not a reason to add CLI microphone capture or bypass consent.
The integration capability map now discloses it; this review does not fix it.

**Bounded follow-up:** make source-only finalization an explicit shared operation,
then expose it to the CLI with a clear resume/finalize semantic. Reuse the
existing source preparation and finalization ownership logic, preserve the
canonical row and notes/speaker/artifact metadata, refuse live owners and
pending writer finalizers, and retain sources on failure. Do not merely remove
the playback existence check or route this state through generic reprocessing.
Before implementation, settle whether an explicit retry command or an additive
mode of `retranscribe` communicates the different completion semantics best.

**Required regression cases:** missing playback with healthy sources; unknown
duration with existing playback; active owner; pending writer finalization;
duplicate admission; failed preparation followed by retry; completed-row refusal
for the recovery-only operation; metadata preservation; cancellation and row
removal races; stable JSON success/error outputs. The CLI contract and discovery
help must be updated with the chosen operation.

## Boundaries traced

- **Stop versus derived work.** `MeetingRecordingService.stopCapture` serializes
  settlement, drains capture, finalizes sources, commits metadata/lock and
  releases capture state before playback/STT preparation. The app persists the
  processing row and hands the capture to `MeetingTranscriptionQueue`; the queue
  claims finalization ownership before queued preparation. The compatibility
  `stopRecording` method still prepares playback after capture settlement.
- **Writer timeout ownership.** A deadline returns a bounded report without
  cancelling AVAssetWriter or releasing ownership early. The registry remains
  until all writer callbacks settle, including an unwritten source. The selected
  writer tests assert this distinction and exactly-once reporting.
- **Retry, completion and cleanup.** Source reconstruction checks the lock and
  writer registry; preparation validates retained source alignment. Ownership
  release restores only the matching lease and remembers failed restoration.
  Completion checks the persisted completed row and artifact folder before lock
  removal. Retention skips any recording lock. Normal folder deletion refuses
  locked folders; no row-resurrection defect was established from the queue's
  missing-row recovery branch.
- **Cancellation and inference.** Scheduler admission, live-session reservation,
  append draining and cancellation keep resource ownership until work settles.
  Runtime shutdown waits for finishing/cancelling live sessions. Inspection did
  not establish that all model adapters terminate promptly; a watchdog is not
  proof that an underlying native inference has stopped.
- **Capture start/stop.** The inspected bounded screen-capture startup path
  retires late successful starts, while meeting capture stop drains relevant
  startup/recovery ownership and invalidates callbacks by lifecycle/generation.
  Shared microphone unsubscribe completes on its engine queue, and VPIO
  promotion considers existing raw-mode blockers. Full platform/audio-driver
  behavior was not exercised.
- **Synthetic keyboard events.** New common event marking and session posting
  are used by paste/selection paths; hotkey handlers filter marked events before
  their state bookkeeping. Cursor interruption preserves physical input and
  stops further insertion after a failed drain, including before first commit;
  the selected tests explicitly prohibit later retry/full-paste fallback.
- **Calendar and URL controls.** Calendar candidate/policy and coalesced
  eligibility paths were inspected, with selected fetch/countdown assertions.
  Dictation URL parsing uses bounded grammar, independent consent and a bounded
  launch buffer. URL delivery has no completion receipt; that limitation is
  intentional in the active contracts. Consent/capture remain GUI-owned.

## Verification and remaining work

For a subsequent source change, start with the specific affected test suites,
not a blanket rebuild. The existing writer, queue, lock, recovery, STT scheduler,
cursor insertion, URL and calendar suites provide useful focused entry points.
A source-only recovery implementation additionally needs CLI contract tests.
Use the project's single final full-suite gate only for actual code-change work.

Before claiming release/runtime confidence, exercise native start/stop/cancel,
writer-timeout recovery, restart after failed preparation, concurrent queue
completion versus a new capture, model shutdown and URL warm/cold delivery in a
packaged app. Physical microphone/system audio, Bluetooth and real third-party
text fields need their own evidence. No historical performance or audio-quality
measurement is reused as proof for this checkout.

## Coverage ledger

`S` means selected source or diff was inspected, as described; it does **not**
mean every line in that file was audited. `I` means filename/scope inventory only.
`Δ` marks a file changed since `v0.8.10` at the source baseline. Generated,
ignored and private paths are excluded. App coverage includes capture/dictation/
meeting coordinators, hotkeys, onboarding preview, relevant environment wiring
and AppDelegate; it does not claim every app coordinator.

Product/guidance inventory: **141 files**, **40 S**, **101 I**. Test inventory: **126 files**, **6 with selected assertions or fixture implementation inspected**, all others inventory/test-name review only. Tests executed: **0**.

### `Sources/MacParakeetCore/Audio`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `AudioCaptureDiagnostics.swift` | I | Inventory only. |
| `AudioChunker.swift` | I | Inventory only. |
| `AudioDeviceManager.swift` | I | Inventory only. |
| `AudioEngineLifecycleDiagnostics.swift` | I | Inventory only. |
| `AudioFileConverter.swift` | I | Inventory only. |
| `AudioFileEnumerator.swift` | I | Inventory only. |
| `AudioProcessor.swift` | I | Inventory only. |
| `AudioProcessorProtocol.swift` | I | Inventory only. |
| `AudioRecorder.swift` | I | Inventory only. |
| `AudioTrackDescriptor.swift` | I | Inventory only. |
| `CMSampleBufferToPCMBuffer.swift` | I | Inventory only. |
| `DiagnosticLogScope.swift` | I | Inventory only. |
| `FFmpegAudioTrackProbe.swift` | I | Inventory only. |
| `MeetingAudioCaptureService.swift` | S | Selected start/lease and stop paths: drain, generation guards and retained microphone-start ownership. |
| `MeetingAudioError.swift` | I | Inventory only. |
| `MeetingAudioStorageWriter.swift` | S | FinalizationCoordinator, writer deadline and late callback ownership; append implementation not fully inspected. |
| `MeetingLiveAudioChunking.swift` | I | Inventory only. |
| `MeetingMicHealthMonitor.swift` | I | Inventory only. |
| `MeetingMicProcessingMode.swift` | I | Inventory only. |
| `MeetingVADChunkingSimulator.swift` | I | Inventory only. |
| `MicrophoneCapture.swift` | I | Inventory only. |
| `MicrophoneEnginePlatform.swift` | I | Inventory only. |
| `ObjCExceptionBridge.swift` | I | Inventory only. |
| `PCMBufferToSampleBuffer.swift` | I | Inventory only. |
| `README.md` | S | Guidance: shared microphone, writer ownership and source settlement rules. |
| `ScreenCaptureLifecycle.swift` | S | Bounded start/late-success stop contract; first half of implementation. |
| `SharedMicrophoneStream.swift` | S | Unsubscribe engine-queue completion and subscribe/VPIO promotion decisions. |
| `SpeechBoundaryMeetingLiveAudioChunker.swift` | I | Inventory only. |
| `SystemAudioStream.swift` | I | Inventory only. |
| `UncheckedSendableAudioPCMBuffer.swift` | I | Inventory only. |

### `Sources/MacParakeetCore/STT`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `AsyncPermit.swift` | S | FIFO acquisition and cancellation bookkeeping. |
| `CohereTranscribeEngine.swift` | I | Inventory only. |
| `CustomVocabularyBoosting.swift` | I | Inventory only. |
| `FnKeyStateMachine.swift` | I | Inventory only. |
| `HotkeyGestureController.swift` | I | Inventory only. |
| `HotkeyTrigger.swift` | I | Inventory only. |
| `KeyCodeNames.swift` | I | Inventory only. |
| `NativeLiveDictating.swift` | I | Inventory only. |
| `NemotronEngine.swift` | I | Inventory only. |
| `NemotronEnglishEngine.swift` | I | Inventory only. |
| `OnboardingProgressParser.swift` | I | Inventory only. |
| `OrukeetModelStore.swift` | I | Inventory only. |
| `ParakeetModelVariant+ASR.swift` | I | Inventory only. |
| `ParakeetTDTASRConfig.swift` | I | Inventory only. |
| `ParakeetUnifiedEngine.swift` | I | Inventory only. |
| `README.md` | S Δ | Guidance: scheduler ownership, live/final split and queue rules. |
| `STTClient.swift` | I | Inventory only. |
| `STTClientProtocol.swift` | I | Inventory only. |
| `STTResult.swift` | I | Inventory only. |
| `STTRuntime.swift` | S | Engine routing, native-live begin/finish/cancel and shutdown; model adapters/cache operations not comprehensively inspected. |
| `STTScheduler.swift` | S | Admission, native live-session reservation/append drain, cancellation, engine switching and shutdown. |
| `STTWordTimingBuilder.swift` | I | Inventory only. |
| `SpeechEngineCapabilities.swift` | I | Inventory only. |
| `WhisperEngine.swift` | I | Inventory only. |

### `Sources/MacParakeetCore/Calendar`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `CalendarAutoStartMode.swift` | I | Inventory only. |
| `CalendarEvent.swift` | I | Inventory only. |
| `CalendarNotificationAuthorization.swift` | I | Inventory only. |
| `CalendarService.swift` | I | Inventory only. |
| `CalendarServicing.swift` | I | Inventory only. |
| `CalendarSkip.swift` | I | Inventory only. |
| `MeetingLinkParser.swift` | I | Inventory only. |
| `MeetingMonitor.swift` | S | Candidate, trigger, reminder and auto-start policy paths. |
| `MeetingTriggerFilter.swift` | I | Inventory only. |
| `README.md` | S | Subsystem guidance. |

### `Sources/MacParakeetCore/Services/MeetingRecording`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `MeetingArtifactAudioFileNames.swift` | I | Inventory only. |
| `MeetingArtifactPathAliases.swift` | I | Inventory only. |
| `MeetingArtifactStore.swift` | I | Inventory only. |
| `MeetingAudioFile.swift` | S Δ | Latest diff and source-saved/retry predicates. |
| `MeetingAudioPairJoiner.swift` | I | Inventory only. |
| `MeetingAudioRetentionPolicy.swift` | I | Inventory only. |
| `MeetingAudioRetentionSweeper.swift` | S | Age selection, lock barrier and centralized removal. |
| `MeetingAutoStopPolicy.swift` | I | Inventory only. |
| `MeetingAutomationHookRunner.swift` | I | Inventory only. |
| `MeetingCaptureDiagnostics.swift` | I | Inventory only. |
| `MeetingCaptureHealth.swift` | I | Inventory only. |
| `MeetingCaptureReport.swift` | I | Inventory only. |
| `MeetingChunkResultBuffer.swift` | I | Inventory only. |
| `MeetingCleanedMicRenderer.swift` | S Δ | Latest shared reference-shift diff only; acoustic/DSP correctness not established. |
| `MeetingCleanedMicrophoneReadiness.swift` | S Δ | Latest deferred single-task readiness/cancellation diff. |
| `MeetingDecodedAudio.swift` | I | Inventory only. |
| `MeetingFinalizationBenchmarkObserver.swift` | I | Inventory only. |
| `MeetingMarkdownRenderer.swift` | I | Inventory only. |
| `MeetingMediaMutationLease.swift` | S | Canonical lock ordering, nonblocking flock, symlink protection and descriptor release. |
| `MeetingNotesFile.swift` | I | Inventory only. |
| `MeetingPlaybackArtifactBuilder.swift` | S Δ | Latest cancellation-before-fallback diff only. |
| `MeetingPreviewIngressQueue.swift` | I | Inventory only. |
| `MeetingRecordingCapture.swift` | S Δ | Entire new capture value: load, processing row, preparation, source alignment and deferred cleaned readiness. |
| `MeetingRecordingLockFileStore.swift` | S Δ | Latest diff plus admission/release/relinquish ownership and restore semantics; not every lock decoder path. |
| `MeetingRecordingMetadata.swift` | I | Inventory only. |
| `MeetingRecordingOutput.swift` | S Δ | Latest capture/output split diff; archived-output and media readers not exhaustively inspected. |
| `MeetingRecordingRecoveryService.swift` | S Δ | Latest deferred-render recovery diff only; full recovery service not audited. |
| `MeetingRecordingService.swift` | S Δ | Latest diff plus stop settlement, metadata, ownership and session guards; remaining capture implementation inventory only. |
| `MeetingRecordingSettlement.swift` | S | Completed-row/folder validation and lock removal. |
| `MeetingSystemAudioSignalVerdict.swift` | I | Inventory only. |
| `MeetingTitleGenerator.swift` | I | Inventory only. |
| `MeetingTranscriptAssembler.swift` | I | Inventory only. |
| `MeetingTranscriptFinalizer.swift` | I | Inventory only. |
| `MeetingTranscriptSourceReconciler.swift` | I | Inventory only. |
| `MeetingTranscriptVocabularyApplier.swift` | I | Inventory only. |
| `MeetingVADModelPreparer.swift` | I | Inventory only. |
| `MeetingVADService.swift` | I | Inventory only. |

### `Sources/MacParakeetCore/Services/System`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `AccessibilityService.swift` | I | Inventory only. |
| `AppGeneratedKeyboardEvents.swift` | S Δ | Entire new common marker and session-post helper. |
| `BackgroundEventTap.swift` | S | Shared event thread/run loop, start/stop and callback ownership. |
| `ClipboardService.swift` | S Δ | Latest synthetic posting helper diff. |
| `EventTapTeardown.swift` | I | Inventory only. |
| `FocusedAppContextService.swift` | I | Inventory only. |
| `FrontmostApplicationProvider.swift` | I | Inventory only. |
| `LaunchAtLoginService.swift` | I | Inventory only. |
| `PermissionService.swift` | I | Inventory only. |
| `README.md` | S Δ | Subsystem event-tap and cursor-interruption rules. |
| `SelectionCaptureService.swift` | S Δ | Latest synthetic posting helper diff. |
| `SelectionReplacementService.swift` | S Δ | Latest synthetic posting helper diff. |
| `StreamingCursorInserter.swift` | S Δ | Latest diff plus interruption/replay/failed-drain and stop paths. |
| `StreamingCursorScheduler.swift` | I | Inventory only. |
| `SystemMediaController.swift` | I | Inventory only. |

### `Sources/MacParakeet`

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `App/AppEnvironmentConfigurer.swift` | S Δ | Latest diff and relevant capture/scheduler wiring only. |
| `App/AppHotkeyCoordinator.swift` | I | Inventory only. |
| `App/DebugDictationPreviewQA.swift` | I | Inventory only. |
| `App/DictationFlowCoordinator.swift` | S Δ | Latest URL-control diff; full dictation coordinator not audited. |
| `App/DictationMediaPauseCoordinator.swift` | I | Inventory only. |
| `App/DictationURLCommand.swift` | S Δ | Parser, bounded launch router and state action matrix. |
| `App/MeetingAudioRetentionSweepCoordinator.swift` | I | Inventory only. |
| `App/MeetingAutoStartCoordinator.swift` | S | Start/stop, coalesced fetch/reconcile, timer/countdown/eligibility and selected reminders. |
| `App/MeetingAutoStopCoordinator.swift` | I | Inventory only. |
| `App/MeetingFinalizationReconciler.swift` | I | Inventory only. |
| `App/MeetingRecordingFlowCoordinator.swift` | S Δ | Latest diff plus stop/save/enqueue and source-only retry branches; remaining coordinator not exhaustive. |
| `App/MeetingRecoveryCoordinator.swift` | I | Inventory only. |
| `App/MeetingSourceLossNoticePresenter.swift` | I | Inventory only. |
| `App/MeetingSplitFinalizationReconciliationCoordinator.swift` | I | Inventory only. |
| `App/MeetingTranscriptionQueue.swift` | S Δ | Entire queue: admission lease, FIFO preparation, row persistence, failure and settlement. |
| `App/MeetingURLCommand.swift` | I | Inventory only. |
| `AppDelegate.swift` | S | Selected quit, URL dispatch and capture shutdown boundaries. |
| `Hotkey/GlobalShortcutManager.swift` | S Δ | Latest marker filter diff. |
| `Hotkey/HotkeyManager.swift` | S Δ | Latest physical Fn/session-event and marker filtering diff. |
| `Hotkey/HotkeyPeerInputPolicy.swift` | I | Inventory only. |
| `Hotkey/HotkeyTapFilter.swift` | I | Inventory only. |
| `Hotkey/ModifierKeyMatcher.swift` | I | Inventory only. |
| `Hotkey/TransformsHotkeyRegistry.swift` | S Δ | Latest marker filter diff. |
| `Hotkey/TransformsShortcutAlias.swift` | I | Inventory only. |
| `Onboarding/OnboardingHotkeyPreviewController.swift` | I | Inventory only. |

### Associated tests

Paths below are relative to `Tests/MacParakeetTests/`. Selected assertion review is explicit; every other entry is inventory only, even where test names were searched.

| File | Coverage | Inspected boundary |
| --- | --- | --- |
| `Audio/AudioCaptureDiagnosticsTests.swift` | I | Inventory only; not run. |
| `Audio/AudioChunkerTests.swift` | I | Inventory only; not run. |
| `Audio/AudioDeviceManagerTransportTests.swift` | I | Inventory only; not run. |
| `Audio/AudioEngineLifecycleDiagnosticsTests.swift` | I | Inventory only; not run. |
| `Audio/AudioFileConverterTests.swift` | I | Inventory only; not run. |
| `Audio/AudioFileEnumeratorTests.swift` | I | Inventory only; not run. |
| `Audio/AudioLifecycleLogCorrelationTests.swift` | I | Inventory only; not run. |
| `Audio/AudioRecorderFormatChangeTests.swift` | I | Inventory only; not run. |
| `Audio/DiagnosticLogScopeTests.swift` | I | Inventory only; not run. |
| `Audio/DictationSoundTests.swift` | I | Inventory only; not run. |
| `Audio/ExtractChannelZeroTests.swift` | I | Inventory only; not run. |
| `Audio/FFmpegAudioTrackProbeTests.swift` | I | Inventory only; not run. |
| `Audio/FixedMeetingLiveAudioChunkerTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingAudioCaptureServiceTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingAudioFileTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingAudioStorageWriterTests.swift` | S | Assertions at 157–245: exactly-once report, timeout registry retention, unwritten-source ownership and late callbacks. |
| `Audio/MeetingIndependentSourceStartupTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingMicHealthMonitorTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingMicrophoneStartRecoveryTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingSourceStartupHealthTests.swift` | I | Inventory only; not run. |
| `Audio/MeetingVADChunkingSimulatorTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneCaptureTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneEngineLifecycleDiagnosticsTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneEnginePlatformConfigChangeRecoveryTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneEnginePlatformStartupReadinessTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneEnginePrewarmRoutingTests.swift` | I | Inventory only; not run. |
| `Audio/MicrophoneEngineRealPlatformTests.swift` | I | Inventory only; not run. |
| `Audio/MockAudioProcessor.swift` | I | Inventory only; not run. |
| `Audio/MutableMicrophoneTapHandlerTests.swift` | I | Inventory only; not run. |
| `Audio/ObjCExceptionBridgeTests.swift` | I | Inventory only; not run. |
| `Audio/PCMBufferToSampleBufferTests.swift` | I | Inventory only; not run. |
| `Audio/ScreenCaptureLifecycleTests.swift` | I | Inventory only; not run. |
| `Audio/SharedMicrophoneQueueDiagnosticsTests.swift` | I | Inventory only; not run. |
| `Audio/SharedMicrophoneStreamTests.swift` | I | Inventory only; not run. |
| `Audio/SpeechBoundaryMeetingLiveAudioChunkerTests.swift` | I | Inventory only; not run. |
| `Calendar/MeetingAutoStartCoordinatorTests.swift` | S | Selected assertions at 510–585: fetch coalescing and unrelated-skip countdown. |
| `Calendar/MeetingLinkParserTests.swift` | I | Inventory only; not run. |
| `Calendar/MeetingMonitorTests.swift` | I | Inventory only; not run. |
| `Calendar/MockCalendarService.swift` | S | Held fetch/continuation test double. |
| `DictationFlow/DictationFlowCoordinatorLoadCaptionTests.swift` | I | Inventory only; not run. |
| `DictationFlow/DictationFlowCoordinatorTests.swift` | I | Inventory only; not run. |
| `DictationFlow/DictationFlowStateMachineTests.swift` | I | Inventory only; not run. |
| `DictationFlow/DictationMediaPauseCoordinatorTests.swift` | I | Inventory only; not run. |
| `DictationFlow/DictationOverlayLayoutTests.swift` | I | Inventory only; not run. |
| `DictationFlow/DictationURLCommandTests.swift` | I | Inventory only; not run. |
| `Hotkey/FnKeyStateMachineTests.swift` | I | Inventory only; not run. |
| `Hotkey/GlobalShortcutManagerTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyConflictPolicyTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyGestureControllerTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyManagerTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyPeerInputPolicyTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyTapFilterTests.swift` | I | Inventory only; not run. |
| `Hotkey/HotkeyTriggerTests.swift` | I | Inventory only; not run. |
| `Hotkey/KeyCodeNamesTests.swift` | I | Inventory only; not run. |
| `Hotkey/SyntheticPasteHotkeyTests.swift` | I | Inventory only; not run. |
| `Hotkey/TransformsHotkeyRegistryTests.swift` | I | Inventory only; not run. |
| `Integration/DictationFlowTests.swift` | I | Inventory only; not run. |
| `MeetingRecordingFlow/MeetingAutoStopCoordinatorTests.swift` | I | Inventory only; not run. |
| `MeetingRecordingFlow/MeetingRecordingFlowCoordinatorTests.swift` | I | Inventory only; not run. |
| `MeetingRecordingFlow/MeetingRecordingFlowStateMachineTests.swift` | I | Inventory only; not run. |
| `MeetingRecordingFlow/MeetingSystemAudioSignalVerdictTests.swift` | I | Inventory only; not run. |
| `MeetingRecordingFlow/MeetingTranscriptionQueueTests.swift` | S | Selected fixture/assertions: FIFO preparation, failed preparation retains sources and releases ownership. |
| `MeetingRecordingFlow/MeetingURLCommandTests.swift` | I | Inventory only; not run. |
| `Onboarding/OnboardingHotkeyPreviewControllerTests.swift` | I | Inventory only; not run. |
| `STT/AsyncPermitTests.swift` | I | Inventory only; not run. |
| `STT/CohereTranscribeEngineTests.swift` | I | Inventory only; not run. |
| `STT/CustomVocabularyBoostingTests.swift` | I | Inventory only; not run. |
| `STT/MeetingSpeechPlanTests.swift` | I | Inventory only; not run. |
| `STT/MockSTTClient.swift` | I | Inventory only; not run. |
| `STT/ModelDeletionTests.swift` | I | Inventory only; not run. |
| `STT/NemotronEnglishEngineLiveDictationTests.swift` | I | Inventory only; not run. |
| `STT/NemotronEnglishEngineLoadGatingTests.swift` | I | Inventory only; not run. |
| `STT/OrukeetModelStoreTests.swift` | I | Inventory only; not run. |
| `STT/ParakeetTDTASRConfigTests.swift` | I | Inventory only; not run. |
| `STT/ParakeetUnifiedEngineDictationPadTests.swift` | I | Inventory only; not run. |
| `STT/ParakeetUnifiedEngineLiveDictationTests.swift` | I | Inventory only; not run. |
| `STT/STTClientTests.swift` | I | Inventory only; not run. |
| `STT/STTRuntimeDictationPadTests.swift` | I | Inventory only; not run. |
| `STT/STTRuntimeInferenceGatingTests.swift` | I | Inventory only; not run. |
| `STT/STTSchedulerTests.swift` | I | Inventory only; not run. |
| `STT/STTWordTimingBuilderTests.swift` | I | Inventory only; not run. |
| `STT/SpeechEngineActivityTests.swift` | I | Inventory only; not run. |
| `STT/SpeechEngineCapabilitiesTests.swift` | I | Inventory only; not run. |
| `STT/SpeechEnginePreferenceTests.swift` | I | Inventory only; not run. |
| `STT/WhisperLanguageCatalogTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingArtifactStoreTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingAudioPairJoinerTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingAudioRetentionPolicyTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingAudioRetentionSweeperTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingAutoStopPolicyTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingAutomationHookRunnerTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingCaptureReportTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingChunkResultBufferTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingCleanedMicRendererTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingCleanedMicrophoneReadinessPolicyTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingDecodedAudioTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingMarkdownRendererClipboardTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingMediaMutationLeaseTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingNotesFileTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingPlaybackArtifactBuilderTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingPreviewIngressQueueTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingCrashRecoveryTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingLockFileStoreTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingOutputTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingRecoveryServiceTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingServiceTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingRecordingSettlementTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingTitleGeneratorTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingTranscriptAssemblerTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingTranscriptFinalizerSpeakerTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingTranscriptSourceReconcilerTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingTranscriptVocabularyApplierTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/MeetingVADLaunchPrepTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/TranscriptionAssetCleanupCleanedMicTests.swift` | I | Inventory only; not run. |
| `Services/MeetingRecording/TranscriptionAssetCleanupMutationLeaseTests.swift` | I | Inventory only; not run. |
| `Services/System/AccessibilityServiceTests.swift` | I | Inventory only; not run. |
| `Services/System/AppGeneratedKeyboardEventsTests.swift` | I | Inventory only; not run. |
| `Services/System/BackgroundEventTapTests.swift` | I | Inventory only; not run. |
| `Services/System/ClipboardServiceTests.swift` | I | Inventory only; not run. |
| `Services/System/EventTapTeardownTests.swift` | I | Inventory only; not run. |
| `Services/System/MockClipboardService.swift` | I | Inventory only; not run. |
| `Services/System/SelectionCaptureServiceTests.swift` | I | Inventory only; not run. |
| `Services/System/SelectionReplacementServiceTests.swift` | I | Inventory only; not run. |
| `Services/System/StreamingCursorInserterTests.swift` | S | Assertions at 235–277: failed interrupt drain never retries and prevents full-paste fallback. |
| `Services/System/StreamingCursorSchedulerTests.swift` | I | Inventory only; not run. |
| `ViewModels/TranscriptionMeetingFinalizationRetryTests.swift` | S | Selected assertions: retry admission, duplicate suppression, completion/navigation and missing sources. |

### Supporting boundaries outside the owned inventory

- `Sources/CLI/Commands/RetranscribeCommand.swift`: source-only recovery check,
  archived meeting selection and retained-audio guard inspected.
- `Sources/CLI/Commands/CalendarCommand.swift`: read in the agent-interface lane;
  its raw event listing and skip annotations are intentionally broader than
  GUI reminder/auto-start eligibility.
- `Sources/MacParakeetCore/Services/Sharing/TranscriptionDeletionCoordinator.swift`:
  deletion ordering, media mutation lease and row removal inspected.
- `Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift`: selected
  full-folder/audio-only cleanup and lock refusal inspected.
- `spec/contracts/meeting-recovery-retention.md`: ownership, writer deadline,
  settlement, source-only recovery and retention sections inspected; the entire
  document was not independently revalidated clause by clause.
- `spec/contracts/dictation-url-control-v1.md` and
  `spec/contracts/meeting-url-control-v1.md`: grammar, consent, lifecycle,
  fire-and-forget limitations and verification boundaries read.
- `spec/contracts/meeting-artifacts-v1.md`, `audio-speaker-timeline-v1.md`,
  `file-transcription-audio-tracks.md`, `dictation-shortcuts.md` and
  `saved-audio-auto-prompt-completion.md`: inventoried as related contracts;
  not comprehensively reviewed in this lane.

No source edits are part of this report. Any follow-up changes need a separate
implementation review and current focused verification.
