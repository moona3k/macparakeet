import Foundation
import GRDB

public enum SegmentSearchSource: String, Codable, Sendable, CaseIterable {
    case meeting
    case file
    case url
}

public struct SegmentSearchQuery: Sendable, Equatable {
    public var query: String
    public var since: Date?
    public var until: Date?
    public var source: SegmentSearchSource?
    public var speaker: String?
    public var limit: Int

    public init(
        query: String,
        since: Date? = nil,
        until: Date? = nil,
        source: SegmentSearchSource? = nil,
        speaker: String? = nil,
        limit: Int = 20
    ) {
        self.query = query
        self.since = since
        self.until = until
        self.source = source
        self.speaker = speaker
        self.limit = limit
    }
}

public struct SegmentSearchHit: Encodable, Sendable, Equatable {
    public var transcriptionId: UUID
    public var title: String
    public var recordedAt: Date
    public var source: SegmentSearchSource
    public var seq: Int
    public var startMs: Int?
    public var speaker: String?
    public var snippet: String
    public var rank: Double?

    private enum CodingKeys: String, CodingKey {
        case transcriptionId, title, recordedAt, source, seq, startMs, speaker, snippet, rank
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionId, forKey: .transcriptionId)
        try container.encode(title, forKey: .title)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(source, forKey: .source)
        try container.encode(seq, forKey: .seq)
        try container.encodeIfPresent(startMs, forKey: .startMs)
        try container.encodeIfPresent(speaker, forKey: .speaker)
        try container.encode(snippet, forKey: .snippet)
        if let rank {
            try container.encode(rank, forKey: .rank)
        } else {
            try container.encodeNil(forKey: .rank)
        }
    }
}

public struct SegmentReindexResult: Codable, Sendable, Equatable {
    public var transcriptionsIndexed: Int
    public var segmentsIndexed: Int
}

public protocol SegmentRepositoryProtocol: Sendable {
    func replaceSegments(for transcription: Transcription) throws
}

public final class SegmentRepository: SegmentRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func replaceSegments(for transcription: Transcription) throws {
        try dbQueue.write { db in
            try Self.replaceSegments(for: transcription, in: db)
        }
    }

    public func fetch(transcriptionId: UUID) throws -> [Segment] {
        try dbQueue.read { db in
            try Segment
                .filter(Segment.Columns.transcriptionId == transcriptionId)
                .order(Segment.Columns.seq.asc)
                .fetchAll(db)
        }
    }

    public func rebuildAll() throws -> SegmentReindexResult {
        try dbQueue.write { db in
            let transcriptions =
                try Transcription
                .filter(Transcription.Columns.status == Transcription.TranscriptionStatus.completed.rawValue)
                .fetchCursor(db)
            _ = try Segment.deleteAll(db)
            var transcriptionCount = 0
            var segmentCount = 0
            while let transcription = try transcriptions.next() {
                let derived = KnowledgeSegmenter.deriveSegments(for: transcription)
                for var segment in derived { try segment.insert(db) }
                transcriptionCount += 1
                segmentCount += derived.count
            }
            // Canonical convergence repair for any historical trigger drift.
            try db.execute(sql: "INSERT INTO segments_fts(segments_fts) VALUES('rebuild')")
            return SegmentReindexResult(
                transcriptionsIndexed: transcriptionCount,
                segmentsIndexed: segmentCount
            )
        }
    }

    public func search(_ query: SegmentSearchQuery) throws -> [SegmentSearchHit] {
        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, query.limit > 0 else { return [] }
        return try dbQueue.read { db in
            if Self.requiresSubstringFallback(trimmed) {
                return try Self.substringSearch(trimmed, query: query, db: db)
            }
            return try Self.ftsSearch(trimmed, query: query, db: db)
        }
    }

    public func fetchSlice(
        transcriptionId: UUID,
        aroundMs: Int? = nil,
        windowMs: Int = 30_000,
        aroundSeq: Int? = nil,
        context: Int = 2
    ) throws -> [Segment] {
        try dbQueue.read { db in
            if let aroundSeq {
                let lower = max(0, aroundSeq - max(0, context))
                let upper = aroundSeq + max(0, context)
                return
                    try Segment
                    .filter(Segment.Columns.transcriptionId == transcriptionId)
                    .filter(Segment.Columns.seq >= lower && Segment.Columns.seq <= upper)
                    .order(Segment.Columns.seq.asc)
                    .fetchAll(db)
            }
            if let aroundMs {
                let lower = max(0, aroundMs - max(0, windowMs))
                let upper = aroundMs + max(0, windowMs)
                let timed =
                    try Segment
                    .filter(Segment.Columns.transcriptionId == transcriptionId)
                    .filter(Segment.Columns.startMs != nil)
                    .filter(Segment.Columns.startMs <= upper)
                    .filter((Segment.Columns.endMs ?? Segment.Columns.startMs) >= lower)
                    .order(Segment.Columns.seq.asc)
                    .fetchAll(db)
                if !timed.isEmpty { return timed }
                let hasTiming =
                    try Segment
                    .filter(Segment.Columns.transcriptionId == transcriptionId)
                    .filter(Segment.Columns.startMs != nil)
                    .fetchCount(db) > 0
                if hasTiming { return [] }
                return
                    try Segment
                    .filter(Segment.Columns.transcriptionId == transcriptionId)
                    .filter(Segment.Columns.seq <= 2)
                    .order(Segment.Columns.seq.asc)
                    .fetchAll(db)
            }
            return
                try Segment
                .filter(Segment.Columns.transcriptionId == transcriptionId)
                .order(Segment.Columns.seq.asc)
                .fetchAll(db)
        }
    }

    private static func replaceSegments(for transcription: Transcription, in db: Database) throws {
        _ =
            try Segment
            .filter(Segment.Columns.transcriptionId == transcription.id)
            .deleteAll(db)
        for var segment in KnowledgeSegmenter.deriveSegments(for: transcription) {
            try segment.insert(db)
        }
    }

    private static func ftsSearch(
        _ text: String,
        query: SegmentSearchQuery,
        db: Database
    ) throws -> [SegmentSearchHit] {
        var predicates = ["segments_fts MATCH ?", "t.status = ?"]
        var arguments: [any DatabaseValueConvertible] = [
            text, Transcription.TranscriptionStatus.completed.rawValue,
        ]
        appendFilters(query, predicates: &predicates, arguments: &arguments)
        arguments.append(query.limit)
        let sql = """
            SELECT s.transcriptionId,
                   \(titleExpression) AS title,
                   t.createdAt AS recordedAt,
                   \(sourceExpression) AS source,
                   s.seq, s.startMs, s.speaker,
                   snippet(segments_fts, 0, '', '', ' … ', 24) AS snippet,
                   bm25(segments_fts) AS rank
            FROM segments_fts
            JOIN segments s ON s.id = segments_fts.rowid
            JOIN transcriptions t ON t.id = s.transcriptionId
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY rank ASC, t.createdAt DESC, s.seq ASC
            LIMIT ?
            """
        return try rowsToHits(Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)))
    }

    private static func substringSearch(
        _ text: String,
        query: SegmentSearchQuery,
        db: Database
    ) throws -> [SegmentSearchHit] {
        var predicates = ["s.text LIKE ? ESCAPE '\\'", "t.status = ?"]
        var arguments: [any DatabaseValueConvertible] = [
            "%\(escapedLikePattern(text))%", Transcription.TranscriptionStatus.completed.rawValue,
        ]
        appendFilters(query, predicates: &predicates, arguments: &arguments)
        arguments.append(query.limit)
        let sql = """
            SELECT s.transcriptionId,
                   \(titleExpression) AS title,
                   t.createdAt AS recordedAt,
                   \(sourceExpression) AS source,
                   s.seq, s.startMs, s.speaker, s.text, NULL AS rank
            FROM segments s
            JOIN transcriptions t ON t.id = s.transcriptionId
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY t.createdAt DESC, s.seq ASC
            LIMIT ?
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            try hit(from: row, snippet: characterSafeSnippet(row["text"], matching: text))
        }
    }

    private static func appendFilters(
        _ query: SegmentSearchQuery,
        predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        if let since = query.since {
            predicates.append("t.createdAt >= ?")
            arguments.append(since)
        }
        if let until = query.until {
            predicates.append("t.createdAt <= ?")
            arguments.append(until)
        }
        if let source = query.source {
            switch source {
            case .meeting:
                predicates.append("t.sourceType = 'meeting'")
            case .file:
                predicates.append("t.sourceType = 'file'")
            case .url:
                predicates.append("t.sourceType IN ('youtube', 'podcast')")
            }
        }
        if let speaker = query.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty {
            predicates.append("s.speaker LIKE ? ESCAPE '\\'")
            arguments.append("%\(escapedLikePattern(speaker))%")
        }
    }

    private static func rowsToHits(_ rows: [Row]) throws -> [SegmentSearchHit] {
        try rows.map { try hit(from: $0, snippet: $0["snippet"]) }
    }

    private static func hit(from row: Row, snippet: String) throws -> SegmentSearchHit {
        guard let source = SegmentSearchSource(rawValue: row["source"]) else {
            throw DatabaseError(message: "Invalid segment search source")
        }
        return SegmentSearchHit(
            transcriptionId: row["transcriptionId"],
            title: row["title"],
            recordedAt: row["recordedAt"],
            source: source,
            seq: row["seq"],
            startMs: row["startMs"],
            speaker: row["speaker"],
            snippet: snippet,
            rank: row["rank"]
        )
    }

    public static func requiresSubstringFallback(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0E7F,  // Thai
                0x3040...0x30FF,  // Hiragana + Katakana
                0x31F0...0x31FF,  // Katakana extensions
                0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // Han BMP
                0x20000...0x2EBEF, 0x2F800...0x2FA1F, 0x30000...0x3134F:  // Han supplementary planes
                true
            default:
                false
            }
        }
    }

    public static func characterSafeSnippet(
        _ text: String,
        matching query: String,
        maximumCharacters: Int = 160
    ) -> String {
        let characters = Array(text)
        guard characters.count > maximumCharacters else { return text }
        let needle = Array(query)
        var matchStart = 0
        if !needle.isEmpty, needle.count <= characters.count {
            for index in 0...(characters.count - needle.count)
            where Array(characters[index..<(index + needle.count)]) == needle {
                matchStart = index
                break
            }
        }
        let half = maximumCharacters / 2
        let lower = max(0, min(matchStart - half, characters.count - maximumCharacters))
        let upper = min(characters.count, lower + maximumCharacters)
        return (lower > 0 ? "…" : "")
            + String(characters[lower..<upper])
            + (upper < characters.count ? "…" : "")
    }

    private static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static let titleExpression = """
        CASE
            WHEN t.sourceType = 'meeting' THEN t.fileName
            ELSE COALESCE(
                NULLIF(TRIM(t.titleOverride), ''),
                NULLIF(TRIM(t.derivedTitle), ''),
                t.fileName
            )
        END
        """

    private static let sourceExpression = """
        CASE
            WHEN t.sourceType = 'meeting' THEN 'meeting'
            WHEN t.sourceType IN ('youtube', 'podcast') THEN 'url'
            ELSE 'file'
        END
        """
}
