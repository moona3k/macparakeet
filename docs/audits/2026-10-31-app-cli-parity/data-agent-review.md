# Data, processing, and agent boundary review

Date: 2026-10-31. Source baseline: `79cf1ca928b53c3853a99f6832c197d664dcdd78`.

This is a bounded source review, not certification of every inventoried file. It covers Core Database, TextProcessing, Licensing, Models, Services except MeetingRecording/System, and AskAgentHelper. No runtime source changed, Swift build or test suite ran, app launched, real provider contacted, or user database/audio accessed. The only execution was a Foundation regular-expression probe using synthetic strings. Existing documentation changes are outside this report's implementation scope.

## Findings

### P2: punctuation at a vocabulary rule's edge defeats standalone matching

`Sources/MacParakeetCore/TextProcessing/CustomWordReplacer.swift:39` and `TextProcessingPipeline.swift:213` unconditionally surround escaped literals with `\b`. A word boundary requires a transition between a word and non-word character. Consequently a trailing punctuation character followed by a space, or leading punctuation preceded by a space, cannot satisfy that boundary. The app accepts these entries: `Sources/MacParakeetViewModels/CustomWordsViewModel.swift:85–103` only trims and checks emptiness/duplicates, and `Models/CustomWord.swift` and `Models/TextSnippet.swift` impose no punctuation restriction.

A native `NSRegularExpression` probe via JXA/Foundation, using the exact pattern construction and case-insensitive option, returned:

| Literal | Input | Matches |
|---|---|---:|
| `C++` | `I use C++ today.` | 0 |
| `C#` | `I use C# today.` | 0 |
| `.NET` | `I use .NET today.` | 0 |
| `::sig` | `Thanks ::sig` | 0 |
| `hello` | `Say hello today.` | 1 |

This verifies the matching mechanism, not a complete GUI/CLI execution. A configured replacement for these words silently does nothing in ordinary standalone use. The same mechanism affects snippet triggers. The inspected `CustomWordReplacerTests` cover ordinary whole words, case, ordering, and literal replacement templates, but do not cover punctuation at a rule edge.

Bounded follow-up: define shared literal token-edge matching that supports punctuation while preserving the existing prohibition on interior-word replacements. Add punctuation-edge and Unicode/interior-word regression cases to the shared replacer and snippet pipeline tests. Do not simply remove all boundary checks. This predates the reviewed post-v0.8.10 changes; it is a codebase finding, not an attributed new regression.

### P2 follow-up: dictation deletion has inconsistent cleanup failure semantics

`Sources/MacParakeetViewModels/DictationHistoryViewModel.swift:619–635` ignores audio removal errors and then deletes the row. If the file operation fails but the database succeeds, saved audio remains without the history row that would let the user retry its deletion. Conversely, a database failure after successful file removal leaves a row without its recording. `Sources/CLI/Commands/HistoryCommand.swift:285–324` checks that audio is beneath the managed dictation directory and throws on removal failure before deleting the row. The GUI does not share either behavior.

`Sources/MacParakeetViewModels/SettingsViewModel.swift:1980–2003` logs a failure from either of two database deletes and still attempts to remove the entire audio directory; it suppresses filesystem failures and offers no failure result. The repository operations at `Database/DictationRepository.swift:279–287,322–325` are separate row transactions. Existing clear-all tests around `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift:1985–2050` cover successful visible/hidden row removal; the inspected deletion tests do not inject the two-sided file/database failures.

This is a failure-reporting, privacy-cleanup, and retryability issue. The user explicitly requested deletion, so successful removal of the target's audio is authorized; calling that removal itself unauthorized data loss would be misleading. No explicit dictation audio-first requirement was found in the inspected feature/data-model/deletion documentation. There is no atomic transaction spanning SQLite and files, and merely reversing the two operations moves the orphan risk. A follow-up should specify success/partial-failure behavior, preserve a retryable cleanup record or equivalent bounded recovery mechanism, use shared owned-path validation, and test file failure plus database failure. Do not make an unreviewed ordering change inside this documentation audit.

## Checks that did not produce findings

- Ask helper: `Sources/AskAgentHelper/src/main.js` exposes only the source list/search/read/summary bridge, bounded JSONL frames, turns, and tool budget. It does not expose a generic shell or arbitrary filesystem tool. `AskModelBridge.swift` validates typed arguments and uses a fixed corrective prompt; `AskWorkspaceService.swift` scopes sources and provider approval, renews a lease, and checks revisions/citations before saving. `AskConversationRepository.swift` validates optimistic revision, run authority, and source revisions in its write transaction. These checks refute a broad claim that an answer can freely save over a deleted or changed conversation. Live provider behavior and helper packaging were not exercised.
- Vocabulary backup: `VocabularyImportExportService.swift:256–308` checks replace-all preview state inside the same database transaction and preserves learned words when pruning manual entries. A generic stale-preview overwrite allegation is unsupported by this path.
- Speaker correction: selected apply/undo code in `SpeakerCorrectionService.swift` uses a transaction, source fingerprint/revision checks, journal entries, and derived-data invalidation. `SpeakerAttributionReadService.swift` supplies effective projections; legacy TEXT UUID handling in `SpeakerTranscriptionPersistence.swift` is intentional compatibility, not a malformed-key finding. The parent audit separately records consumers that omit these projections.
- Telemetry: `TelemetryPolicy.swift` keeps GUI consent authoritative; `TelemetryService.swift:344–353` rechecks transport eligibility, queue generation, and consent at dispatch. The final opt-out event is an explicit documented exception. `CrashReportStore.swift` bounds queued reports and checks regular-file ownership/symlink properties. No claim of a complete telemetry payload audit is made.
- Licensing: `EntitlementsService.swift:50–62` intentionally keeps the free/GPL app unlocked; activation/validation plumbing remains for future use. It is not a current paywall defect. `KeychainKeyValueStore.swift` serializes process-wide interaction suppression and restores it, while updating existing items rather than deleting them first.
- Voiceprints: `SpeakerVoiceprintService.swift:247–257,358–383` gates matching/enrollment/recognition on consent; retained enrollment candidates have expiry, and `forgetAllVoices` explicitly removes profiles, candidates, and journal entries. This does not prove cross-process failure atomicity or native UI acceptance.
- Meeting import/split: selected import staging retains original source data and uses managed publication; split discard at `MeetingSplitService.swift:458–485` acquires operation/media leases, rechecks status, and removes only positively claimed child folders. A broad claim that discard deletes arbitrary existing folders is contradicted by the inspected path.
- Transforms: `TransformRunSerializer.swift` cancels and awaits the preceding operation before beginning a replacement. This addresses the naive same-app overlapping-run concern; native Accessibility/clipboard races remain outside this lane.
- Voice control: selected `ScreenTextSource.swift` code rechecks the foreground window around capture/OCR and redacts overlapping windows; `VoiceControlTraceStore.swift:253–288` rejects a pre-created symlink or another account's directory for the public pointer. Trace files deliberately contain command/window/static text; speech timing metrics contain durations and numeric overlap, not transcript strings. This is a local sensitive diagnostic surface, not proof of remote transmission.
- Video: `VideoStreamService.swift:186–228` runs explicit executable arguments, drains subprocess output to files, uses the shared cancellable waiter, and bounds returned output/error excerpts. The subprocess tree and live media sites were not exercised.
- Models/capture/dictation/discover: `DictationSoundConfiguration` normalizes finite volume and validates generated custom basenames. `DictationStopDecision` makes in-flight start defer a stop. The inspected passthrough mic conditioner preserves samples; broader DSP behavior was not revalidated. Discover feedback sends explicitly submitted message plus system metadata to its configured endpoint; no automatic transcript-send path was identified in that service.

## Coverage and limits

The inventory below is exhaustive for tracked files in the assigned source directories; it is not a claim of exhaustive reading. Deeper reads included the Database/TextProcessing/Licensing local guides; CustomWordReplacer and its tests; Ask helper JS/README and AskConversationRepository; selected AskWorkspaceService, AskModelBridge and PiAskAgent sections; SpeakerCorrectionService and SpeakerAttributionReadService critical paths; SpeakerTranscriptionPersistence; VocabularyImportExportService decode/export/apply paths; TelemetryPolicy, KeychainKeyValueStore, EntitlementsService, CrashReportStore; TranscriptionDeletionCoordinator; TransformRunSerializer and selected TransformExecutor; selected MeetingImportService, MeetingSplitService, SpeakerVoiceprintService and retention; ScreenTextSource and voice trace pointer handling; and the exact deletion call sites above.

Symbol/control-flow scans covered the remaining service families, repositories, and model inventory. Associated test names were inventoried across Ask, vocabulary backup, speaker correction/voiceprints, telemetry, transforms, meeting split/import, voice control, and view-model deletion; only the tests specifically discussed above were read in detail. Relevant sections of `spec/contracts/ask-workspace.md`, `telemetry-v1.md`, and deletion/recovery feature/data-model docs were cross-checked. No test suite ran. Neither dormant feature availability nor native/provider/hardware acceptance is established here.

The `v0.8.10..HEAD` owned-file change list was checked. LLMService/CardGenerationService diffs were read; DictationSoundConfiguration and VoiceControlSpeechTiming were read; selected changed VideoStreamService and voice trace/speech-session code was inspected. Remaining changed voice-control adapters and timing integration received symbol/diff-level review, not complete path execution. No additional regression is asserted from those limited reads. Source files not named in the deeper-read list remain inventory/scan coverage only.

A stale task-routing sentence in TextProcessing/README was reported to the parent and reconciled in the documentation diff; it is not an additional runtime finding. Jev was not used: this was source tracing and adversarial review, with deterministic inventory/probe output, not delegated semantic ranking or classification.

## Focused regex follow-up qualification

The existing governing description is whole-word, case-insensitive replacement (`TextProcessing/README.md:64`; `CustomWordReplacer.swift:11–20`). The latter explicitly spells the old implementation as `\b…\b`, so a fix should deliberately clarify the semantic contract rather than pretend punctuation behavior is unchanged. `spec/02-features.md:937–967` describes domain vocabulary/proper nouns and natural spoken snippet phrases. `::sig` demonstrates the accepted-input mechanism but is not the primary documented speech-trigger use case. Technical vocabulary such as `C++`, `C#`, and `.NET` is the stronger example.

All production direct call sites found by repository search:

- `TextProcessingPipeline.swift:157–158` delegates custom words to `CustomWordReplacer`; `process` invokes it at line 33 and text-snippet expansion at line 49.
- `Services/MeetingRecording/MeetingTranscriptVocabularyApplier.swift:37` constructs the same shared replacer for meeting transcript/word-token projection. The custom-word fix therefore affects both dictation cleanup and meeting vocabulary, and needs tests for both.
- `TextProcessingPipeline.swift:213` separately constructs snippet regexes. It should share the same literal-edge helper if the contract adopts it.
- Trailing **action** snippets use their own whitespace/start plus terminal-punctuation pattern at lines 176–179. They are not affected by the reported `\b` defect and should retain their intentional terminal semantics. Filler patterns also use `\b`, but their controlled literals have word-character edges; there is no demonstrated filler defect here.

Candidate to evaluate in a focused change: `(?<!\w)<escaped literal>(?!\w)` with the same Foundation regex case-insensitive option and literal replacement escaping. This asks whether an adjacent character is a Unicode regex word character, independent of whether the literal starts/ends in punctuation. It blocks letters, digits, combining marks, connectors, and joiners in the tested cases. It is a bounded candidate, not a complete Unicode specification or a guarantee about arbitrary programming-language identifier grammars. For example, how `C++` should behave next to another `+` needs an explicit punctuation-neighbor expectation; no broad symbol-tokenizer redesign is implied.

The expanded probe also revealed the inverse of the missing-match problem: old `\b` matches `C++` inside `C++17`, `C++_`, and `C++é`, and `.NET` inside `x.NET`, precisely because the punctuation edge reverses the desired transition. The candidate blocks those matches.

Run this synthetic Foundation probe without building the app:

```sh
osascript -l JavaScript <<'JS'
ObjC.import('Foundation');
const cases = [
 ['C++','I use C++ today.',1],['C#','I use C# today.',1],
 ['.NET','I use .NET today.',1],['::sig','Thanks ::sig',1],
 ['cap','cap capacity recap cap_ cap2',1],
 ['hello','(HELLO), hello!',2],
 ['mac parakeet','use MAC PARAKEET today.',1],
 ['C++','XC++ C++17 C++_ C++é',0],
 ['.NET','x.NET .NETwork .NET_ .NET2',0],
 ['::sig','x::sig ::signal ::sig_',0],
 ['café','CAFÉ caféteria xcafé café_',1],
 ['e\u0301','e\u0301 e\u0301x xe\u0301',1],
 ['東京','東京 東京都 新東京',1],
 ['a.b','(A.B) aXb a.bx xa.b',1],
 ['cap','cap\u0301 cap\u200D cap\u203F cap\u0662',0]
];
JSON.stringify(cases.map(c=>{
 const literal=ObjC.unwrap($.NSRegularExpression.escapedPatternForString(c[0]));
 function count(pattern){
  const regex=$.NSRegularExpression.regularExpressionWithPatternOptionsError(pattern,1,null);
  const input=$(c[1]);
  return Number(regex.numberOfMatchesInStringOptionsRange(input,0,$.NSMakeRange(0,input.length)));
 }
 return {literal:c[0],input:c[1],before:count('\\b'+literal+'\\b'),
  candidate:count('(?<!\\w)'+literal+'(?!\\w)'),expected:c[2]};
}));
JS
```

Observed old match counts in case order: `0,0,0,0,1,2,1,3,1,1,1,1,1,1,0`.
Observed candidate counts: `1,1,1,1,1,2,1,0,0,0,1,1,1,1,0`, all equal to the explicit expected counts. This is executable mechanism evidence; no source or tests were changed. A focused implementation should still run shared replacer/pipeline tests and meeting-vocabulary tests, including literal replacement templates, disabled/nil rules, ordering, and unchanged action-snippet behavior.

## Tracked source inventory

Total: **251 tracked files**. Filenames are relative to each directory heading.

### `Sources/AskAgentHelper` (4)

- `.gitignore`
- `README.md`
- `package-lock.json`
- `package.json`

### `Sources/AskAgentHelper/legal` (1)

- `Pi-MIT-LICENSE`

### `Sources/AskAgentHelper/scripts` (1)

- `notices.js`

### `Sources/AskAgentHelper/src` (1)

- `main.js`

### `Sources/AskAgentHelper/test` (1)

- `helper.test.js`

### `Sources/MacParakeetCore/Database` (32)

- `AIFormatterProfileRepository.swift`
- `AskConversationRepository.swift`
- `CardRepository.swift`
- `ChatConversationRepository.swift`
- `CustomWordRepository.swift`
- `DatabaseManager.swift`
- `DictationRepository.swift`
- `LLMRunRepository.swift`
- `MeetingLabelRepository.swift`
- `MeetingSplitRepository.swift`
- `MeetingTypeRepository.swift`
- `PromptCollectionRepository.swift`
- `PromptEditingService.swift`
- `PromptLabelPolicyRepository.swift`
- `PromptMeetingPolicyRepository.swift`
- `PromptRepository.swift`
- `PromptResultRepository.swift`
- `PromptVersionRepository.swift`
- `QuickPromptRepository.swift`
- `README.md`
- `SegmentRepository.swift`
- `SharePublicationRepository.swift`
- `SpeakerCorrectionRepository.swift`
- `SpeakerEmbeddingCandidateRepository.swift`
- `SpeakerMatchJournalRepository.swift`
- `SpeakerProfileRepository.swift`
- `SpeakerTranscriptionPersistence.swift`
- `TextSnippetRepository.swift`
- `TranscriptionLibraryQuery.swift`
- `TranscriptionMeetingLabelRepository.swift`
- `TranscriptionRepository.swift`
- `TransformHistoryRepository.swift`

### `Sources/MacParakeetCore/Licensing` (6)

- `Entitlements.swift`
- `EntitlementsService.swift`
- `KeyValueStore.swift`
- `KeychainKeyValueStore.swift`
- `LemonSqueezyLicenseAPI.swift`
- `README.md`

### `Sources/MacParakeetCore/Models` (50)

- `AIFormatterProfile.swift`
- `AIFormatterProfileMatcher.swift`
- `AppPromptContext.swift`
- `AskWorkspace.swift`
- `AudioSource.swift`
- `BranchingRecordingCoverRecipe.swift`
- `Card.swift`
- `ChatCompletionsModelPolicy.swift`
- `ChatConversation.swift`
- `CustomWord.swift`
- `DailyDictationStat.swift`
- `Dictation.swift`
- `DictationResult.swift`
- `DictationSoundConfiguration.swift`
- `DiscoverContent.swift`
- `KeyAction.swift`
- `KeyboardShortcut.swift`
- `LLMFormatterResult.swift`
- `LLMProvider.swift`
- `LLMResult.swift`
- `LLMRun.swift`
- `LLMTypes.swift`
- `MeetingAIOutputLanguagePolicy.swift`
- `MeetingCalendarSnapshot.swift`
- `MeetingClassification.swift`
- `MeetingSplitProvenance.swift`
- `MeetingStartContext.swift`
- `Prompt.swift`
- `PromptCollection.swift`
- `PromptInferenceSettings.swift`
- `PromptLabelPolicy.swift`
- `PromptMeetingPolicy.swift`
- `PromptResult.swift`
- `PromptResultFreshness.swift`
- `PromptSystemPromptAssembler.swift`
- `PromptTemplateRenderer.swift`
- `PromptVersion.swift`
- `QuickPrompt.swift`
- `QuickPromptBundle.swift`
- `Segment.swift`
- `SharePublication.swift`
- `SpeakerCorrection.swift`
- `SpeakerEmbeddingCandidate.swift`
- `SpeakerProfile.swift`
- `TextSnippet.swift`
- `Transcription.swift`
- `TranscriptionProgress.swift`
- `TransformHistoryEntry.swift`
- `TransformShortcutReservedHotkey.swift`
- `VocabularyBundle.swift`

### `Sources/MacParakeetCore/Services` (32)

- `ANEInferenceGate.swift`
- `AppPaths.swift`
- `AutoSaveService.swift`
- `BinaryBootstrap.swift`
- `BuildIdentity.swift`
- `DAPTDocumentRenderer.swift`
- `DerivedFieldsBackfillService.swift`
- `ExportService.swift`
- `FeedbackService.swift`
- `KnowledgeLayerMutationService.swift`
- `MediaMetadataExtractor.swift`
- `MeetingClassificationService.swift`
- `PasteShortcutKeyResolver.swift`
- `PodcastAudioDownloader.swift`
- `PodcastDirectoryService.swift`
- `PodcastEpisodeResolver.swift`
- `PodcastFeedParser.swift`
- `PodcastQueryResolver.swift`
- `PromptApplicabilityResolver.swift`
- `PromptAutoRunSelector.swift`
- `PromptDiffService.swift`
- `PromptLabelApplicabilityResolver.swift`
- `SavedAudioAutoPromptCompletionService.swift`
- `SpeakerCorrectionService.swift`
- `SystemInfo.swift`
- `ThumbnailCacheService.swift`
- `ThumbnailImageDecoder.swift`
- `TranscriptionService.swift`
- `VideoStreamService.swift`
- `VocabularyImportExportService.swift`
- `YouTubeAudioPlaybackConverter.swift`
- `YouTubeDownloader.swift`

### `Sources/MacParakeetCore/Services/Ask` (6)

- `AskAgentTypes.swift`
- `AskModelBridge.swift`
- `AskSourceService.swift`
- `AskWorkspaceService.swift`
- `AskWorkspaceServing.swift`
- `PiAskAgent.swift`

### `Sources/MacParakeetCore/Services/Capture` (5)

- `CaptureOrchestrator.swift`
- `LiveChunkTranscriber.swift`
- `MeetingEchoDelayEstimator.swift`
- `MeetingEchoSuppressionRuntime.swift`
- `MicConditioner.swift`

### `Sources/MacParakeetCore/Services/Diarization` (11)

- `DiarizationService.swift`
- `MeetingSpeakerPrior.swift`
- `NemotronDiarizationModelStore.swift`
- `NemotronDiarizationService.swift`
- `SpeakerAttributionReadService.swift`
- `SpeakerAttributionResolver.swift`
- `SpeakerEmbedding.swift`
- `SpeakerMerger.swift`
- `SpeakerVoiceprintMatcher.swift`
- `SpeakerVoiceprintRetention.swift`
- `SpeakerVoiceprintService.swift`

### `Sources/MacParakeetCore/Services/Dictation` (4)

- `DictationService.swift`
- `DictationServiceSession.swift`
- `DictationStopDecision.swift`
- `LiveTranscriptStabilizer.swift`

### `Sources/MacParakeetCore/Services/Discover` (2)

- `DiscoverService.swift`
- `DiscoverThoughtsService.swift`

### `Sources/MacParakeetCore/Services/LLM` (21)

- `AnthropicLLMHTTPAdapter.swift`
- `AppleIntelligenceAvailability.swift`
- `AppleIntelligenceGenerating.swift`
- `AppleIntelligenceLLMClient.swift`
- `CardGenerationService.swift`
- `FoundationModelsAppleIntelligenceGenerator.swift`
- `InProcessLLMClient.swift`
- `InProcessModelDownloader.swift`
- `LLMClient.swift`
- `LLMConfigStore.swift`
- `LLMError.swift`
- `LLMExecutionContext.swift`
- `LLMHTTPTransport.swift`
- `LLMRunRecorder.swift`
- `LLMService.swift`
- `LocalCLIExecutor.swift`
- `LocalCLILLMClient.swift`
- `LocalLLMRuntime.swift`
- `OllamaLLMHTTPAdapter.swift`
- `OpenAICompatibleLLMHTTPAdapter.swift`
- `RoutingLLMClient.swift`

### `Sources/MacParakeetCore/Services/MeetingImport` (2)

- `MeetingImportResult.swift`
- `MeetingImportService.swift`

### `Sources/MacParakeetCore/Services/MeetingSplit` (7)

- `MeetingSplitAudioExporter.swift`
- `MeetingSplitChildFolderClaim.swift`
- `MeetingSplitChildProcessingLease.swift`
- `MeetingSplitEligibility.swift`
- `MeetingSplitOperationLease.swift`
- `MeetingSplitService.swift`
- `MeetingSplitSourceRange.swift`

### `Sources/MacParakeetCore/Services/Sharing` (10)

- `ShareBundle.swift`
- `ShareCoordinator.swift`
- `ShareCredentialStore.swift`
- `ShareCryptography.swift`
- `ShareLink.swift`
- `ShareOwnerCredentials.swift`
- `ShareProjection.swift`
- `ShareRemoteClient.swift`
- `ShareServiceModels.swift`
- `TranscriptionDeletionCoordinator.swift`

### `Sources/MacParakeetCore/Services/Telemetry` (11)

- `CrashAudioContext.swift`
- `CrashContextArchive.swift`
- `CrashDiagnosticMetadata.swift`
- `CrashReportStore.swift`
- `CrashReporter.swift`
- `Observability.swift`
- `TelemetryAppCategory.swift`
- `TelemetryErrorClassifier.swift`
- `TelemetryEvent.swift`
- `TelemetryPolicy.swift`
- `TelemetryService.swift`

### `Sources/MacParakeetCore/Services/Transforms` (3)

- `MenuBarTransformCatalog.swift`
- `TransformExecutor.swift`
- `TransformRunSerializer.swift`

### `Sources/MacParakeetCore/Services/VoiceControl` (27)

- `AXTreeWalk.swift`
- `GUIMutationArbiter.swift`
- `JevDecisionClient.swift`
- `NativeVoiceControlAdapter.swift`
- `README.md`
- `ScreenTextSource.swift`
- `SpokenDateParser.swift`
- `VoiceControlAppActivation.swift`
- `VoiceControlCommandRouter.swift`
- `VoiceControlCredentialStore.swift`
- `VoiceControlDiagnostics.swift`
- `VoiceControlFlightPlan.swift`
- `VoiceControlInbox.swift`
- `VoiceControlLocalTools.swift`
- `VoiceControlMachine.swift`
- `VoiceControlNamedPageAction.swift`
- `VoiceControlSessionGrammar.swift`
- `VoiceControlSpeechPreview.swift`
- `VoiceControlSpeechRevocation.swift`
- `VoiceControlSpeechSession.swift`
- `VoiceControlSpeechTiming.swift`
- `VoiceControlTraceStore.swift`
- `VoiceControlTurnRunner.swift`
- `VoiceControlTypes.swift`
- `VoiceControlUtterance.swift`
- `VoiceControlWebDestination.swift`
- `VoiceControlWebQuery.swift`

### `Sources/MacParakeetCore/TextProcessing` (14)

- `AIFormatter.swift`
- `AIFormatterSmartDefaults.swift`
- `CustomWordReplacer.swift`
- `README.md`
- `SpokenPunctuation.swift`
- `TextProcessingPipeline.swift`
- `TextProcessingResult.swift`
- `TextRefinementService.swift`
- `TranscriptAIContextFormatter.swift`
- `TranscriptCueBuilder.swift`
- `TranscriptDerivers.swift`
- `TranscriptFormatter.swift`
- `TranscriptParagraphBuilder.swift`
- `TranscriptReadingEdit.swift`

