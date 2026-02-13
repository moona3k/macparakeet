import XCTest
@testable import MacParakeetCore

final class DictationServiceErrorTests: XCTestCase {

    func testNotRecordingErrorDescription() {
        let error = DictationServiceError.notRecording
        XCTAssertEqual(error.errorDescription, "Not currently recording")
    }

    func testSTTErrorDescriptions() {
        let errors: [(STTError, String)] = [
            (.engineNotRunning, "Speech engine is not running"),
            (.modelNotLoaded, "STT model not loaded"),
            (.outOfMemory, "Out of memory during transcription"),
            (.transcriptionFailed("bad audio"), "Transcription failed: bad audio"),
            (.timeout, "STT request timed out"),
            (.invalidResponse, "Invalid response from speech engine"),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.errorDescription, expected, "STTError.\(error) description mismatch")
        }
    }

    func testAudioProcessorErrorDescriptions() {
        let errors: [(AudioProcessorError, String)] = [
            (.microphonePermissionDenied, "Microphone permission denied"),
            (.microphoneNotAvailable, "No microphone available"),
            (.recordingFailed("timeout"), "Recording failed: timeout"),
            (.conversionFailed("bad format"), "Audio conversion failed: bad format"),
            (.unsupportedFormat("xyz"), "Unsupported audio format: xyz"),
            (.fileTooLarge("2GB"), "File too large: 2GB"),
            (.insufficientSamples, "Recording too short"),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.errorDescription, expected, "AudioProcessorError.\(error) description mismatch")
        }
    }
}
