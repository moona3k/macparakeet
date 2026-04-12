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

    public init(sourceAlignment: MeetingSourceAlignment) {
        self.sourceAlignment = sourceAlignment
    }
}

enum MeetingRecordingMetadataStore {
    static func metadataURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(MeetingRecordingMetadata.fileName)
    }

    static func save(_ metadata: MeetingRecordingMetadata, folderURL: URL) throws {
        let data = try JSONEncoder.meetingRecordingMetadata.encode(metadata)
        try data.write(to: metadataURL(for: folderURL), options: .atomic)
    }

    static func load(from folderURL: URL) throws -> MeetingRecordingMetadata {
        let data = try Data(contentsOf: metadataURL(for: folderURL))
        return try JSONDecoder.meetingRecordingMetadata.decode(MeetingRecordingMetadata.self, from: data)
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
