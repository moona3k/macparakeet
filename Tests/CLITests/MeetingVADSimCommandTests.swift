import Foundation
import XCTest
@testable import CLI

final class MeetingVADSimCommandTests: XCTestCase {
    func testJSONModeEmitsFailureEnvelopeForMissingAudioFile() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-missing-vad-\(UUID().uuidString).wav")
        let command = try MeetingVADSimCommand.parse([
            missingURL.path,
            "--json",
        ])

        var thrownError: Error?
        let output = try await captureStandardOutput {
            do {
                try await command.run()
            } catch {
                thrownError = error
            }
        }

        let error = try XCTUnwrap(thrownError)
        XCTAssertTrue(error is CLIJSONEnvelopeExit)
        XCTAssertEqual(CLI.normalizedExitCode(for: error), .failure)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "runtime")
        XCTAssertTrue((object["error"] as? String)?.contains("Cannot open audio file") == true)
    }
}
