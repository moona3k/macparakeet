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
| REQ-YT-001 | `MacParakeetCore/Services/YouTubeService.swift` | `YouTubeServiceTests.swift` |
| REQ-EXP-002 | `MacParakeetCore/Services/ExportService.swift` | `ExportServiceTests.swift` |

## v0.4 Polish & Launch

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DIAR-001 | `MacParakeetCore/Services/DiarizationService.swift` | `DiarizationServiceTests.swift` |
| REQ-DICT-004 | `MacParakeetCore/Services/HotkeyService.swift` | `HotkeyServiceTests.swift` |
| REQ-LLM-001 | `MacParakeetCore/Services/LLMProviderService.swift` | `LLMProviderServiceTests.swift` |

## v0.5 Data & Reliability

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-DICT-005 | `MacParakeetCore/Database/DictationRepository.swift` | `DictationRepositoryTests.swift` |
| REQ-DATA-003 | `MacParakeetCore/Database/ChatRepository.swift` | `ChatRepositoryTests.swift` |
| REQ-YT-002 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-DATA-004 | `MacParakeetCore/Database/TranscriptionRepository.swift` | `TranscriptionRepositoryTests.swift` |

## v0.6 Video Player & UI Revamp

| Requirement | Source Files | Test Files |
|------------|-------------|------------|
| REQ-PLAY-001 | `MacParakeetCore/Services/HLSStreamService.swift`, `MacParakeetViewModels/MediaPlayerViewModel.swift` | `MediaPlayerViewModelTests.swift` |
| REQ-PLAY-002 | `MacParakeet/Views/Transcription/AudioScrubberView.swift` | (ViewModel tests) |
| REQ-PLAY-003 | `MacParakeet/Views/Transcription/TranscriptTabView.swift` | `TranscriptHighlightTests.swift` |
| REQ-UI-004 | `MacParakeet/Views/Transcription/TranscriptionDetailView.swift` | (ViewModel tests) |
| REQ-LIB-001 | `MacParakeet/Views/Transcription/TranscriptionLibraryView.swift` | `TranscriptionRepositoryTests.swift` |
| REQ-UI-005 | `MacParakeet/Views/Transcription/HomeView.swift` | (ViewModel tests) |
