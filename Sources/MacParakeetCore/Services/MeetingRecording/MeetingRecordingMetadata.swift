import AVFAudio
import Foundation

public struct MeetingSourceAlignment: Sendable, Codable, Equatable {
    public struct Track: Sendable, Codable, Equatable {
        public let firstHostTime: UInt64?
        public let lastHostTime: UInt64?
        public let startOffsetMs: Int
        /// Frames received from the capture source. Synthetic recovery padding
        /// is intentionally excluded so coverage remains honest.
        public let writtenFrameCount: Int64
        /// End of the playable source timeline, including recovery padding.
        /// Absent in legacy metadata, where it is equivalent to written frames.
        public let timelineFrameCount: Int64?
        public let sampleRate: Double

        public init(
            firstHostTime: UInt64?,
            lastHostTime: UInt64?,
            startOffsetMs: Int,
            writtenFrameCount: Int64,
            timelineFrameCount: Int64? = nil,
            sampleRate: Double
        ) {
            self.firstHostTime = firstHostTime
            self.lastHostTime = lastHostTime
            self.startOffsetMs = startOffsetMs
            self.writtenFrameCount = writtenFrameCount
            self.timelineFrameCount = timelineFrameCount
            self.sampleRate = sampleRate
        }
    }

    public let meetingOriginHostTime: UInt64?
    public let microphone: Track?
    public let system: Track?

    public init(
        meetingOriginHostTime: UInt64?,
        microphone: Track?,
        system: Track?
    ) {
        self.meetingOriginHostTime = meetingOriginHostTime
        self.microphone = microphone
        self.system = system
    }

    public func track(for source: AudioSource) -> Track? {
        switch source {
        case .microphone:
            return microphone
        case .system:
            return system
        }
    }
}

public struct MeetingRecordingMetadata: Sendable, Codable, Equatable {
    public static let fileName = "meeting-recording-metadata.json"

    public let sourceAlignment: MeetingSourceAlignment
    /// Final frame-derived capture truth. Absent or unreadable in legacy and
    /// malformed sidecars means unknown; it never invalidates core metadata.
    public let captureReport: MeetingCaptureReport?
    public let speechEngine: SpeechEngineSelection
    public let speechEngineWasCaptured: Bool
    /// Best-effort live-preview route captured for archived provenance. `nil`
    /// for preview-unsupported engines and legacy artifacts. Crash recovery
    /// preserves this value when a finalized sidecar already contains it.
    public let previewSpeechEngine: SpeechEngineSelection?
    public let startContext: MeetingStartContext?
    public let echoSuppression: MeetingEchoSuppressionMetadata?
    public let calendarEventSnapshot: MeetingCalendarSnapshot?

    public init(
        sourceAlignment: MeetingSourceAlignment,
        captureReport: MeetingCaptureReport? = nil,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        speechEngineWasCaptured: Bool = true,
        previewSpeechEngine: SpeechEngineSelection? = nil,
        startContext: MeetingStartContext? = nil,
        echoSuppression: MeetingEchoSuppressionMetadata? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil
    ) {
        self.sourceAlignment = sourceAlignment
        self.captureReport = captureReport
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = speechEngineWasCaptured
        self.previewSpeechEngine = previewSpeechEngine
        self.startContext = startContext
        self.echoSuppression = echoSuppression
        self.calendarEventSnapshot = calendarEventSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case sourceAlignment
        case captureReport
        case speechEngine
        case previewSpeechEngine
        case startContext
        case echoSuppression
        case calendarEventSnapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceAlignment = try container.decode(MeetingSourceAlignment.self, forKey: .sourceAlignment)
        captureReport =
            (try? container.decodeIfPresent(
                MeetingCaptureReport.self,
                forKey: .captureReport
            )) ?? nil
        let decodedSpeechEngine = try container.decodeIfPresent(SpeechEngineSelection.self, forKey: .speechEngine)
        speechEngine = decodedSpeechEngine ?? SpeechEngineSelection(engine: .parakeet)
        speechEngineWasCaptured = decodedSpeechEngine != nil
        previewSpeechEngine = try? container.decodeIfPresent(
            SpeechEngineSelection.self,
            forKey: .previewSpeechEngine
        )
        startContext = (try? container.decodeIfPresent(MeetingStartContext.self, forKey: .startContext)) ?? nil
        echoSuppression = try container.decodeIfPresent(
            MeetingEchoSuppressionMetadata.self,
            forKey: .echoSuppression
        )
        calendarEventSnapshot =
            (try? container.decodeIfPresent(
                MeetingCalendarSnapshot.self,
                forKey: .calendarEventSnapshot
            )) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceAlignment, forKey: .sourceAlignment)
        try container.encodeIfPresent(captureReport, forKey: .captureReport)
        if speechEngineWasCaptured {
            try container.encode(speechEngine, forKey: .speechEngine)
        }
        try container.encodeIfPresent(previewSpeechEngine, forKey: .previewSpeechEngine)
        try container.encodeIfPresent(startContext, forKey: .startContext)
        try container.encodeIfPresent(echoSuppression, forKey: .echoSuppression)
        try container.encodeIfPresent(calendarEventSnapshot, forKey: .calendarEventSnapshot)
    }

    public func withEchoSuppression(
        _ echoSuppression: MeetingEchoSuppressionMetadata
    ) -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            sourceAlignment: sourceAlignment,
            captureReport: captureReport,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            previewSpeechEngine: previewSpeechEngine,
            startContext: startContext,
            echoSuppression: echoSuppression,
            calendarEventSnapshot: calendarEventSnapshot
        )
    }

    public func withCaptureReport(
        _ captureReport: MeetingCaptureReport?
    ) -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            sourceAlignment: sourceAlignment,
            captureReport: captureReport,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            previewSpeechEngine: previewSpeechEngine,
            startContext: startContext,
            echoSuppression: echoSuppression,
            calendarEventSnapshot: calendarEventSnapshot
        )
    }
}

public struct MeetingEchoSuppressionMetadata: Sendable, Codable, Equatable {
    public let reasonCode: MeetingCleanedMicrophoneRoutingReason
    public let modelVersion: String?
    public let renderDurationMs: Int?
    public let delayEstimateMs: Int?
    public let probeBestCorrelation: Float?

    public init(
        reasonCode: MeetingCleanedMicrophoneRoutingReason,
        modelVersion: String? = nil,
        renderDurationMs: Int? = nil,
        delayEstimateMs: Int? = nil,
        probeBestCorrelation: Float? = nil
    ) {
        self.reasonCode = reasonCode
        self.modelVersion = modelVersion
        self.renderDurationMs = renderDurationMs
        self.delayEstimateMs = delayEstimateMs
        self.probeBestCorrelation = probeBestCorrelation
    }
}

enum MeetingRecordingMetadataStore {
    static func metadataURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(MeetingRecordingMetadata.fileName)
    }

    static func save(
        _ metadata: MeetingRecordingMetadata,
        folderURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = try JSONEncoder.meetingRecordingMetadata.encode(metadata)
        let url = metadataURL(for: folderURL)
        if fileManager === FileManager.default {
            try data.write(to: url, options: .atomic)
            return
        }
        guard fileManager.createFile(atPath: url.path, contents: data) else {
            throw MeetingAudioError.storageFailed(
                "Unable to write archived meeting metadata: \(MeetingRecordingMetadata.fileName)")
        }
    }

    static func load(
        from folderURL: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingMetadata {
        let url = metadataURL(for: folderURL)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingAudioError.storageFailed(
                "Missing archived meeting metadata: \(MeetingRecordingMetadata.fileName)")
        }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw MeetingAudioError.storageFailed(
                "Unable to read archived meeting metadata: \(MeetingRecordingMetadata.fileName)")
        }
        return try JSONDecoder.meetingRecordingMetadata.decode(MeetingRecordingMetadata.self, from: data)
    }

    static func updateEchoSuppression(
        _ echoSuppression: MeetingEchoSuppressionMetadata,
        folderURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let metadata = try load(from: folderURL, fileManager: fileManager)
        try save(
            metadata.withEchoSuppression(echoSuppression),
            folderURL: folderURL,
            fileManager: fileManager
        )
    }
}

private extension JSONEncoder {
    static let meetingRecordingMetadata: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let meetingRecordingMetadata: JSONDecoder = {
        JSONDecoder()
    }()
}

extension MeetingSourceAlignment {
    static func make(
        meetingOriginHostTime: UInt64?,
        microphone: Track?,
        system: Track?
    ) -> MeetingSourceAlignment {
        MeetingSourceAlignment(
            meetingOriginHostTime: meetingOriginHostTime,
            microphone: microphone,
            system: system
        )
    }

    static func startOffsetMs(hostTime: UInt64?, originHostTime: UInt64?) -> Int {
        guard let hostTime, let originHostTime else { return 0 }
        let startSeconds = AVAudioTime.seconds(forHostTime: hostTime)
        let originSeconds = AVAudioTime.seconds(forHostTime: originHostTime)
        return Int(((startSeconds - originSeconds) * 1000).rounded())
    }

    var cleanedMicrophoneRenderDurationSeconds: TimeInterval {
        [microphone?.durationSeconds, system?.durationSeconds]
            .compactMap { $0 }
            .max() ?? 0
    }
}

extension MeetingSourceAlignment.Track {
    var durationSeconds: TimeInterval {
        let playableFrameCount = timelineFrameCount ?? writtenFrameCount
        guard playableFrameCount > 0, sampleRate.isFinite, sampleRate > 0 else {
            return 0
        }
        return Double(playableFrameCount) / sampleRate
    }
}
