# Traceability Matrix

> Status: **ACTIVE** — Maps requirements to test files and source files.

This matrix traces each requirement ID from `requirements.yaml` to its implementing source files and test coverage.

## v0.1 Core MVP

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DICT-001 | `MacParakeetCore/Services/Dictation/DictationService.swift`, `MacParakeetCore/DictationFlow/` | `DictationServiceTests.swift` |
| REQ-DICT-002 | `MacParakeet/App/AppHotkeyCoordinator.swift`, `MacParakeet/Hotkey/HotkeyManager.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeetCore/STT/FnKeyStateMachine.swift`, `MacParakeetCore/STT/HotkeyGestureController.swift` | `AppHotkeyCoordinatorTests.swift`, `HotkeyManagerTests.swift`, `HotkeyGestureControllerTests.swift`, `FnKeyStateMachineTests.swift`, `SettingsViewModelTests.swift` |
| REQ-DICT-003 | `MacParakeetCore/Services/System/ClipboardService.swift`, `MacParakeet/App/DictationFlowCoordinator.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeetViewModels/SettingsViewModel.swift` | `ClipboardServiceTests.swift`, `DictationFlowCoordinatorLoadCaptionTests.swift`, `SettingsViewModelTests.swift` |
| REQ-TRANS-001 | `MacParakeetCore/Services/TranscriptionService.swift` | `TranscriptionServiceTests.swift` |
| REQ-UI-001 | `MacParakeet/Views/Dictation/DictationOverlayView.swift` | (ViewModel tests) |
| REQ-UI-002 | `MacParakeet/Views/Dictation/IdlePillView.swift` | (ViewModel tests) |
| REQ-UI-003 | `MacParakeet/Views/MainWindowView.swift` | (ViewModel tests) |
| REQ-DATA-001 | `MacParakeetCore/Database/DictationRepository.swift`, `MacParakeetViewModels/DictationHistoryViewModel.swift`, `MacParakeet/Views/History/DictationHistoryView.swift` | `DictationRepositoryTests.swift`, `DictationHistoryViewModelTests.swift` |
| REQ-DATA-002 | `MacParakeetCore/Database/DatabaseManager.swift` | `DatabaseManagerTests.swift` |
| REQ-STT-001 | `MacParakeet/App/AppEnvironment.swift`, `MacParakeetCore/STT/STTRuntime.swift`, `MacParakeetCore/STT/STTScheduler.swift`, `MacParakeetCore/STT/STTClient.swift`, `MacParakeetCore/Services/Dictation/DictationService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetCore/Services/TranscriptionService.swift`, `MacParakeetViewModels/OnboardingViewModel.swift` | `STTSchedulerTests.swift`, `STTClientTests.swift`, `DictationServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `TranscriptionServiceTests.swift`, `OnboardingViewModelTests.swift` |
| REQ-EXP-001 | `MacParakeetCore/Services/ExportService.swift` | `ExportServiceTests.swift` |

## v0.2 Clean Pipeline

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-PIPE-001 | `MacParakeetCore/TextProcessing/TextProcessingPipeline.swift` | `TextProcessingPipelineTests.swift` |
| REQ-PIPE-002 | `MacParakeet/Views/Vocabulary/` | `CustomWordTests.swift`, `SnippetTests.swift` |

## v0.3 YouTube & Export

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-YT-001 | `MacParakeetCore/Services/YouTubeDownloader.swift`, `MacParakeetCore/Utilities/YouTubeURLValidator.swift` | `YouTubeDownloaderTests.swift`, `YouTubeURLValidatorTests.swift` |
| REQ-EXP-002 | `MacParakeetCore/Services/ExportService.swift` | `ExportServiceTests.swift` |

## v0.4 Polish & Launch

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DIAR-001 | `MacParakeetCore/Services/Diarization/DiarizationService.swift` | `DiarizationServiceTests.swift` |
| REQ-DICT-004 | `MacParakeet/Hotkey/HotkeyManager.swift`, `MacParakeet/Hotkey/GlobalShortcutManager.swift`, `MacParakeet/Hotkey/ModifierKeyMatcher.swift`, `MacParakeet/Views/Settings/HotkeyRecorderView.swift`, `MacParakeetCore/STT/HotkeyTrigger.swift`, `MacParakeetCore/STT/HotkeyGestureController.swift` | `HotkeyManagerTests.swift`, `GlobalShortcutManagerTests.swift`, `HotkeyTriggerTests.swift`, `HotkeyGestureControllerTests.swift`, `HotkeyRecorderViewTests.swift` |
| REQ-LLM-001 | `MacParakeetCore/Services/LLM/LLMService.swift`, `MacParakeetCore/Services/LLM/LLMClient.swift`, `MacParakeetCore/Services/LLM/LLMConfigStore.swift`, `MacParakeetCore/Services/LLM/RoutingLLMClient.swift`, `MacParakeetCore/Services/LLM/LocalCLILLMClient.swift` | `LLMServiceTests.swift`, `LLMClientTests.swift`, `LLMConfigStoreTests.swift`, `RoutingLLMClientTests.swift`, `LocalCLILLMClientTests.swift` |
| REQ-LLM-002 | `CLI/Commands/LLMChatCommand.swift`, `CLI/Commands/LLMSummarizeCommand.swift`, `CLI/Commands/LLMTestCommand.swift`, `CLI/Commands/LLMTransformCommand.swift`, `CLI/Commands/PromptsCommand.swift`, `MacParakeetCore/Models/LLMResult.swift`, `MacParakeetCore/Services/LLM/LLMClient.swift`, `MacParakeetCore/Services/LLM/LLMService.swift` | `LLMJSONOutputTests.swift`, `LLMResultTests.swift`, `LLMClientTests.swift`, `LLMServiceTests.swift` |
| REQ-LLM-003 | `MacParakeetCore/Models/LLMRun.swift`, `MacParakeetCore/Models/LLMFormatterResult.swift`, `MacParakeetCore/Database/DatabaseManager.swift`, `MacParakeetCore/Database/LLMRunRepository.swift`, `MacParakeetCore/Services/LLM/LLMRunRecorder.swift`, `MacParakeetCore/Services/LLM/LLMService.swift`, `MacParakeetCore/Services/Dictation/DictationService.swift`, `MacParakeetCore/Services/TranscriptionService.swift` | `LLMRunRepositoryTests.swift`, `LLMServiceTests.swift`, `DictationServiceTests.swift`, `TranscriptionServiceTests.swift` |
| REQ-LLM-004 | `MacParakeetCore/Models/AIFormatterProfile.swift`, `MacParakeetCore/Models/AIFormatterProfileMatcher.swift`, `MacParakeetCore/Models/AppPromptContext.swift`, `MacParakeetCore/Database/DatabaseManager.swift`, `MacParakeetCore/Database/AIFormatterProfileRepository.swift`, `MacParakeetCore/Services/Dictation/DictationService.swift`, `MacParakeetCore/Services/System/FocusedAppContextService.swift`, `MacParakeet/App/DictationFlowCoordinator.swift`, `MacParakeetViewModels/LLMSettingsViewModel.swift`, `MacParakeet/Views/Settings/LLMSettingsView.swift` | `AIFormatterProfileMatcherTests.swift`, `AIFormatterProfileRepositoryTests.swift`, `DictationRepositoryTests.swift`, `DictationServiceTests.swift`, `LLMSettingsViewModelTests.swift` |

## v0.5 Data & Reliability

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DICT-005 | `MacParakeetCore/Database/DictationRepository.swift` | `DictationRepositoryTests.swift` |
| REQ-DICT-006 | `MacParakeet/App/AppDelegate.swift`, `MacParakeet/App/OnboardingCoordinator.swift`, `MacParakeet/App/DictationFlowCoordinator.swift`, `MacParakeet/Views/Dictation/DictationOverlayController.swift`, `MacParakeet/Views/Dictation/DictationOverlayView.swift`, `MacParakeet/Views/Dictation/LoadingCaptionView.swift`, `MacParakeetCore/AppRuntimePreferences.swift`, `MacParakeetCore/Services/Dictation/DictationService.swift`, `MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | `DictationFlowCoordinatorLoadCaptionTests.swift`, `DictationServiceTests.swift`, `TelemetryServiceTests.swift` |
| REQ-DATA-003 | `MacParakeetCore/Database/ChatConversationRepository.swift`, `MacParakeetCore/Models/ChatConversation.swift` | `ChatConversationRepositoryTests.swift`, `TranscriptChatViewModelTests.swift` |
| REQ-YT-002 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-TRANS-003 | `MacParakeetCore/Services/MediaMetadataExtractor.swift`, `MacParakeetCore/Services/TranscriptionService.swift`, `MacParakeetCore/Services/ThumbnailCacheService.swift` | `MediaMetadataExtractorTests.swift`, `TranscriptionServiceTests.swift`, `ThumbnailCacheServiceTests.swift` |
| REQ-TRANS-004 | `MacParakeetCore/Audio/AudioFileEnumerator.swift`, `MacParakeetViewModels/TranscriptionViewModel.swift`, `MacParakeet/Views/Transcription/TranscribeView.swift`, `MacParakeet/Views/MainWindowView.swift`, `MacParakeet/App/MenuBarCoordinator.swift` | `AudioFileEnumeratorTests.swift`, `TranscriptionViewModelBatchTests.swift` |
| REQ-UI-006 | `MacParakeetViewModels/TranscriptionCompletionNotifier.swift`, `MacParakeetViewModels/TranscriptionViewModel.swift`, `MacParakeet/App/TranscriptionCompletionPresenter.swift`, `MacParakeet/App/AppEnvironmentConfigurer.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeet/Views/Settings/SettingsView.swift` | `TranscriptionCompletionNotifierTests.swift`, `TranscriptionViewModelBatchTests.swift` |
| REQ-DATA-004 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |

## v0.5 Video Player & UI Revamp

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-PLAY-001 | `MacParakeetCore/Services/VideoStreamService.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `VideoStreamServiceTests.swift`, `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-002 | `MacParakeet/Views/Components/AudioScrubberBar.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-003 | `MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-004 | `MacParakeet/Views/Components/PlaybackSpeedMenu.swift`, `MacParakeet/Views/Components/AudioScrubberBar.swift`, `MacParakeet/Views/Transcription/TranscriptionVideoPanel.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-UI-004 | `MacParakeet/Views/Transcription/TranscriptResultView.swift`, `MacParakeet/Views/Transcription/TranscriptionVideoPanel.swift` | (ViewModel tests) |
| REQ-LIB-001 | `MacParakeet/Views/Transcription/TranscriptionLibraryView.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-UI-005 | `MacParakeet/Views/Transcription/TranscribeView.swift`, `MacParakeet/Views/Transcription/YouTubeInputPanelView.swift`, `MacParakeet/Views/Transcription/PortalDropZone.swift` | (ViewModel tests) |

## v0.6 Meeting Recording Hardening

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-MEET-001 | `MacParakeetCore/Audio/MicrophoneCapture.swift`, `MacParakeetCore/Audio/SystemAudioStream.swift`, `MacParakeetCore/Audio/MeetingAudioCaptureService.swift`, `MacParakeetCore/Services/Capture/MicConditioner.swift`, `MacParakeetCore/Services/Capture/CaptureOrchestrator.swift`, `MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift` | `MeetingAudioCaptureServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `PCMBufferToSampleBufferTests.swift` |
| REQ-MEET-002 | `MacParakeetCore/Services/MeetingRecording/MeetingAudioPairJoiner.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift` | `MeetingAudioPairJoinerTests.swift`, `MeetingRecordingServiceTests.swift` |
| REQ-MEET-003 | `MacParakeet/Views/Transcription/TranscriptionLibraryView.swift`, `MacParakeet/Views/MeetingRecording/MeetingRowCard.swift`, `MacParakeet/Views/MeetingRecording/MeetingDateGroupHeader.swift`, `MacParakeetViewModels/TranscriptionLibraryViewModel.swift` | `TranscriptionLibraryViewModelTests.swift` |
| REQ-MEET-004 | `MacParakeetCore/Audio/AudioFileConverter.swift`, `MacParakeetCore/Audio/MeetingAudioStorageWriter.swift` | `AudioFileConverterTests.swift` |
| REQ-MEET-005 | `MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetCore/Models/Transcription.swift`, `MacParakeetCore/Database/DatabaseManager.swift`, `MacParakeet/App/AppEnvironment.swift`, `MacParakeet/App/AppEnvironmentConfigurer.swift`, `MacParakeet/AppDelegate.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeet/Views/MeetingRecording/MeetingRowCard.swift`, `MacParakeet/Views/Transcription/TranscriptResultView.swift`, `MacParakeet/Views/Transcription/TranscriptionThumbnailCard.swift` | `MeetingRecordingLockFileStoreTests.swift`, `MeetingRecordingRecoveryServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `MeetingRecordingCrashRecoveryTests.swift`, `DatabaseManagerTests.swift`, `TranscriptionModelTests.swift` |
| REQ-MEET-006 | `MacParakeetCore/Audio/MeetingAudioStorageWriter.swift`, `MacParakeetCore/Audio/PCMBufferToSampleBuffer.swift` | `PCMBufferToSampleBufferTests.swift`, `MeetingAudioStorageWriterTests.swift`, `MeetingRecordingCrashRecoveryTests.swift` |
| REQ-MEET-008 | `MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift`, `MacParakeet/Views/MeetingRecording/LiveNotesPaneView.swift`, `MacParakeet/Views/MeetingRecording/TranscriptTextView.swift`, `MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift`, `MacParakeetViewModels/MeetingRecordingPanelViewModel.swift`, `MacParakeetViewModels/TranscriptChatViewModel.swift` | `MeetingRecordingPanelViewModelTests.swift`, `TranscriptChatViewModelTests.swift` |
| REQ-MEET-009 | `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingNotesFile.swift`, `MacParakeetCore/Services/LLM/LLMService.swift`, `MacParakeetCore/Models/PromptTemplateRenderer.swift`, `MacParakeet/Views/Transcription/TranscriptResultView.swift`, `MacParakeetViewModels/MeetingNotesViewModel.swift`, `MacParakeetViewModels/TranscriptChatViewModel.swift` | `MeetingRecordingServiceTests.swift`, `MeetingRecordingRecoveryServiceTests.swift`, `MeetingNotesFileTests.swift`, `LLMServiceTests.swift`, `PromptTemplateRendererTests.swift`, `TranscriptChatViewModelTests.swift` |
| REQ-MEET-010 | `MacParakeetCore/Models/QuickPrompt.swift`, `MacParakeetCore/Models/QuickPromptBundle.swift`, `MacParakeetCore/Database/QuickPromptRepository.swift`, `MacParakeetCore/Database/DatabaseManager.swift`, `MacParakeetViewModels/QuickPromptsViewModel.swift`, `MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift`, `MacParakeet/Views/MeetingRecording/AskPromptsSheet.swift`, `CLI/Commands/QuickPromptsCommand.swift`, `CLI/MacParakeetCLI.swift` | `QuickPromptRepositoryTests.swift`, `QuickPromptBundleTests.swift`, `QuickPromptsViewModelTests.swift`, `QuickPromptsCommandTests.swift`, `DatabaseManagerTests.swift` |
| REQ-MEET-011 | `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetViewModels/MeetingRecordingPanelViewModel.swift`, `MacParakeetViewModels/MeetingRecordingPillViewModel.swift` | `MeetingRecordingServiceTests.swift`, `MeetingRecordingPanelViewModelTests.swift`, `MeetingRecordingPillViewModelTests.swift` |
| REQ-MEET-012 | `MacParakeetCore/Services/MeetingRecording/MeetingAudioFile.swift`, `MacParakeet/Views/Transcription/MeetingAudioActions.swift`, `MacParakeet/Views/Transcription/TranscriptionLibraryView.swift`, `MacParakeet/Views/Transcription/TranscriptResultView.swift` | `MeetingAudioFileTests.swift` |
| REQ-MEET-013 | `MacParakeetCore/Audio/MeetingLiveAudioChunking.swift`, `MacParakeetCore/Audio/SpeechBoundaryMeetingLiveAudioChunker.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingVADService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingVADModelPreparer.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetCore/Services/Capture/CaptureOrchestrator.swift`, `MacParakeet/App/AppDelegate.swift`, `MacParakeet/App/AppEnvironment.swift`, `MacParakeetCore/AppFeatures.swift`, `CLI/Commands/MeetingVADSimCommand.swift` | `FixedMeetingLiveAudioChunkerTests.swift`, `SpeechBoundaryMeetingLiveAudioChunkerTests.swift`, `MeetingVADChunkingSimulatorTests.swift`, `MeetingVADLaunchPrepTests.swift`, `MeetingRecordingServiceTests.swift`, `TelemetryServiceTests.swift` |

## v0.6 Multilingual Speech Recognition

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-STT-002 | `MacParakeetCore/SpeechEnginePreference.swift`, `MacParakeetCore/STT/ParakeetModelVariant+ASR.swift`, `MacParakeetCore/STT/NemotronEngine.swift`, `MacParakeetCore/STT/WhisperEngine.swift`, `MacParakeetCore/STT/STTRuntime.swift`, `Package.swift` | `STTClientTests.swift`, `SpeechEnginePreferenceTests.swift`, `ModelDeletionTests.swift` |
| REQ-STT-003 | `MacParakeetCore/STT/STTScheduler.swift`, `MacParakeetCore/STT/STTClient.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeet/Views/Settings/SettingsStatusRules.swift`, `MacParakeet/App/AppEnvironment.swift`, `MacParakeet/App/AppEnvironmentConfigurer.swift` | `STTSchedulerTests.swift`, `SettingsViewModelTests.swift`, `SettingsStatusRulesTests.swift`, `SpeechEnginePreferenceTests.swift` |
| REQ-TRANS-002 | `CLI/Commands/TranscribeCommand.swift`, `CLI/Commands/ModelsCommand.swift`, `CLI/Commands/ConfigCommand.swift`, `CLI/Commands/SpecCommand.swift`, `MacParakeetCore/SpeechEnginePreference.swift`, `MacParakeetCore/STT/ParakeetModelVariant+ASR.swift`, `MacParakeetCore/STT/NemotronEngine.swift`, `MacParakeetCore/STT/STTResult.swift`, `MacParakeetCore/Services/TranscriptionService.swift`, `MacParakeetCore/Services/AppPaths.swift` | `TranscribeCommandTests.swift`, `ModelLifecycleCommandTests.swift`, `ConfigCommandTests.swift`, `SpecCommandTests.swift`, `TranscriptionServiceTests.swift` |
| REQ-MEET-007 | `MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingMetadata.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingOutput.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift`, `MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift`, `MacParakeetCore/Services/TranscriptionService.swift` | `MeetingRecordingServiceTests.swift`, `MeetingRecordingLockFileStoreTests.swift`, `MeetingRecordingRecoveryServiceTests.swift`, `TranscriptionServiceTests.swift`, `STTSchedulerTests.swift` |

## v0.6 Transforms

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-XFORM-001 | `MacParakeetCore/Models/Prompt.swift`, `MacParakeetCore/Models/KeyboardShortcut.swift`, `MacParakeetCore/Services/System/SelectionCaptureService.swift`, `MacParakeetCore/Services/System/SelectionReplacementService.swift`, `MacParakeetCore/Services/Transforms/TransformExecutor.swift`, `MacParakeet/Hotkey/TransformsHotkeyRegistry.swift`, `MacParakeet/App/TransformsCoordinator.swift`, `MacParakeet/Views/Transforms/TransformsView.swift`, `MacParakeetViewModels/TransformsViewModel.swift`, `MacParakeetViewModels/TransformEditorViewModel.swift`, `CLI/Commands/TransformsCommand.swift` | `PromptRepositoryTests.swift`, `KeyboardShortcutTests.swift`, `SelectionCaptureServiceTests.swift`, `SelectionReplacementServiceTests.swift`, `TransformExecutorTests.swift`, `TransformsHotkeyRegistryTests.swift`, `TransformsViewModelTests.swift`, `TransformEditorViewModelTests.swift`, `TransformsCommandTests.swift` |
| REQ-XFORM-002 | `MacParakeetCore/Models/TransformHistoryEntry.swift`, `MacParakeetCore/Database/TransformHistoryRepository.swift`, `MacParakeetCore/Services/Transforms/TransformExecutor.swift`, `MacParakeetViewModels/TransformsViewModel.swift`, `CLI/Commands/TransformsCommand.swift` | `TransformHistoryRepositoryTests.swift`, `TransformExecutorTests.swift`, `TransformsViewModelTests.swift`, `TransformsCommandTests.swift` |

## v0.6 Calendar Auto-Start

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-CAL-001 | `MacParakeetCore/Calendar/CalendarService.swift`, `MacParakeetCore/Calendar/CalendarServicing.swift`, `MacParakeetCore/Calendar/CalendarEvent.swift`, `MacParakeetCore/Calendar/CalendarAutoStartMode.swift`, `MacParakeetCore/Calendar/CalendarNotificationAuthorization.swift`, `MacParakeetCore/Calendar/MeetingMonitor.swift`, `MacParakeetCore/Calendar/MeetingLinkParser.swift`, `MacParakeet/App/MeetingAutoStartCoordinator.swift`, `MacParakeetViewModels/MeetingCountdownToastViewModel.swift` | `MeetingAutoStartCoordinatorTests.swift`, `MeetingMonitorTests.swift`, `MeetingLinkParserTests.swift`, `MeetingCountdownToastViewModelTests.swift` |
| REQ-CAL-002 | `MacParakeet/Views/Settings/CalendarSettingsView.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeetViewModels/SettingsSearchIndex.swift`, `MacParakeet/Views/Onboarding/OnboardingFlowView.swift`, `MacParakeetViewModels/OnboardingViewModel.swift`, `MacParakeet/Views/Meetings/MeetingsView.swift`, `MacParakeetViewModels/MeetingsWorkspaceViewModel.swift`, `CLI/Commands/CalendarCommand.swift` | `SettingsViewModelTests.swift`, `SettingsSearchIndexTests.swift`, `OnboardingViewModelTests.swift`, `MeetingsWorkspaceViewModelTests.swift` |

## CLI Public Surface

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-CLI-001 | `CLI/MacParakeetCLI.swift`, `CLI/Commands/CLIHelpers.swift`, `CLI/Commands/CLITelemetry.swift`, `CLI/Commands/ConfigCommand.swift`, `CLI/Commands/TranscribeCommand.swift`, `MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`, `MacParakeet/Views/Settings/SettingsView.swift` | `LLMJSONOutputTests.swift`, `CLITelemetryTests.swift`, `ConfigCommandTests.swift`, `CLIOperationPrivacyTests.swift` |
| REQ-CLI-002 | `CLI/Commands/TranscribeCommand.swift`, `CLI/Commands/CLIHelpers.swift`, `MacParakeetCore/Audio/AudioFileEnumerator.swift` | `TranscribeCommandTests.swift` |
