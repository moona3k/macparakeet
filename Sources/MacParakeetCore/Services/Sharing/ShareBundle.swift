import Foundation

/// Failure reasons that keep an invalid share bundle from ever being encrypted
/// or uploaded, per the structural rules in Share Link and Bundle v1.
public enum ShareBundleError: Error, Sendable, Equatable {
    case noSections
    case emptySectionContent
    case invalidTranscriptSegmentTiming
    case multipleNotesSections
    case multipleTranscriptSections
    case payloadTooLarge(byteCount: Int)
    case unknownSchema(String)
    case unknownSchemaVersion(Int)
    case unknownSectionKind(String)
    case malformedJSON
    case invalidDisplayMetadata
}

/// The decrypted plaintext bundle exchanged by the Mac app and the browser
/// viewer, matching the `com.macparakeet.share-bundle` wire schema exactly.
public struct ShareBundle: Sendable, Equatable {
    public static let schema = "com.macparakeet.share-bundle"
    public static let schemaVersion = 1

    /// The maximum UTF-8 plaintext bundle size allowed by the contract.
    public static let maxPlaintextBytes = 2_097_152

    public let publishedAt: Date
    public let title: String?
    public let source: Source?
    public let sections: [Section]

    public enum SourceKind: String, Sendable, Equatable, Codable {
        case meeting
        case file
        case web
        case podcast
        case other
    }

    public struct Source: Sendable, Equatable {
        public var kind: SourceKind
        public var displayDate: Date?
        public var durationMs: Int?

        public init(kind: SourceKind, displayDate: Date? = nil, durationMs: Int? = nil) {
            self.kind = kind
            self.displayDate = displayDate
            self.durationMs = durationMs
        }
    }

    public struct TranscriptSegment: Sendable, Equatable {
        public let text: String
        public let startMs: Int?
        public let endMs: Int?
        public let speaker: String?

        public init(text: String, startMs: Int? = nil, endMs: Int? = nil, speaker: String? = nil) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ShareBundleError.emptySectionContent
            }
            switch (startMs, endMs) {
            case (nil, nil):
                break
            case let (.some(start), .some(end)):
                guard start >= 0, start <= end else { throw ShareBundleError.invalidTranscriptSegmentTiming }
            default:
                throw ShareBundleError.invalidTranscriptSegmentTiming
            }
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
            self.speaker = speaker
        }
    }

    public enum Section: Sendable, Equatable {
        case summary(title: String, markdown: String)
        case notes(title: String, markdown: String)
        case transcript(title: String, segments: [TranscriptSegment])
    }

    /// The only entry point: constructs a bundle only when every stable
    /// structural rule holds, so an invalid bundle can never be encrypted or
    /// uploaded.
    public init(publishedAt: Date, title: String? = nil, source: Source? = nil, sections: [Section]) throws {
        guard publishedAt.timeIntervalSince1970.isFinite,
            source?.displayDate?.timeIntervalSince1970.isFinite != false,
            (source?.durationMs ?? 0) >= 0
        else { throw ShareBundleError.invalidDisplayMetadata }
        guard !sections.isEmpty else { throw ShareBundleError.noSections }

        var notesCount = 0
        var transcriptCount = 0
        var hasNonEmptySection = false
        for section in sections {
            switch section {
            case .summary(_, let markdown):
                guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ShareBundleError.emptySectionContent
                }
                hasNonEmptySection = true
            case .notes(_, let markdown):
                notesCount += 1
                guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ShareBundleError.emptySectionContent
                }
                hasNonEmptySection = true
            case .transcript(_, let segments):
                transcriptCount += 1
                guard !segments.isEmpty else { throw ShareBundleError.emptySectionContent }
                hasNonEmptySection = true
            }
        }
        guard notesCount <= 1 else { throw ShareBundleError.multipleNotesSections }
        guard transcriptCount <= 1 else { throw ShareBundleError.multipleTranscriptSections }
        guard hasNonEmptySection else { throw ShareBundleError.emptySectionContent }

        // publishedAt is whole-second UTC on the wire; truncating here keeps a
        // round trip through JSON exactly equal rather than merely close.
        self.publishedAt = Date(timeIntervalSince1970: publishedAt.timeIntervalSince1970.rounded(.down))
        self.title = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        self.source = source
        self.sections = sections
    }

    static var dateFormatter: ISO8601DateFormatter {
        // A fresh instance per call avoids sharing a non-thread-safe formatter
        // across concurrent encode/decode calls.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// Encodes the bundle as the exact UTF-8 JSON that gets authenticated and
    /// encrypted, enforcing the maximum plaintext size before any I/O.
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        guard data.count <= Self.maxPlaintextBytes else {
            throw ShareBundleError.payloadTooLarge(byteCount: data.count)
        }
        return data
    }

    public static func decodedFromJSON(_ data: Data) throws -> ShareBundle {
        guard data.count <= Self.maxPlaintextBytes else {
            throw ShareBundleError.payloadTooLarge(byteCount: data.count)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ShareBundle.self, from: data)
    }
}

extension ShareBundle: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, publishedAt, title, source, sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw ShareBundleError.unknownSchema(schema) }

        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw ShareBundleError.unknownSchemaVersion(schemaVersion)
        }

        let publishedAtString = try container.decode(String.self, forKey: .publishedAt)
        guard let publishedAt = ShareBundle.dateFormatter.date(from: publishedAtString) else {
            throw ShareBundleError.malformedJSON
        }

        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let source = try container.decodeIfPresent(Source.self, forKey: .source)
        let sections = try container.decode([Section].self, forKey: .sections)

        try self.init(publishedAt: publishedAt, title: title, source: source, sections: sections)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(ShareBundle.dateFormatter.string(from: publishedAt), forKey: .publishedAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(sections, forKey: .sections)
    }
}

extension ShareBundle.Source: Codable {}

extension ShareBundle.TranscriptSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, startMs, endMs, speaker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let startMs = try container.decodeIfPresent(Int.self, forKey: .startMs)
        let endMs = try container.decodeIfPresent(Int.self, forKey: .endMs)
        let speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        try self.init(text: text, startMs: startMs, endMs: endMs, speaker: speaker)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(startMs, forKey: .startMs)
        try container.encodeIfPresent(endMs, forKey: .endMs)
        try container.encodeIfPresent(speaker, forKey: .speaker)
    }
}

extension ShareBundle.Section: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, title, markdown, segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        switch kind {
        case "summary":
            self = .summary(title: title, markdown: try container.decode(String.self, forKey: .markdown))
        case "notes":
            self = .notes(title: title, markdown: try container.decode(String.self, forKey: .markdown))
        case "transcript":
            self = .transcript(
                title: title,
                segments: try container.decode([ShareBundle.TranscriptSegment].self, forKey: .segments)
            )
        default:
            throw ShareBundleError.unknownSectionKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .summary(let title, let markdown):
            try container.encode("summary", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(markdown, forKey: .markdown)
        case .notes(let title, let markdown):
            try container.encode("notes", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(markdown, forKey: .markdown)
        case .transcript(let title, let segments):
            try container.encode("transcript", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(segments, forKey: .segments)
        }
    }
}
