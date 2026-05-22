import ArgumentParser
import Foundation

struct SpecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec",
        abstract: "Print the machine-readable CLI contract for agents and scripts."
    )

    @Flag(name: .long, help: "Emit the machine-readable JSON spec.")
    var json: Bool = false

    func run() throws {
        let spec = CLISpec.current
        if json {
            try printJSON(spec)
            return
        }

        print("\(spec.commandName) \(spec.cliVersion)")
        print("Schema: \(spec.schema) v\(spec.schemaVersion)")
        print()
        for command in spec.commands {
            let mode = command.readOnly ? "read" : "write"
            print("\(command.path.joined(separator: " "))  [\(mode)]")
            print("  \(command.summary)")
        }
    }
}

private struct CLISpec: Encodable {
    let schema: String
    let schemaVersion: Int
    let commandName: String
    let cliVersion: String
    let conventions: CLISpecConventions
    let commands: [CLISpecCommand]

    static var current: CLISpec {
        CLISpec(
            schema: "macparakeet.cli.spec",
            schemaVersion: 1,
            commandName: "macparakeet-cli",
            cliVersion: CLI.cliVersion,
            conventions: CLISpecConventions(
                jsonDateFormat: "iso8601",
                idLookup: "Full UUID, UUID prefix of at least 4 hex characters, or exact title/name where documented.",
                stdout: "Machine-readable payloads are written to stdout.",
                stderr: "Human progress/status messages are written to stderr.",
                failureEnvelope: CLIErrorEnvelopeSpec(
                    fields: ["ok", "error", "errorType"],
                    okValueOnFailure: false,
                    appliesAfterArgumentParsing: true
                ),
                exitCodes: [
                    CLIExitCodeSpec(code: 0, meaning: "success"),
                    CLIExitCodeSpec(code: 1, meaning: "runtime failure after work was attempted"),
                    CLIExitCodeSpec(code: 2, meaning: "validation or invocation misuse"),
                    CLIExitCodeSpec(code: 130, meaning: "interrupted by SIGINT"),
                ]
            ),
            commands: CLISpecCommand.catalog
        )
    }
}

private struct CLISpecConventions: Encodable {
    let jsonDateFormat: String
    let idLookup: String
    let stdout: String
    let stderr: String
    let failureEnvelope: CLIErrorEnvelopeSpec
    let exitCodes: [CLIExitCodeSpec]
}

private struct CLIErrorEnvelopeSpec: Encodable {
    let fields: [String]
    let okValueOnFailure: Bool
    let appliesAfterArgumentParsing: Bool
}

private struct CLIExitCodeSpec: Encodable {
    let code: Int
    let meaning: String
}

private struct CLISpecCommand: Encodable {
    let path: [String]
    let summary: String
    let readOnly: Bool
    let jsonMode: String
    let arguments: [CLISpecParameter]
    let options: [CLISpecParameter]
    let output: String

    init(
        _ path: [String],
        summary: String,
        readOnly: Bool = true,
        jsonMode: String = "--json",
        arguments: [CLISpecParameter] = [],
        options: [CLISpecParameter] = [],
        output: String
    ) {
        self.path = path
        self.summary = summary
        self.readOnly = readOnly
        self.jsonMode = jsonMode
        self.arguments = arguments
        self.options = options
        self.output = output
    }
}

private struct CLISpecParameter: Encodable {
    let name: String
    let valueName: String?
    let required: Bool
    let summary: String

    static func argument(_ name: String, summary: String) -> CLISpecParameter {
        CLISpecParameter(name: name, valueName: nil, required: true, summary: summary)
    }

    static func option(
        _ name: String,
        valueName: String,
        required: Bool = false,
        summary: String
    ) -> CLISpecParameter {
        CLISpecParameter(name: name, valueName: valueName, required: required, summary: summary)
    }

    static func flag(_ name: String, summary: String) -> CLISpecParameter {
        CLISpecParameter(name: name, valueName: nil, required: false, summary: summary)
    }
}

private extension CLISpecCommand {
    static let databaseOption = CLISpecParameter.option(
        "--database",
        valueName: "PATH",
        summary: "Use a specific MacParakeet SQLite database instead of the app default."
    )

    static let catalog: [CLISpecCommand] = [
        CLISpecCommand(
            ["spec"],
            summary: "Print this machine-readable CLI contract.",
            output: "CLISpec object."
        ),
        CLISpecCommand(
            ["health"],
            summary: "Check database, speech stack, helper binaries, and local runtime readiness.",
            options: [
                CLISpecParameter.flag("--repair-models", summary: "Attempt to prepare local speech models."),
                CLISpecParameter.flag("--repair-binaries", summary: "Install or update helper binaries such as yt-dlp."),
            ],
            output: "HealthReport object."
        ),
        CLISpecCommand(
            ["transcribe"],
            summary: "Transcribe an audio, video, or YouTube input.",
            jsonMode: "--format json",
            arguments: [.argument("input", summary: "Path or supported URL.")],
            options: [
                CLISpecParameter.option("--engine", valueName: "parakeet|whisper|app-default", summary: "Speech engine for this run."),
                CLISpecParameter.option("--language", valueName: "CODE", summary: "Language hint for Whisper."),
                CLISpecParameter.flag("--no-history", summary: "Do not persist the completed transcription."),
            ],
            output: "Transcription result object."
        ),
        CLISpecCommand(
            ["history", "transcriptions"],
            summary: "List saved file, URL, and meeting transcriptions.",
            options: [databaseOption],
            output: "Array of saved transcription objects."
        ),
        CLISpecCommand(
            ["history", "search-transcriptions"],
            summary: "Search saved transcriptions by title and transcript text.",
            arguments: [.argument("query", summary: "Search query.")],
            options: [databaseOption],
            output: "Array of matching transcription objects."
        ),
        CLISpecCommand(
            ["prompts", "list"],
            summary: "List result prompts in the prompt library.",
            options: [databaseOption],
            output: "Array of Prompt objects."
        ),
        CLISpecCommand(
            ["prompts", "run"],
            summary: "Run a saved result prompt against a saved transcription.",
            readOnly: false,
            arguments: [.argument("prompt", summary: "Prompt ID, UUID prefix, or exact name.")],
            options: [
                CLISpecParameter.option("--transcription", valueName: "ID", required: true, summary: "Saved transcription ID or prefix."),
                CLISpecParameter.flag("--no-store", summary: "Do not save a PromptResult."),
                databaseOption,
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["meetings", "list"],
            summary: "List recent meeting recordings.",
            options: [databaseOption],
            output: "Array of meeting list objects."
        ),
        CLISpecCommand(
            ["meetings", "show"],
            summary: "Show one meeting artifact.",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [databaseOption],
            output: "MeetingRecord object."
        ),
        CLISpecCommand(
            ["meetings", "transcript"],
            summary: "Print a meeting transcript.",
            jsonMode: "--format json",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--format", valueName: "text|json|srt|vtt", summary: "Transcript output format."),
                databaseOption,
            ],
            output: "MeetingTranscriptRecord object for --format json."
        ),
        CLISpecCommand(
            ["meetings", "notes", "append"],
            summary: "Append user-authored notes to a meeting.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--text", valueName: "TEXT", summary: "Notes text to append."),
                CLISpecParameter.flag("--stdin", summary: "Read notes text from stdin."),
                databaseOption,
            ],
            output: "MeetingNotesRecord object."
        ),
        CLISpecCommand(
            ["meetings", "results", "list"],
            summary: "List saved PromptResults for a meeting.",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [databaseOption],
            output: "Array of MeetingPromptResultRecord objects."
        ),
        CLISpecCommand(
            ["meetings", "results", "add"],
            summary: "Store externally generated output as a PromptResult for a meeting.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--name", valueName: "NAME", required: true, summary: "Display name for the saved result."),
                CLISpecParameter.option("--content", valueName: "TEXT", summary: "Generated result content to store."),
                CLISpecParameter.flag("--stdin", summary: "Read generated result content from stdin."),
                CLISpecParameter.option("--prompt-content", valueName: "TEXT", summary: "Optional prompt/instructions that produced the result."),
                CLISpecParameter.option("--extra", valueName: "TEXT", summary: "Optional extra instructions or provenance."),
                databaseOption,
            ],
            output: "MeetingPromptResultRecord object."
        ),
        CLISpecCommand(
            ["meetings", "export"],
            summary: "Export a deterministic local meeting artifact.",
            readOnly: true,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--format", valueName: "md|json", summary: "Export format."),
                CLISpecParameter.flag("--stdout", summary: "Print export content to stdout."),
                databaseOption,
            ],
            output: "Markdown text or MeetingRecord JSON."
        ),
    ]
}
