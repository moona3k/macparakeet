import XCTest
@testable import CLI

final class SpecCommandTests: XCTestCase {
    func testSpecCommandIsRegisteredAtTopLevel() {
        XCTAssertTrue(
            CLI.configuration.subcommands.contains { $0 == SpecCommand.self },
            "spec must be available from macparakeet-cli"
        )
    }

    func testSpecJSONIncludesAgentFacingMeetingResultsCommand() throws {
        let command = try SpecCommand.parse(["--json"])
        let output = try captureStandardOutput {
            try command.run()
        }
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["schema"] as? String, "macparakeet.cli.spec")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["cliVersion"] as? String, CLI.cliVersion)

        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let paths = commands.compactMap { $0["path"] as? [String] }
        XCTAssertTrue(paths.contains(["meetings", "results", "add"]))
        XCTAssertTrue(paths.contains(["spec"]))

        let writeback = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "results", "add"] })
        XCTAssertEqual(writeback["readOnly"] as? Bool, false)
        XCTAssertEqual(writeback["jsonMode"] as? String, "--json")
    }
}
