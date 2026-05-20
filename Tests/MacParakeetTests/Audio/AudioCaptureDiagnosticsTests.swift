import CoreAudio
import XCTest
@testable import MacParakeetCore

final class AudioCaptureDiagnosticsTests: XCTestCase {
    func testAppendUsesTemporaryLogUnderXCTest() throws {
        let logURL = AudioCaptureDiagnostics.diagnosticLogURL()
        let marker = "unit_test_diagnostic_marker_\(UUID().uuidString)"

        AudioCaptureDiagnostics.append(marker)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logURL.path.contains("MacParakeetTests/Logs"))
        XCTAssertFalse(logURL.path.hasPrefix(AppPaths.logsDir))
        XCTAssertTrue(contents.contains(marker))
    }

    func testDeviceLabelDoesNotExposeRawDeviceID() {
        let label = AudioCaptureDiagnostics.deviceLabel(AudioDeviceID(12345))

        XCTAssertEqual(label, "present")
        XCTAssertFalse(label.contains("12345"))
    }

    func testDiagnosticMessageSanitizerStripsPathsAndURLs() {
        let message = #"failed path=/Users/alex/Secret/file.wav url=https://example.com/watch?v=abc"#

        let sanitized = AudioCaptureDiagnostics.sanitizedMessage(message)

        XCTAssertFalse(sanitized.contains("/Users/alex"))
        XCTAssertFalse(sanitized.contains("https://example.com"))
        XCTAssertTrue(sanitized.contains("<path>"))
        XCTAssertTrue(sanitized.contains("<url>"))
    }

    func testDiagnosticMessageSanitizerKeepsSingleLogLine() {
        let message = "first line\nsecond line\r\nthird line"

        let sanitized = AudioCaptureDiagnostics.sanitizedMessage(message)

        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertEqual(sanitized, "first line second line third line")
    }
}
