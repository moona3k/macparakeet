import XCTest
@testable import MacParakeetCore

final class VibeVoiceModelDownloaderTests: XCTestCase {

    func testModelFileSpecHasURLAndExpectedSize() {
        let spec = VibeVoiceModelDownloader.modelFile
        XCTAssertTrue(spec.remoteURL.absoluteString.contains("huggingface.co"))
        XCTAssertTrue(spec.remoteURL.absoluteString.hasSuffix("/vibevoice-asr-q4_k.gguf"))
        XCTAssertGreaterThan(spec.expectedSizeBytes, 9_000_000_000)  // ~9.7 GB
        XCTAssertLessThan(spec.expectedSizeBytes, 11_000_000_000)
        XCTAssertEqual(spec.expectedSHA256.count, 64)  // hex digest length
    }

    func testTokenizerFileSpecHasURLAndExpectedSize() {
        let spec = VibeVoiceModelDownloader.tokenizerFile
        XCTAssertTrue(spec.remoteURL.absoluteString.hasSuffix("/tokenizer.gguf"))
        XCTAssertGreaterThan(spec.expectedSizeBytes, 5_000_000)  // ~5.6 MB
        XCTAssertLessThan(spec.expectedSizeBytes, 7_000_000)
        XCTAssertEqual(spec.expectedSHA256.count, 64)
    }

    func testDefaultDirectoryMatchesVibeVoiceEngineConvention() {
        let dir = VibeVoiceModelDownloader.defaultModelDirectory()
        XCTAssertTrue(dir.path.contains("MacParakeet/models/stt/vibevoice"))
        // Same path the VibeVoiceEngine uses
        XCTAssertEqual(dir, VibeVoiceEngine.defaultModelDirectory())
    }

    func testAreModelsInstalledReturnsFalseWhenMissing() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertFalse(VibeVoiceModelDownloader.areModelsInstalled(at: tmp))
    }

    func testAreModelsInstalledReturnsTrueWhenBothFilesPresent() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = tmp.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = tmp.appendingPathComponent("tokenizer.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        FileManager.default.createFile(atPath: tok.path, contents: Data())

        XCTAssertTrue(VibeVoiceModelDownloader.areModelsInstalled(at: tmp))
    }
}
