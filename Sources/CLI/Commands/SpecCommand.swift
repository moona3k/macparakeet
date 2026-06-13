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
                    fields: ["ok", "error", "errorType", "fix", "meta"],
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

    static func argument(
        _ name: String,
        required: Bool = true,
        summary: String
    ) -> CLISpecParameter {
        CLISpecParameter(name: name, valueName: nil, required: required, summary: summary)
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
            summary: "Check database, speech stack, helper binaries, and local runtime readiness; repair flags mutate local caches.",
            readOnly: false,
            options: [
                CLISpecParameter.flag("--repair-models", summary: "Mutating: attempt to prepare local speech models."),
                CLISpecParameter.option("--repair-attempts", valueName: "N", summary: "Maximum repair attempts when --repair-models is set."),
                CLISpecParameter.flag("--repair-binaries", summary: "Mutating: install or update helper binaries such as yt-dlp."),
            ],
            output: "HealthReport object."
        ),
        CLISpecCommand(
            ["transcribe"],
            summary: "Transcribe audio/video files, folders, Apple Podcasts links/searches, or media URLs.",
            readOnly: false,
            jsonMode: "--format json",
            arguments: [
                .argument(
                    "input...",
                    required: false,
                    summary: "Zero or more file paths, folders, Apple Podcasts links, or HTTP(S) media URLs supported by yt-dlp. Omit when using --podcast."
                ),
            ],
            options: [
                CLISpecParameter.option("--podcast", valueName: "QUERY", summary: "Search Apple Podcasts by show/episode text and transcribe the selected episode."),
                CLISpecParameter.option("--output-dir", valueName: "DIR", summary: "Write one transcript file per input to this directory; implies batch mode."),
                CLISpecParameter.option("--format", valueName: "text|transcript|json", summary: "Output format for stdout or written transcript files."),
                CLISpecParameter.option("--mode", valueName: "raw|clean|app-default", summary: "Text processing mode for this run."),
                CLISpecParameter.option("--engine", valueName: "parakeet|nemotron|whisper|app-default", summary: "Speech engine for this run."),
                CLISpecParameter.option("--language", valueName: "CODE", summary: "Language hint for Nemotron or Whisper."),
                CLISpecParameter.option("--parakeet-model", valueName: "app-default|v3|v2", summary: "Parakeet build for this run; ignored for Nemotron and Whisper."),
                CLISpecParameter.option("--downloaded-audio", valueName: "app-default|keep|delete", summary: "Downloaded media retention policy."),
                CLISpecParameter.option("--speaker-detection", valueName: "app-default|on|off", summary: "Speaker detection behavior for this run."),
                CLISpecParameter.option("--speaker-count", valueName: "N", summary: "Exact known speaker count; implies speaker detection unless explicitly disabled."),
                CLISpecParameter.option("--speaker-min", valueName: "N", summary: "Minimum speaker count bound for diarization."),
                CLISpecParameter.option("--speaker-max", valueName: "N", summary: "Maximum speaker count bound for diarization."),
                CLISpecParameter.option("--media-audio-quality", valueName: "app-default|m4a|best-available", summary: "Downloaded media audio quality."),
                CLISpecParameter.flag("--no-history", summary: "Do not persist the completed transcription."),
                databaseOption,
            ],
            output: "Single Transcription object for stdout mode; one transcript file per input in batch/output-dir mode."
        ),
        CLISpecCommand(
            ["config", "list"],
            summary: "List shared app/CLI configuration values.",
            output: "Dictionary of canonical configuration keys to values."
        ),
        CLISpecCommand(
            ["config", "get"],
            summary: "Read one shared app/CLI configuration value.",
            arguments: [.argument("key", summary: "Configuration key, such as speech-engine, meeting-artifacts-folder, meeting-hook-enabled, meeting-hook-path, or meeting-hook-timeout.")],
            output: "Configuration value."
        ),
        CLISpecCommand(
            ["config", "set"],
            summary: "Write one shared app/CLI configuration value.",
            readOnly: false,
            arguments: [
                .argument("key", summary: "Configuration key."),
                .argument("value", summary: "Configuration value."),
            ],
            output: "Written canonical configuration value."
        ),
        CLISpecCommand(
            ["models", "list"],
            summary: "List selectable local speech models.",
            output: "Array of selectable speech model objects."
        ),
        CLISpecCommand(
            ["models", "select"],
            summary: "Set the shared app/CLI default speech model.",
            readOnly: false,
            arguments: [.argument("model-id", summary: "Model ID from models list.")],
            output: "Selected speech model object."
        ),
        CLISpecCommand(
            ["models", "status"],
            summary: "Show local speech and speaker model status without forcing downloads.",
            output: "SpeechStackPayload object."
        ),
        CLISpecCommand(
            ["models", "download"],
            summary: "Download a local speech model without selecting it.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("model-id", summary: "Model ID from models list.")],
            output: "Human-readable progress and completion lines."
        ),
        CLISpecCommand(
            ["models", "delete"],
            summary: "Delete one downloaded speech model.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("model-id", summary: "Model ID from models list.")],
            options: [CLISpecParameter.flag("--force", summary: "Delete even when the model is currently in use.")],
            output: "Human-readable deletion confirmation or no-op line."
        ),
        CLISpecCommand(
            ["models", "warm-up"],
            summary: "Warm up the selected local speech stack.",
            readOnly: false,
            jsonMode: "none",
            options: [CLISpecParameter.option("--attempts", valueName: "N", summary: "Maximum attempts.")],
            output: "Human-readable warm-up progress."
        ),
        CLISpecCommand(
            ["models", "repair"],
            summary: "Best-effort retry for the selected local speech stack.",
            readOnly: false,
            jsonMode: "none",
            options: [CLISpecParameter.option("--attempts", valueName: "N", summary: "Maximum attempts.")],
            output: "Human-readable repair progress."
        ),
        CLISpecCommand(
            ["models", "clear"],
            summary: "Delete cached speech and speaker models.",
            readOnly: false,
            jsonMode: "none",
            output: "Human-readable cache clear confirmation."
        ),
        CLISpecCommand(
            ["history", "dictations"],
            summary: "List saved dictations.",
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of dictations."),
                databaseOption,
            ],
            output: "Array of saved dictation objects."
        ),
        CLISpecCommand(
            ["history", "search"],
            summary: "Search saved dictations by transcript text.",
            arguments: [.argument("query", summary: "Search query.")],
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of matches."),
                databaseOption,
            ],
            output: "Array of matching dictation objects."
        ),
        CLISpecCommand(
            ["history", "transcriptions"],
            summary: "List saved file, URL, and meeting transcriptions.",
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of transcriptions."),
                databaseOption,
            ],
            output: "Array of saved transcription objects."
        ),
        CLISpecCommand(
            ["history", "search-transcriptions"],
            summary: "Search saved transcriptions by title and transcript text.",
            arguments: [.argument("query", summary: "Search query.")],
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of matches."),
                databaseOption,
            ],
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
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "Array of meeting list objects with transcript, notes, and prompt-result availability."
        ),
        CLISpecCommand(
            ["meetings", "show"],
            summary: "Show one meeting artifact.",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingRecord object with transcript, notes, and prompt-result count."
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
            ["meetings", "notes", "get"],
            summary: "Read user-authored notes from a meeting.",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingNotesRecord object."
        ),
        CLISpecCommand(
            ["meetings", "notes", "set"],
            summary: "Replace user-authored notes for a meeting.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--text", valueName: "TEXT", summary: "Notes text to store."),
                CLISpecParameter.flag("--stdin", summary: "Read notes text from stdin."),
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingNotesRecord object."
        ),
        CLISpecCommand(
            ["meetings", "notes", "append"],
            summary: "Append user-authored notes to a meeting.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--text", valueName: "TEXT", summary: "Notes text to append."),
                CLISpecParameter.flag("--stdin", summary: "Read notes text from stdin."),
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingNotesRecord object."
        ),
        CLISpecCommand(
            ["meetings", "notes", "clear"],
            summary: "Clear user-authored notes from a meeting.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingNotesRecord object."
        ),
        CLISpecCommand(
            ["meetings", "results", "list"],
            summary: "List saved PromptResults for a meeting.",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
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
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingPromptResultRecord object."
        ),
        CLISpecCommand(
            ["meetings", "artifact"],
            summary: "Materialize and inspect the first-class meeting session artifact folder.",
            readOnly: false,
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.flag("--envelope", summary: "Wrap JSON output in an ok/data/meta success envelope."),
                databaseOption,
            ],
            output: "MeetingArtifactSnapshot object."
        ),
        CLISpecCommand(
            ["meetings", "export"],
            summary: "Export a deterministic local meeting artifact.",
            readOnly: false,
            jsonMode: "--format json",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--format", valueName: "md|json", summary: "Export format."),
                CLISpecParameter.option("--output", valueName: "PATH", summary: "Output file path; defaults to an auto-generated file."),
                CLISpecParameter.flag("--stdout", summary: "Print export content to stdout."),
                databaseOption,
            ],
            output: "Markdown text or MeetingRecord JSON with prompt-result count."
        ),
    ]
}
