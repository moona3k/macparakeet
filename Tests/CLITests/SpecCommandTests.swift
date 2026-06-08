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
        let payload = try specPayload()
        XCTAssertEqual(payload["schema"] as? String, "macparakeet.cli.spec")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["cliVersion"] as? String, CLI.cliVersion)

        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let paths = commands.compactMap { $0["path"] as? [String] }
        XCTAssertTrue(paths.contains(["meetings", "results", "add"]))
        XCTAssertTrue(paths.contains(["config", "set"]))
        XCTAssertTrue(paths.contains(["models", "delete"]))
        XCTAssertTrue(paths.contains(["spec"]))

        let writeback = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "results", "add"] })
        XCTAssertEqual(writeback["readOnly"] as? Bool, false)
        XCTAssertEqual(writeback["jsonMode"] as? String, "--json")
    }

    func testSpecCatalogDocumentsRegisteredAgentFacingRoots() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let paths = try commands.map { command in
            try XCTUnwrap(command["path"] as? [String])
        }
        let registeredTopLevelCommands = Set(CLI.configuration.subcommands.compactMap {
            $0.configuration.commandName
        })
        let documentedTopLevelCommands = Set(paths.compactMap(\.first))

        XCTAssertEqual(
            documentedTopLevelCommands,
            ["spec", "health", "transcribe", "config", "models", "history", "prompts", "meetings"],
            "The spec catalog is a curated agent-facing surface; update this expectation when that surface changes."
        )
        for path in paths {
            let topLevel = try XCTUnwrap(path.first)
            XCTAssertTrue(
                registeredTopLevelCommands.contains(topLevel),
                "\(path.joined(separator: " ")) documents a top-level command that is not registered."
            )
        }
    }

    func testTranscribeSpecDocumentsMediaURLAndSpeakerOptions() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let transcribe = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["transcribe"] })

        XCTAssertEqual(
            transcribe["summary"] as? String,
            "Transcribe an audio/video file, folder, or media URL."
        )

        let arguments = try XCTUnwrap(transcribe["arguments"] as? [[String: Any]])
        XCTAssertTrue(
            (arguments.first?["summary"] as? String)?.contains("HTTP(S) media URL") == true
        )

        let options = try XCTUnwrap(transcribe["options"] as? [[String: Any]])
        let optionNames = Set(options.compactMap { $0["name"] as? String })
        XCTAssertTrue(optionNames.contains("--speaker-count"))
        XCTAssertTrue(optionNames.contains("--speaker-min"))
        XCTAssertTrue(optionNames.contains("--speaker-max"))
        XCTAssertTrue(optionNames.contains("--media-audio-quality"))

        let engine = try XCTUnwrap(options.first { ($0["name"] as? String) == "--engine" })
        XCTAssertEqual(engine["valueName"] as? String, "parakeet|nemotron|whisper|app-default")
        let language = try XCTUnwrap(options.first { ($0["name"] as? String) == "--language" })
        XCTAssertEqual(language["summary"] as? String, "Language hint for Nemotron or Whisper.")
    }

    func testSpecDocumentsConfigAndModelsCommands() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])

        let configSet = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["config", "set"] })
        XCTAssertEqual(configSet["readOnly"] as? Bool, false)

        let modelsDelete = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["models", "delete"] })
        XCTAssertEqual(modelsDelete["readOnly"] as? Bool, false)
        let options = try XCTUnwrap(modelsDelete["options"] as? [[String: Any]])
        XCTAssertTrue(options.contains { ($0["name"] as? String) == "--force" })
    }

    private func specPayload() throws -> [String: Any] {
        let command = try SpecCommand.parse(["--json"])
        let output = try captureStandardOutput {
            try command.run()
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
    }
}
