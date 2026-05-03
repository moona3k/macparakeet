import Foundation
import Testing
@testable import MacParakeetCore

@Suite("TelemetryErrorClassifier")
struct TelemetryErrorClassifierTests {

    @Test("classifies AudioProcessorError cases with case name")
    func audioProcessorErrorCases() {
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.insufficientSamples)
            == "AudioProcessorError.insufficientSamples")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.microphoneNotAvailable)
            == "AudioProcessorError.microphoneNotAvailable")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.microphonePermissionDenied)
            == "AudioProcessorError.microphonePermissionDenied")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.recordingFailed("test"))
            == "AudioProcessorError.recordingFailed")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.conversionFailed("test"))
            == "AudioProcessorError.conversionFailed")
    }

    @Test("classifies STTError cases with case name")
    func sttErrorCases() {
        #expect(TelemetryErrorClassifier.classify(STTError.engineStartFailed("test"))
            == "STTError.engineStartFailed")
    }

    @Test("classifies DictationServiceError cases with case name")
    func dictationServiceErrorCases() {
        #expect(TelemetryErrorClassifier.classify(DictationServiceError.emptyTranscript)
            == "DictationServiceError.emptyTranscript")
        #expect(TelemetryErrorClassifier.classify(DictationServiceError.notRecording)
            == "DictationServiceError.notRecording")
    }

    @Test("classifies URLError with code name")
    func urlErrorCodes() {
        #expect(TelemetryErrorClassifier.classify(URLError(.notConnectedToInternet))
            == "URLError.notConnectedToInternet")
        #expect(TelemetryErrorClassifier.classify(URLError(.timedOut))
            == "URLError.timedOut")
    }

    @Test("classifies CancellationError")
    func cancellationError() {
        #expect(TelemetryErrorClassifier.classify(CancellationError())
            == "CancellationError")
    }

    @Test("classifies NSError with domain and code")
    func nsError() {
        let error = NSError(domain: "TestDomain", code: 42)
        #expect(TelemetryErrorClassifier.classify(error)
            == "TestDomain.42")
    }

    // MARK: - errorDetail

    @Test("errorDetail returns localizedDescription")
    func errorDetailBasic() {
        let error = STTError.engineStartFailed("Neural Engine unavailable")
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(detail.contains("Neural Engine unavailable"))
    }

    @Test("errorDetail replaces user home paths with <path>")
    func errorDetailStripsHomePath() {
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to load model at /Users/john/Library/Application Support/MacParakeet/models/stt"
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(!detail.contains("/Users/john"))
        #expect(!detail.contains("Library/Application Support"))
        #expect(detail.contains("<path>"))
    }

    @Test("errorDetail replaces temp paths with <path>")
    func errorDetailStripsTempPath() {
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot write to /var/folders/xx/yyy/T/macparakeet/audio.wav"
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(!detail.contains("/var/folders"))
        #expect(detail.contains("<path>"))

        // /private/var/folders/...
        let error2 = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Error at /private/var/folders/ab/cd/T/tmp.wav"
        ])
        let detail2 = TelemetryErrorClassifier.errorDetail(error2)
        #expect(!detail2.contains("/private/var"))
        #expect(detail2.contains("<path>"))

        // /tmp/...
        let error3 = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Missing file /tmp/macparakeet/recording.wav"
        ])
        let detail3 = TelemetryErrorClassifier.errorDetail(error3)
        #expect(!detail3.contains("/tmp/macparakeet"))
        #expect(detail3.contains("<path>"))
    }

    @Test("errorDetail replaces file:// URLs with <path>")
    func errorDetailStripsFileURL() {
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open file://localhost/Users/alice/Documents/meeting.m4v"
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(!detail.contains("file://"))
        #expect(!detail.contains("alice"))
        #expect(detail.contains("<path>"))
    }

    @Test("errorDetail replaces http(s) URLs with <url>")
    func errorDetailStripsHTTPURL() {
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Download failed: https://youtube.com/watch?v=dQw4w9WgXcQ returned 403"
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(!detail.contains("youtube.com"))
        #expect(!detail.contains("dQw4w9WgXcQ"))
        #expect(detail.contains("<url>"))
    }

    @Test("errorDetail handles multiple paths in one message")
    func errorDetailMultiplePaths() {
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot move /Users/alice/a.wav to /Users/alice/b.wav"
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(!detail.contains("/Users/alice"))
        // Both paths should be replaced
        #expect(!detail.contains("a.wav"))
    }

    @Test("errorDetail truncates to 512 characters")
    func errorDetailTruncates() {
        let longMessage = String(repeating: "x", count: 600)
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: longMessage
        ])
        let detail = TelemetryErrorClassifier.errorDetail(error)
        #expect(detail.count == 512)
    }
}
