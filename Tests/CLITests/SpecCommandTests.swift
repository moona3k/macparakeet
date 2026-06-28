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
        XCTAssertTrue(paths.contains(["meetings", "artifact"]))
        XCTAssertTrue(paths.contains(["config", "set"]))
        XCTAssertTrue(paths.contains(["models", "delete"]))
        XCTAssertTrue(paths.contains(["spec"]))

        let writeback = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "results", "add"] })
        XCTAssertEqual(writeback["readOnly"] as? Bool, false)
        XCTAssertEqual(writeback["jsonMode"] as? String, "--json")

        let artifact = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "artifact"] })
        XCTAssertEqual(artifact["readOnly"] as? Bool, false)
        let artifactOptions = try XCTUnwrap(artifact["options"] as? [[String: Any]])
        XCTAssertTrue(artifactOptions.contains { ($0["name"] as? String) == "--envelope" })

        XCTAssertTrue(paths.contains(["meetings", "notes", "get"]))
        XCTAssertTrue(paths.contains(["meetings", "notes", "set"]))
        XCTAssertTrue(paths.contains(["meetings", "notes", "append"]))
        XCTAssertTrue(paths.contains(["meetings", "notes", "clear"]))

        for path in [
            ["meetings", "notes", "get"],
            ["meetings", "notes", "set"],
            ["meetings", "notes", "clear"],
        ] {
            let command = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == path })
            let options = try XCTUnwrap(command["options"] as? [[String: Any]])
            XCTAssertTrue(options.contains { ($0["name"] as? String) == "--envelope" })
        }
    }

    func testSpecJSONDocumentsCLIJSONConventions() throws {
        let payload = try specPayload()
        let conventions = try XCTUnwrap(payload["conventions"] as? [String: Any])

        XCTAssertEqual(conventions["jsonDateFormat"] as? String, "iso8601")
        XCTAssertEqual(conventions["stdout"] as? String, "Machine-readable payloads are written to stdout.")
        XCTAssertEqual(conventions["stderr"] as? String, "Human progress/status messages are written to stderr.")

        let failureEnvelope = try XCTUnwrap(conventions["failureEnvelope"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(failureEnvelope["fields"] as? [String])), [
            "ok",
            "error",
            "errorType",
            "fix",
            "meta",
        ])
        XCTAssertEqual(failureEnvelope["okValueOnFailure"] as? Bool, false)
        XCTAssertEqual(failureEnvelope["appliesAfterArgumentParsing"] as? Bool, true)
    }

    func testSpecJSONDocumentsPublicExitCodes() throws {
        let payload = try specPayload()
        let conventions = try XCTUnwrap(payload["conventions"] as? [String: Any])
        let exitCodes = try XCTUnwrap(conventions["exitCodes"] as? [[String: Any]])
        let meaningsByCode = Dictionary(uniqueKeysWithValues: exitCodes.compactMap { entry -> (Int, String)? in
            guard let code = entry["code"] as? Int,
                  let meaning = entry["meaning"] as? String else {
                return nil
            }
            return (code, meaning)
        })

        XCTAssertEqual(Set(meaningsByCode.keys), [0, 1, 2, 130])
        XCTAssertEqual(meaningsByCode[0], "success")
        XCTAssertEqual(meaningsByCode[1], "runtime failure after work was attempted")
        XCTAssertEqual(meaningsByCode[2], "validation or invocation misuse")
        XCTAssertEqual(meaningsByCode[130], "interrupted by SIGINT")
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
            [
                "calendar",
                "config",
                "export",
                "health",
                "history",
                "llm",
                "meetings",
                "models",
                "prompts",
                "quick-prompts",
                "spec",
                "stats",
                "transcribe",
                "transforms",
                "vocab",
            ],
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

    /// Every documented spec path must resolve in the real ArgumentParser tree.
    /// The catalog in `SpecCommand` is hand-maintained and duplicates the command
    /// tree, so a renamed or removed subcommand could otherwise keep being
    /// advertised to agents while no longer existing. Resolving each path with
    /// `--help` short-circuits before any work runs: a known path throws a help
    /// request (exit `0`); an unknown subcommand throws a parse error (exit `2`).
    func testEveryDocumentedSpecPathResolvesInTheCommandTree() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let paths = try commands.map { try XCTUnwrap($0["path"] as? [String]) }
        XCTAssertFalse(paths.isEmpty, "spec catalog should document at least one command")

        for path in paths {
            do {
                _ = try CLI.parseAsRoot(path + ["--help"])
                // Parsed without throwing: the path resolved and had no required
                // arguments to complain about. Still a valid resolution.
            } catch {
                XCTAssertTrue(
                    CLI.exitCode(for: error).isSuccess,
                    """
                    Spec catalog documents '\(path.joined(separator: " "))' but it \
                    does not resolve in the real command tree: \
                    \(CLI.fullMessage(for: error))
                    """
                )
            }
        }
    }

    func testSpecCatalogDocumentsAgentAutomationFamilies() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let paths = try commands.map { command in
            try XCTUnwrap(command["path"] as? [String])
        }

        for path in [
            ["llm", "test-connection"],
            ["llm", "summarize"],
            ["quick-prompts", "list"],
            ["quick-prompts", "import"],
            ["transforms", "run"],
            ["transforms", "restore-defaults"],
            ["transforms", "history", "clear"],
            ["vocab", "process"],
            ["vocab", "words", "add"],
            ["vocab", "words", "set"],
            ["vocab", "snippets", "edit"],
            ["vocab", "import"],
            ["history", "favorite"],
            ["history", "delete-meeting-audio"],
            ["stats"],
            ["export"],
            ["calendar", "upcoming"],
        ] {
            XCTAssertTrue(paths.contains(path), "\(path.joined(separator: " ")) missing from spec catalog")
        }

        let promptsSet = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["prompts", "set"] })
        XCTAssertEqual(promptsSet["jsonMode"] as? String, "--json")
        let promptSetOptions = try XCTUnwrap(promptsSet["options"] as? [[String: Any]])
        XCTAssertTrue(promptSetOptions.contains { ($0["name"] as? String) == "--source" })

        for path in [
            ["prompts", "run"],
            ["llm", "summarize"],
            ["transforms", "run"],
        ] {
            let command = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == path })
            let options = try XCTUnwrap(command["options"] as? [[String: Any]])
            XCTAssertTrue(options.contains { ($0["name"] as? String) == "--provider" })
            XCTAssertTrue(options.contains { ($0["name"] as? String) == "--api-key-env" })
            XCTAssertTrue(options.contains { ($0["name"] as? String) == "--base-url" })
        }
    }

    func testSpecDocumentsPromptListFilterAndMeetingsListLimit() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])

        let promptsList = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["prompts", "list"] })
        let promptListOptions = try XCTUnwrap(promptsList["options"] as? [[String: Any]])
        let filter = try XCTUnwrap(promptListOptions.first { ($0["name"] as? String) == "--filter" })
        XCTAssertEqual(filter["valueName"] as? String, "all|visible|auto-run")

        let meetingsList = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "list"] })
        let meetingsListOptions = try XCTUnwrap(meetingsList["options"] as? [[String: Any]])
        let limit = try XCTUnwrap(meetingsListOptions.first { ($0["name"] as? String) == "--limit" })
        XCTAssertEqual(limit["valueName"] as? String, "N")
    }

    func testSpecDocumentsAllConfigKeys() throws {
        let payload = try specPayload()
        let configKeys = try XCTUnwrap(payload["configKeys"] as? [[String: Any]])
        let keys = configKeys.compactMap { $0["key"] as? String }
        XCTAssertEqual(keys, ConfigCommand.supportedKeys)

        let speechEngine = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "speech-engine" })
        XCTAssertEqual(
            speechEngine["allowedValues"] as? [String],
            ["parakeet", "nemotron", "whisper", "cohere"]
        )

        let cohereLanguage = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "cohere-language" })
        let cohereValues = try XCTUnwrap(cohereLanguage["allowedValues"] as? [String])
        XCTAssertTrue(cohereValues.contains("en"))
        XCTAssertTrue(cohereValues.contains("ja"))

        let nemotronLanguage = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "nemotron-language" })
        XCTAssertNil(nemotronLanguage["allowedValues"] as? [String])

        let whisperLanguage = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "whisper-language" })
        XCTAssertNil(whisperLanguage["allowedValues"] as? [String])

        let meetingAudioRetention = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "meeting-audio-retention" })
        XCTAssertNil(meetingAudioRetention["allowedValues"] as? [String])

        let voiceReturnTriggers = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "voice-return-triggers" })
        XCTAssertEqual(voiceReturnTriggers["valueSyntax"] as? String, "phrase[|phrase...]")
        XCTAssertNil(voiceReturnTriggers["allowedValues"] as? [String])

        let bluetoothMicPreference = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "prefer-built-in-mic-bluetooth-output" })
        XCTAssertEqual(bluetoothMicPreference["allowedValues"] as? [String], ["on", "off"])

        let timeout = try XCTUnwrap(configKeys.first { ($0["key"] as? String) == "meeting-hook-timeout" })
        XCTAssertEqual(timeout["valueSyntax"] as? String, "seconds 1-300")
    }

    func testTranscribeSpecDocumentsCurrentTranscribeSurface() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let transcribe = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["transcribe"] })

        XCTAssertEqual(
            transcribe["summary"] as? String,
            "Transcribe audio/video files, folders, Apple Podcasts links/searches, or media URLs."
        )
        XCTAssertEqual(transcribe["readOnly"] as? Bool, false)

        let arguments = try XCTUnwrap(transcribe["arguments"] as? [[String: Any]])
        XCTAssertEqual(arguments.first?["name"] as? String, "input...")
        XCTAssertEqual(arguments.first?["required"] as? Bool, false)
        XCTAssertTrue(
            (arguments.first?["summary"] as? String)?.contains("Apple Podcasts links") == true
        )
        XCTAssertTrue(
            (arguments.first?["summary"] as? String)?.contains("HTTP(S) media URLs") == true
        )

        let options = try XCTUnwrap(transcribe["options"] as? [[String: Any]])
        let optionNames = Set(options.compactMap { $0["name"] as? String })
        XCTAssertTrue(optionNames.contains("--podcast"))
        XCTAssertTrue(optionNames.contains("--output-dir"))
        XCTAssertTrue(optionNames.contains("--format"))
        XCTAssertTrue(optionNames.contains("--mode"))
        XCTAssertTrue(optionNames.contains("--parakeet-model"))
        XCTAssertTrue(optionNames.contains("--nemotron-model"))
        XCTAssertTrue(optionNames.contains("--downloaded-audio"))
        XCTAssertTrue(optionNames.contains("--speaker-count"))
        XCTAssertTrue(optionNames.contains("--speaker-min"))
        XCTAssertTrue(optionNames.contains("--speaker-max"))
        XCTAssertTrue(optionNames.contains("--media-audio-quality"))
        XCTAssertTrue(optionNames.contains("--database"))

        let engine = try XCTUnwrap(options.first { ($0["name"] as? String) == "--engine" })
        XCTAssertEqual(engine["valueName"] as? String, "parakeet|nemotron|whisper|cohere|app-default")
        let format = try XCTUnwrap(options.first { ($0["name"] as? String) == "--format" })
        XCTAssertEqual(format["valueName"] as? String, "text|transcript|json|srt|vtt")
        let parakeetModel = try XCTUnwrap(options.first { ($0["name"] as? String) == "--parakeet-model" })
        XCTAssertEqual(
            parakeetModel["summary"] as? String,
            "Parakeet build for this run; ignored for Nemotron, Cohere, and Whisper."
        )
        let nemotronModel = try XCTUnwrap(options.first { ($0["name"] as? String) == "--nemotron-model" })
        XCTAssertEqual(nemotronModel["valueName"] as? String, "app-default|multilingual-1120ms|english-1120ms")
        XCTAssertEqual(
            nemotronModel["summary"] as? String,
            "Nemotron build for this run; ignored for Parakeet, Cohere, and Whisper."
        )
        let language = try XCTUnwrap(options.first { ($0["name"] as? String) == "--language" })
        XCTAssertEqual(
            language["summary"] as? String,
            "Language hint for Nemotron, Whisper, or Cohere; the English-only Nemotron build ignores it."
        )
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

        let health = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["health"] })
        XCTAssertEqual(health["readOnly"] as? Bool, false)
        let healthOptions = try XCTUnwrap(health["options"] as? [[String: Any]])
        XCTAssertTrue(healthOptions.contains { ($0["name"] as? String) == "--repair-attempts" })
    }

    func testSpecDocumentsMeetingNotesAndExportSurface() throws {
        let payload = try specPayload()
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])

        let notesSet = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "notes", "set"] })
        XCTAssertEqual(notesSet["readOnly"] as? Bool, false)
        let notesSetOptions = try XCTUnwrap(notesSet["options"] as? [[String: Any]])
        XCTAssertTrue(notesSetOptions.contains { ($0["name"] as? String) == "--text" })
        XCTAssertTrue(notesSetOptions.contains { ($0["name"] as? String) == "--stdin" })

        let export = try XCTUnwrap(commands.first { ($0["path"] as? [String]) == ["meetings", "export"] })
        XCTAssertEqual(export["readOnly"] as? Bool, false)
        XCTAssertEqual(export["jsonMode"] as? String, "--format json")
        let exportOptions = try XCTUnwrap(export["options"] as? [[String: Any]])
        XCTAssertTrue(exportOptions.contains { ($0["name"] as? String) == "--output" })
        XCTAssertTrue(exportOptions.contains { ($0["name"] as? String) == "--stdout" })
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
