import AVFAudio
import Foundation

public struct MeetingSourceAlignment: Sendable, Codable, Equatable {
    public struct Track: Sendable, Codable, Equatable {
        public let firstHostTime: UInt64?
        public let lastHostTime: UInt64?
        public let startOffsetMs: Int
        public let writtenFrameCount: Int64
        public let sampleRate: Double

        public init(
            firstHostTime: UInt64?,
            lastHostTime: UInt64?,
            startOffsetMs: Int,
            writtenFrameCount: Int64,
            sampleRate: Double
        ) {
            self.firstHostTime = firstHostTime
            self.lastHostTime = lastHostTime
            self.startOffsetMs = startOffsetMs
            self.writtenFrameCount = writtenFrameCount
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
    public let speechEngine: SpeechEngineSelection
    public let speechEngineWasCaptured: Bool
    public let echoSuppression: MeetingEchoSuppressionMetadata?

    public init(
        sourceAlignment: MeetingSourceAlignment,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        echoSuppression: MeetingEchoSuppressionMetadata? = nil
    ) {
        self.sourceAlignment = sourceAlignment
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = true
        self.echoSuppression = echoSuppression
    }

    private init(
        sourceAlignment: MeetingSourceAlignment,
        speechEngine: SpeechEngineSelection,
        speechEngineWasCaptured: Bool,
        echoSuppression: MeetingEchoSuppressionMetadata?
    ) {
        self.sourceAlignment = sourceAlignment
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = speechEngineWasCaptured
        self.echoSuppression = echoSuppression
    }

    private enum CodingKeys: String, CodingKey {
        case sourceAlignment
        case speechEngine
        case echoSuppression
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceAlignment = try container.decode(MeetingSourceAlignment.self, forKey: .sourceAlignment)
        let decodedSpeechEngine = try container.decodeIfPresent(SpeechEngineSelection.self, forKey: .speechEngine)
        speechEngine = decodedSpeechEngine ?? SpeechEngineSelection(engine: .parakeet)
        speechEngineWasCaptured = decodedSpeechEngine != nil
        echoSuppression = try container.decodeIfPresent(
            MeetingEchoSuppressionMetadata.self,
            forKey: .echoSuppression
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceAlignment, forKey: .sourceAlignment)
        if speechEngineWasCaptured {
            try container.encode(speechEngine, forKey: .speechEngine)
        }
        try container.encodeIfPresent(echoSuppression, forKey: .echoSuppression)
    }

    public func withEchoSuppression(
        _ echoSuppression: MeetingEchoSuppressionMetadata
    ) -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            sourceAlignment: sourceAlignment,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            echoSuppression: echoSuppression
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
}
