import CryptoKit
import Foundation
import GRDB

/// Target languages offered for transcript and live-meeting translation.
public enum TranslationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case persian = "fa"
    case english = "en"
    case german = "de"

    public var id: String { rawValue }

    /// English name, used in prompts and menus.
    public var displayName: String {
        switch self {
        case .persian: return "Persian"
        case .english: return "English"
        case .german: return "German"
        }
    }

    public var nativeName: String {
        switch self {
        case .persian: return "فارسی"
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    public var isRightToLeft: Bool {
        self == .persian
    }

    /// Resolves a stored preference. Accepts a language code or an English
    /// name so values written by earlier free-text settings keep working.
    public static func resolve(_ stored: String?) -> TranslationLanguage? {
        guard let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !value.isEmpty
        else { return nil }
        return allCases.first {
            $0.rawValue == value || $0.displayName.lowercased() == value
        }
    }
}

/// One unit of transcript text handed to the translator. Timing and speaker
/// are carried through untouched so translated lines stay seekable.
public struct TranslationSourceSegment: Sendable, Equatable {
    public var startMs: Int?
    public var endMs: Int?
    public var speakerId: String?
    public var text: String

    public init(startMs: Int? = nil, endMs: Int? = nil, speakerId: String? = nil, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.text = text
    }
}

public struct TranslatedSegment: Codable, Sendable, Equatable {
    public var startMs: Int?
    public var endMs: Int?
    public var speakerId: String?
    public var text: String

    public init(startMs: Int? = nil, endMs: Int? = nil, speakerId: String? = nil, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.text = text
    }
}

/// A saved translation of one transcript into one language. Derived state:
/// it can always be regenerated from the transcript, and `sourceHash` records
/// which transcript text it was produced from.
public struct TranscriptTranslation: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var transcriptionId: UUID
    public var languageCode: String
    public var segments: [TranslatedSegment]
    public var sourceHash: String
    public var modelName: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        languageCode: String,
        segments: [TranslatedSegment],
        sourceHash: String,
        modelName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.languageCode = languageCode
        self.segments = segments
        self.sourceHash = sourceHash
        self.modelName = modelName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var language: TranslationLanguage? {
        TranslationLanguage(rawValue: languageCode)
    }

    public var hasTimedSegments: Bool {
        segments.contains { $0.startMs != nil && $0.endMs != nil }
    }

    /// Plain text, one translated segment per line.
    public var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }
}

extension TranscriptTranslation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcript_translations"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, languageCode, segments, sourceHash, modelName, createdAt, updatedAt
    }
}

/// Derives the segments to translate from a transcript, and the fingerprint
/// used to tell whether a saved translation still matches it.
public enum TranscriptTranslationSource {
    /// Untimed fallback chunks stay below this so one paragraph cannot become
    /// a single oversized translation unit.
    static let maxUntimedSegmentCharacters = 400

    /// Pass the effective transcription (the ADR-031 projection) so user
    /// corrections are translated, not the automatic baseline.
    public static func segments(for transcription: Transcription) -> [TranslationSourceSegment] {
        // A whole-transcript edit no longer lines up with word timings, so the
        // edited text is translated as plain paragraphs.
        if transcription.isTranscriptEdited,
            let text = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return untimedSegments(from: text)
        }

        // Segment-timed corrections: the displayed segments are the text.
        if transcription.transcriptTextAlignment == .segment,
            let segments = transcription.transcriptSegments
        {
            return segments.compactMap { segment in
                timedSegment(
                    text: segment.text,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    speakerId: segment.speakerId
                )
            }
        }

        if let words = transcription.wordTimestamps, !words.isEmpty {
            return TranscriptSegmenter.materializeSegments(words: words).compactMap { segment in
                timedSegment(
                    text: segment.text,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    speakerId: segment.speakerId
                )
            }
        }

        return untimedSegments(from: transcription.cleanTranscript ?? transcription.rawTranscript ?? "")
    }

    private static func timedSegment(
        text: String,
        startMs: Int,
        endMs: Int,
        speakerId: String?
    ) -> TranslationSourceSegment? {
        let text = normalized(text)
        guard !text.isEmpty else { return nil }
        return TranslationSourceSegment(startMs: startMs, endMs: endMs, speakerId: speakerId, text: text)
    }

    public static func hash(of segments: [TranslationSourceSegment]) -> String {
        var digest = SHA256()
        // Length-prefix each optional field so boundaries and nil values cannot
        // collide. Timing and speaker edits also invalidate derived subtitles.
        func append(_ value: String?) {
            guard let value else {
                digest.update(data: Data("nil:".utf8))
                return
            }
            let bytes = Data(value.utf8)
            digest.update(data: Data("\(bytes.count):".utf8))
            digest.update(data: bytes)
        }
        for segment in segments {
            append(segment.text)
            append(segment.startMs.map(String.init))
            append(segment.endMs.map(String.init))
            append(segment.speakerId)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func untimedSegments(from text: String) -> [TranslationSourceSegment] {
        var result: [TranslationSourceSegment] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let trimmed = normalized(paragraph)
            guard !trimmed.isEmpty else { continue }
            for chunk in sentenceChunks(trimmed, limit: maxUntimedSegmentCharacters) {
                result.append(TranslationSourceSegment(text: chunk))
            }
        }
        return result
    }

    private static func sentenceChunks(_ paragraph: String, limit: Int) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }

        var chunks: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ") {
            if !current.isEmpty { current.append(" ") }
            current.append(contentsOf: word)
            let endsSentence = word.last.map { ".!?؟。".contains($0) } ?? false
            if (endsSentence && current.count >= limit / 2) || current.count >= limit {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
