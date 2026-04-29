# Traceability Matrix

> Status: **ACTIVE** — Maps requirements to test files and source files.

This matrix traces each requirement ID from `requirements.yaml` to its implementing source files and test coverage.

## v0.1 Core MVP

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DICT-001 | `MacParakeetCore/Services/DictationService.swift`, `MacParakeetCore/DictationFlow/` | `DictationServiceTests.swift` |
| REQ-DICT-002 | `MacParakeetCore/DictationFlow/FnKeyStateMachine.swift` | `FnKeyStateMachineTests.swift` |
| REQ-DICT-003 | `MacParakeetCore/Services/ClipboardService.swift` | `ClipboardServiceTests.swift` |
| REQ-TRANS-001 | `MacParakeetCore/Services/TranscriptionService.swift` | `TranscriptionServiceTests.swift` |
| REQ-UI-001 | `MacParakeet/Views/Dictation/DictationOverlayView.swift` | (ViewModel tests) |
| REQ-UI-002 | `MacParakeet/Views/Dictation/IdlePillView.swift` | (ViewModel tests) |
| REQ-UI-003 | `MacParakeet/Views/MainWindowView.swift` | (ViewModel tests) |
| REQ-DATA-001 | `MacParakeetCore/Database/DictationRepository.swift` | `DictationRepositoryTests.swift` |
| REQ-DATA-002 | `MacParakeetCore/Database/DatabaseManager.swift` | `DatabaseManagerTests.swift` |
| REQ-STT-001 | `MacParakeet/App/AppEnvironment.swift`, `MacParakeetCore/STT/STTRuntime.swift`, `MacParakeetCore/STT/STTScheduler.swift`, `MacParakeetCore/STT/STTClient.swift`, `MacParakeetCore/Services/DictationService.swift`, `MacParakeetCore/Services/MeetingRecordingService.swift`, `MacParakeetCore/Services/TranscriptionService.swift`, `MacParakeetViewModels/OnboardingViewModel.swift` | `STTSchedulerTests.swift`, `STTClientTests.swift`, `DictationServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `TranscriptionServiceTests.swift`, `OnboardingViewModelTests.swift` |
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
| REQ-DIAR-001 | `MacParakeetCore/Services/DiarizationService.swift` | `DiarizationServiceTests.swift` |
| REQ-DICT-004 | `MacParakeet/Hotkey/HotkeyManager.swift`, `MacParakeet/Hotkey/GlobalShortcutManager.swift`, `MacParakeetCore/STT/HotkeyTrigger.swift`, `MacParakeetCore/STT/HotkeyGestureController.swift` | `HotkeyManagerTests.swift`, `GlobalShortcutManagerTests.swift`, `HotkeyTriggerTests.swift`, `HotkeyGestureControllerTests.swift` |
| REQ-LLM-001 | `MacParakeetCore/Services/LLMService.swift`, `MacParakeetCore/Services/LLMClient.swift`, `MacParakeetCore/Services/LLMConfigStore.swift`, `MacParakeetCore/Services/RoutingLLMClient.swift`, `MacParakeetCore/Services/LocalCLILLMClient.swift` | `LLMServiceTests.swift`, `LLMClientTests.swift`, `LLMConfigStoreTests.swift`, `RoutingLLMClientTests.swift`, `LocalCLILLMClientTests.swift` |
| REQ-LLM-002 | `CLI/Commands/LLMChatCommand.swift`, `CLI/Commands/LLMSummarizeCommand.swift`, `CLI/Commands/LLMTestCommand.swift`, `CLI/Commands/LLMTransformCommand.swift`, `CLI/Commands/PromptsCommand.swift`, `MacParakeetCore/Models/LLMResult.swift`, `MacParakeetCore/Services/LLMClient.swift`, `MacParakeetCore/Services/LLMService.swift` | `LLMJSONOutputTests.swift`, `LLMResultTests.swift`, `LLMClientTests.swift`, `LLMServiceTests.swift` |

## v0.5 Data & Reliability

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DICT-005 | `MacParakeetCore/Database/DictationRepository.swift` | `DictationRepositoryTests.swift` |
| REQ-DATA-003 | `MacParakeetCore/Database/ChatConversationRepository.swift`, `MacParakeetCore/Models/ChatConversation.swift` | `ChatConversationRepositoryTests.swift`, `TranscriptChatViewModelTests.swift` |
| REQ-YT-002 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-DATA-004 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |

## v0.6 Video Player & UI Revamp

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-PLAY-001 | `MacParakeetCore/Services/VideoStreamService.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `VideoStreamServiceTests.swift`, `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-002 | `MacParakeet/Views/Components/AudioScrubberBar.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-003 | `MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-UI-004 | `MacParakeet/Views/Transcription/TranscriptResultView.swift`, `MacParakeet/Views/Transcription/TranscriptionVideoPanel.swift` | (ViewModel tests) |
| REQ-LIB-001 | `MacParakeet/Views/Transcription/TranscriptionLibraryView.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-UI-005 | `MacParakeet/Views/Transcription/TranscribeView.swift`, `MacParakeet/Views/Transcription/YouTubeInputPanelView.swift`, `MacParakeet/Views/Transcription/PortalDropZone.swift` | (ViewModel tests) |

## v0.6 Meeting Recording Hardening

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-MEET-001 | `MacParakeetCore/Audio/MicrophoneCapture.swift`, `MacParakeetCore/Audio/MeetingAudioCaptureService.swift`, `MacParakeetCore/Services/MicConditioner.swift`, `MacParakeetCore/Services/CaptureOrchestrator.swift`, `MacParakeetCore/Services/LiveChunkTranscriber.swift`, `MacParakeetCore/Services/MeetingRecordingService.swift`, `MacParakeetCore/Services/MeetingSoftwareAEC.swift` | `MeetingAudioCaptureServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `MeetingSoftwareAECTests.swift` |
| REQ-MEET-002 | `MacParakeetCore/Services/MeetingAudioPairJoiner.swift`, `MacParakeetCore/Services/MeetingRecordingService.swift` | `MeetingAudioPairJoinerTests.swift`, `MeetingRecordingServiceTests.swift` |
| REQ-MEET-003 | `MacParakeet/Views/MeetingRecording/MeetingsView.swift` | (none — copy-only UI change) |
| REQ-MEET-004 | `MacParakeetCore/Audio/AudioFileConverter.swift`, `MacParakeetCore/Audio/MeetingAudioStorageWriter.swift` | `AudioFileConverterTests.swift` |
| REQ-MEET-005 | `MacParakeetCore/Services/MeetingRecordingLockFileStore.swift`, `MacParakeetCore/Services/MeetingRecordingRecoveryService.swift`, `MacParakeetCore/Services/MeetingRecordingService.swift`, `MacParakeetCore/Models/Transcription.swift`, `MacParakeetCore/Database/DatabaseManager.swift`, `MacParakeet/App/AppEnvironment.swift`, `MacParakeet/App/AppEnvironmentConfigurer.swift`, `MacParakeet/AppDelegate.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeet/Views/MeetingRecording/MeetingRowCard.swift`, `MacParakeet/Views/Transcription/TranscriptResultView.swift`, `MacParakeet/Views/Transcription/TranscriptionThumbnailCard.swift` | `MeetingRecordingLockFileStoreTests.swift`, `MeetingRecordingRecoveryServiceTests.swift`, `MeetingRecordingServiceTests.swift`, `MeetingRecordingCrashRecoveryTests.swift`, `DatabaseManagerTests.swift`, `TranscriptionModelTests.swift` |
| REQ-MEET-006 | `MacParakeetCore/Audio/MeetingAudioStorageWriter.swift`, `MacParakeetCore/Audio/PCMBufferToSampleBuffer.swift` | `PCMBufferToSampleBufferTests.swift`, `MeetingAudioStorageWriterTests.swift`, `MeetingRecordingCrashRecoveryTests.swift` |

## v0.7 Multilingual Speech Recognition

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-STT-002 | `MacParakeetCore/SpeechEnginePreference.swift`, `MacParakeetCore/STT/WhisperEngine.swift`, `MacParakeetCore/STT/STTRuntime.swift`, `Package.swift` | `STTClientTests.swift` |
| REQ-STT-003 | `MacParakeetCore/STT/STTScheduler.swift`, `MacParakeetCore/STT/STTClient.swift`, `MacParakeetViewModels/SettingsViewModel.swift`, `MacParakeet/Views/Settings/SettingsView.swift`, `MacParakeet/App/AppEnvironment.swift`, `MacParakeet/App/AppEnvironmentConfigurer.swift` | `STTSchedulerTests.swift`, `SettingsViewModelTests.swift` |
| REQ-TRANS-002 | `CLI/Commands/TranscribeCommand.swift`, `CLI/Commands/ModelsCommand.swift`, `MacParakeetCore/STT/STTResult.swift`, `MacParakeetCore/Services/TranscriptionService.swift`, `MacParakeetCore/Services/AppPaths.swift` | `TranscribeCommandTests.swift`, `ModelLifecycleCommandTests.swift`, `TranscriptionServiceTests.swift` |
| REQ-MEET-007 | `MacParakeetCore/Services/MeetingRecordingService.swift`, `MacParakeetCore/Services/MeetingRecordingMetadata.swift`, `MacParakeetCore/Services/MeetingRecordingOutput.swift`, `MacParakeetCore/Services/MeetingRecordingLockFileStore.swift`, `MacParakeetCore/Services/MeetingRecordingRecoveryService.swift`, `MacParakeetCore/Services/TranscriptionService.swift` | `MeetingRecordingServiceTests.swift`, `MeetingRecordingLockFileStoreTests.swift`, `MeetingRecordingRecoveryServiceTests.swift`, `TranscriptionServiceTests.swift`, `STTSchedulerTests.swift` |

## CLI Public Surface

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-CLI-001 | `CLI/MacParakeetCLI.swift`, `CLI/Commands/CLIHelpers.swift`, `CLI/Commands/CLITelemetry.swift`, `CLI/Commands/ConfigCommand.swift`, `CLI/Commands/TranscribeCommand.swift`, `MacParakeetCore/Services/TelemetryEvent.swift`, `MacParakeet/Views/Settings/SettingsView.swift` | `LLMJSONOutputTests.swift`, `CLITelemetryTests.swift`, `ConfigCommandTests.swift`, `CLIOperationPrivacyTests.swift` |
