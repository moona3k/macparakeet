import CryptoKit
import Foundation
import GRDB

public enum AskSourceError: Error, Equatable {
    case outOfScope
    case unavailable
    case stale
    case invalidReference
    case invalidQuery
}

public protocol AskSourceServiceProtocol: Sendable {
    func listLabels() throws -> [MeetingLabel]
    func listSources(filter: AskSourceFilter) throws -> [AskSourceDescriptor]
    func snapshot(sourceIDs: [UUID]) throws -> [AskSourceSnapshot]
    func search(query: String, sourceRevisions: [UUID: String], limit: Int) throws -> [AskPassage]
    func passages(sourceID: UUID, start: Int, limit: Int, sourceRevisions: [UUID: String]) throws -> [AskPassage]
    func read(reference: AskEvidenceReference, sourceRevisions: [UUID: String]) throws -> AskPassage
    func summaries(sourceID: UUID, sourceRevisions: [UUID: String]) throws -> [AskSummary]
    func validate(reference: AskEvidenceReference, sourceRevisions: [UUID: String]) throws -> AskEvidenceStatus
}

/// Tools receive an immutable run scope. Every content read checks the current
/// canonical recording against that scope before returning text or metadata.
public final class AskSourceService: AskSourceServiceProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private static let maxSources = 32
    private static let maxPassages = 25
    // Match the whitespace-only inputs rejected by KnowledgeSegmenter.usableText
    // without returning transcript bodies in the bounded picker metadata page.
    private static let whitespaceSQL =
        "char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288)"

    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func listLabels() throws -> [MeetingLabel] {
        try dbQueue.read { db in
            try MeetingLabel
                .filter(MeetingLabel.Columns.isArchived == false)
                .order(MeetingLabel.Columns.sortOrder.asc, MeetingLabel.Columns.name.collating(.nocase).asc)
                .fetchAll(db)
        }
    }

    /// Metadata-only page for the picker. Transcript bodies are not fetched.
    public func listSources(filter: AskSourceFilter = AskSourceFilter()) throws -> [AskSourceDescriptor] {
        try dbQueue.read { db in
            var clauses = ["t.status = ?"]
            var args: [any DatabaseValueConvertible] = [Transcription.TranscriptionStatus.completed.rawValue]
            if let type = filter.sourceType {
                clauses.append("t.sourceType = ?")
                args.append(type.rawValue)
            }
            if let since = filter.since {
                clauses.append("t.createdAt >= ?")
                args.append(since)
            }
            if let until = filter.until {
                clauses.append("t.createdAt <= ?")
                args.append(until)
            }
            let search = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                clauses.append(
                    "(t.fileName LIKE ? ESCAPE '!' OR t.titleOverride LIKE ? ESCAPE '!' OR t.derivedTitle LIKE ? ESCAPE '!')"
                )
                let escaped = search.replacingOccurrences(of: "!", with: "!!")
                    .replacingOccurrences(of: "%", with: "!%")
                    .replacingOccurrences(of: "_", with: "!_")
                let pattern = "%\(escaped)%"
                args.append(contentsOf: [pattern, pattern, pattern])
            }
            if !filter.labelIDs.isEmpty {
                let ids = filter.labelIDs.sorted { $0.uuidString < $1.uuidString }
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                clauses.append(
                    "EXISTS (SELECT 1 FROM transcription_meeting_labels l WHERE l.transcriptionId = t.id AND l.labelId IN (\(placeholders)))"
                )
                args.append(contentsOf: ids)
            }
            args.append(min(max(filter.limit, 0), 100))
            args.append(max(filter.offset, 0))
            let sql = """
                SELECT t.id, t.fileName, t.titleOverride, t.derivedTitle,
                       CASE WHEN t.isTranscriptEdited OR EXISTS (
                           SELECT 1 FROM speaker_correction_states s
                           WHERE s.transcriptionId = t.id AND s.headId IS NOT NULL
                       ) THEN NULL ELSE t.derivedSnippet END AS preview,
                       t.createdAt, t.sourceType, t.durationMs,
                       CASE WHEN t.isTranscriptEdited THEN
                           trim(coalesce(t.cleanTranscript, ''), char(9,10,11,12,13,32)) <> ''
                       ELSE
                           trim(coalesce(t.cleanTranscript, ''), \(Self.whitespaceSQL)) <> ''
                           OR trim(coalesce(t.rawTranscript, ''), \(Self.whitespaceSQL)) <> ''
                           OR EXISTS (
                               SELECT 1 FROM json_each(CASE WHEN json_valid(t.transcriptSegments)
                                   THEN t.transcriptSegments ELSE '[]' END) s
                               WHERE trim(coalesce(json_extract(CASE WHEN s.type = 'object'
                                   THEN s.value ELSE '{}' END, '$.text'), ''), \(Self.whitespaceSQL)) <> ''
                           ) OR EXISTS (
                               SELECT 1 FROM json_each(CASE WHEN json_valid(t.wordTimestamps)
                                   THEN t.wordTimestamps ELSE '[]' END) w
                               WHERE trim(coalesce(json_extract(CASE WHEN w.type = 'object'
                                   THEN w.value ELSE '{}' END, '$.word'), ''), \(Self.whitespaceSQL)) <> ''
                           )
                       END AS hasText
                FROM transcriptions t
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY t.createdAt DESC, t.id ASC
                LIMIT ? OFFSET ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map { row in
                let id: UUID = row["id"]
                let rawType: String = row["sourceType"]
                let sourceType = Transcription.SourceType(rawValue: rawType) ?? .file
                let fileName: String = row["fileName"]
                let override: String? = row["titleOverride"]
                let derived: String? = row["derivedTitle"]
                let title = Self.displayTitle(
                    fileName: fileName, override: override, derived: derived, type: sourceType
                )
                return AskSourceDescriptor(
                    id: id,
                    title: title,
                    recordedAt: row["createdAt"],
                    sourceType: sourceType,
                    durationMs: row["durationMs"],
                    labelIDs: try Self.labelIDs(sourceID: id, db: db),
                    preview: row["preview"],
                    isAvailable: row["hasText"]
                )
            }
        }
    }

    /// One database read transaction gives a consistent initial run receipt.
    public func snapshot(sourceIDs: [UUID]) throws -> [AskSourceSnapshot] {
        guard sourceIDs.count <= Self.maxSources else { throw AskSourceError.invalidQuery }
        return try dbQueue.read { db in
            var seen = Set<UUID>()
            return try sourceIDs.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                guard let loaded = try Self.load(id: id, db: db) else {
                    return AskSourceSnapshot(
                        descriptor: Self.missingDescriptor(id: id),
                        revision: "",
                        passageCount: 0,
                        status: .unavailable
                    )
                }
                return AskSourceSnapshot(
                    descriptor: try Self.descriptor(
                        for: loaded.transcription, isAvailable: !loaded.segments.isEmpty, db: db
                    ),
                    revision: loaded.revision,
                    passageCount: loaded.segments.count,
                    status: loaded.segments.isEmpty ? .unavailable : .available
                )
            }
        }
    }

    /// Lexical matching over the current corrected passages, with no derived
    /// index trust or expansion beyond the supplied source IDs.
    public func search(
        query: String,
        sourceRevisions: [UUID: String],
        limit: Int = 20
    ) throws -> [AskPassage] {
        let words = query.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard !words.isEmpty, query.count <= 500, sourceRevisions.count <= Self.maxSources else {
            throw AskSourceError.invalidQuery
        }
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            var result: [AskPassage] = []
            let maximum = min(limit, Self.maxPassages)
            let orderedIDs = sourceRevisions.keys.sorted { $0.uuidString < $1.uuidString }
            let matches = try orderedIDs.map { id -> [AskPassage] in
                let loaded = try Self.checkedLoad(id: id, revisions: sourceRevisions, db: db)
                return loaded.segments.lazy.filter { segment in
                    let lower = segment.text.lowercased()
                    return words.allSatisfy { lower.contains($0) }
                }.prefix(maximum).map { Self.passage($0, revision: loaded.revision) }
            }
            // Distribute the bounded result across recordings; one long
            // recording must not consume every hit in a comparison query.
            for index in 0..<maximum {
                for sourceMatches in matches where sourceMatches.indices.contains(index) {
                    result.append(sourceMatches[index])
                    if result.count == maximum { return result }
                }
            }
            return result
        }
    }

    public func passages(
        sourceID: UUID,
        start: Int,
        limit: Int = 5,
        sourceRevisions: [UUID: String]
    ) throws -> [AskPassage] {
        guard start >= 0, limit > 0 else { throw AskSourceError.invalidReference }
        return try dbQueue.read { db in
            let loaded = try Self.checkedLoad(id: sourceID, revisions: sourceRevisions, db: db)
            guard start < loaded.segments.count else { throw AskSourceError.invalidReference }
            let end = min(loaded.segments.count, start + min(limit, Self.maxPassages))
            return loaded.segments[start..<end].map { Self.passage($0, revision: loaded.revision) }
        }
    }

    public func read(
        reference: AskEvidenceReference,
        sourceRevisions: [UUID: String]
    ) throws -> AskPassage {
        guard reference.segmentIndex >= 0 else { throw AskSourceError.invalidReference }
        return try dbQueue.read { db in
            let loaded = try Self.checkedLoad(id: reference.sourceID, revisions: sourceRevisions, db: db)
            guard reference.sourceRevision == loaded.revision else { throw AskSourceError.stale }
            guard loaded.segments.indices.contains(reference.segmentIndex) else {
                throw AskSourceError.invalidReference
            }
            return Self.passage(loaded.segments[reference.segmentIndex], revision: loaded.revision)
        }
    }

    public func summaries(
        sourceID: UUID,
        sourceRevisions: [UUID: String]
    ) throws -> [AskSummary] {
        try dbQueue.read { db in
            let loaded = try Self.checkedLoad(id: sourceID, revisions: sourceRevisions, db: db)
            let projection = try SpeakerAttributionReadService.resolve(
                transcription: loaded.transcription, in: db
            )
            let transcriptHash = PromptResultFreshness.sourceTranscriptHash(
                for: projection.effectiveTranscription
            )
            let rows =
                try PromptResult
                .filter(PromptResult.Columns.transcriptionId == sourceID)
                .order(PromptResult.Columns.createdAt.desc)
                .limit(10)
                .fetchAll(db)
            return try rows.compactMap { result -> AskSummary? in
                // Old receipts cannot certify that a summary still describes
                // the current corrected transcript.
                guard result.sourceTranscriptHash != nil,
                    result.sourceCorrectionRevision != nil,
                    !PromptResultFreshness.summaryNeedsUpdate(
                        sourceCorrectionRevision: result.sourceCorrectionRevision,
                        currentCorrectionRevision: projection.correctionRevision,
                        sourceTranscriptHash: result.sourceTranscriptHash,
                        currentTranscriptHash: transcriptHash
                    )
                else { return nil }
                // `summaries` also stores imported/legacy outputs. Only a
                // linked result-category prompt identifies overview context;
                // a transform or an unlinked row cannot be treated as one.
                guard let promptID = result.promptId,
                    let prompt = try PromptQuery.fetch(id: promptID, includingDeleted: true, db: db),
                    prompt.category == .result
                else { return nil }
                if let versionID = result.promptVersionId {
                    guard let version = try PromptVersion.fetchOne(db, key: versionID),
                        version.promptId == promptID
                    else { return nil }
                }
                return AskSummary(
                    id: result.id,
                    sourceID: sourceID,
                    title: result.promptName,
                    content: String(result.content.prefix(4_000)),
                    createdAt: result.createdAt,
                    isUserEdited: result.isContentUserEdited
                )
            }
        }
    }

    public func validate(
        reference: AskEvidenceReference,
        sourceRevisions: [UUID: String]
    ) throws -> AskEvidenceStatus {
        guard sourceRevisions[reference.sourceID] != nil else { return .outOfScope }
        guard reference.segmentIndex >= 0 else { return .invalid }
        return try dbQueue.read { db in
            guard let loaded = try Self.load(id: reference.sourceID, db: db),
                !loaded.segments.isEmpty
            else { return .unavailable }
            guard sourceRevisions[reference.sourceID] == loaded.revision,
                reference.sourceRevision == loaded.revision
            else { return .stale }
            return loaded.segments.indices.contains(reference.segmentIndex) ? .available : .invalid
        }
    }

    private struct Loaded {
        var transcription: Transcription
        var segments: [Segment]
        var revision: String
    }

    /// Called from the conversation repository's terminal write transaction.
    /// This closes the gap between a separate final read and the answer save.
    static func validateRevisions(_ revisions: [UUID: String], in db: Database) throws {
        guard revisions.count <= maxSources else { throw AskSourceError.invalidQuery }
        for (id, expected) in revisions {
            guard let loaded = try load(id: id, db: db), !loaded.segments.isEmpty else {
                throw AskSourceError.unavailable
            }
            guard loaded.revision == expected else { throw AskSourceError.stale }
        }
    }

    static func validateSummaries(_ receipts: [AskSummary], in db: Database) throws {
        for receipt in receipts {
            guard let current = try PromptResult.fetchOne(db, key: receipt.id) else { throw AskSourceError.unavailable }
            guard current.transcriptionId == receipt.sourceID,
                current.promptName == receipt.title,
                String(current.content.prefix(4_000)) == receipt.content,
                current.createdAt == receipt.createdAt,
                current.isContentUserEdited == receipt.isUserEdited
            else { throw AskSourceError.stale }
        }
    }

    private static func checkedLoad(
        id: UUID,
        revisions: [UUID: String],
        db: Database
    ) throws -> Loaded {
        guard let expected = revisions[id] else { throw AskSourceError.outOfScope }
        guard let loaded = try load(id: id, db: db), !loaded.segments.isEmpty else {
            throw AskSourceError.unavailable
        }
        guard loaded.revision == expected else { throw AskSourceError.stale }
        return loaded
    }

    private static func load(id: UUID, db: Database) throws -> Loaded? {
        guard let transcription = try Transcription.fetchOne(db, key: id),
            transcription.status == .completed
        else { return nil }
        let segments: [Segment]
        if transcription.isTranscriptEdited {
            // A legacy whole-text edit makes old word timings and durable
            // segments invalid. Derive only untimed chunks from the edited text.
            let text = transcription.cleanTranscript ?? ""
            segments = KnowledgeSegmenter.pseudoSegment(text).enumerated().map { index, chunk in
                Segment(
                    transcriptionId: id,
                    seq: index,
                    startMs: nil,
                    endMs: nil,
                    speaker: nil,
                    text: chunk,
                    segmenterVersion: KnowledgeSegmenter.currentVersion
                )
            }
        } else {
            segments = try SegmentRepository.deriveResolvedSegments(for: transcription, in: db)
        }
        let bounded = boundedSegments(segments)
        let revision = try revision(for: bounded)
        return Loaded(transcription: transcription, segments: bounded, revision: revision)
    }

    private static func boundedSegments(_ segments: [Segment]) -> [Segment] {
        var bounded: [Segment] = []
        for segment in segments {
            let chunks: [String]
            if segment.text.unicodeScalars.count > 500 {
                chunks = KnowledgeSegmenter.pseudoSegment(segment.text)
            } else {
                chunks = [segment.text]
            }
            for chunk in chunks {
                var part = segment
                part.seq = bounded.count
                part.text = chunk
                if chunks.count > 1 {
                    // The original envelope cannot time its individual text
                    // chunks. A text anchor remains valid without false timing.
                    part.startMs = nil
                    part.endMs = nil
                }
                bounded.append(part)
            }
        }
        return bounded
    }

    private struct RevisionSegment: Encodable {
        var seq: Int
        var text: String
        var speaker: String?
        var startMs: Int?
        var endMs: Int?
    }

    private static func revision(for segments: [Segment]) throws -> String {
        let input = segments.map {
            RevisionSegment(
                seq: $0.seq, text: $0.text, speaker: $0.speaker,
                startMs: $0.startMs, endMs: $0.endMs
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(input)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func passage(_ segment: Segment, revision: String) -> AskPassage {
        AskPassage(
            reference: AskEvidenceReference(
                sourceID: segment.transcriptionId,
                sourceRevision: revision,
                segmentIndex: segment.seq
            ),
            text: segment.text,
            speaker: segment.speaker,
            startMs: segment.startMs,
            endMs: segment.endMs
        )
    }

    private static func descriptor(
        for transcription: Transcription,
        isAvailable: Bool,
        db: Database
    ) throws -> AskSourceDescriptor {
        let hasCorrections =
            try SpeakerCorrectionRepository.fetchState(
                transcriptionId: transcription.id, in: db
            )?.headId != nil
        return AskSourceDescriptor(
            id: transcription.id,
            title: transcription.effectiveDisplayTitle,
            recordedAt: transcription.createdAt,
            sourceType: transcription.sourceType,
            durationMs: transcription.durationMs,
            labelIDs: try labelIDs(sourceID: transcription.id, db: db),
            preview: transcription.isTranscriptEdited || hasCorrections ? nil : transcription.derivedSnippet,
            isAvailable: isAvailable
        )
    }

    private static func missingDescriptor(id: UUID) -> AskSourceDescriptor {
        AskSourceDescriptor(
            id: id,
            title: "Recording unavailable",
            recordedAt: .distantPast,
            sourceType: .file,
            durationMs: nil,
            labelIDs: [],
            preview: nil,
            isAvailable: false
        )
    }

    private static func labelIDs(sourceID: UUID, db: Database) throws -> [UUID] {
        let rows =
            try TranscriptionMeetingLabel
            .filter(TranscriptionMeetingLabel.Columns.transcriptionId == sourceID)
            .fetchAll(db)
        return rows.map(\.labelId).sorted { $0.uuidString < $1.uuidString }
    }

    private static func displayTitle(
        fileName: String,
        override: String?,
        derived: String?,
        type: Transcription.SourceType
    ) -> String {
        if type == .meeting { return fileName }
        if let override = Transcription.normalizedTitleOverride(from: override) { return override }
        if type == .file { return fileName }
        if let derived = Transcription.normalizedTitleOverride(from: derived) { return derived }
        return fileName
    }
}
