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
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.inputUnavailable(.noInputBuffers))
            == "AudioProcessorError.inputUnavailable")
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

    @Test("classifies NSError with a known platform domain and code")
    func nsError() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 42)
        #expect(TelemetryErrorClassifier.classify(error)
            == "NSPOSIXErrorDomain.42")
    }

    @Test("omits identifier-shaped private NSError domains")
    func identifierShapedNSErrorDomainIsPrivate() {
        let error = NSError(domain: "private_customer_amy", code: 7)
        #expect(TelemetryErrorClassifier.classify(error) == "NSError.7")
    }

    @Test("preserves the allowlisted Foundation and CoreAudio domain codes")
    func knownPlatformNSErrorDomains() {
        for domain in [
            NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
            "AVFoundationErrorDomain", "com.apple.coreaudio.avfaudio",
        ] {
            let error = NSError(domain: domain, code: -10868)
            #expect(TelemetryErrorClassifier.classify(error) == "\(domain).-10868")
        }
        let urlError = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        #expect(TelemetryErrorClassifier.classify(urlError) == "URLError.notConnectedToInternet")
    }

    @Test("does not classify arbitrary custom descriptions as error types")
    func customDescriptionsAreNotTelemetryDimensions() {
        enum DescribedError: Error, CustomStringConvertible {
            case failed
            var description: String { "private_transcript_text" }
        }
        struct DescribedStructError: Error, CustomStringConvertible {
            var description: String { "private transcript text" }
        }
        #expect(TelemetryErrorClassifier.classify(DescribedError.failed) == "DescribedError")
        #expect(TelemetryErrorClassifier.classify(DescribedStructError()) == "DescribedStructError")
    }

    @Test("rejects NSError domains containing paths or user content")
    func unsafeNSErrorDomain() {
        let error = NSError(domain: "/Users/alice/private meeting.wav", code: -10868)
        #expect(TelemetryErrorClassifier.classify(error) == "NSError.-10868")
    }

    @Test("preserves CoreAudio status in the microphone engine start wrapper")
    func microphoneStartCoreAudioStatus() {
        for domain in ["com.apple.coreaudio.avfaudio", "NSOSStatusErrorDomain"] {
            let underlying = NSError(domain: domain, code: -10868)
            let error = SharedMicrophoneStream.SubscribeError.engineStartFailed(underlying.localizedDescription)
            #expect(TelemetryErrorClassifier.classify(error) == "SubscribeError.engineStartFailed.\(domain).-10868")
        }
        for domain in ["com.apple.coreaudio.avfaudio", "NSOSStatusErrorDomain"] {
            let error = SharedMicrophoneStream.SubscribeError.engineStartFailed(
                "Error Domain=\(domain) Code=-10868 UserInfo={private spoken content}"
            )
            #expect(TelemetryErrorClassifier.classify(error) == "SubscribeError.engineStartFailed.\(domain).-10868")
        }
        let localizedAlias = SharedMicrophoneStream.SubscribeError.engineStartFailed(
            "The operation couldn’t be completed. (OSStatus error -10868.)"
        )
        #expect(TelemetryErrorClassifier.classify(localizedAlias)
            == "SubscribeError.engineStartFailed.NSOSStatusErrorDomain.-10868")
    }

    @Test("does not scrape arbitrary numeric data from microphone errors")
    func microphoneStartUnrecognizedDetails() {
        let messages = [
            "private spoken content -10868",
            "(private.customer.domain error -10868.)",
            "(com.apple.coreaudio.avfaudio error 999999999999999999999.)",
        ]
        for message in messages {
            let error = SharedMicrophoneStream.SubscribeError.engineStartFailed(message)
            #expect(TelemetryErrorClassifier.classify(error) == "SubscribeError.engineStartFailed")
        }
    }

    @Test("preserves the fixed interrupted-subscribe diagnostic without free-form text")
    func interruptedSubscribeCode() {
        #expect(TelemetryErrorClassifier.classify(
            AudioProcessorError.recordingFailed("interrupted during subscribe")
        ) == "AudioProcessorError.recordingFailed.interrupted_subscribe")
        #expect(TelemetryErrorClassifier.classify(
            AudioProcessorError.recordingFailed("interrupted during subscribe: private spoken content")
        ) == "AudioProcessorError.recordingFailed")
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

    @Test("redacts complete paths containing spaces and punctuation")
    func pathsWithSpaces() {
        let paths = [
            "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/private meeting.wav",
            "/Volumes/External Disk/Alice's Private Meeting (final).wav",
            "~/Documents/private meeting.wav",
            "/custom location/private meeting.wav",
            "file:///Users/alice/Library/Application Support/private meeting.wav",
        ]
        for path in paths {
            let message = "Audio conversion failed: \(path)\nCoreAudio status -10868"
            let sanitized = TelemetryErrorClassifier.sanitize(message)
            #expect(sanitized == "Audio conversion failed: <path>\nCoreAudio status -10868")
            #expect(TelemetryErrorClassifier.sanitize(sanitized) == sanitized)
        }
    }

    @Test("redacts email addresses and recognizable credentials")
    func emailsAndCredentials() {
        let message = "user=alice@example.com\nAuthorization: Bearer private-token-value\napi_key=private-key-value\nsk-proj-12345678901234567890"
        let sanitized = TelemetryErrorClassifier.sanitize(message)
        #expect(!sanitized.contains("alice@example.com"))
        #expect(!sanitized.contains("private-token-value"))
        #expect(!sanitized.contains("private-key-value"))
        #expect(!sanitized.contains("sk-proj-"))
        #expect(TelemetryErrorClassifier.sanitize(sanitized) == sanitized)
    }

    @Test("preserves useful technical dimensions")
    func technicalContextIsPreserved() {
        let message = "AUHAL -10868; input=48000Hz/2ch; conversionFailed; NSOSStatusErrorDomain.-10868"
        #expect(TelemetryErrorClassifier.sanitize(message) == message)
    }

    @Test("file URI redaction preserves words ending in file")
    func fileURIBoundaries() {
        let diagnostic = "profile: microphone; file: unavailable; sample_rate=48000"
        #expect(TelemetryErrorClassifier.sanitize(diagnostic) == diagnostic)
        #expect(TelemetryErrorClassifier.sanitize("open file:/private/audio.wav") == "open <path>")
    }

    @Test("redacts quoted credential values without leaking their suffix")
    func quotedCredentials() {
        for message in [
            "api_key: \"private-key-value\"",
            "Authorization: 'Basic private credential value'",
            "access_token=\"private-token-value\"; status=401",
            #"token="abc\"private-suffix""#,
            #"api_key='abc\'private-suffix'"#,
            "token=\"unterminated private suffix\nstatus=401",
            "token=\"private suffix\\",
        ] {
            let sanitized = TelemetryErrorClassifier.sanitize(message)
            #expect(!sanitized.contains("private"))
            #expect(!sanitized.contains("credential value"))
            #expect(TelemetryErrorClassifier.sanitize(sanitized) == sanitized)
        }
    }
}
