import XCTest
@testable import MacParakeetCore

@MainActor
final class AutoSaveServiceTests: XCTestCase {

    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "com.macparakeet.test.autosave.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        if let name = defaults.volatileDomainNames.first {
            defaults.removeVolatileDomain(forName: name)
        }
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTranscription(
        fileName: String = "test-audio.mp3",
        rawTranscript: String = "Hello world",
        createdAt: Date = Date(),
        sourceType: Transcription.SourceType = .file
    ) -> Transcription {
        Transcription(
            id: UUID(),
            createdAt: createdAt,
            fileName: fileName,
            rawTranscript: rawTranscript,
            status: .completed,
            isFavorite: false,
            sourceType: sourceType,
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

    // MARK: - Meeting Scope

    private func configureMeetingAutoSave(enabled: Bool = true, format: AutoSaveFormat = .md) {
        defaults.set(enabled, forKey: AutoSaveScope.meeting.enabledKey)
        defaults.set(format.rawValue, forKey: AutoSaveScope.meeting.formatKey)
        let bookmarkData = try! tempDir.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: AutoSaveScope.meeting.folderBookmarkKey)
    }

    func testMeetingScopeWritesFile() {
        configureMeetingAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(sourceType: .meeting)
        let service = makeService()

        service.saveIfEnabled(transcription, scope: .meeting)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".md"))
    }

    func testMeetingFileNameUsesCalendarEventTitle() {
        // Post-#135: calendar-driven meetings carry the event title as
        // the displayName. The auto-saved filename must reflect that —
        // otherwise a user with auto-save enabled sees "Roadmap Sync" in
        // the in-app library but a generic "Meeting" file on disk.
        configureMeetingAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(
            fileName: "Roadmap Sync",
            sourceType: .meeting
        )
        let service = makeService()

        let url = service.buildFileURL(for: transcription, format: .md, in: tempDir)
        let name = url.lastPathComponent
        XCTAssertTrue(name.contains("Roadmap Sync"),
                      "Filename should contain the calendar event title, got \(name)")
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    func testMeetingFileNameUsesDisplayNameForUncalendaredRecordings() {
        // Manual meeting recordings (no calendar link) keep the
        // date-based default displayName, e.g. "Meeting Apr 6, 2026 at
        // 10:02 PM". The filename mirrors the library label exactly —
        // there's a date duplication with the YYYY-MM-DD prefix, but
        // that's an acceptable trade for "what you see is what's on
        // disk" so users can grep their export folder for the same
        // string they see in the app.
        configureMeetingAutoSave(enabled: true, format: .md)
        let transcription = makeTranscription(
            fileName: "Meeting Apr 6, 2026 at 10:02 PM",
            sourceType: .meeting
        )
        let service = makeService()

        let url = service.buildFileURL(for: transcription, format: .md, in: tempDir)
        let name = url.lastPathComponent
        // Sanitizer strips ":" but preserves the rest — the human-readable
        // bits the user remembers ("Apr 6", "10 02 PM") survive.
        XCTAssertTrue(name.contains("Meeting"), "Filename should contain the displayName")
        XCTAssertTrue(name.contains("Apr 6"), "Filename should preserve the date components from the displayName, got \(name)")
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    func testMeetingScopeDisabledDoesNothing() {
        configureMeetingAutoSave(enabled: false)
        let service = makeService()

        service.saveIfEnabled(makeTranscription(), scope: .meeting)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 0)
    }

    func testMeetingScopeMigratesLegacyTranscriptionScope() {
        configureAutoSave(enabled: true, format: .txt)
        let service = makeService()

        service.saveIfEnabled(makeTranscription(sourceType: .meeting), scope: .meeting)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".txt"))
        XCTAssertEqual(defaults.object(forKey: AutoSaveScope.meeting.enabledKey) as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: AutoSaveScope.meeting.formatKey), AutoSaveFormat.txt.rawValue)
        XCTAssertNotNil(defaults.data(forKey: AutoSaveScope.meeting.folderBookmarkKey))
    }

    func testMeetingScopeExplicitDisableOverridesLegacyTranscriptionScope() {
        configureAutoSave(enabled: true, format: .txt)
        defaults.set(false, forKey: AutoSaveScope.meeting.enabledKey)
        let service = makeService()

        service.saveIfEnabled(makeTranscription(sourceType: .meeting), scope: .meeting)

        let files = try! FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files.count, 0)
    }

    func testMigrationDoesNotOverwriteExistingMeetingSettings() {
        configureAutoSave(enabled: true, format: .txt)
        configureMeetingAutoSave(enabled: false, format: .json)

        AutoSaveService.migrateLegacyMeetingSettingsIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: AutoSaveScope.meeting.enabledKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: AutoSaveScope.meeting.formatKey), AutoSaveFormat.json.rawValue)
    }

    func testMeetingScopeFolderStoreAndResolve() {
        let path = AutoSaveService.storeFolder(tempDir, scope: .meeting, defaults: defaults)
        XCTAssertNotNil(path)

        let service = makeService()
        let resolved = service.resolveFolder(scope: .meeting)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.standardizedFileURL.path, tempDir.standardizedFileURL.path)

        // Transcription scope should be unaffected
        XCTAssertNil(service.resolveFolder(scope: .transcription))
    }

    func testMeetingScopeClearFolder() {
        AutoSaveService.storeFolder(tempDir, scope: .meeting, defaults: defaults)
        AutoSaveService.clearFolder(scope: .meeting, defaults: defaults)

        let service = makeService()
        XCTAssertNil(service.resolveFolder(scope: .meeting))
    }

    func testMeetingScopeUsesOwnFormat() {
        // Meeting saves as TXT, transcription as MD
        configureMeetingAutoSave(enabled: true, format: .txt)
        configureAutoSave(enabled: true, format: .md)
        let service = makeService()

        // Create two separate temp dirs so files don't mix
        let meetingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transcriptionDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: transcriptionDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: meetingDir)
            try? FileManager.default.removeItem(at: transcriptionDir)
        }

        // Reconfigure folders to separate dirs
        AutoSaveService.storeFolder(meetingDir, scope: .meeting, defaults: defaults)
        AutoSaveService.storeFolder(transcriptionDir, scope: .transcription, defaults: defaults)

        service.saveIfEnabled(makeTranscription(), scope: .meeting)
        service.saveIfEnabled(makeTranscription(), scope: .transcription)

        let meetingFiles = try! FileManager.default.contentsOfDirectory(atPath: meetingDir.path)
        let transcriptionFiles = try! FileManager.default.contentsOfDirectory(atPath: transcriptionDir.path)

        XCTAssertEqual(meetingFiles.count, 1)
        XCTAssertTrue(meetingFiles[0].hasSuffix(".txt"))
        XCTAssertEqual(transcriptionFiles.count, 1)
        XCTAssertTrue(transcriptionFiles[0].hasSuffix(".md"))
    }
}
