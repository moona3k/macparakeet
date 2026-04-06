import XCTest
@testable import MacParakeetCore

final class DiarizationServiceTests: XCTestCase {

    func testMockDiarizationServiceReturnsConfiguredResult() async throws {
        let mock = MockDiarizationService()
        let expected = MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 5000),
                SpeakerSegment(speakerId: "S2", startMs: 5000, endMs: 10000),
            ],
            speakerCount: 2,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S2", label: "Speaker 2"),
            ]
        )
        await mock.configure(result: expected)

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertEqual(result.speakers[0].id, "S1")
        XCTAssertEqual(result.speakers[1].label, "Speaker 2")

        let wasCalled = await mock.diarizeCalled
        XCTAssertTrue(wasCalled)
    }

    func testMockDiarizationServiceThrowsConfiguredError() async {
        let mock = MockDiarizationService()
        await mock.configure(error: STTError.transcriptionFailed("mock error"))

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        do {
            _ = try await mock.diarize(audioURL: dummyURL)
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    func testMockDiarizationServiceDefaultsToEmpty() async throws {
        let mock = MockDiarizationService()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 0)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testMockPrepareModels() async throws {
        let mock = MockDiarizationService()
        try await mock.prepareModels()
        let wasCalled = await mock.prepareModelsCalled
        XCTAssertTrue(wasCalled)
        let ready = await mock.isReady()
        XCTAssertTrue(ready)
        let cached = await mock.hasCachedModels()
        XCTAssertTrue(cached)
    }

    func testIsReady() async {
        let mock = MockDiarizationService()
        let ready = await mock.isReady()
        XCTAssertFalse(ready)
    }

    func testClearModelCacheRemovesCachedSpeakerModels() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoDirectory = DiarizationService.modelCacheDirectory(directory: tempDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        for modelName in DiarizationService.requiredModelNames() {
            let modelURL = repoDirectory.appendingPathComponent(modelName, isDirectory: false)
            FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        }

        XCTAssertTrue(DiarizationService.isModelCached(directory: tempDirectory))

        DiarizationService.clearModelCache(directory: tempDirectory)

        XCTAssertFalse(DiarizationService.isModelCached(directory: tempDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDirectory.path))
    }
}
