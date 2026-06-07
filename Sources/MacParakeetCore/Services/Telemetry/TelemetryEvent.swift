import Foundation

public enum TelemetryEventName: String, Sendable, CaseIterable {
    case appLaunched = "app_launched"
    case appQuit = "app_quit"
    case dictationStarted = "dictation_started"
    case dictationCompleted = "dictation_completed"
    /// One-shot activation milestone: fired exactly once per install, the
    /// first time a dictation completes end-to-end. Forward-looking — existing
    /// users already carry the `hasCompletedFirstDictation` flag, so this never
    /// produces a retroactive spike. Counted against `onboarding_completed` to
    /// derive the activation rate.
    case firstDictationCompleted = "first_dictation_completed"
    case dictationCancelled = "dictation_cancelled"
    case dictationEmpty = "dictation_empty"
    case dictationFailed = "dictation_failed"
    case dictationOperation = "dictation_operation"
    case dictationFirstLoadCaptionShown = "dictation_first_load_caption_shown"
    case dictationFirstLoadCaptionDuration = "dictation_first_load_caption_duration"
    case transcriptionStarted = "transcription_started"
    case transcriptionCompleted = "transcription_completed"
    case transcriptionCancelled = "transcription_cancelled"
    case transcriptionFailed = "transcription_failed"
    case transcriptionOperation = "transcription_operation"
    case diarizationStarted = "diarization_started"
    case diarizationCompleted = "diarization_completed"
    case diarizationFailed = "diarization_failed"
    case exportUsed = "export_used"
    case llmPromptResultUsed = "llm_prompt_result_used"
    case llmPromptResultFailed = "llm_prompt_result_failed"
    case llmChatUsed = "llm_chat_used"
    case llmChatFailed = "llm_chat_failed"
    case llmTransformUsed = "llm_transform_used"
    case llmTransformFailed = "llm_transform_failed"
    /// Transforms feature surface (ADR-022). Distinct from
    /// `llm_transform_used` (the call-level event fired by
    /// `LLMService.transformStream`). `transform_executed` is the
    /// product-level event fired by `TransformsCoordinator` after a
    /// hotkey-bound Transform completes end-to-end. Properties:
    /// `transform_name` (built-in name or `custom`), `capture_path`
    /// (`ax | clipboard`), `replace_path` (`ax | clipboardPaste`),
    /// `llm_ms`, `total_ms`, and optional `app_category`. NO prompt body, NO
    /// selected text, NO output. Custom-Transform names map to `custom` so a
    /// Transform named after e.g. an employer never leaves the device.
    case transformExecuted = "transform_executed"
    case transformFailed = "transform_failed"
    case transformOperation = "transform_operation"
    case askMenuOpened = "ask_menu_opened"
    case askPromptFired = "ask_prompt_fired"
    case llmFormatterUsed = "llm_formatter_used"
    case llmFormatterFailed = "llm_formatter_failed"
    case llmProviderUnavailable = "llm_provider_unavailable"
    case llmOperation = "llm_operation"
    case historySearched = "history_searched"
    case historyReplayed = "history_replayed"
    case copyToClipboard = "copy_to_clipboard"
    case hotkeyCustomized = "hotkey_customized"
    case processingModeChanged = "processing_mode_changed"
    case customWordAdded = "custom_word_added"
    case customWordDeleted = "custom_word_deleted"
    case snippetAdded = "snippet_added"
    case snippetEdited = "snippet_edited"
    case snippetDeleted = "snippet_deleted"
    case keystrokeSnippetFired = "keystroke_snippet_fired"
    case feedbackSubmitted = "feedback_submitted"
    case feedbackOperation = "feedback_operation"
    case transcriptionDeleted = "transcription_deleted"
    case dictationDeleted = "dictation_deleted"
    case transcriptionFavorited = "transcription_favorited"
    case dictationUndoUsed = "dictation_undo_used"
    case chatConversationCreated = "chat_conversation_created"
    // Prompt library
    case promptCreated = "prompt_created"
    case promptUpdated = "prompt_updated"
    case promptDeleted = "prompt_deleted"
    case settingChanged = "setting_changed"
    case telemetryOptedOut = "telemetry_opted_out"
    case onboardingCompleted = "onboarding_completed"
    case onboardingStep = "onboarding_step"
    case licenseActivated = "license_activated"
    case licenseActivationFailed = "license_activation_failed"
    case trialStarted = "trial_started"
    case trialExpired = "trial_expired"
    case purchaseStarted = "purchase_started"
    case restoreAttempted = "restore_attempted"
    case restoreSucceeded = "restore_succeeded"
    case restoreFailed = "restore_failed"
    // Permissions
    case permissionPrompted = "permission_prompted"
    case permissionGranted = "permission_granted"
    case permissionDenied = "permission_denied"
    // Performance
    case modelLoaded = "model_loaded"
    case modelDownloadStarted = "model_download_started"
    case modelDownloadCompleted = "model_download_completed"
    case modelDownloadFailed = "model_download_failed"
    case modelOperation = "model_operation"
    case speechEngineSwitchOperation = "speech_engine_switch_operation"
    // Meeting recording
    case meetingRecordingStarted = "meeting_recording_started"
    case meetingRecordingCompleted = "meeting_recording_completed"
    case meetingRecordingCancelled = "meeting_recording_cancelled"
    case meetingRecordingFailed = "meeting_recording_failed"
    case meetingOperation = "meeting_operation"
    case meetingRecoveryDiscovered = "meeting_recovery_discovered"
    case meetingRecoveryStarted = "meeting_recovery_started"
    case meetingRecoveryCompleted = "meeting_recovery_completed"
    case meetingRecoveryDiscarded = "meeting_recovery_discarded"
    case meetingRecoveryFailed = "meeting_recovery_failed"
    /// Universal launch-time Silero VAD model prep for VAD-guided meeting live
    /// chunking (`plans/active/2026-05-meeting-vad-guided-live-chunking.md` §6).
    /// Confirms the installed base actually acquires the model once the feature
    /// is enabled — see `TelemetryVADModelPrepOutcome`. Gated on
    /// `AppFeatures.meetingVadLiveChunkingEnabled`, so it never fires in a
    /// flag-off build.
    case vadModelPrep = "vad_model_prep"
    // Calendar auto-start (ADR-017)
    case calendarReminderShown = "calendar_reminder_shown"
    case calendarAutoStartTriggered = "calendar_auto_start_triggered"
    case calendarAutoStartCancelled = "calendar_auto_start_cancelled"
    case calendarAutoStartFailed = "calendar_auto_start_failed"
    // STT runtime observability
    case sttRuntimeUnhealthy = "stt_runtime_unhealthy"
    // Errors
    case errorOccurred = "error_occurred"
    // Crashes
    case crashOccurred = "crash_occurred"
    // CLI
    case cliOperation = "cli_operation"
    // Local file automation
    case autoSaveOperation = "auto_save_operation"
}

public enum TelemetryDictationTrigger: String, Sendable, Equatable {
    case hotkey
    case pillClick = "pill_click"
    case menuBar = "menu_bar"
}

public enum TelemetryDictationMode: String, Sendable, Equatable {
    case hold
    case persistent
}

public enum TelemetryDictationCancelReason: String, Sendable, Equatable {
    case escape
    case hotkey
    case ui
}

public enum TelemetryTranscriptionSource: String, Sendable, Equatable {
    case file
    case youtube
    case meeting
    case dragDrop = "drag_drop"
}

public enum TelemetryTranscriptionStage: String, Sendable, Equatable {
    case preflight
    case download
    case audioConversion = "audio_conversion"
    case stt
    case diarization
    case postProcessing = "post_processing"
    case persistence
}

public enum TelemetryModelKind: String, Sendable, Equatable {
    case parakeetSTT = "parakeet_stt"
    case whisperSTT = "whisper_stt"
    case speakerDiarization = "speaker_diarization"
    case localSpeechStack = "local_speech_stack"
}

public enum TelemetryModelOperationAction: String, Sendable, Equatable {
    case download
    case warmUp = "warm_up"
    case repair
    case clearCache = "clear_cache"
    /// Removing a single model from disk (one Parakeet build or the Whisper
    /// variant), as opposed to `clearCache` which wipes the whole local stack.
    case deleteModel = "delete_model"
}

public enum TelemetryModelOperationStage: String, Sendable, Equatable {
    case preflight
    case download
    case load
    case warmUp = "warm_up"
    case clearCache = "clear_cache"
    case delete
}

public enum TelemetrySpeechEngineSwitchBlockedReason: String, Sendable, Equatable {
    case modelNotDownloaded = "model_not_downloaded"
    case engineBusy = "engine_busy"
    case meetingActive = "meeting_active"
    case transcribing
    case switchInProgress = "switch_in_progress"
    case unavailable
}

public enum TelemetryCopySource: String, Sendable, Equatable {
    case dictation
    case transcription
    case history
    case meeting
    case discover
}

public enum TelemetryFormatterSource: String, Sendable, Equatable {
    case dictation
    case transcription
}

/// Which chat surface a `llm_chat_used` / chat-feature LLM operation came
/// from. Pre-2026-05-19 builds emitted `llm_chat_used` without a source,
/// which collapsed live meeting Ask chat and post-transcription transcript
/// chat into one unattributable bucket. New rows carry `source` so the two
/// surfaces are separable in production telemetry.
public enum TelemetryChatSource: String, Sendable, Equatable {
    /// Live in-meeting Ask tab (ADR-018). `userNotesProvider` is bound by
    /// `MeetingRecordingPanelViewModel`.
    case meetingAsk = "meeting_ask"
    /// Post-transcription chat surface — file, YouTube, dictation, or a
    /// finalized meeting transcript shown in `TranscriptResultView`.
    case transcriptChat = "transcript_chat"
}

/// Which Transform (ADR-022) ran. Built-in names are transmitted verbatim
/// (`polish`, `distill`, `decide`) so per-built-in usage is observable.
/// Custom Transforms map to `custom` — a user-supplied name like "Boss
/// Mode" or a company name never leaves the device.
public enum TelemetryTransformName: String, Sendable, Equatable {
    case polish
    case distill
    case decide
    case custom

    public init(builtInName: String?, isBuiltIn: Bool) {
        guard isBuiltIn, let name = builtInName?.lowercased() else {
            self = .custom
            return
        }
        switch name {
        case "polish": self = .polish
        case "distill": self = .distill
        case "decide": self = .decide
        default: self = .custom
        }
    }
}

/// Selection-capture path the Transforms pipeline used. Mirrors
/// `SelectionCaptureResult` minus the payloads.
public enum TelemetryTransformCapturePath: String, Sendable, Equatable {
    case ax
    case clipboard
}

/// Selection-replacement path the Transforms pipeline used. Mirrors
/// `SelectionReplacementPath`.
public enum TelemetryTransformReplacePath: String, Sendable, Equatable {
    case ax
    case clipboardPaste = "clipboard_paste"
}

public enum TelemetryTransformOperationStage: String, Sendable, Equatable {
    case capture
    case llm
    case replacement
    case complete
}

public enum TelemetryAskPromptSource: String, Sendable, Equatable {
    case emptyState = "empty_state"
    case menu
    case followUp = "follow_up"
}

/// Why a Transforms run terminated abnormally. Maps onto
/// `TransformExecutorError` cases plus a `noProvider` rollup for the
/// "user hasn't configured an LLM yet" gate.
public enum TelemetryTransformFailureReason: String, Sendable, Equatable {
    case emptySelection = "empty_selection"
    case noProvider = "no_provider"
    case captureFailed = "capture_failed"
    case llmFailed = "llm_failed"
    case replacementFailed = "replacement_failed"
    case cancelled
}

/// Which LLM call site produced a `llm_provider_unavailable` event. Lets a
/// single event cover all the LLM entry points while still answering
/// "which feature was the user trying to use when their provider wasn't
/// reachable?" without minting four near-identical event names.
public enum TelemetryLLMFeature: String, Sendable, Equatable {
    case formatter
    case promptResult = "prompt_result"
    case chat
    case transform
}

public enum TelemetryLLMSource: String, Sendable, Equatable {
    case dictation
    case transcription
    case meetingAsk = "meeting_ask"
    case transcriptChat = "transcript_chat"

    public init(_ source: TelemetryFormatterSource) {
        switch source {
        case .dictation: self = .dictation
        case .transcription: self = .transcription
        }
    }

    public init(_ source: TelemetryChatSource) {
        switch source {
        case .meetingAsk: self = .meetingAsk
        case .transcriptChat: self = .transcriptChat
        }
    }
}

/// Why a meeting recording started. Lets us distinguish manual user action
/// from calendar-driven auto-start in adoption metrics.
public enum TelemetryMeetingRecordingTrigger: String, Sendable, Equatable {
    case manual
    case hotkey
    case calendarAutoStart = "calendar_auto_start"
}

public enum TelemetryMeetingOperationStage: String, Sendable, Equatable {
    case permissions
    case startRecording = "start_recording"
    case recording
    case stopRecording = "stop_recording"
    case transcription
    case completeTranscription = "complete_transcription"
    case cancel
}

public enum TelemetryMeetingRecoverySource: String, Sendable, Equatable {
    case launch
    case settings
}

/// Outcome of a launch-time Silero VAD model prep attempt (Phase 4.5,
/// `plans/active/2026-05-meeting-vad-guided-live-chunking.md` §6). The full
/// vocabulary is modeled here, but the launch hook only transmits the
/// *transitions* worth seeing: `prepared` (an install just acquired the model
/// — the field-reach signal) and `failed` (a download problem). The
/// steady-state `alreadyCached` is intentionally NOT emitted on every launch to
/// avoid per-launch telemetry spam; cumulative `prepared` counts already
/// approximate how much of the installed base has the model.
public enum TelemetryVADModelPrepOutcome: String, Sendable, Equatable {
    case alreadyCached = "already_cached"
    case prepared
    case failed
}

public enum TelemetryPermission: String, Sendable, Equatable {
    case microphone
    case accessibility
    case screenRecording = "screen_recording"
    case calendar
}

/// Which capture surface a hotkey customization applies to. Lets us answer
/// product questions like "do meeting hotkeys get customized as often as
/// dictation?" and "which surface is most likely to land on a chord vs a
/// single-key trigger?".
public enum TelemetryHotkeySurface: String, Sendable, Equatable {
    case dictation
    case pushToTalk = "push_to_talk"
    case meeting
    case fileTranscription = "file_transcription"
    case youtubeTranscription = "youtube_transcription"
}

/// Mirrors `HotkeyTrigger.Kind` for telemetry. Kept separate so changes to the
/// runtime model (e.g., the proposed modifier-only chord in #234) can land
/// without forcing every prior value through a schema migration.
///
/// We deliberately track structural category only — see
/// `docs/telemetry.md` item 10: "track boolean, not which key." `kind` is
/// one step up from a boolean (4 categories of binding pattern); it does
/// not reveal the actual modifier or keycode the user picked.
public enum TelemetryHotkeyKind: String, Sendable, Equatable {
    case disabled
    case modifier
    case keyCode = "key_code"
    case chord
}

public enum TelemetrySettingName: String, Sendable, Equatable {
    case saveHistory = "save_history"
    case audioRetention = "audio_retention"
    case appAppearance = "app_appearance"
    case menuBarOnly = "menu_bar_only"
    case hidePill = "hide_pill"
    case saveTranscriptionAudio = "save_transcription_audio"
    case youtubeAudioQuality = "youtube_audio_quality"
    case speakerDiarization = "speaker_diarization"
    case parakeetModelVariant = "parakeet_model_variant"
    case whisperDefaultLanguage = "whisper_default_language"
    case autoSave = "auto_save"
    case meetingAutoSave = "meeting_auto_save"
    case meetingHotkey = "meeting_hotkey"
    case fileTranscriptionHotkey = "file_transcription_hotkey"
    case youtubeTranscriptionHotkey = "youtube_transcription_hotkey"
    case microphoneSelection = "microphone_selection"
    case meetingAudioSourceMode = "meeting_audio_source_mode"
    case pauseMediaDuringDictation = "pause_media_during_dictation"
    case instantDictation = "instant_dictation"
    case dictationInsertionStyle = "dictation_insertion_style"
    case transcriptionCompletionNotification = "transcription_completion_notification"

    case launchAtLogin = "launch_at_login"
    case silenceAutoStop = "silence_auto_stop"
    case keepDictationOnClipboard = "keep_dictation_on_clipboard"
    case voiceReturn = "voice_return"

    // Calendar auto-start (ADR-017)
    case calendarAutoStartMode = "calendar_auto_start_mode"
    case calendarReminderMinutes = "calendar_reminder_minutes"
    case calendarTriggerFilter = "calendar_trigger_filter"
    case calendarIncludedCalendars = "calendar_included_calendars"
}

public enum TelemetryEventSpec: Sendable {
    static let maxCrashStackTraceCharacters = 1024

    case appLaunched
    case appQuit(sessionDurationSeconds: Double)
    case dictationStarted(trigger: TelemetryDictationTrigger?, mode: TelemetryDictationMode?)
    case dictationCompleted(
        durationSeconds: Double,
        wordCount: Int,
        mode: TelemetryDictationMode?,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        appCategory: TelemetryAppCategory? = nil,
        device: RecordingDeviceInfo? = nil
    )
    /// First-ever completed dictation for this install (see
    /// `TelemetryEventName.firstDictationCompleted`). `activationWindow` is the
    /// bucketed time since onboarding completed — coarse buckets only.
    case firstDictationCompleted(activationWindow: TelemetryActivationWindow)
    case dictationCancelled(durationSeconds: Double?, reason: TelemetryDictationCancelReason?, device: RecordingDeviceInfo? = nil)
    case dictationEmpty(durationSeconds: Double?, device: RecordingDeviceInfo? = nil)
    case dictationFailed(errorType: String, errorDetail: String? = nil, device: RecordingDeviceInfo? = nil)
    case dictationOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        outcome: ObservabilityOutcome,
        trigger: TelemetryDictationTrigger?,
        mode: TelemetryDictationMode?,
        durationSeconds: Double?,
        wordCount: Int?,
        errorType: String?,
        cancelReason: TelemetryDictationCancelReason? = nil,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        appCategory: TelemetryAppCategory? = nil,
        device: RecordingDeviceInfo? = nil
    )
    case dictationFirstLoadCaptionShown(firstInstall: Bool)
    case dictationFirstLoadCaptionDuration(durationMs: Int, outcome: String)
    case transcriptionStarted(source: TelemetryTranscriptionSource, audioDurationSeconds: Double?)
    case transcriptionCompleted(
        source: TelemetryTranscriptionSource,
        audioDurationSeconds: Double?,
        processingSeconds: Double?,
        wordCount: Int,
        speakerCount: Int? = nil,
        diarizationRequested: Bool,
        diarizationApplied: Bool,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil
    )
    case transcriptionCancelled(
        source: TelemetryTranscriptionSource,
        audioDurationSeconds: Double?,
        stage: TelemetryTranscriptionStage
    )
    case transcriptionFailed(
        source: TelemetryTranscriptionSource,
        stage: TelemetryTranscriptionStage,
        errorType: String,
        errorDetail: String? = nil
    )
    case transcriptionOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        outcome: ObservabilityOutcome,
        source: TelemetryTranscriptionSource,
        stage: TelemetryTranscriptionStage?,
        durationSeconds: Double,
        audioDurationSeconds: Double?,
        processingSeconds: Double?,
        wordCount: Int?,
        speakerCount: Int?,
        diarizationRequested: Bool,
        diarizationApplied: Bool,
        inputKind: ObservabilityInputKind?,
        mediaExtension: String?,
        fileSizeBucket: String?,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        errorType: String?
    )
    case diarizationStarted(source: TelemetryTranscriptionSource)
    case diarizationCompleted(source: TelemetryTranscriptionSource, speakerCount: Int, durationSeconds: Double)
    case diarizationFailed(source: TelemetryTranscriptionSource, errorType: String, errorDetail: String? = nil)
    case exportUsed(format: String)
    case llmPromptResultUsed(provider: String)
    case llmPromptResultFailed(provider: String, errorType: String, errorDetail: String? = nil)
    case llmChatUsed(provider: String, source: TelemetryChatSource, messageCount: Int)
    case llmChatFailed(provider: String, source: TelemetryChatSource, errorType: String, errorDetail: String? = nil)
    case llmTransformUsed(provider: String)
    case llmTransformFailed(provider: String, errorType: String, errorDetail: String? = nil)
    /// Transforms (ADR-022) feature-level success. Fired by
    /// `TransformsCoordinator` when a hotkey-bound Transform finishes
    /// end-to-end. NO content captured — see
    /// `TelemetryTransformName.custom` for the privacy contract.
    case transformExecuted(
        transformName: TelemetryTransformName,
        capturePath: TelemetryTransformCapturePath,
        replacePath: TelemetryTransformReplacePath,
        llmMs: Int,
        totalMs: Int,
        appCategory: TelemetryAppCategory? = nil
    )
    case transformFailed(
        transformName: TelemetryTransformName,
        reason: TelemetryTransformFailureReason
    )
    case transformOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        outcome: ObservabilityOutcome,
        transformName: TelemetryTransformName,
        stage: TelemetryTransformOperationStage?,
        capturePath: TelemetryTransformCapturePath?,
        replacePath: TelemetryTransformReplacePath?,
        durationSeconds: Double,
        llmMs: Int?,
        totalMs: Int?,
        appCategory: TelemetryAppCategory? = nil,
        errorType: TelemetryTransformFailureReason?
    )
    case askMenuOpened
    case askPromptFired(source: TelemetryAskPromptSource, group: String, label: String)
    case llmFormatterUsed(
        provider: String,
        source: TelemetryFormatterSource,
        durationSeconds: Double,
        inputChars: Int,
        outputChars: Int,
        defaultPromptUsed: Bool,
        inputTruncated: Bool
    )
    case llmFormatterFailed(
        provider: String,
        source: TelemetryFormatterSource,
        durationSeconds: Double,
        errorType: String,
        defaultPromptUsed: Bool,
        inputTruncated: Bool
    )
    /// User-environment state, not an app failure: the configured LLM
    /// provider can't be reached (server not running, model name out of
    /// date, API key invalid, CLI tool missing). Emitted *instead of*
    /// `llm*Failed` for these cases so the `*_failed` buckets reflect
    /// things actually worth investigating, while this event tracks
    /// how many users have drifted-config installs.
    case llmProviderUnavailable(
        provider: String,
        errorType: String,
        feature: TelemetryLLMFeature,
        source: TelemetryLLMSource? = nil
    )
    case llmOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        feature: String,
        provider: String,
        streaming: Bool,
        outcome: ObservabilityOutcome,
        durationSeconds: Double,
        inputChars: Int?,
        outputChars: Int?,
        inputTruncated: Bool?,
        promptDefaultUsed: Bool?,
        messageCount: Int?,
        errorType: String?
    )
    case historySearched
    case historyReplayed
    case copyToClipboard(source: TelemetryCopySource)
    case hotkeyCustomized(
        surface: TelemetryHotkeySurface,
        kind: TelemetryHotkeyKind
    )
    case processingModeChanged(mode: String)
    case customWordAdded
    case customWordDeleted
    case snippetAdded
    case snippetEdited
    case snippetDeleted
    case settingChanged(setting: TelemetrySettingName)
    case telemetryOptedOut
    case onboardingCompleted(durationSeconds: Double?)
    case onboardingStep(step: String)
    case licenseActivated
    case licenseActivationFailed(errorType: String, errorDetail: String? = nil)
    case trialStarted
    case trialExpired
    case purchaseStarted
    case restoreAttempted
    case restoreSucceeded
    case restoreFailed(errorType: String?, errorDetail: String? = nil)
    // Permissions
    case permissionPrompted(permission: TelemetryPermission)
    case permissionGranted(permission: TelemetryPermission)
    case permissionDenied(permission: TelemetryPermission)
    // Performance
    case modelLoaded(
        loadTimeSeconds: Double,
        modelKind: TelemetryModelKind? = nil,
        speechEngine: SpeechEnginePreference? = nil,
        engineVariant: String? = nil
    )
    case modelDownloadStarted(
        modelKind: TelemetryModelKind? = nil,
        speechEngine: SpeechEnginePreference? = nil,
        engineVariant: String? = nil
    )
    case modelDownloadCompleted(
        durationSeconds: Double,
        modelKind: TelemetryModelKind? = nil,
        speechEngine: SpeechEnginePreference? = nil,
        engineVariant: String? = nil
    )
    case modelDownloadFailed(
        errorType: String,
        errorDetail: String? = nil,
        modelKind: TelemetryModelKind? = nil,
        speechEngine: SpeechEnginePreference? = nil,
        engineVariant: String? = nil
    )
    case modelOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        action: TelemetryModelOperationAction,
        outcome: ObservabilityOutcome,
        stage: TelemetryModelOperationStage?,
        modelKind: TelemetryModelKind?,
        speechEngine: SpeechEnginePreference?,
        engineVariant: String? = nil,
        durationSeconds: Double,
        errorType: String?
    )
    case speechEngineSwitchOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        fromEngine: SpeechEnginePreference,
        toEngine: SpeechEnginePreference,
        outcome: ObservabilityOutcome,
        durationSeconds: Double,
        blockedReason: TelemetrySpeechEngineSwitchBlockedReason?,
        errorType: String?,
        wasCold: Bool
    )
    // Lifecycle actions
    case feedbackSubmitted(category: String)
    case feedbackOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        category: String,
        outcome: ObservabilityOutcome,
        durationSeconds: Double,
        screenshotAttached: Bool,
        diagnosticLogAttached: Bool,
        systemInfoIncluded: Bool,
        errorType: String?
    )
    case transcriptionDeleted
    case dictationDeleted
    case transcriptionFavorited(isFavorite: Bool)
    case dictationUndoUsed
    case chatConversationCreated
    // Prompt library
    case promptCreated
    case promptUpdated
    case promptDeleted
    // Keystroke actions
    case keystrokeSnippetFired(action: String)
    // Meeting recording
    case meetingRecordingStarted(trigger: TelemetryMeetingRecordingTrigger? = nil)
    case meetingRecordingCompleted(durationSeconds: Double, liveWordCount: Int, liveTranscriptLagged: Bool)
    case meetingRecordingCancelled(durationSeconds: Double)
    case meetingRecordingFailed(errorType: String, errorDetail: String? = nil)
    case meetingOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        outcome: ObservabilityOutcome,
        trigger: TelemetryMeetingRecordingTrigger?,
        stage: TelemetryMeetingOperationStage? = nil,
        durationSeconds: Double?,
        liveWordCount: Int?,
        liveTranscriptLagged: Bool?,
        microphoneTrackPresent: Bool?,
        systemTrackPresent: Bool?,
        notesUsed: Bool?,
        notesLengthBucket: String?,
        errorType: String?
    )
    case meetingRecoveryDiscovered(count: Int, source: TelemetryMeetingRecoverySource)
    case meetingRecoveryStarted(count: Int, source: TelemetryMeetingRecoverySource)
    case meetingRecoveryCompleted(count: Int, durationSeconds: Double, source: TelemetryMeetingRecoverySource)
    case meetingRecoveryDiscarded(count: Int, source: TelemetryMeetingRecoverySource)
    case meetingRecoveryFailed(
        count: Int,
        source: TelemetryMeetingRecoverySource,
        errorType: String,
        errorDetail: String? = nil
    )
    /// Launch-time VAD model prep outcome (Phase 4.5). Only `.prepared` /
    /// `.failed` are ever sent — see `TelemetryVADModelPrepOutcome`.
    case vadModelPrep(outcome: TelemetryVADModelPrepOutcome)
    // Calendar auto-start (ADR-017). Mode is "notify" / "auto_start" — `.off`
    // never produces an event because the coordinator short-circuits.
    case calendarReminderShown(mode: String, leadMinutes: Int, hasMeetUrl: Bool)
    /// Auto-start countdown shown to the user. Fires when `.autoStartDue`
    /// emits and `MeetingAutoStartCoordinator` actually presents the toast
    /// (after permission + active-recording checks).
    case calendarAutoStartTriggered(leadSeconds: Int, hasMeetUrl: Bool)
    /// User actively cancelled the countdown before recording started.
    /// Currently only fires `reason: "user_cancel"`. System-side
    /// failures (permission denial, service throw, state-busy) go
    /// through `calendarAutoStartFailed` instead so the analyst can
    /// tell "user said no" from "system couldn't" cleanly.
    case calendarAutoStartCancelled(reason: String)
    /// Auto-start countdown completed but the recording flow couldn't
    /// actually start. Distinguishes user opt-out from system failure
    /// — see ADR-017 §10. Reasons:
    /// - `permission_denied` — user denied mic/screen during the prompt
    /// - `state_busy` — recording flow was non-idle (back-to-back meeting)
    /// - `service_threw` — `MeetingRecordingService.startRecording` errored
    case calendarAutoStartFailed(reason: String)
    // STT runtime observability. Fires when an STT runtime call (cancel-drain,
    // model-cache clear, shutdown, engine swap) exceeds the watchdog timeout.
    // Detection-only; the caller continues to await as today.
    case sttRuntimeUnhealthy(reason: String)
    // Errors
    case errorOccurred(domain: String, code: String, description: String)
    // Crashes
    case crashOccurred(
        crashType: String, signal: String, name: String,
        crashTimestamp: String, crashAppVer: String,
        crashOsVer: String, uuid: String,
        slide: String, reason: String?, stackTrace: String
    )
    case cliOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        command: String,
        subcommand: String?,
        outcome: ObservabilityOutcome,
        durationSeconds: Double,
        inputKind: ObservabilityInputKind?,
        outputFormat: String?,
        json: Bool?,
        exitCode: Int?,
        errorType: String?
    )
    case autoSaveOperation(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        scope: AutoSaveScope,
        format: AutoSaveFormat,
        outcome: ObservabilityOutcome,
        durationSeconds: Double,
        errorType: String?
    )
}

extension TelemetryEventSpec {
    var name: TelemetryEventName {
        switch self {
        case .appLaunched: return .appLaunched
        case .appQuit: return .appQuit
        case .dictationStarted: return .dictationStarted
        case .dictationCompleted: return .dictationCompleted
        case .firstDictationCompleted: return .firstDictationCompleted
        case .dictationCancelled: return .dictationCancelled
        case .dictationEmpty: return .dictationEmpty
        case .dictationFailed: return .dictationFailed
        case .dictationOperation: return .dictationOperation
        case .dictationFirstLoadCaptionShown: return .dictationFirstLoadCaptionShown
        case .dictationFirstLoadCaptionDuration: return .dictationFirstLoadCaptionDuration
        case .transcriptionStarted: return .transcriptionStarted
        case .transcriptionCompleted: return .transcriptionCompleted
        case .transcriptionCancelled: return .transcriptionCancelled
        case .transcriptionFailed: return .transcriptionFailed
        case .transcriptionOperation: return .transcriptionOperation
        case .diarizationStarted: return .diarizationStarted
        case .diarizationCompleted: return .diarizationCompleted
        case .diarizationFailed: return .diarizationFailed
        case .exportUsed: return .exportUsed
        case .llmPromptResultUsed: return .llmPromptResultUsed
        case .llmPromptResultFailed: return .llmPromptResultFailed
        case .llmChatUsed: return .llmChatUsed
        case .llmChatFailed: return .llmChatFailed
        case .llmTransformUsed: return .llmTransformUsed
        case .llmTransformFailed: return .llmTransformFailed
        case .transformExecuted: return .transformExecuted
        case .transformFailed: return .transformFailed
        case .transformOperation: return .transformOperation
        case .askMenuOpened: return .askMenuOpened
        case .askPromptFired: return .askPromptFired
        case .llmFormatterUsed: return .llmFormatterUsed
        case .llmFormatterFailed: return .llmFormatterFailed
        case .llmProviderUnavailable: return .llmProviderUnavailable
        case .llmOperation: return .llmOperation
        case .historySearched: return .historySearched
        case .historyReplayed: return .historyReplayed
        case .copyToClipboard: return .copyToClipboard
        case .hotkeyCustomized: return .hotkeyCustomized
        case .processingModeChanged: return .processingModeChanged
        case .customWordAdded: return .customWordAdded
        case .customWordDeleted: return .customWordDeleted
        case .snippetAdded: return .snippetAdded
        case .snippetEdited: return .snippetEdited
        case .snippetDeleted: return .snippetDeleted
        case .settingChanged: return .settingChanged
        case .telemetryOptedOut: return .telemetryOptedOut
        case .onboardingCompleted: return .onboardingCompleted
        case .onboardingStep: return .onboardingStep
        case .licenseActivated: return .licenseActivated
        case .licenseActivationFailed: return .licenseActivationFailed
        case .trialStarted: return .trialStarted
        case .trialExpired: return .trialExpired
        case .purchaseStarted: return .purchaseStarted
        case .restoreAttempted: return .restoreAttempted
        case .restoreSucceeded: return .restoreSucceeded
        case .restoreFailed: return .restoreFailed
        case .permissionPrompted: return .permissionPrompted
        case .permissionGranted: return .permissionGranted
        case .permissionDenied: return .permissionDenied
        case .modelLoaded: return .modelLoaded
        case .modelDownloadStarted: return .modelDownloadStarted
        case .modelDownloadCompleted: return .modelDownloadCompleted
        case .modelDownloadFailed: return .modelDownloadFailed
        case .modelOperation: return .modelOperation
        case .speechEngineSwitchOperation: return .speechEngineSwitchOperation
        case .feedbackSubmitted: return .feedbackSubmitted
        case .feedbackOperation: return .feedbackOperation
        case .transcriptionDeleted: return .transcriptionDeleted
        case .dictationDeleted: return .dictationDeleted
        case .transcriptionFavorited: return .transcriptionFavorited
        case .dictationUndoUsed: return .dictationUndoUsed
        case .chatConversationCreated: return .chatConversationCreated
        case .promptCreated: return .promptCreated
        case .promptUpdated: return .promptUpdated
        case .promptDeleted: return .promptDeleted
        case .keystrokeSnippetFired: return .keystrokeSnippetFired
        case .meetingRecordingStarted: return .meetingRecordingStarted
        case .meetingRecordingCompleted: return .meetingRecordingCompleted
        case .meetingRecordingCancelled: return .meetingRecordingCancelled
        case .meetingRecordingFailed: return .meetingRecordingFailed
        case .meetingOperation: return .meetingOperation
        case .meetingRecoveryDiscovered: return .meetingRecoveryDiscovered
        case .meetingRecoveryStarted: return .meetingRecoveryStarted
        case .meetingRecoveryCompleted: return .meetingRecoveryCompleted
        case .meetingRecoveryDiscarded: return .meetingRecoveryDiscarded
        case .meetingRecoveryFailed: return .meetingRecoveryFailed
        case .vadModelPrep: return .vadModelPrep
        case .calendarReminderShown: return .calendarReminderShown
        case .calendarAutoStartTriggered: return .calendarAutoStartTriggered
        case .calendarAutoStartCancelled: return .calendarAutoStartCancelled
        case .calendarAutoStartFailed: return .calendarAutoStartFailed
        case .sttRuntimeUnhealthy: return .sttRuntimeUnhealthy
        case .errorOccurred: return .errorOccurred
        case .crashOccurred: return .crashOccurred
        case .cliOperation: return .cliOperation
        case .autoSaveOperation: return .autoSaveOperation
        }
    }

    var props: [String: String]? {
        switch self {
        case .appLaunched,
             .historySearched,
             .historyReplayed,
             .customWordAdded,
             .customWordDeleted,
             .snippetAdded,
             .snippetEdited,
             .snippetDeleted,
             .telemetryOptedOut,
             .transcriptionDeleted,
             .dictationDeleted,
             .dictationUndoUsed,
             .chatConversationCreated,
             .promptCreated,
             .promptUpdated,
             .promptDeleted,
             .askMenuOpened,
             .licenseActivated,
             .trialStarted,
             .trialExpired,
             .purchaseStarted,
             .restoreAttempted,
             .restoreSucceeded:
            return nil
        case .hotkeyCustomized(let surface, let kind):
            return Self.compactProps(
                ("surface", surface.rawValue),
                ("kind", kind.rawValue)
            )
        case .appQuit(let sessionDurationSeconds):
            return ["session_duration_seconds": Self.format(sessionDurationSeconds)]
        case .dictationStarted(let trigger, let mode):
            return Self.compactProps(
                ("trigger", trigger?.rawValue),
                ("mode", mode?.rawValue)
            )
        case .dictationCompleted(
            let durationSeconds,
            let wordCount,
            let mode,
            let speechEngine,
            let engineVariant,
            let language,
            let appCategory,
            let device
        ):
            return Self.mergeDevice(Self.compactProps(
                ("duration_seconds", Self.format(durationSeconds)),
                ("word_count", "\(wordCount)"),
                ("mode", mode?.rawValue),
                ("speech_engine", speechEngine),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("language", Self.safeLanguageCode(language)),
                ("app_category", appCategory?.rawValue)
            ), device)
        case .firstDictationCompleted(let activationWindow):
            return ["activation_window": activationWindow.rawValue]
        case .dictationCancelled(let durationSeconds, let reason, let device):
            return Self.mergeDevice(Self.compactProps(
                ("duration_seconds", durationSeconds.map(Self.format)),
                ("reason", reason?.rawValue)
            ), device)
        case .dictationEmpty(let durationSeconds, let device):
            return Self.mergeDevice(Self.compactProps(
                ("duration_seconds", durationSeconds.map(Self.format))
            ), device)
        case .dictationFailed(let errorType, let errorDetail, let device):
            var props = ["error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return Self.mergeDevice(props, device)
        case .dictationOperation(
            let operationID,
            let operationContext,
            let outcome,
            let trigger,
            let mode,
            let durationSeconds,
            let wordCount,
            let errorType,
            let cancelReason,
            let speechEngine,
            let engineVariant,
            let language,
            let appCategory,
            let device
        ):
            return Self.mergeDevice(Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("outcome", outcome.rawValue),
                ("trigger", trigger?.rawValue),
                ("mode", mode?.rawValue),
                ("duration_seconds", durationSeconds.map(Self.format)),
                ("word_count", wordCount.map(String.init)),
                ("speech_engine", speechEngine),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("language", Self.safeLanguageCode(language)),
                ("app_category", appCategory?.rawValue),
                ("error_type", errorType),
                ("cancel_reason", cancelReason?.rawValue)
            ), device)
        case .dictationFirstLoadCaptionShown(let firstInstall):
            return ["first_install": Self.boolString(firstInstall)]
        case .dictationFirstLoadCaptionDuration(let durationMs, let outcome):
            return [
                "duration_ms": "\(durationMs)",
                "outcome": outcome,
            ]
        case .transcriptionStarted(let source, let audioDurationSeconds):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format))
            )
        case .transcriptionCompleted(
            let source,
            let audioDurationSeconds,
            let processingSeconds,
            let wordCount,
            let speakerCount,
            let diarizationRequested,
            let diarizationApplied,
            let speechEngine,
            let engineVariant,
            let language
        ):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format)),
                ("processing_seconds", processingSeconds.map(Self.format)),
                ("word_count", "\(wordCount)"),
                ("speaker_count", speakerCount.map(String.init)),
                ("diarization_requested", Self.boolString(diarizationRequested)),
                ("diarization_applied", Self.boolString(diarizationApplied)),
                ("speech_engine", speechEngine),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("language", Self.safeLanguageCode(language))
            )
        case .transcriptionCancelled(let source, let audioDurationSeconds, let stage):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format)),
                ("stage", stage.rawValue)
            )
        case .transcriptionFailed(let source, let stage, let errorType, let errorDetail):
            var props = [
                "source": source.rawValue,
                "stage": stage.rawValue,
                "error_type": errorType,
            ]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .transcriptionOperation(
            let operationID,
            let operationContext,
            let outcome,
            let source,
            let stage,
            let durationSeconds,
            let audioDurationSeconds,
            let processingSeconds,
            let wordCount,
            let speakerCount,
            let diarizationRequested,
            let diarizationApplied,
            let inputKind,
            let mediaExtension,
            let fileSizeBucket,
            let speechEngine,
            let engineVariant,
            let language,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("outcome", outcome.rawValue),
                ("source", source.rawValue),
                ("stage", stage?.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format)),
                ("processing_seconds", processingSeconds.map(Self.format)),
                ("word_count", wordCount.map(String.init)),
                ("speaker_count", speakerCount.map(String.init)),
                ("diarization_requested", Self.boolString(diarizationRequested)),
                ("diarization_applied", Self.boolString(diarizationApplied)),
                ("input_kind", inputKind?.rawValue),
                ("media_extension", mediaExtension),
                ("file_size_bucket", fileSizeBucket),
                ("speech_engine", speechEngine),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("language", Self.safeLanguageCode(language)),
                ("error_type", errorType)
            )
        case .diarizationStarted(let source):
            return ["source": source.rawValue]
        case .diarizationCompleted(let source, let speakerCount, let durationSeconds):
            return [
                "source": source.rawValue,
                "speaker_count": "\(speakerCount)",
                "duration_seconds": Self.format(durationSeconds)
            ]
        case .diarizationFailed(let source, let errorType, let errorDetail):
            var props = ["source": source.rawValue, "error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .exportUsed(let format):
            return ["format": format]
        case .llmPromptResultUsed(let provider):
            return ["provider": provider]
        case .llmPromptResultFailed(let provider, let errorType, let errorDetail):
            var props = ["provider": provider, "error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .llmChatUsed(let provider, let source, let messageCount):
            return ["provider": provider, "source": source.rawValue, "message_count": "\(messageCount)"]
        case .llmChatFailed(let provider, let source, let errorType, let errorDetail):
            var props = ["provider": provider, "source": source.rawValue, "error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .llmTransformUsed(let provider):
            return ["provider": provider]
        case .llmTransformFailed(let provider, let errorType, let errorDetail):
            var props = ["provider": provider, "error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .transformExecuted(let name, let capture, let replace, let llmMs, let totalMs, let appCategory):
            return Self.compactProps(
                ("transform_name", name.rawValue),
                ("capture_path", capture.rawValue),
                ("replace_path", replace.rawValue),
                ("llm_ms", "\(llmMs)"),
                ("total_ms", "\(totalMs)"),
                ("app_category", appCategory?.rawValue)
            )
        case .transformFailed(let name, let reason):
            return [
                "transform_name": name.rawValue,
                "reason": reason.rawValue,
            ]
        case .transformOperation(
            let operationID,
            let operationContext,
            let outcome,
            let name,
            let stage,
            let capture,
            let replace,
            let durationSeconds,
            let llmMs,
            let totalMs,
            let appCategory,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("outcome", outcome.rawValue),
                ("transform_name", name.rawValue),
                ("stage", stage?.rawValue),
                ("capture_path", capture?.rawValue),
                ("replace_path", replace?.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("llm_ms", llmMs.map(String.init)),
                ("total_ms", totalMs.map(String.init)),
                ("app_category", appCategory?.rawValue),
                ("error_type", errorType?.rawValue)
            )
        case .askPromptFired(let source, let group, let label):
            return [
                "source": source.rawValue,
                "group": group,
                "label": label,
            ]
        case .llmFormatterUsed(
            let provider,
            let source,
            let durationSeconds,
            let inputChars,
            let outputChars,
            let defaultPromptUsed,
            let inputTruncated
        ):
            return [
                "provider": provider,
                "source": source.rawValue,
                "duration_seconds": Self.format(durationSeconds),
                "input_chars": "\(inputChars)",
                "output_chars": "\(outputChars)",
                "default_prompt_used": Self.boolString(defaultPromptUsed),
                "input_truncated": Self.boolString(inputTruncated),
            ]
        case .llmFormatterFailed(
            let provider,
            let source,
            let durationSeconds,
            let errorType,
            let defaultPromptUsed,
            let inputTruncated
        ):
            return [
                "provider": provider,
                "source": source.rawValue,
                "duration_seconds": Self.format(durationSeconds),
                "error_type": errorType,
                "default_prompt_used": Self.boolString(defaultPromptUsed),
                "input_truncated": Self.boolString(inputTruncated),
            ]
        case .llmProviderUnavailable(let provider, let errorType, let feature, let source):
            var props: [String: String] = [
                "provider": provider,
                "error_type": errorType,
                "feature": feature.rawValue,
            ]
            if let source { props["source"] = source.rawValue }
            return props
        case .llmOperation(
            let operationID,
            let operationContext,
            let feature,
            let provider,
            let streaming,
            let outcome,
            let durationSeconds,
            let inputChars,
            let outputChars,
            let inputTruncated,
            let promptDefaultUsed,
            let messageCount,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("feature", feature),
                ("provider", provider),
                ("streaming", Self.boolString(streaming)),
                ("outcome", outcome.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("input_chars", inputChars.map(String.init)),
                ("output_chars", outputChars.map(String.init)),
                ("input_truncated", inputTruncated.map(Self.boolString)),
                ("prompt_default_used", promptDefaultUsed.map(Self.boolString)),
                ("message_count", messageCount.map(String.init)),
                ("error_type", errorType)
            )
        case .copyToClipboard(let source):
            return ["source": source.rawValue]
        case .processingModeChanged(let mode):
            return ["mode": mode]
        case .settingChanged(let setting):
            return ["setting": setting.rawValue]
        case .onboardingCompleted(let durationSeconds):
            return Self.compactProps(
                ("duration_seconds", durationSeconds.map(Self.format))
            )
        case .onboardingStep(let step):
            return ["step": step]
        case .licenseActivationFailed(let errorType, let errorDetail):
            var props = ["error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .restoreFailed(let errorType, let errorDetail):
            return Self.compactProps(("error_type", errorType), ("error_detail", Self.sanitizedErrorDetail(errorDetail)))
        case .permissionPrompted(let permission):
            return ["permission": permission.rawValue]
        case .permissionGranted(let permission):
            return ["permission": permission.rawValue]
        case .permissionDenied(let permission):
            return ["permission": permission.rawValue]
        case .modelLoaded(let loadTimeSeconds, let modelKind, let speechEngine, let engineVariant):
            return Self.compactProps(
                ("load_time_seconds", Self.format(loadTimeSeconds)),
                ("model_kind", modelKind?.rawValue),
                ("speech_engine", speechEngine?.rawValue),
                ("engine_variant", Self.safeEngineVariant(engineVariant))
            )
        case .modelDownloadStarted(let modelKind, let speechEngine, let engineVariant):
            return Self.compactProps(
                ("model_kind", modelKind?.rawValue),
                ("speech_engine", speechEngine?.rawValue),
                ("engine_variant", Self.safeEngineVariant(engineVariant))
            )
        case .modelDownloadCompleted(let durationSeconds, let modelKind, let speechEngine, let engineVariant):
            return Self.compactProps(
                ("duration_seconds", Self.format(durationSeconds)),
                ("model_kind", modelKind?.rawValue),
                ("speech_engine", speechEngine?.rawValue),
                ("engine_variant", Self.safeEngineVariant(engineVariant))
            )
        case .modelDownloadFailed(let errorType, let errorDetail, let modelKind, let speechEngine, let engineVariant):
            var props = Self.compactProps(
                ("error_type", errorType),
                ("model_kind", modelKind?.rawValue),
                ("speech_engine", speechEngine?.rawValue),
                ("engine_variant", Self.safeEngineVariant(engineVariant))
            ) ?? [:]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .modelOperation(
            let operationID,
            let operationContext,
            let action,
            let outcome,
            let stage,
            let modelKind,
            let speechEngine,
            let engineVariant,
            let durationSeconds,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("action", action.rawValue),
                ("outcome", outcome.rawValue),
                ("stage", stage?.rawValue),
                ("model_kind", modelKind?.rawValue),
                ("speech_engine", speechEngine?.rawValue),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("duration_seconds", Self.format(durationSeconds)),
                ("error_type", errorType)
            )
        case .speechEngineSwitchOperation(
            let operationID,
            let operationContext,
            let fromEngine,
            let toEngine,
            let outcome,
            let durationSeconds,
            let blockedReason,
            let errorType,
            let wasCold
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("from_engine", fromEngine.rawValue),
                ("to_engine", toEngine.rawValue),
                ("outcome", outcome.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("blocked_reason", blockedReason?.rawValue),
                ("error_type", errorType),
                ("was_cold", Self.boolString(wasCold))
            )
        case .feedbackSubmitted(let category):
            return ["category": category]
        case .feedbackOperation(
            let operationID,
            let operationContext,
            let category,
            let outcome,
            let durationSeconds,
            let screenshotAttached,
            let diagnosticLogAttached,
            let systemInfoIncluded,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("category", category),
                ("outcome", outcome.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("screenshot_attached", Self.boolString(screenshotAttached)),
                ("diagnostic_log_attached", Self.boolString(diagnosticLogAttached)),
                ("system_info_included", Self.boolString(systemInfoIncluded)),
                ("error_type", errorType)
            )
        case .transcriptionFavorited(let isFavorite):
            return ["is_favorite": isFavorite ? "true" : "false"]
        case .keystrokeSnippetFired(let action):
            return ["action": action]
        case .meetingRecordingStarted(let trigger):
            return Self.compactProps(("trigger", trigger?.rawValue))
        case .meetingRecordingCompleted(let durationSeconds, let liveWordCount, let liveTranscriptLagged):
            return [
                "duration_seconds": Self.format(durationSeconds),
                "live_word_count": "\(liveWordCount)",
                "live_transcript_lagged": Self.boolString(liveTranscriptLagged),
            ]
        case .meetingRecordingCancelled(let durationSeconds):
            return ["duration_seconds": Self.format(durationSeconds)]
        case .meetingRecordingFailed(let errorType, let errorDetail):
            var props = ["error_type": errorType]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .meetingOperation(
            let operationID,
            let operationContext,
            let outcome,
            let trigger,
            let stage,
            let durationSeconds,
            let liveWordCount,
            let liveTranscriptLagged,
            let microphoneTrackPresent,
            let systemTrackPresent,
            let notesUsed,
            let notesLengthBucket,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("outcome", outcome.rawValue),
                ("trigger", trigger?.rawValue),
                ("stage", stage?.rawValue),
                ("duration_seconds", durationSeconds.map(Self.format)),
                ("live_word_count", liveWordCount.map(String.init)),
                ("live_transcript_lagged", liveTranscriptLagged.map(Self.boolString)),
                ("microphone_track_present", microphoneTrackPresent.map(Self.boolString)),
                ("system_track_present", systemTrackPresent.map(Self.boolString)),
                ("notes_used", notesUsed.map(Self.boolString)),
                ("notes_length_bucket", notesLengthBucket),
                ("error_type", errorType)
            )
        case .meetingRecoveryDiscovered(let count, let source):
            return [
                "count": "\(count)",
                "source": source.rawValue,
            ]
        case .meetingRecoveryStarted(let count, let source):
            return [
                "count": "\(count)",
                "source": source.rawValue,
            ]
        case .meetingRecoveryCompleted(let count, let durationSeconds, let source):
            return [
                "count": "\(count)",
                "duration_seconds": Self.format(durationSeconds),
                "source": source.rawValue,
            ]
        case .meetingRecoveryDiscarded(let count, let source):
            return [
                "count": "\(count)",
                "source": source.rawValue,
            ]
        case .meetingRecoveryFailed(let count, let source, let errorType, let errorDetail):
            var props = [
                "count": "\(count)",
                "source": source.rawValue,
                "error_type": errorType,
            ]
            if let errorDetail = Self.sanitizedErrorDetail(errorDetail) { props["error_detail"] = errorDetail }
            return props
        case .vadModelPrep(let outcome):
            return ["outcome": outcome.rawValue]
        case .calendarReminderShown(let mode, let leadMinutes, let hasMeetUrl):
            return [
                "mode": mode,
                "lead_minutes": "\(leadMinutes)",
                "has_meet_url": Self.boolString(hasMeetUrl),
            ]
        case .calendarAutoStartTriggered(let leadSeconds, let hasMeetUrl):
            return [
                "lead_seconds": "\(leadSeconds)",
                "has_meet_url": Self.boolString(hasMeetUrl),
            ]
        case .calendarAutoStartCancelled(let reason):
            return ["reason": reason]
        case .calendarAutoStartFailed(let reason):
            return ["reason": reason]
        case .sttRuntimeUnhealthy(let reason):
            return ["reason": reason]
        case .errorOccurred(let domain, let code, let description):
            // Defense in depth: sanitize() at the boundary so any caller route
            // (including future call sites that forget to run
            // `TelemetryErrorClassifier.errorDetail` first) cannot leak file
            // paths or URLs into telemetry. `sanitize` is idempotent, so
            // double-sanitizing existing well-behaved callers costs nothing.
            return [
                "domain": domain,
                "code": code,
                "description": String(TelemetryErrorClassifier.sanitize(description).prefix(512)),
            ]
        case .crashOccurred(let crashType, let signal, let name, let crashTimestamp,
                            let crashAppVer, let crashOsVer, let uuid, let slide,
                            let reason, let stackTrace):
            return Self.compactProps(
                ("crash_type", crashType),
                ("signal", signal),
                ("name", name),
                ("crash_ts", crashTimestamp),
                ("crash_app_ver", crashAppVer),
                ("crash_os_ver", crashOsVer),
                ("uuid", uuid),
                ("slide", slide),
                ("reason", reason.map { String($0.prefix(512)) }),
                ("stack_trace", String(stackTrace.prefix(Self.maxCrashStackTraceCharacters)))
            )
        case .cliOperation(
            let operationID,
            let operationContext,
            let command,
            let subcommand,
            let outcome,
            let durationSeconds,
            let inputKind,
            let outputFormat,
            let json,
            let exitCode,
            let errorType
        ):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("command", command),
                ("subcommand", subcommand),
                ("outcome", outcome.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("input_kind", inputKind?.rawValue),
                ("output_format", outputFormat),
                ("json", json.map(Self.boolString)),
                ("exit_code", exitCode.map(String.init)),
                ("error_type", errorType)
            )
        case .autoSaveOperation(let operationID, let operationContext, let scope, let format, let outcome, let durationSeconds, let errorType):
            return Self.compactProps(
                ("operation_id", operationID),
                ("workflow_id", operationContext?.workflowID),
                ("parent_operation_id", operationContext?.parentOperationID),
                ("scope", scope.rawValue),
                ("format", format.rawValue),
                ("outcome", outcome.rawValue),
                ("duration_seconds", Self.format(durationSeconds)),
                ("error_type", errorType)
            )
        }
    }

    private static func compactProps(_ entries: (String, String?)...) -> [String: String]? {
        let pairs: [(String, String)] = entries.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return (key, value)
        }
        let props = Dictionary(uniqueKeysWithValues: pairs)
        return props.isEmpty ? nil : props
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func sanitizedErrorDetail(_ detail: String?) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        return String(TelemetryErrorClassifier.sanitize(detail).prefix(512))
    }

    private static func safeEngineVariant(_ variant: String?) -> String? {
        guard let normalized = SpeechEnginePreference.normalizeModelVariant(variant) else {
            return nil
        }

        let allowedVariants: Set<String> = [
            "tiny",
            "base",
            "small",
            "medium",
            "large",
            "large-v2",
            "large-v3",
            SpeechEnginePreference.defaultWhisperModelVariant,
        ]

        return allowedVariants.contains(normalized) ? normalized : "custom"
    }

    private static func safeLanguageCode(_ language: String?) -> String? {
        SpeechEnginePreference.normalizeKnownLanguage(language)
    }

    private static func mergeDevice(_ base: [String: String]?, _ device: RecordingDeviceInfo?) -> [String: String]? {
        guard let device else { return base }
        var merged = base ?? [:]
        merged["device_transport"] = device.transport
        if let sub = device.subTransport { merged["device_sub_transport"] = sub }
        merged["device_sample_rate"] = "\(Int(device.sampleRate))"
        merged["device_channels"] = "\(device.channels)"
        if device.fallbackUsed { merged["device_fallback"] = "true" }
        if device.requestedDeviceUID != nil { merged["device_selected"] = "true" }
        return merged
    }
}

public enum TelemetryImplementedContract {
    public static let requiredProps: [TelemetryEventName: Set<String>] = [
        .appLaunched: [],
        .appQuit: ["session_duration_seconds"],
        .dictationStarted: [],
        .dictationCompleted: ["duration_seconds", "word_count"],
        .firstDictationCompleted: ["activation_window"],
        .dictationCancelled: [],
        .dictationEmpty: [],
        .dictationFailed: ["error_type"],
        .dictationOperation: ["operation_id", "outcome"],
        .dictationFirstLoadCaptionShown: ["first_install"],
        .dictationFirstLoadCaptionDuration: ["duration_ms", "outcome"],
        .transcriptionStarted: ["source"],
        .transcriptionCompleted: ["source", "word_count", "diarization_requested", "diarization_applied"],
        .transcriptionCancelled: ["source", "stage"],
        .transcriptionFailed: ["source", "stage", "error_type"],
        .transcriptionOperation: ["operation_id", "outcome", "source", "duration_seconds", "diarization_requested", "diarization_applied"],
        .diarizationStarted: ["source"],
        .diarizationCompleted: ["source", "speaker_count"],
        .diarizationFailed: ["source", "error_type"],
        .exportUsed: ["format"],
        .llmPromptResultUsed: ["provider"],
        .llmPromptResultFailed: ["provider", "error_type"],
        .llmChatUsed: ["provider", "source", "message_count"],
        .llmChatFailed: ["provider", "source", "error_type"],
        .llmTransformUsed: ["provider"],
        .llmTransformFailed: ["provider", "error_type"],
        .transformExecuted: ["transform_name", "capture_path", "replace_path", "llm_ms", "total_ms"],
        .transformFailed: ["transform_name", "reason"],
        .transformOperation: ["operation_id", "outcome", "transform_name", "duration_seconds"],
        .askMenuOpened: [],
        .askPromptFired: ["source", "group", "label"],
        .llmFormatterUsed: ["provider", "source", "duration_seconds", "input_chars", "output_chars", "default_prompt_used", "input_truncated"],
        .llmFormatterFailed: ["provider", "source", "duration_seconds", "error_type", "default_prompt_used", "input_truncated"],
        .llmProviderUnavailable: ["provider", "error_type", "feature"],
        .llmOperation: ["operation_id", "feature", "provider", "streaming", "outcome", "duration_seconds"],
        .historySearched: [],
        .historyReplayed: [],
        .copyToClipboard: ["source"],
        .hotkeyCustomized: ["surface", "kind"],
        .processingModeChanged: ["mode"],
        .customWordAdded: [],
        .customWordDeleted: [],
        .snippetAdded: [],
        .snippetEdited: [],
        .snippetDeleted: [],
        .settingChanged: ["setting"],
        .telemetryOptedOut: [],
        .onboardingCompleted: [],
        .onboardingStep: ["step"],
        .licenseActivated: [],
        .licenseActivationFailed: ["error_type"],
        .trialStarted: [],
        .trialExpired: [],
        .purchaseStarted: [],
        .restoreAttempted: [],
        .restoreSucceeded: [],
        .restoreFailed: [],
        .permissionPrompted: ["permission"],
        .permissionGranted: ["permission"],
        .permissionDenied: ["permission"],
        .modelLoaded: ["load_time_seconds"],
        .modelDownloadStarted: [],
        .modelDownloadCompleted: ["duration_seconds"],
        .modelDownloadFailed: ["error_type"],
        .modelOperation: ["operation_id", "action", "outcome", "duration_seconds"],
        .speechEngineSwitchOperation: ["operation_id", "from_engine", "to_engine", "outcome", "duration_seconds", "was_cold"],
        .feedbackSubmitted: ["category"],
        .feedbackOperation: ["operation_id", "category", "outcome", "duration_seconds", "screenshot_attached", "diagnostic_log_attached", "system_info_included"],
        .transcriptionDeleted: [],
        .dictationDeleted: [],
        .transcriptionFavorited: ["is_favorite"],
        .dictationUndoUsed: [],
        .chatConversationCreated: [],
        .promptCreated: [],
        .promptUpdated: [],
        .promptDeleted: [],
        .keystrokeSnippetFired: ["action"],
        .meetingRecordingStarted: [],
        .meetingRecordingCompleted: ["duration_seconds", "live_word_count", "live_transcript_lagged"],
        .meetingRecordingCancelled: ["duration_seconds"],
        .meetingRecordingFailed: ["error_type"],
        .meetingOperation: ["operation_id", "outcome"],
        .meetingRecoveryDiscovered: ["count", "source"],
        .meetingRecoveryStarted: ["count", "source"],
        .meetingRecoveryCompleted: ["count", "duration_seconds", "source"],
        .meetingRecoveryDiscarded: ["count", "source"],
        .meetingRecoveryFailed: ["count", "source", "error_type"],
        .vadModelPrep: ["outcome"],
        .calendarReminderShown: ["mode", "lead_minutes", "has_meet_url"],
        .calendarAutoStartTriggered: ["lead_seconds", "has_meet_url"],
        .calendarAutoStartCancelled: ["reason"],
        .calendarAutoStartFailed: ["reason"],
        .sttRuntimeUnhealthy: ["reason"],
        .errorOccurred: ["domain", "code", "description"],
        .crashOccurred: ["crash_type", "signal", "name", "crash_ts", "crash_app_ver"],
        .cliOperation: ["operation_id", "command", "outcome", "duration_seconds"],
        .autoSaveOperation: ["operation_id", "scope", "format", "outcome", "duration_seconds"],
    ]

    public static var implementedEventNames: Set<TelemetryEventName> {
        Set(requiredProps.keys)
    }
}

/// A single telemetry event queued for batch submission.
public struct TelemetryEvent: Sendable, Encodable {
    public let eventId: String
    public let event: String
    public let props: [String: String]?
    public let appVer: String
    public let osVer: String
    public let locale: String?
    public let chip: String
    public let session: String
    public let surface: String
    public let ts: String

    public init(
        spec: TelemetryEventSpec,
        appVer: String,
        osVer: String,
        locale: String?,
        chip: String,
        session: String,
        surface: String = "gui",
        ts: Date = Date()
    ) {
        self.eventId = UUID().uuidString
        self.event = spec.name.rawValue
        self.props = spec.props
        self.appVer = appVer
        self.osVer = osVer
        self.locale = locale
        self.chip = chip
        self.session = session
        self.surface = surface == "cli" ? "cli" : "gui"
        self.ts = ISO8601DateFormatter.string(
            from: ts,
            timeZone: .gmt,
            formatOptions: [.withInternetDateTime]
        )
    }
}

/// Batch payload sent to the telemetry endpoint.
struct TelemetryPayload: Sendable, Encodable {
    let events: [TelemetryEvent]
}
