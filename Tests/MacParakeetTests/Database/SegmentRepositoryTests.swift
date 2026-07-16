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
        let sources: [Transcription.SourceType] = [.file, .youtube, .podcast]
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Alpha", startMs: 0, endMs: 100, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "beta", startMs: 120, endMs: 200, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "gamma.", startMs: 220, endMs: 350, confidence: 1, speakerId: "S1"),
        ]
        let speakers: [SpeakerInfo] = [SpeakerInfo(id: "S1", label: "Riley")]

        for source in sources {
            let transcription = completedTranscription(
                source: source,
                text: "Alpha beta gamma.",
                words: words,
                speakers: speakers
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

    func testWordTimestampMaterializationHandlesBothWhitespaceTokenStyles() {
        XCTAssertEqual(KnowledgeSegmenter.currentVersion, 2)
        let wordStyle = ["That's", "incredible.", "I", "will", "be", "honest"]
        let tokenizerStyle = ["That's", " incredible", ".", " I", " will", " be", "honest"]

        for tokens in [wordStyle, tokenizerStyle] {
            let words = tokens.enumerated().map { index, token in
                WordTimestamp(
                    word: token,
                    startMs: index * 100,
                    endMs: index * 100 + 80,
                    confidence: 1
                )
            }

            XCTAssertEqual(
                KnowledgeSegmenter.materializeFileTranscriptSegments(words: words).map(\.text),
                ["That's incredible. I will be honest"]
            )
        }
    }

    func testWordTimestampMaterializationHandlesMixedPunctuationAndDelimitersDeterministically() {
        let cases: [([String], String)] = [
            (["Hello", " ,", "world"], "Hello, world"),
            (["Open", " (", "the", " door", ")", "."], "Open (the door)."),
            (["She", " said", " \"", "ship", " it", "\"", "."], "She said \"ship it\"."),
            (["“", "Hello", "”", ",", " world"], "“Hello”, world"),
            (["That", "'", "s", " Dana", "'", "s", " plan", "."], "That's Dana's plan."),
            (["Alpha", ",", " beta", ";", "gamma", " !"], "Alpha, beta; gamma!"),
        ]

        for (tokens, expected) in cases {
            let words = tokens.enumerated().map { index, token in
                WordTimestamp(
                    word: token,
                    startMs: index * 100,
                    endMs: index * 100 + 80,
                    confidence: 1
                )
            }
            let first = KnowledgeSegmenter.materializeFileTranscriptSegments(words: words)
            let second = KnowledgeSegmenter.materializeFileTranscriptSegments(words: words)
            XCTAssertEqual(first.map(\.text), [expected], "tokens: \(tokens)")
            XCTAssertEqual(first.map(\.text), second.map(\.text), "tokens: \(tokens)")
            XCTAssertEqual(first.map(\.wordRange), second.map(\.wordRange), "tokens: \(tokens)")
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
        let sources: [Transcription.SourceType] = [.meeting, .file]
        for source in sources {
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
        let alpha: Transcription = completedTranscription(source: .file, text: "new canonical alpha")
        let beta: Transcription = completedTranscription(source: .file, text: "new canonical beta")
        let recordings: [Transcription] = [alpha, beta]
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

        let allQuery = SegmentSearchQuery(query: "sparkle", limit: 10)
        let all: [SegmentSearchHit] = try segments.search(allQuery)
        let actualIDs: Set<UUID> = Set(all.map(\.transcriptionId))
        let expectedIDs: Set<UUID> = Set([old.id, recent.id, url.id])
        XCTAssertEqual(actualIDs, expectedIDs)
        XCTAssertEqual(all.first?.transcriptionId, old.id, "higher term frequency should improve bm25 rank")
        XCTAssertNotNil(all.first?.rank)
        let limitedQuery = SegmentSearchQuery(query: "sparkle", limit: 1)
        let limited: [SegmentSearchHit] = try segments.search(limitedQuery)
        XCTAssertEqual(limited.count, 1)

        let meetingQuery = SegmentSearchQuery(
            query: "sparkle",
            since: Date(timeIntervalSince1970: 1_750_000_000),
            source: .meeting,
            speaker: "Dana",
            limit: 10
        )
        let meetingIDs: [UUID] = try searchIDs(meetingQuery)
        XCTAssertEqual(meetingIDs, [recent.id])

        let oldFileQuery = SegmentSearchQuery(
            query: "sparkle",
            until: Date(timeIntervalSince1970: 1_725_000_000),
            source: .file,
            limit: 10
        )
        let oldFileIDs: [UUID] = try searchIDs(oldFileQuery)
        XCTAssertEqual(oldFileIDs, [old.id])

        let urlQuery = SegmentSearchQuery(query: "sparkle", source: .url, limit: 10)
        let urlIDs: [UUID] = try searchIDs(urlQuery)
        XCTAssertEqual(urlIDs, [url.id])

        var row = try XCTUnwrap(segments.fetch(transcriptionId: recent.id).first)
        row.text = "Updated retrieval token."
        try manager.dbQueue.write { db in try row.update(db) }
        let sparkleAfterUpdate: [SegmentSearchHit] = try segments.search(allQuery)
        let recentStillMatches = sparkleAfterUpdate.contains { $0.transcriptionId == recent.id }
        XCTAssertFalse(recentStillMatches)

        let updatedQuery = SegmentSearchQuery(query: "updated", limit: 10)
        let updated: [SegmentSearchHit] = try segments.search(updatedQuery)
        XCTAssertEqual(updated.first?.transcriptionId, recent.id)

        try manager.dbQueue.write { db in _ = try row.delete(db) }
        let afterDelete: [SegmentSearchHit] = try segments.search(updatedQuery)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testSearchUsesSourceAwareDisplayTitles() throws {
        let local = Transcription(
            fileName: " source-recording .m4a",
            rawTranscript: "shared naming marker",
            status: .completed,
            sourceType: .file,
            derivedTitle: "Spoken Local Opening"
        )
        let renamedLocal = Transcription(
            fileName: "renamed-source.m4a",
            rawTranscript: "shared naming marker",
            status: .completed,
            sourceType: .file,
            titleOverride: "Customer Interview",
            derivedTitle: "Spoken Renamed Opening"
        )
        let url = Transcription(
            fileName: "Published Video Title",
            rawTranscript: "shared naming marker",
            status: .completed,
            sourceType: .youtube,
            derivedTitle: "Spoken URL Opening"
        )

        for transcription in [local, renamedLocal, url] {
            try transcriptions.save(transcription)
            try segments.replaceSegments(for: transcription)
        }

        let hits = try segments.search(SegmentSearchQuery(query: "naming", limit: 10))
        let titlesByID = Dictionary(uniqueKeysWithValues: hits.map { ($0.transcriptionId, $0.title) })
        XCTAssertEqual(titlesByID[local.id], " source-recording .m4a")
        XCTAssertEqual(titlesByID[renamedLocal.id], "Customer Interview")
        XCTAssertEqual(titlesByID[url.id], "Spoken URL Opening")
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

        let query = SegmentSearchQuery(query: "重要な会議", limit: 10)
        let hits: [SegmentSearchHit] = try segments.search(query)
        let hit = try XCTUnwrap(hits.first)
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

        let mixedText = String(repeating: "prefix ", count: 20) + "tanaka 会議 decision"
        let mixedCase = SegmentRepository.characterSafeSnippet(
            mixedText,
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

        let timedRows = try segments.fetchSlice(
            transcriptionId: transcription.id,
            aroundMs: 5_000,
            windowMs: 1_000
        )
        let timedSequences: [Int] = timedRows.map(\.seq)
        XCTAssertEqual(timedSequences, [1])

        let contextRows = try segments.fetchSlice(
            transcriptionId: transcription.id,
            aroundSeq: 1,
            context: 1
        )
        let contextSequences: [Int] = contextRows.map(\.seq)
        XCTAssertEqual(contextSequences, [0, 1, 2])
    }

    private func deterministicRows() throws -> [[String]] {
        try manager.dbQueue.read { db in
            let rows: [Row] = try Row.fetchAll(
                db,
                sql: """
                    SELECT hex(transcriptionId) AS transcriptionId, seq, startMs, endMs,
                           COALESCE(speaker, '') AS speaker, text, segmenterVersion
                    FROM segments
                    ORDER BY transcriptionId, seq
                    """
            )
            return rows.map { row -> [String] in
                let transcriptionID: String = row["transcriptionId"]
                let sequence = String(row["seq"] as Int)
                let start = (row["startMs"] as Int?).map(String.init) ?? "nil"
                let end = (row["endMs"] as Int?).map(String.init) ?? "nil"
                let speaker: String = row["speaker"]
                let text: String = row["text"]
                let version = String(row["segmenterVersion"] as Int)
                return [transcriptionID, sequence, start, end, speaker, text, version]
            }
        }
    }

    private func searchIDs(_ query: SegmentSearchQuery) throws -> [UUID] {
        let hits: [SegmentSearchHit] = try segments.search(query)
        return hits.map(\.transcriptionId)
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
