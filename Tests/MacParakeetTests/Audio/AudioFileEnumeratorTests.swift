import XCTest
@testable import MacParakeetCore

final class AudioFileEnumeratorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioFileEnumeratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func touch(_ relativePath: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    func testSingleSupportedFilePassesThrough() throws {
        let mp3 = try touch("a.mp3")
        let result = AudioFileEnumerator.expand(urls: [mp3])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["a.mp3"])
        XCTAssertFalse(result.truncated)
    }

    func testFiltersUnsupportedExtensions() throws {
        let mp3 = try touch("a.mp3")
        let txt = try touch("notes.txt")
        let result = AudioFileEnumerator.expand(urls: [mp3, txt])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["a.mp3"])
    }

    func testExpandsFolderRecursivelySkippingHiddenAndUnsupported() throws {
        _ = try touch("lectures/lecture02.mp3")
        _ = try touch("lectures/lecture01.m4a")
        _ = try touch("lectures/nested/lecture03.wav")
        _ = try touch("lectures/readme.txt")
        _ = try touch("lectures/.hidden.mp3")

        let result = AudioFileEnumerator.expand(urls: [tempDir.appendingPathComponent("lectures")])
        // Sorted by natural name order, unsupported + hidden excluded.
        XCTAssertEqual(
            result.files.map(\.lastPathComponent),
            ["lecture01.m4a", "lecture02.mp3", "lecture03.wav"]
        )
    }

    func testDeduplicatesWhenFileAndItsFolderAreBothProvided() throws {
        let mp3 = try touch("dir/song.mp3")
        let result = AudioFileEnumerator.expand(urls: [tempDir.appendingPathComponent("dir"), mp3])
        XCTAssertEqual(result.files.count, 1)
    }

    func testNaturalSortOrder() throws {
        let f10 = try touch("clip10.mp3")
        let f2 = try touch("clip2.mp3")
        let f1 = try touch("clip1.mp3")
        let result = AudioFileEnumerator.expand(urls: [f10, f2, f1])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["clip1.mp3", "clip2.mp3", "clip10.mp3"])
    }

    func testCapSurfacesDroppedCount() throws {
        var urls: [URL] = []
        for i in 0..<10 {
            urls.append(try touch(String(format: "f%02d.mp3", i)))
        }
        let result = AudioFileEnumerator.expand(urls: urls, maxFiles: 4)
        XCTAssertEqual(result.files.count, 4)
        XCTAssertEqual(result.droppedCount, 6)
        XCTAssertTrue(result.truncated)
        // Cap is applied AFTER the name sort, so the kept subset is the
        // name-first `maxFiles` — deterministic, not a filesystem-order slice.
        XCTAssertEqual(
            result.files.map(\.lastPathComponent),
            ["f00.mp3", "f01.mp3", "f02.mp3", "f03.mp3"]
        )
    }

    func testFolderTraversalStopsAfterOverflowDetected() throws {
        for i in 0..<10 {
            _ = try touch(String(format: "folder/f%02d.mp3", i))
        }

        let result = AudioFileEnumerator.expand(
            urls: [tempDir.appendingPathComponent("folder")],
            maxFiles: 4
        )

        XCTAssertEqual(result.files.count, 4)
        XCTAssertEqual(result.droppedCount, 1)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.stoppedEarly)
    }

    func testEmptyWhenNoSupportedFiles() throws {
        let txt = try touch("a.txt")
        let result = AudioFileEnumerator.expand(urls: [txt])
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertFalse(result.truncated)
    }
}
