import XCTest
@testable import MacParakeetCore

final class DictationModelTests: XCTestCase {

    func testDefaultInit() {
        let d = Dictation(durationMs: 5000, rawTranscript: "Hello world")

        XCTAssertFalse(d.id.uuidString.isEmpty)
        XCTAssertEqual(d.durationMs, 5000)
        XCTAssertEqual(d.rawTranscript, "Hello world")
        XCTAssertNil(d.cleanTranscript)
        XCTAssertNil(d.audioPath)
        XCTAssertNil(d.pastedToApp)
        XCTAssertEqual(d.processingMode, .raw)
        XCTAssertEqual(d.status, .completed)
        XCTAssertNil(d.errorMessage)
    }

    func testCustomInit() {
        let id = UUID()
        let date = Date.distantPast
        let d = Dictation(
            id: id,
            createdAt: date,
            durationMs: 1234,
            rawTranscript: "raw",
            cleanTranscript: "clean",
            audioPath: "/path/to/audio.m4a",
            pastedToApp: "TextEdit",
            processingMode: .clean,
            status: .error,
            errorMessage: "Something went wrong",
            updatedAt: date
        )

        XCTAssertEqual(d.id, id)
        XCTAssertEqual(d.createdAt, date)
        XCTAssertEqual(d.durationMs, 1234)
        XCTAssertEqual(d.rawTranscript, "raw")
        XCTAssertEqual(d.cleanTranscript, "clean")
        XCTAssertEqual(d.audioPath, "/path/to/audio.m4a")
        XCTAssertEqual(d.pastedToApp, "TextEdit")
        XCTAssertEqual(d.processingMode, .clean)
        XCTAssertEqual(d.status, .error)
        XCTAssertEqual(d.errorMessage, "Something went wrong")
    }

    func testProcessingModeRawValues() {
        XCTAssertEqual(Dictation.ProcessingMode.raw.rawValue, "raw")
        XCTAssertEqual(Dictation.ProcessingMode.clean.rawValue, "clean")
    }

    func testDictationStatusRawValues() {
        XCTAssertEqual(Dictation.DictationStatus.recording.rawValue, "recording")
        XCTAssertEqual(Dictation.DictationStatus.processing.rawValue, "processing")
        XCTAssertEqual(Dictation.DictationStatus.completed.rawValue, "completed")
        XCTAssertEqual(Dictation.DictationStatus.error.rawValue, "error")
    }

    func testProcessingModeHelpers() {
        XCTAssertFalse(Dictation.ProcessingMode.raw.usesDeterministicPipeline)
        XCTAssertTrue(Dictation.ProcessingMode.clean.usesDeterministicPipeline)
    }

    func testDeprecatedModeDecodesAsClean() throws {
        let json = #"{"processingMode":"formal"}"#.data(using: .utf8)!

        struct ModeWrapper: Codable {
            let processingMode: Dictation.ProcessingMode
        }

        let decoded = try JSONDecoder().decode(ModeWrapper.self, from: json)
        XCTAssertEqual(decoded.processingMode, .clean)
    }

    func testDeprecatedEmailModeDecodesAsClean() throws {
        let json = #"{"processingMode":"email"}"#.data(using: .utf8)!

        struct ModeWrapper: Codable {
            let processingMode: Dictation.ProcessingMode
        }

        let decoded = try JSONDecoder().decode(ModeWrapper.self, from: json)
        XCTAssertEqual(decoded.processingMode, .clean)
    }

    func testDeprecatedCodeModeDecodesAsClean() throws {
        let json = #"{"processingMode":"code"}"#.data(using: .utf8)!

        struct ModeWrapper: Codable {
            let processingMode: Dictation.ProcessingMode
        }

        let decoded = try JSONDecoder().decode(ModeWrapper.self, from: json)
        XCTAssertEqual(decoded.processingMode, .clean)
    }

    func testDeprecatedModeRawValueInitMapsToClean() {
        // Verifies init?(rawValue:) handles legacy stored preferences (UserDefaults, CLI args)
        XCTAssertEqual(Dictation.ProcessingMode(rawValue: "formal"), .clean)
        XCTAssertEqual(Dictation.ProcessingMode(rawValue: "email"), .clean)
        XCTAssertEqual(Dictation.ProcessingMode(rawValue: "code"), .clean)
        XCTAssertEqual(Dictation.ProcessingMode(rawValue: "clean"), .clean)
        XCTAssertEqual(Dictation.ProcessingMode(rawValue: "raw"), .raw)
        XCTAssertNil(Dictation.ProcessingMode(rawValue: "unknown"))
    }

    func testCodableRoundTrip() throws {
        let original = Dictation(
            durationMs: 3000,
            rawTranscript: "Test transcript with unicode: cafe\u{0301}",
            cleanTranscript: "Clean version"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Dictation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.durationMs, original.durationMs)
        XCTAssertEqual(decoded.rawTranscript, original.rawTranscript)
        XCTAssertEqual(decoded.cleanTranscript, original.cleanTranscript)
        XCTAssertEqual(decoded.processingMode, original.processingMode)
        XCTAssertEqual(decoded.status, original.status)
    }

    func testZeroDuration() {
        let d = Dictation(durationMs: 0, rawTranscript: "")
        XCTAssertEqual(d.durationMs, 0)
        XCTAssertEqual(d.rawTranscript, "")
    }

    func testEmptyTranscript() {
        let d = Dictation(durationMs: 100, rawTranscript: "")
        XCTAssertTrue(d.rawTranscript.isEmpty)
    }
}
