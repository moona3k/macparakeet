import XCTest
import GRDB
@testable import MacParakeetCore

final class VocabularyImportExportServiceTests: XCTestCase {
    var manager: DatabaseManager!
    var customWordRepo: CustomWordRepository!
    var snippetRepo: TextSnippetRepository!
    var service: VocabularyImportExportService!
    let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() async throws {
        manager = try DatabaseManager()
        customWordRepo = CustomWordRepository(dbQueue: manager.dbQueue)
        snippetRepo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let now = fixedNow
        service = VocabularyImportExportService(
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            dbQueue: manager.dbQueue,
            appVersion: "0.6.0-test",
            clock: { now }
        )
    }

    // MARK: - Export

    func testExportProducesValidBundle() throws {
        try customWordRepo.save(CustomWord(word: "kubernetes", replacement: "Kubernetes"))
        try snippetRepo.save(TextSnippet(trigger: "addr", expansion: "123 Main St"))

        let data = try service.exportData()
        let bundle = try JSONDecoder.iso8601().decode(VocabularyBundle.self, from: data)

        XCTAssertEqual(bundle.schema, VocabularyBundle.schemaIdentifier)
        XCTAssertEqual(bundle.version, VocabularyBundle.currentVersion)
        XCTAssertEqual(bundle.appVersion, "0.6.0-test")
        XCTAssertEqual(bundle.exportedAt, fixedNow)
        XCTAssertEqual(bundle.customWords.count, 1)
        XCTAssertEqual(bundle.textSnippets.count, 1)
        XCTAssertEqual(bundle.customWords.first?.word, "kubernetes")
        XCTAssertEqual(bundle.textSnippets.first?.trigger, "addr")
    }

    func testExportSkipsLearnedWords() throws {
        try customWordRepo.save(CustomWord(word: "manual-only", source: .manual))
        try customWordRepo.save(CustomWord(word: "auto-learned", source: .learned))

        let bundle = try service.makeBundle()
        XCTAssertEqual(bundle.customWords.count, 1)
        XCTAssertEqual(bundle.customWords.first?.word, "manual-only")
    }

    func testExportPreservesIsEnabledAndAction() throws {
        try customWordRepo.save(CustomWord(word: "off", isEnabled: false))
        try snippetRepo.save(TextSnippet(trigger: "send", expansion: "ok", action: .returnKey))

        let bundle = try service.makeBundle()
        XCTAssertEqual(bundle.customWords.first?.isEnabled, false)
        XCTAssertEqual(bundle.textSnippets.first?.action, .returnKey)
    }

    func testEmptyExportProducesEmptyArrays() throws {
        let bundle = try service.makeBundle()
        XCTAssertTrue(bundle.customWords.isEmpty)
        XCTAssertTrue(bundle.textSnippets.isEmpty)
    }

    func testSuggestedFilenameUsesUTCDate() {
        let date = Date(timeIntervalSince1970: 1_714_003_200) // 2024-04-25 00:00:00 UTC
        let name = service.suggestedFilename(now: date)
        XCTAssertEqual(name, "MacParakeet-Vocabulary-2024-04-25.json")
    }

    // MARK: - Round-trip

    func testRoundTripPreservesData() throws {
        try customWordRepo.save(CustomWord(word: "Daniel", replacement: nil))
        try customWordRepo.save(CustomWord(word: "centre", replacement: "centre"))
        try snippetRepo.save(TextSnippet(trigger: "sig", expansion: "Cheers,\nDaniel"))

        let data = try service.exportData()

        // Wipe DB.
        try customWordRepo.deleteAll()
        try snippetRepo.deleteAll()
        XCTAssertEqual(try customWordRepo.fetchAll().count, 0)
        XCTAssertEqual(try snippetRepo.fetchAll().count, 0)

        // Import.
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .skip)

        XCTAssertEqual(result.wordsAdded, 2)
        XCTAssertEqual(result.snippetsAdded, 1)
        XCTAssertEqual(try customWordRepo.fetchAll().count, 2)
        XCTAssertEqual(try snippetRepo.fetchAll().count, 1)

        let snippet = try XCTUnwrap(try snippetRepo.fetchAll().first)
        XCTAssertEqual(snippet.expansion, "Cheers,\nDaniel")
    }

    // MARK: - Conflicts

    func testDecodePreviewDetectsConflictsCaseInsensitive() throws {
        try customWordRepo.save(CustomWord(word: "Kubernetes"))
        try snippetRepo.save(TextSnippet(trigger: "Addr", expansion: "x"))

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "kubernetes", replacement: nil, isEnabled: true, createdAt: nil),
                .init(word: "fresh", replacement: nil, isEnabled: true, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: "addr", expansion: "y", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)

        XCTAssertEqual(preview.wordsTotal, 2)
        XCTAssertEqual(preview.snippetsTotal, 1)
        XCTAssertEqual(preview.wordConflicts, ["kubernetes"])
        XCTAssertEqual(preview.snippetConflicts, ["addr"])
        XCTAssertTrue(preview.duplicateWords.isEmpty)
        XCTAssertTrue(preview.duplicateSnippets.isEmpty)
        XCTAssertTrue(preview.hasConflicts)
    }

    func testDecodePreviewDetectsInBundleDuplicatesCaseInsensitive() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "Kubernetes", replacement: "A", isEnabled: true, createdAt: nil),
                .init(word: "kubernetes", replacement: "B", isEnabled: true, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: "Addr", expansion: "A", isEnabled: true, action: nil, createdAt: nil),
                .init(trigger: "addr", expansion: "B", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)

        XCTAssertEqual(preview.duplicateWords, ["kubernetes"])
        XCTAssertEqual(preview.duplicateSnippets, ["addr"])
        XCTAssertTrue(preview.hasConflicts)
    }

    func testApplyWithSkipPolicyKeepsExisting() throws {
        try customWordRepo.save(CustomWord(word: "Kubernetes", replacement: "Existing"))

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "kubernetes", replacement: "Imported", isEnabled: true, createdAt: nil)
            ],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .skip)

        XCTAssertEqual(result.wordsAdded, 0)
        XCTAssertEqual(result.wordsSkipped, 1)
        XCTAssertEqual(result.wordsReplaced, 0)

        let stored = try XCTUnwrap(try customWordRepo.fetchAll().first)
        XCTAssertEqual(stored.replacement, "Existing")
    }

    func testApplyWithReplacePolicyOverwritesExisting() throws {
        try customWordRepo.save(CustomWord(word: "Kubernetes", replacement: "Existing"))
        try snippetRepo.save(TextSnippet(trigger: "addr", expansion: "Old"))

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "kubernetes", replacement: "New", isEnabled: false, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: "addr", expansion: "New expansion", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .replace)

        XCTAssertEqual(result.wordsReplaced, 1)
        XCTAssertEqual(result.snippetsReplaced, 1)

        let words = try customWordRepo.fetchAll()
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].word, "kubernetes")
        XCTAssertEqual(words[0].replacement, "New")
        XCTAssertFalse(words[0].isEnabled)

        let snippets = try snippetRepo.fetchAll()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].expansion, "New expansion")
    }

    func testApplyMixedAddAndConflict() throws {
        try customWordRepo.save(CustomWord(word: "kubernetes"))

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "kubernetes", replacement: nil, isEnabled: true, createdAt: nil),
                .init(word: "centre", replacement: "centre", isEnabled: true, createdAt: nil)
            ],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .skip)

        XCTAssertEqual(result.wordsAdded, 1)
        XCTAssertEqual(result.wordsSkipped, 1)
        XCTAssertEqual(try customWordRepo.fetchAll().count, 2)
    }

    func testApplyWithSkipPolicySkipsDuplicateEntriesInsideBundle() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "Kubernetes", replacement: "First", isEnabled: true, createdAt: nil),
                .init(word: "kubernetes", replacement: "Second", isEnabled: true, createdAt: nil)
            ],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .skip)

        XCTAssertEqual(result.wordsAdded, 1)
        XCTAssertEqual(result.wordsSkipped, 1)
        XCTAssertEqual(result.wordsReplaced, 0)

        let stored = try XCTUnwrap(try customWordRepo.fetchAll().first)
        XCTAssertEqual(stored.word, "Kubernetes")
        XCTAssertEqual(stored.replacement, "First")
    }

    func testApplyWithReplacePolicyLetsLaterDuplicateEntryWinInsideBundle() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "Kubernetes", replacement: "First", isEnabled: true, createdAt: nil),
                .init(word: "kubernetes", replacement: "Second", isEnabled: false, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: "Addr", expansion: "First", isEnabled: true, action: nil, createdAt: nil),
                .init(trigger: "addr", expansion: "Second", isEnabled: false, action: .returnKey, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .replace)

        XCTAssertEqual(result.wordsAdded, 1)
        XCTAssertEqual(result.wordsReplaced, 1)
        XCTAssertEqual(result.snippetsAdded, 1)
        XCTAssertEqual(result.snippetsReplaced, 1)

        let storedWord = try XCTUnwrap(try customWordRepo.fetchAll().first)
        XCTAssertEqual(storedWord.word, "kubernetes")
        XCTAssertEqual(storedWord.replacement, "Second")
        XCTAssertFalse(storedWord.isEnabled)

        let storedSnippet = try XCTUnwrap(try snippetRepo.fetchAll().first)
        XCTAssertEqual(storedSnippet.trigger, "addr")
        XCTAssertEqual(storedSnippet.expansion, "Second")
        XCTAssertEqual(storedSnippet.action, .returnKey)
        XCTAssertFalse(storedSnippet.isEnabled)
    }

    func testApplyRollsBackWholeImportWhenLaterWriteFails() throws {
        try customWordRepo.save(CustomWord(word: "Kubernetes", replacement: "Existing"))
        try manager.dbQueue.write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_vocab_import_insert
            BEFORE INSERT ON custom_words
            WHEN NEW.word = 'explode'
            BEGIN
                SELECT RAISE(ABORT, 'forced import failure');
            END
            """)
        }

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "kubernetes", replacement: "Replacement", isEnabled: false, createdAt: nil),
                .init(word: "safe-new", replacement: nil, isEnabled: true, createdAt: nil),
                .init(word: "explode", replacement: nil, isEnabled: true, createdAt: nil),
            ],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)

        XCTAssertThrowsError(try service.apply(preview: preview, policy: .replace))

        let storedWords = try customWordRepo.fetchAll()
        XCTAssertEqual(storedWords.count, 1)
        let stored = try XCTUnwrap(storedWords.first)
        XCTAssertEqual(stored.word, "Kubernetes")
        XCTAssertEqual(stored.replacement, "Existing")
        XCTAssertTrue(stored.isEnabled)
    }

    // MARK: - Validation

    func testDecodeRejectsInvalidSchema() throws {
        let bogus = """
        { "schema": "not.us", "version": 1, "exportedAt": "2026-04-28T12:00:00Z",
          "customWords": [], "textSnippets": [] }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try service.decodePreview(from: bogus)) { error in
            XCTAssertEqual(error as? VocabularyImportExportService.ImportError, .invalidSchema)
        }
    }

    func testDecodeRejectsFutureVersion() throws {
        let future = """
        { "schema": "macparakeet.vocabulary", "version": 999,
          "exportedAt": "2026-04-28T12:00:00Z",
          "customWords": [], "textSnippets": [] }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try service.decodePreview(from: future)) { error in
            XCTAssertEqual(
                error as? VocabularyImportExportService.ImportError,
                .unsupportedVersion(found: 999, supported: VocabularyBundle.currentVersion)
            )
        }
    }

    func testDecodeRejectsMalformedJSON() throws {
        let bad = Data("not valid json {{{".utf8)
        XCTAssertThrowsError(try service.decodePreview(from: bad)) { error in
            guard case .decodingFailed = error as? VocabularyImportExportService.ImportError else {
                XCTFail("expected .decodingFailed, got \(error)")
                return
            }
        }
    }

    func testDecodePreviewNormalizesEntriesBeforeImport() throws {
        try customWordRepo.save(CustomWord(word: "Kubernetes"))
        try snippetRepo.save(TextSnippet(trigger: "my address", expansion: "Old"))

        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: "  kubernetes\n", replacement: " Kubernetes  ", isEnabled: true, createdAt: nil),
                .init(word: "\tMacParakeet ", replacement: " \n ", isEnabled: true, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: " my address ", expansion: "  123 Main\\nSF  ", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)

        XCTAssertEqual(preview.bundle.customWords[0].word, "kubernetes")
        XCTAssertEqual(preview.bundle.customWords[0].replacement, "Kubernetes")
        XCTAssertEqual(preview.bundle.customWords[1].word, "MacParakeet")
        XCTAssertNil(preview.bundle.customWords[1].replacement)
        XCTAssertEqual(preview.bundle.textSnippets[0].trigger, "my address")
        XCTAssertEqual(preview.bundle.textSnippets[0].expansion, "123 Main\nSF")
        XCTAssertEqual(preview.wordConflicts, ["kubernetes"])
        XCTAssertEqual(preview.snippetConflicts, ["my address"])
    }

    func testDecodeRejectsBlankCustomWord() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [
                .init(word: " \n\t ", replacement: "Nope", isEnabled: true, createdAt: nil)
            ],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)

        XCTAssertThrowsError(try service.decodePreview(from: data)) { error in
            guard case let .invalidEntry(message) = error as? VocabularyImportExportService.ImportError else {
                XCTFail("expected .invalidEntry, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("customWords[0].word"))
        }
    }

    func testDecodeRejectsBlankSnippetTrigger() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [],
            textSnippets: [
                .init(trigger: " \n\t ", expansion: "Expansion", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)

        XCTAssertThrowsError(try service.decodePreview(from: data)) { error in
            guard case let .invalidEntry(message) = error as? VocabularyImportExportService.ImportError else {
                XCTFail("expected .invalidEntry, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("textSnippets[0].trigger"))
        }
    }

    func testDecodeRejectsBlankSnippetExpansion() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [],
            textSnippets: [
                .init(trigger: "my phrase", expansion: " \t ", isEnabled: true, action: nil, createdAt: nil)
            ]
        )
        let data = try JSONEncoder.iso8601().encode(bundle)

        XCTAssertThrowsError(try service.decodePreview(from: data)) { error in
            guard case let .invalidEntry(message) = error as? VocabularyImportExportService.ImportError else {
                XCTFail("expected .invalidEntry, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("textSnippets[0].expansion"))
        }
    }

    func testEmptyBundleAppliesCleanly() throws {
        let bundle = VocabularyBundle(
            exportedAt: fixedNow,
            appVersion: nil,
            customWords: [],
            textSnippets: []
        )
        let data = try JSONEncoder.iso8601().encode(bundle)
        let preview = try service.decodePreview(from: data)
        let result = try service.apply(preview: preview, policy: .skip)

        XCTAssertEqual(result.wordsAdded, 0)
        XCTAssertEqual(result.snippetsAdded, 0)
        XCTAssertFalse(preview.hasConflicts)
    }
}

// MARK: - Test helpers

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
