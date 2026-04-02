import Foundation

public enum TelemetryEventName: String, Sendable, CaseIterable {
    case appLaunched = "app_launched"
    case appQuit = "app_quit"
    case dictationStarted = "dictation_started"
    case dictationCompleted = "dictation_completed"
    case dictationCancelled = "dictation_cancelled"
    case dictationEmpty = "dictation_empty"
    case dictationFailed = "dictation_failed"
    case transcriptionStarted = "transcription_started"
    case transcriptionCompleted = "transcription_completed"
    case transcriptionCancelled = "transcription_cancelled"
    case transcriptionFailed = "transcription_failed"
    case diarizationStarted = "diarization_started"
    case diarizationCompleted = "diarization_completed"
    case diarizationFailed = "diarization_failed"
    case exportUsed = "export_used"
    case llmSummaryUsed = "llm_summary_used"
    case llmSummaryFailed = "llm_summary_failed"
    case llmChatUsed = "llm_chat_used"
    case llmChatFailed = "llm_chat_failed"
    case historySearched = "history_searched"
    case historyReplayed = "history_replayed"
    case copyToClipboard = "copy_to_clipboard"
    case hotkeyCustomized = "hotkey_customized"
    case processingModeChanged = "processing_mode_changed"
    case customWordAdded = "custom_word_added"
    case snippetAdded = "snippet_added"
    case keystrokeSnippetFired = "keystroke_snippet_fired"
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
    // Errors
    case errorOccurred = "error_occurred"
    // Crashes
    case crashOccurred = "crash_occurred"
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
    case dragDrop = "drag_drop"
}

public enum TelemetryCopySource: String, Sendable, Equatable {
    case dictation
    case transcription
    case history
}

public enum TelemetryPermission: String, Sendable, Equatable {
    case microphone
    case accessibility
}

public enum TelemetrySettingName: String, Sendable, Equatable {
    case saveHistory = "save_history"
    case audioRetention = "audio_retention"
    case menuBarOnly = "menu_bar_only"
    case hidePill = "hide_pill"
    case saveTranscriptionAudio = "save_transcription_audio"
}

public enum TelemetryEventSpec: Sendable {
    case appLaunched
    case appQuit(sessionDurationSeconds: Double)
    case dictationStarted(trigger: TelemetryDictationTrigger?, mode: TelemetryDictationMode?)
    case dictationCompleted(durationSeconds: Double, wordCount: Int, mode: TelemetryDictationMode?, device: RecordingDeviceInfo? = nil)
    case dictationCancelled(durationSeconds: Double?, reason: TelemetryDictationCancelReason?, device: RecordingDeviceInfo? = nil)
    case dictationEmpty(durationSeconds: Double?, device: RecordingDeviceInfo? = nil)
    case dictationFailed(errorType: String, errorDetail: String? = nil, device: RecordingDeviceInfo? = nil)
    case transcriptionStarted(source: TelemetryTranscriptionSource, audioDurationSeconds: Double?)
    case transcriptionCompleted(
        source: TelemetryTranscriptionSource,
        audioDurationSeconds: Double?,
        processingSeconds: Double?,
        wordCount: Int
    )
    case transcriptionCancelled(source: TelemetryTranscriptionSource, audioDurationSeconds: Double?)
    case transcriptionFailed(source: TelemetryTranscriptionSource, errorType: String, errorDetail: String? = nil)
    case diarizationStarted(source: TelemetryTranscriptionSource)
    case diarizationCompleted(source: TelemetryTranscriptionSource, speakerCount: Int, durationSeconds: Double)
    case diarizationFailed(source: TelemetryTranscriptionSource, errorType: String, errorDetail: String? = nil)
    case exportUsed(format: String)
    case llmSummaryUsed(provider: String)
    case llmSummaryFailed(provider: String, errorType: String, errorDetail: String? = nil)
    case llmChatUsed(provider: String, messageCount: Int)
    case llmChatFailed(provider: String, errorType: String, errorDetail: String? = nil)
    case historySearched
    case historyReplayed
    case copyToClipboard(source: TelemetryCopySource)
    case hotkeyCustomized
    case processingModeChanged(mode: String)
    case customWordAdded
    case snippetAdded
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
    case modelLoaded(loadTimeSeconds: Double)
    case modelDownloadStarted
    case modelDownloadCompleted(durationSeconds: Double)
    case modelDownloadFailed(errorType: String, errorDetail: String? = nil)
    // Keystroke actions
    case keystrokeSnippetFired(action: String)
    // Errors
    case errorOccurred(domain: String, code: String, description: String)
    // Crashes
    case crashOccurred(
        crashType: String, signal: String, name: String,
        crashTimestamp: String, crashAppVer: String,
        crashOsVer: String, uuid: String,
        slide: String, reason: String?, stackTrace: String
    )
}

extension TelemetryEventSpec {
    var name: TelemetryEventName {
        switch self {
        case .appLaunched: return .appLaunched
        case .appQuit: return .appQuit
        case .dictationStarted: return .dictationStarted
        case .dictationCompleted: return .dictationCompleted
        case .dictationCancelled: return .dictationCancelled
        case .dictationEmpty: return .dictationEmpty
        case .dictationFailed: return .dictationFailed
        case .transcriptionStarted: return .transcriptionStarted
        case .transcriptionCompleted: return .transcriptionCompleted
        case .transcriptionCancelled: return .transcriptionCancelled
        case .transcriptionFailed: return .transcriptionFailed
        case .diarizationStarted: return .diarizationStarted
        case .diarizationCompleted: return .diarizationCompleted
        case .diarizationFailed: return .diarizationFailed
        case .exportUsed: return .exportUsed
        case .llmSummaryUsed: return .llmSummaryUsed
        case .llmSummaryFailed: return .llmSummaryFailed
        case .llmChatUsed: return .llmChatUsed
        case .llmChatFailed: return .llmChatFailed
        case .historySearched: return .historySearched
        case .historyReplayed: return .historyReplayed
        case .copyToClipboard: return .copyToClipboard
        case .hotkeyCustomized: return .hotkeyCustomized
        case .processingModeChanged: return .processingModeChanged
        case .customWordAdded: return .customWordAdded
        case .snippetAdded: return .snippetAdded
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
        case .keystrokeSnippetFired: return .keystrokeSnippetFired
        case .errorOccurred: return .errorOccurred
        case .crashOccurred: return .crashOccurred
        }
    }

    var props: [String: String]? {
        switch self {
        case .appLaunched,
             .historySearched,
             .historyReplayed,
             .hotkeyCustomized,
             .customWordAdded,
             .snippetAdded,
             .telemetryOptedOut,
             .licenseActivated,
             .trialStarted,
             .trialExpired,
             .purchaseStarted,
             .restoreAttempted,
             .restoreSucceeded:
            return nil
        case .appQuit(let sessionDurationSeconds):
            return ["session_duration_seconds": Self.format(sessionDurationSeconds)]
        case .dictationStarted(let trigger, let mode):
            return Self.compactProps(
                ("trigger", trigger?.rawValue),
                ("mode", mode?.rawValue)
            )
        case .dictationCompleted(let durationSeconds, let wordCount, let mode, let device):
            return Self.mergeDevice(Self.compactProps(
                ("duration_seconds", Self.format(durationSeconds)),
                ("word_count", "\(wordCount)"),
                ("mode", mode?.rawValue)
            ), device)
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
            if let errorDetail { props["error_detail"] = errorDetail }
            return Self.mergeDevice(props, device)
        case .transcriptionStarted(let source, let audioDurationSeconds):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format))
            )
        case .transcriptionCompleted(let source, let audioDurationSeconds, let processingSeconds, let wordCount):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format)),
                ("processing_seconds", processingSeconds.map(Self.format)),
                ("word_count", "\(wordCount)")
            )
        case .transcriptionCancelled(let source, let audioDurationSeconds):
            return Self.compactProps(
                ("source", source.rawValue),
                ("audio_duration_seconds", audioDurationSeconds.map(Self.format))
            )
        case .transcriptionFailed(let source, let errorType, let errorDetail):
            var props = ["source": source.rawValue, "error_type": errorType]
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
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
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
        case .exportUsed(let format):
            return ["format": format]
        case .llmSummaryUsed(let provider):
            return ["provider": provider]
        case .llmSummaryFailed(let provider, let errorType, let errorDetail):
            var props = ["provider": provider, "error_type": errorType]
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
        case .llmChatUsed(let provider, let messageCount):
            return ["provider": provider, "message_count": "\(messageCount)"]
        case .llmChatFailed(let provider, let errorType, let errorDetail):
            var props = ["provider": provider, "error_type": errorType]
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
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
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
        case .restoreFailed(let errorType, let errorDetail):
            return Self.compactProps(("error_type", errorType), ("error_detail", errorDetail))
        case .permissionPrompted(let permission):
            return ["permission": permission.rawValue]
        case .permissionGranted(let permission):
            return ["permission": permission.rawValue]
        case .permissionDenied(let permission):
            return ["permission": permission.rawValue]
        case .modelLoaded(let loadTimeSeconds):
            return ["load_time_seconds": Self.format(loadTimeSeconds)]
        case .modelDownloadStarted:
            return nil
        case .modelDownloadCompleted(let durationSeconds):
            return ["duration_seconds": Self.format(durationSeconds)]
        case .modelDownloadFailed(let errorType, let errorDetail):
            var props = ["error_type": errorType]
            if let errorDetail { props["error_detail"] = errorDetail }
            return props
        case .keystrokeSnippetFired(let action):
            return ["action": action]
        case .errorOccurred(let domain, let code, let description):
            return ["domain": domain, "code": code, "description": String(description.prefix(512))]
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
                ("stack_trace", String(stackTrace.prefix(2048)))
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

    private static func mergeDevice(_ base: [String: String]?, _ device: RecordingDeviceInfo?) -> [String: String]? {
        guard let device else { return base }
        var merged = base ?? [:]
        merged["device_name"] = device.deviceName
        merged["device_transport"] = device.transport
        if let sub = device.subTransport { merged["device_sub_transport"] = sub }
        merged["device_sample_rate"] = "\(Int(device.sampleRate))"
        merged["device_channels"] = "\(device.channels)"
        if device.fallbackUsed { merged["device_fallback"] = "true" }
        return merged
    }
}

public enum TelemetryImplementedContract {
    public static let requiredProps: [TelemetryEventName: Set<String>] = [
        .appLaunched: [],
        .appQuit: ["session_duration_seconds"],
        .dictationStarted: [],
        .dictationCompleted: ["duration_seconds", "word_count"],
        .dictationCancelled: [],
        .dictationEmpty: [],
        .dictationFailed: ["error_type"],
        .transcriptionStarted: ["source"],
        .transcriptionCompleted: ["source", "word_count"],
        .transcriptionCancelled: ["source"],
        .transcriptionFailed: ["source", "error_type"],
        .diarizationStarted: ["source"],
        .diarizationCompleted: ["source", "speaker_count"],
        .diarizationFailed: ["source", "error_type"],
        .exportUsed: ["format"],
        .llmSummaryUsed: ["provider"],
        .llmSummaryFailed: ["provider", "error_type"],
        .llmChatUsed: ["provider", "message_count"],
        .llmChatFailed: ["provider", "error_type"],
        .historySearched: [],
        .historyReplayed: [],
        .copyToClipboard: ["source"],
        .hotkeyCustomized: [],
        .processingModeChanged: ["mode"],
        .customWordAdded: [],
        .snippetAdded: [],
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
        .keystrokeSnippetFired: ["action"],
        .errorOccurred: ["domain", "code", "description"],
        .crashOccurred: ["crash_type", "signal", "name", "crash_ts", "crash_app_ver"],
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
    public let ts: String

    public init(
        spec: TelemetryEventSpec,
        appVer: String,
        osVer: String,
        locale: String?,
        chip: String,
        session: String,
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
        self.ts = Self.iso8601Formatter.string(from: ts)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Batch payload sent to the telemetry endpoint.
struct TelemetryPayload: Sendable, Encodable {
    let events: [TelemetryEvent]
}
