import GRDB
import XCTest
@testable import MacParakeetCore

final class SegmentRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var transcriptions: TranscriptionRepository!
    private var segments: SegmentRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        segments = SegmentRepository(dbQueue: manager.dbQueue)
    }

    func testMeetingMaterializationUsesDurableTranscriptSegments() throws {
        let transcription = completedTranscription(
            source: .meeting,
            text: "Flat text should not replace the cited segment.",
            transcriptSegments: [segmentRecord(text: "Durable meeting decision.", startMs: 1_000, speaker: "Dana")]
        )
        try transcriptions.save(transcription)

        try segments.replaceSegments(for: transcription)

        let rows = try segments.fetch(transcriptionId: transcription.id)
        XCTAssertEqual(rows.map(\.text), ["Durable meeting decision."])
        XCTAssertEqual(rows.map(\.startMs), [1_000])
        XCTAssertEqual(rows.map(\.speaker), ["Dana"])
    }

    func testTimedFileAndURLRowsDeriveSentenceSizedSegmentsWithSpeakers() throws {
        for source in [Transcription.SourceType.file, .youtube, .podcast] {
            let transcription = completedTranscription(
                source: source,
                text: "Alpha beta gamma.",
                words: [
                    WordTimestamp(word: "Alpha", startMs: 0, endMs: 100, confidence: 1, speakerId: "S1"),
                    WordTimestamp(word: "beta", startMs: 120, endMs: 200, confidence: 1, speakerId: "S1"),
                    WordTimestamp(word: "gamma.", startMs: 220, endMs: 350, confidence: 1, speakerId: "S1"),
                ],
                speakers: [SpeakerInfo(id: "S1", label: "Riley")]
            )
            try transcriptions.save(transcription)
            try segments.replaceSegments(for: transcription)
            let row = try XCTUnwrap(segments.fetch(transcriptionId: transcription.id).first)
            XCTAssertEqual(row.text, "Alpha beta gamma.")
            XCTAssertEqual(row.startMs, 0)
            XCTAssertEqual(row.endMs, 350)
            XCTAssertEqual(row.speaker, "Riley")
        }
    }

    func testFileMaterializationTargetsTwoHundredToFiveHundredCharacters() {
        let words = (0..<180).map { index in
            WordTimestamp(
                word: "token\(index)",
                startMs: index * 100,
                endMs: index * 100 + 80,
                confidence: 1
            )
        }

        let durable = KnowledgeSegmenter.materializeFileTranscriptSegments(words: words)

        XCTAssertGreaterThan(durable.count, 1)
        XCTAssertTrue(durable.allSatisfy { $0.text.unicodeScalars.count <= 500 })
        XCTAssertTrue(durable.dropLast().allSatisfy { $0.text.unicodeScalars.count >= 200 })
        XCTAssertEqual(durable.first?.wordRange.startIndex, 0)
        XCTAssertEqual(durable.last?.wordRange.endIndexExclusive, words.count)
        for pair in zip(durable, durable.dropFirst()) {
            XCTAssertEqual(pair.0.wordRange.endIndexExclusive, pair.1.wordRange.startIndex)
        }
    }

    func testLegacyAndNoTimingRowsUseDeterministicPseudoSegments() throws {
        for source in [Transcription.SourceType.meeting, .file] {
            let transcription = completedTranscription(
                source: source,
                text: "First deterministic sentence. Second deterministic sentence!"
            )
            try transcriptions.save(transcription)
            try segments.replaceSegments(for: transcription)
            let rows = try segments.fetch(transcriptionId: transcription.id)
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.startMs == nil && $0.endMs == nil })
            XCTAssertEqual(rows.map(\.segmenterVersion), [KnowledgeSegmenter.currentVersion])
        }
    }

    func testCohereStyleNoTimingRowUsesDeterministicPseudoSegments() throws {
        var transcription = completedTranscription(
            source: .file,
            text: "Cohere result without word timing. Search remains available."
        )
        transcription.engine = "cohere"
        try transcriptions.save(transcription)

        try segments.replaceSegments(for: transcription)

        let rows = try segments.fetch(transcriptionId: transcription.id)
        XCTAssertEqual(rows.map(\.text), ["Cohere result without word timing. Search remains available."])
        XCTAssertTrue(rows.allSatisfy { $0.startMs == nil && $0.endMs == nil })
    }

    func testPopulationCascadeFiltersBlankStagesAndResequencesUsableContent() {
        let blankRecord = segmentRecord(text: " \n ", startMs: 0, speaker: "S1")
        let usableRecord = segmentRecord(text: "  Durable decision.  ", startMs: 500, speaker: "S1")
        let mixedStored = completedTranscription(
            source: .meeting,
            text: "Raw fallback must not win.",
            words: [WordTimestamp(word: "Word", startMs: 0, endMs: 100, confidence: 1)],
            transcriptSegments: [blankRecord, usableRecord, blankRecord]
        )

        let durable = KnowledgeSegmenter.deriveSegments(for: mixedStored)
        XCTAssertEqual(durable.map(\.seq), [0])
        XCTAssertEqual(durable.map(\.text), ["Durable decision."])

        let blankStoredWithWords = completedTranscription(
            source: .file,
            text: "Raw fallback must not win.",
            words: [
                WordTimestamp(word: " \t", startMs: 0, endMs: 50, confidence: 1),
                WordTimestamp(word: " usable ", startMs: 100, endMs: 200, confidence: 1),
            ],
            transcriptSegments: [blankRecord]
        )
        let fromWords = KnowledgeSegmenter.deriveSegments(for: blankStoredWithWords)
        XCTAssertEqual(fromWords.map(\.text), ["usable"])
        XCTAssertEqual(fromWords.map(\.startMs), [100])

        var blankClean = completedTranscription(source: .file, text: "  Raw fallback.  ")
        blankClean.cleanTranscript = " \n "
        blankClean.wordTimestamps = [WordTimestamp(word: " ", startMs: 0, endMs: 1, confidence: 1)]
        blankClean.transcriptSegments = [blankRecord]
        XCTAssertEqual(KnowledgeSegmenter.deriveSegments(for: blankClean).map(\.text), ["Raw fallback."])

        var allBlank = completedTranscription(source: .file, text: " \n ")
        allBlank.cleanTranscript = "\t"
        allBlank.wordTimestamps = [WordTimestamp(word: " ", startMs: 0, endMs: 1, confidence: 1)]
        allBlank.transcriptSegments = [blankRecord]
        XCTAssertTrue(KnowledgeSegmenter.deriveSegments(for: allBlank).isEmpty)
    }

    func testBackfillTwiceConvergesToIdenticalDerivedRows() throws {
        let meeting = completedTranscription(
            source: .meeting,
            text: "Meeting fallback.",
            transcriptSegments: [segmentRecord(text: "Meeting indexed text.", startMs: 500, speaker: "Me")]
        )
        let file = completedTranscription(source: .file, text: "Legacy file sentence. Another sentence.")
        try transcriptions.save(meeting)
        try transcriptions.save(file)

        let firstResult = try segments.rebuildAll()
        let first = try deterministicRows()
        let secondResult = try segments.rebuildAll()
        let second = try deterministicRows()

        XCTAssertEqual(firstResult.transcriptionsIndexed, 2)
        XCTAssertEqual(secondResult.transcriptionsIndexed, 2)
        XCTAssertEqual(first, second)
    }

    func testRebuildAllowsAppWriteBetweenPerTranscriptionTransactions() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("segments_cooperative_rebuild_\(UUID().uuidString).db")
            .path
        defer { cleanupDatabaseFiles(atPath: path) }
        let rebuildManager = try DatabaseManager(path: path)
        let appManager = try DatabaseManager(path: path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: rebuildManager.dbQueue)
        let appTranscriptionRepo = TranscriptionRepository(dbQueue: appManager.dbQueue)
        let repository = SegmentRepository(dbQueue: rebuildManager.dbQueue)
        let recordings = [
            completedTranscription(source: .file, text: "new canonical alpha"),
            completedTranscription(source: .file, text: "new canonical beta"),
        ]
        for (index, recording) in recordings.enumerated() {
            try transcriptionRepo.save(recording)
            var old = recording
            old.rawTranscript = "legacy searchable marker \(index)"
            try repository.replaceSegments(for: old)
        }

        let interleaved = Transcription(
            fileName: "app-write.m4a",
            rawTranscript: "A normal app write during maintenance.",
            status: .processing,
            sourceType: .file
        )
        let result = try repository.rebuildAll { completedCount in
            guard completedCount == 1 else { return }
            XCTAssertEqual(
                try repository.search(SegmentSearchQuery(query: "legacy", limit: 10)).count,
                1,
                "the next recording's old searchable rows remain until its replacement commits"
            )
            try appTranscriptionRepo.save(interleaved)
        }

        XCTAssertEqual(result.transcriptionsIndexed, 2)
        XCTAssertNotNil(try appTranscriptionRepo.fetch(id: interleaved.id))
        XCTAssertTrue(try repository.search(SegmentSearchQuery(query: "legacy", limit: 10)).isEmpty)
        XCTAssertEqual(try repository.search(SegmentSearchQuery(query: "canonical", limit: 10)).count, 2)
    }

    func testFTSSearchRankingFiltersAndTriggerSynchronization() throws {
        let old = completedTranscription(
            source: .file,
            text: "sparkle sparkle cache",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let recent = completedTranscription(
            source: .meeting,
            text: "sparkle cache busting",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcriptSegments: [
                segmentRecord(text: "Dana decided sparkle cache busting.", startMs: 3_000, speaker: "Dana")
            ]
        )
        let url = completedTranscription(
            source: .youtube,
            text: "sparkle remote recording",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try transcriptions.save(old)
        try transcriptions.save(recent)
        try transcriptions.save(url)
        try segments.replaceSegments(for: old)
        try segments.replaceSegments(for: recent)
        try segments.replaceSegments(for: url)

        let all = try segments.search(SegmentSearchQuery(query: "sparkle", limit: 10))
        XCTAssertEqual(Set(all.map(\.transcriptionId)), [old.id, recent.id, url.id])
        XCTAssertEqual(all.first?.transcriptionId, old.id, "higher term frequency should improve bm25 rank")
        XCTAssertNotNil(all.first?.rank)
        XCTAssertEqual(try segments.search(SegmentSearchQuery(query: "sparkle", limit: 1)).count, 1)

        let filtered = try segments.search(
            SegmentSearchQuery(
                query: "sparkle",
                since: Date(timeIntervalSince1970: 1_750_000_000),
                source: .meeting,
                speaker: "Dana",
                limit: 10
            ))
        XCTAssertEqual(filtered.map(\.transcriptionId), [recent.id])
        XCTAssertEqual(
            try segments.search(
                SegmentSearchQuery(
                    query: "sparkle",
                    until: Date(timeIntervalSince1970: 1_725_000_000),
                    source: .file,
                    limit: 10
                )
            ).map(\.transcriptionId),
            [old.id]
        )
        XCTAssertEqual(
            try segments.search(
                SegmentSearchQuery(query: "sparkle", source: .url, limit: 10)
            ).map(\.transcriptionId),
            [url.id]
        )

        var row = try XCTUnwrap(segments.fetch(transcriptionId: recent.id).first)
        row.text = "Updated retrieval token."
        try manager.dbQueue.write { db in try row.update(db) }
        XCTAssertTrue(
            try segments.search(SegmentSearchQuery(query: "sparkle", limit: 10))
                .allSatisfy { $0.transcriptionId != recent.id })
        XCTAssertEqual(
            try segments.search(SegmentSearchQuery(query: "updated", limit: 10)).first?.transcriptionId, recent.id)

        try manager.dbQueue.write { db in _ = try row.delete(db) }
        XCTAssertTrue(try segments.search(SegmentSearchQuery(query: "updated", limit: 10)).isEmpty)
    }

    func testCJKFallbackAndGraphemeSafeSnippet() throws {
        XCTAssertTrue(SegmentRepository.requiresSubstringFallback("\u{20000}"))
        XCTAssertTrue(SegmentRepository.requiresSubstringFallback("\u{FF76}"), "halfwidth Katakana")
        XCTAssertTrue(SegmentRepository.requiresSubstringFallback("\u{1B000}"), "supplementary kana")
        let transcription = completedTranscription(
            source: .file,
            text: "前置き🙂これは重要な会議の結論です🚀次の話題"
        )
        try transcriptions.save(transcription)
        try segments.replaceSegments(for: transcription)

        let hit = try XCTUnwrap(segments.search(SegmentSearchQuery(query: "重要な会議", limit: 10)).first)
        XCTAssertNil(hit.rank)
        XCTAssertTrue(hit.snippet.contains("重要な会議"))
        XCTAssertTrue(hit.snippet.contains("🙂") || hit.snippet.contains("🚀"))

        let truncated = SegmentRepository.characterSafeSnippet(
            "前前前前🙂これは重要な会議です🚀後後後後",
            matching: "重要な会議",
            maximumCharacters: 12
        )
        XCTAssertTrue(truncated.contains("重要な会議"))
        XCTAssertLessThanOrEqual(truncated.count, 14, "up to two ellipsis graphemes may surround the snippet")

        let mixedCase = SegmentRepository.characterSafeSnippet(
            String(repeating: "prefix ", count: 20) + "tanaka 会議 decision",
            matching: "Tanaka 会議",
            maximumCharacters: 24
        )
        XCTAssertTrue(mixedCase.contains("tanaka 会議"))
        XCTAssertFalse(mixedCase.contains("prefix prefix prefix"))
    }

    func testSegmentSliceSupportsTimeAndSequenceContext() throws {
        let transcription = completedTranscription(
            source: .meeting,
            text: "one two three",
            transcriptSegments: [
                segmentRecord(text: "one", startMs: 0, speaker: "A"),
                segmentRecord(text: "two", startMs: 5_000, speaker: "B"),
                segmentRecord(text: "three", startMs: 10_000, speaker: "A"),
            ]
        )
        try transcriptions.save(transcription)
        try segments.replaceSegments(for: transcription)

        XCTAssertEqual(
            try segments.fetchSlice(transcriptionId: transcription.id, aroundMs: 5_000, windowMs: 1_000).map(\.seq),
            [1]
        )
        XCTAssertEqual(
            try segments.fetchSlice(transcriptionId: transcription.id, aroundSeq: 1, context: 1).map(\.seq),
            [0, 1, 2]
        )
    }

    private func deterministicRows() throws -> [[String]] {
        try manager.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT hex(transcriptionId) AS transcriptionId, seq, startMs, endMs,
                           COALESCE(speaker, '') AS speaker, text, segmenterVersion
                    FROM segments
                    ORDER BY transcriptionId, seq
                    """
            ).map { row in
                [
                    row["transcriptionId"],
                    String(row["seq"] as Int),
                    (row["startMs"] as Int?).map(String.init) ?? "nil",
                    (row["endMs"] as Int?).map(String.init) ?? "nil",
                    row["speaker"],
                    row["text"],
                    String(row["segmenterVersion"] as Int),
                ]
            }
        }
    }

    private func completedTranscription(
        source: Transcription.SourceType,
        text: String,
        createdAt: Date = Date(),
        words: [WordTimestamp]? = nil,
        speakers: [SpeakerInfo]? = nil,
        transcriptSegments: [TranscriptSegmentRecord]? = nil
    ) -> Transcription {
        Transcription(
            createdAt: createdAt,
            fileName: "Fixture",
            rawTranscript: text,
            wordTimestamps: words,
            speakers: speakers,
            transcriptSegments: transcriptSegments,
            status: .completed,
            sourceType: source,
            updatedAt: createdAt
        )
    }

    private func segmentRecord(text: String, startMs: Int, speaker: String) -> TranscriptSegmentRecord {
        TranscriptSegmentRecord(
            startMs: startMs,
            endMs: startMs + 500,
            speakerId: speaker,
            speakerLabel: speaker,
            text: text,
            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
        )
    }

    private func cleanupDatabaseFiles(atPath path: String) {
        for suffix in ["", "-shm", "-wal", ".migration.lock"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
