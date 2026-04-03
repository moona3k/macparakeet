import XCTest
@testable import MacParakeetCore

@MainActor
final class AutoSaveServiceTests: XCTestCase {

    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "com.macparakeet.test.autosave.\(UUID().uuidString)")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        if let name = defaults.volatileDomainNames.first {
            defaults.removeVolatileDomain(forName: name)
        }
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTranscription(
        fileName: String = "test-audio.mp3",
        rawTranscript: String = "Hello world",
        createdAt: Date = Date()
    ) -> Transcription {
        Transcription(
            id: UUID(),
            createdAt: createdAt,
            fileName: fileName,
            rawTranscript: rawTranscript,
            status: .completed,
            isFavorite: false,
            updatedAt: createdAt
        )
    }

    private func configureAutoSave(enabled: Bool = true, format: AutoSaveFormat = .md) {
        defaults.set(enabled, forKey: AutoSaveService.enabledKey)
        defaults.set(format.rawValue, forKey: AutoSaveService.formatKey)
        let bookmarkData = try! tempDir.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: AutoSaveService.folderBookmarkKey)
    }

    private func makeService() -> AutoSaveService {
        AutoSaveService(exportService: ExportService(), defaults: defaults)
    }

    // MARK: - Tests

    func testSaveIfEnabledWritesMarkdownFile() {
        configureAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".md"))
    }

    func testSaveIfEnabledWritesTxtFile() {
        configureAutoSave(enabled: true, format: .txt)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".txt"))
    }

    func testSaveIfEnabledWritesSRTFile() {
        configureAutoSave(enabled: true, format: .srt)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".srt"))
    }

    func testSaveIfEnabledWritesVTTFile() {
        configureAutoSave(enabled: true, format: .vtt)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".vtt"))
    }

    func testSaveIfEnabledWritesJSONFile() {
        configureAutoSave(enabled: true, format: .json)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".json"))
    }

    func testSaveIfDisabledDoesNothing() {
        configureAutoSave(enabled: false)
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 0)
    }

    func testSaveWithNoFolderConfiguredDoesNothing() {
        defaults.set(true, forKey: AutoSaveService.enabledKey)
        defaults.set("md", forKey: AutoSaveService.formatKey)
        // No folder bookmark set
        let transcription = makeTranscription()
        let service = makeService()

        service.saveIfEnabled(transcription)

        // Nothing should crash or be written
    }

    func testFileNameContainsDateAndSource() {
        configureAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(fileName: "interview-with-bob.m4a")
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("interview-with-bob"))
        XCTAssertTrue(files[0].hasSuffix(".md"))
        // Should start with date pattern YYYY-MM-DD
        let yearPrefix = String(files[0].prefix(4))
        XCTAssertTrue(Int(yearPrefix) != nil, "Filename should start with year")
    }

    func testDeduplicatesFilenames() {
        configureAutoSave(enabled: true, format: .md)

        // Use a fixed date so both transcriptions generate the same base filename
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = makeTranscription(fileName: "audio.mp3", createdAt: fixedDate)
        let t2 = makeTranscription(fileName: "audio.mp3", createdAt: fixedDate)
        let service = makeService()

        service.saveIfEnabled(t1)
        service.saveIfEnabled(t2)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 2, "Second save should create a deduplicated file")
    }

    func testBuildFileURLSanitizesFilename() {
        configureAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(fileName: "my/weird:file.mp3")
        let service = makeService()

        let url = service.buildFileURL(for: transcription, format: .md, in: tempDir)
        // Verify the file lands in the target folder (not nested via unsanitized path separators)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
    }

    // MARK: - AutoSaveFormat

    func testAllFormatsHaveDisplayNames() {
        for format in AutoSaveFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
        }
    }

    func testFormatRawValueMatchesFileExtension() {
        for format in AutoSaveFormat.allCases {
            XCTAssertEqual(format.rawValue, format.fileExtension)
        }
    }

    // MARK: - Folder Bookmark

    func testStoreFolderAndResolve() {
        let path = AutoSaveService.storeFolder(tempDir, defaults: defaults)
        XCTAssertNotNil(path)

        let service = makeService()
        let resolved = service.resolveFolder()
        XCTAssertNotNil(resolved)
        // Compare standardized paths to handle /var vs /private/var symlink
        XCTAssertEqual(resolved?.standardizedFileURL.path, tempDir.standardizedFileURL.path)
    }

    func testClearFolderRemovesBookmark() {
        AutoSaveService.storeFolder(tempDir, defaults: defaults)
        AutoSaveService.clearFolder(defaults: defaults)

        let service = makeService()
        XCTAssertNil(service.resolveFolder())
    }

    func testMarkdownContentIsWritten() {
        configureAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(
            fileName: "my-interview.mp3",
            rawTranscript: "This is a test transcript with some content."
        )
        let service = makeService()

        service.saveIfEnabled(transcription)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        let content = try! String(contentsOf: tempDir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(content.contains("my-interview"))
        XCTAssertTrue(content.contains("This is a test transcript"))
    }

    func testDeletedFolderDoesNotCrash() {
        configureAutoSave(enabled: true, format: .txt)
        // Remove the target folder after configuring — bookmark resolution will fail
        try! FileManager.default.removeItem(at: tempDir)

        let service = makeService()
        // Should not crash; auto-save silently skips when folder is gone
        service.saveIfEnabled(makeTranscription())
    }

    func testFallsBackToMarkdownForInvalidStoredFormat() {
        configureAutoSave(enabled: true, format: .md)
        // Corrupt the format key
        defaults.set("docx", forKey: AutoSaveService.formatKey)

        let service = makeService()
        service.saveIfEnabled(makeTranscription())

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".md"), "Should fall back to Markdown for unknown format")
    }

    func testInvalidBookmarkDataReturnsNilFolder() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AutoSaveService.folderBookmarkKey)
        let service = makeService()
        XCTAssertNil(service.resolveFolder())
    }
}
