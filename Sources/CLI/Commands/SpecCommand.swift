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
    let configKeys: [CLIConfigKeySpec]
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
            configKeys: ConfigCommand.supportedKeySpecs,
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

    static let llmInlineOptions: [CLISpecParameter] = [
        CLISpecParameter.option("--provider", valueName: "ID", required: true, summary: "LLM provider: anthropic, openai, openaiCompatible, gemini, openrouter, ollama, lmstudio, or cli."),
        CLISpecParameter.option("--api-key", valueName: "KEY", summary: "API key literal; prefer --api-key-env for scripts."),
        CLISpecParameter.option("--api-key-env", valueName: "ENV", summary: "Environment variable containing the API key."),
        CLISpecParameter.option("--model", valueName: "MODEL", summary: "Provider model name."),
        CLISpecParameter.option("--base-url", valueName: "URL", summary: "Provider base URL override."),
        CLISpecParameter.flag("--allow-insecure-http", summary: "Allow non-loopback http:// base URLs intentionally."),
        CLISpecParameter.option("--command", valueName: "COMMAND", summary: "CLI command for the cli provider."),
        CLISpecParameter.flag("--local", summary: "Mark provider as local for context budgeting."),
    ]

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
                CLISpecParameter.option("--format", valueName: "text|transcript|json|srt|vtt", summary: "Output format for stdout or written transcript files."),
                CLISpecParameter.option("--mode", valueName: "raw|clean|app-default", summary: "Text processing mode for this run."),
                CLISpecParameter.option("--engine", valueName: "parakeet|nemotron|whisper|cohere|app-default", summary: "Speech engine for this run."),
                CLISpecParameter.option("--language", valueName: "CODE", summary: "Language hint for Nemotron, Whisper, or Cohere; Cohere has no auto-detect."),
                CLISpecParameter.option("--parakeet-model", valueName: "app-default|v3|v2|unified", summary: "Parakeet build: v3 supported languages, v2 English timestamps, or Unified readable English without timestamps."),
                CLISpecParameter.option("--nemotron-model", valueName: "app-default|multilingual-1120ms|english-1120ms", summary: "Nemotron Beta build for this run; ignored for Parakeet, Cohere, and Whisper."),
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
            ["retranscribe"],
            summary: "Retranscribe retained source audio for an existing saved dictation, transcription, or meeting in place.",
            readOnly: false,
            jsonMode: "--json|--envelope",
            arguments: [
                .argument("record", summary: "Saved record UUID, UUID prefix, or exact transcription/meeting title."),
            ],
            options: [
                CLISpecParameter.option("--kind", valueName: "auto|dictation|transcription|meeting", summary: "Constrain record resolution; auto fails on ambiguous matches."),
                CLISpecParameter.flag("--update", summary: "Required confirmation that the command updates the existing saved record in place."),
                CLISpecParameter.flag("--json", summary: "Emit the updated record payload as JSON."),
                CLISpecParameter.flag("--envelope", summary: "Emit a success/failure envelope."),
                CLISpecParameter.option("--mode", valueName: "raw|clean|app-default", summary: "Text processing mode for this rerun."),
                CLISpecParameter.option("--engine", valueName: "parakeet|nemotron|whisper|cohere|app-default", summary: "Speech engine for this rerun."),
                CLISpecParameter.option("--language", valueName: "CODE", summary: "Language hint for Nemotron, Whisper, or Cohere; Cohere has no auto-detect."),
                CLISpecParameter.option("--parakeet-model", valueName: "app-default|v3|v2|unified", summary: "Parakeet build: v3 supported languages, v2 English timestamps, or Unified readable English without timestamps."),
                CLISpecParameter.option("--nemotron-model", valueName: "app-default|multilingual-1120ms|english-1120ms", summary: "Nemotron Beta build for this rerun; ignored for Parakeet, Cohere, and Whisper."),
                CLISpecParameter.option("--speaker-detection", valueName: "app-default|on|off", summary: "Speaker detection for saved transcriptions and meetings."),
                CLISpecParameter.option("--speaker-count", valueName: "N", summary: "Exact known speaker count for saved transcriptions and meetings."),
                CLISpecParameter.option("--speaker-min", valueName: "N", summary: "Minimum speaker count bound for saved transcriptions and meetings."),
                CLISpecParameter.option("--speaker-max", valueName: "N", summary: "Maximum speaker count bound for saved transcriptions and meetings."),
                CLISpecParameter.flag("--no-diarize", summary: "Compatibility alias for --speaker-detection off."),
                databaseOption,
            ],
            output: "RetranscribeResult with kind, id, sourcePath, updatedAt, and the updated Dictation or Transcription record."
        ),
        CLISpecCommand(
            ["config", "list"],
            summary: "List shared app/CLI configuration values.",
            output: "Dictionary of canonical configuration keys to values."
        ),
        CLISpecCommand(
            ["config", "get"],
            summary: "Read one shared app/CLI configuration value.",
            arguments: [.argument("key", summary: "Configuration key, such as speech-engine, parakeet-model, nemotron-model, nemotron-language, whisper-language, cohere-language, voice-return-enabled, voice-return-triggers, prefer-built-in-mic-bluetooth-output, meeting-artifacts-folder, or meeting-hook-timeout.")],
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
            ["history", "delete-dictation"],
            summary: "Delete one saved dictation and its owned dictation audio.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Dictation UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable deletion confirmation."
        ),
        CLISpecCommand(
            ["history", "delete-transcription"],
            summary: "Delete one saved transcription and owned local assets.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Transcription UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable deletion confirmation."
        ),
        CLISpecCommand(
            ["history", "delete-meeting-audio"],
            summary: "Detach and delete stored audio for one meeting transcript while keeping the transcript row.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Meeting transcription UUID, UUID prefix, or file name.")],
            options: [databaseOption],
            output: "Human-readable deletion or no-op confirmation."
        ),
        CLISpecCommand(
            ["history", "clear-meeting-audio"],
            summary: "Delete all managed meeting audio while keeping saved meeting transcripts.",
            readOnly: false,
            jsonMode: "none",
            options: [databaseOption],
            output: "Human-readable deletion confirmation."
        ),
        CLISpecCommand(
            ["history", "favorites"],
            summary: "List favorite transcriptions.",
            options: [databaseOption],
            output: "Array of favorite transcription objects."
        ),
        CLISpecCommand(
            ["history", "favorite"],
            summary: "Mark a transcription as favorite.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Transcription UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable favorite confirmation."
        ),
        CLISpecCommand(
            ["history", "unfavorite"],
            summary: "Remove a transcription from favorites.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Transcription UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable unfavorite confirmation."
        ),
        CLISpecCommand(
            ["prompts", "list"],
            summary: "List result prompts in the prompt library.",
            options: [
                CLISpecParameter.option("--filter", valueName: "all|visible|auto-run", summary: "Which prompts to list."),
                databaseOption,
            ],
            output: "Array of Prompt objects."
        ),
        CLISpecCommand(
            ["prompts", "show"],
            summary: "Show one prompt's full content.",
            arguments: [.argument("prompt", summary: "Prompt ID, UUID prefix, or exact name.")],
            options: [databaseOption],
            output: "Prompt object when --json is used."
        ),
        CLISpecCommand(
            ["prompts", "add"],
            summary: "Add a custom result prompt.",
            readOnly: false,
            jsonMode: "none",
            options: [
                CLISpecParameter.option("--name", valueName: "NAME", required: true, summary: "Prompt display name."),
                CLISpecParameter.option("--content", valueName: "TEXT", summary: "Prompt body text."),
                CLISpecParameter.option("--from-file", valueName: "PATH", summary: "Read prompt body from a file."),
                CLISpecParameter.flag("--auto-run", summary: "Mark as auto-run for completed transcriptions."),
                databaseOption,
            ],
            output: "Human-readable add confirmation."
        ),
        CLISpecCommand(
            ["prompts", "set"],
            summary: "Toggle a result prompt's visibility or auto-run state.",
            readOnly: false,
            arguments: [.argument("prompt", summary: "Prompt ID, UUID prefix, or exact name.")],
            options: [
                CLISpecParameter.flag("--visible", summary: "Make the prompt visible."),
                CLISpecParameter.flag("--hidden", summary: "Hide the prompt and disable auto-run."),
                CLISpecParameter.flag("--auto-run", summary: "Enable global auto-run."),
                CLISpecParameter.flag("--no-auto-run", summary: "Disable auto-run."),
                CLISpecParameter.option("--source", valueName: "file|youtube|podcast|meeting", summary: "Scope --auto-run/--no-auto-run to one source; omit for global all-source behavior."),
                databaseOption,
            ],
            output: "Updated Prompt object when --json is used."
        ),
        CLISpecCommand(
            ["prompts", "delete"],
            summary: "Delete a custom result prompt; built-ins are protected.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("prompt", summary: "Prompt ID, UUID prefix, or exact name.")],
            options: [databaseOption],
            output: "Human-readable delete confirmation."
        ),
        CLISpecCommand(
            ["prompts", "restore-defaults"],
            summary: "Re-show built-in result prompts and hidden built-in Transforms without changing custom prompts.",
            readOnly: false,
            jsonMode: "none",
            options: [databaseOption],
            output: "Human-readable restore confirmation."
        ),
        CLISpecCommand(
            ["prompts", "run"],
            summary: "Run a saved result prompt against a saved transcription.",
            readOnly: false,
            arguments: [.argument("prompt", summary: "Prompt ID, UUID prefix, or exact name.")],
            options: llmInlineOptions + [
                CLISpecParameter.option("--transcription", valueName: "ID", required: true, summary: "Saved transcription ID or prefix."),
                CLISpecParameter.flag("--no-store", summary: "Do not save a PromptResult."),
                CLISpecParameter.flag("--stream", summary: "Stream tokens; incompatible with --json."),
                CLISpecParameter.option("--extra", valueName: "TEXT", summary: "Append extra instructions for this run."),
                databaseOption,
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["llm", "test-connection"],
            summary: "Test connectivity to an LLM provider.",
            readOnly: false,
            options: llmInlineOptions,
            output: "LLM test-connection result envelope when --json is used."
        ),
        CLISpecCommand(
            ["llm", "summarize"],
            summary: "Summarize text from a file or stdin using an LLM provider.",
            readOnly: false,
            arguments: [.argument("input", summary: "Path to text file; use '-' for stdin.")],
            options: llmInlineOptions + [
                CLISpecParameter.flag("--stream", summary: "Stream tokens; incompatible with --json."),
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["llm", "chat"],
            summary: "Ask a question about transcript text using an LLM provider.",
            readOnly: false,
            arguments: [.argument("input", summary: "Path to transcript text file; use '-' for stdin.")],
            options: llmInlineOptions + [
                CLISpecParameter.option("--question", valueName: "TEXT", required: true, summary: "Question to ask about the transcript."),
                CLISpecParameter.flag("--stream", summary: "Stream tokens; incompatible with --json."),
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["llm", "transform"],
            summary: "Apply an ad-hoc LLM transform to text from a file or stdin.",
            readOnly: false,
            arguments: [.argument("input", summary: "Path to text file; use '-' for stdin.")],
            options: llmInlineOptions + [
                CLISpecParameter.option("--prompt", valueName: "TEXT", required: true, summary: "Transform instruction."),
                CLISpecParameter.flag("--stream", summary: "Stream tokens; incompatible with --json."),
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "list"],
            summary: "List live Meeting Ask quick prompts.",
            options: [
                CLISpecParameter.option("--pinned", valueName: "true|false", summary: "Filter by pin state."),
                CLISpecParameter.flag("--visible-only", summary: "Only visible prompts."),
                databaseOption,
            ],
            output: "Array of QuickPrompt objects."
        ),
        CLISpecCommand(
            ["quick-prompts", "show"],
            summary: "Show one quick prompt's full content.",
            arguments: [.argument("quick-prompt", summary: "Quick prompt ID, UUID prefix, or label.")],
            options: [databaseOption],
            output: "QuickPrompt object when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "add"],
            summary: "Add a custom Meeting Ask quick prompt.",
            readOnly: false,
            options: [
                CLISpecParameter.option("--label", valueName: "LABEL", required: true, summary: "Display label shown on the pill."),
                CLISpecParameter.option("--prompt", valueName: "TEXT", summary: "Prompt body text."),
                CLISpecParameter.option("--from-file", valueName: "PATH", summary: "Read prompt body from a file."),
                CLISpecParameter.option("--group", valueName: "LABEL", summary: "Optional group label."),
                CLISpecParameter.flag("--hidden", summary: "Insert as hidden."),
                CLISpecParameter.flag("--pinned", summary: "Pin immediately."),
                databaseOption,
            ],
            output: "QuickPrompt write result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "set"],
            summary: "Update a quick prompt's fields or visibility.",
            readOnly: false,
            arguments: [.argument("quick-prompt", summary: "Quick prompt ID, UUID prefix, or label.")],
            options: [
                CLISpecParameter.option("--label", valueName: "LABEL", summary: "Replace the display label."),
                CLISpecParameter.option("--prompt", valueName: "TEXT", summary: "Replace the prompt body."),
                CLISpecParameter.option("--group", valueName: "LABEL", summary: "Replace or clear the group label."),
                CLISpecParameter.option("--sort-order", valueName: "N", summary: "Replace sort order."),
                CLISpecParameter.flag("--visible", summary: "Make visible."),
                CLISpecParameter.flag("--hidden", summary: "Hide."),
                databaseOption,
            ],
            output: "QuickPrompt write result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "delete"],
            summary: "Delete a custom quick prompt; built-ins are protected.",
            readOnly: false,
            arguments: [.argument("quick-prompt", summary: "Quick prompt ID, UUID prefix, or label.")],
            options: [databaseOption],
            output: "Delete result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "pin"],
            summary: "Pin a quick prompt to the after-response strip.",
            readOnly: false,
            arguments: [.argument("quick-prompt", summary: "Quick prompt ID, UUID prefix, or label.")],
            options: [databaseOption],
            output: "QuickPrompt write result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "unpin"],
            summary: "Unpin a quick prompt from the after-response strip.",
            readOnly: false,
            arguments: [.argument("quick-prompt", summary: "Quick prompt ID, UUID prefix, or label.")],
            options: [databaseOption],
            output: "QuickPrompt write result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "restore-defaults"],
            summary: "Reset built-in quick prompts to canonical values.",
            readOnly: false,
            options: [
                CLISpecParameter.option("--id", valueName: "ID", summary: "Limit restore to one built-in quick prompt."),
                databaseOption,
            ],
            output: "Restore result when --json is used."
        ),
        CLISpecCommand(
            ["quick-prompts", "export"],
            summary: "Export quick prompts as a versioned JSON bundle.",
            jsonMode: "--json for failure envelopes only",
            options: [
                CLISpecParameter.option("--out", valueName: "PATH", summary: "Write bundle to a file; stdout if omitted."),
                CLISpecParameter.option("--pinned", valueName: "true|false", summary: "Filter by pin state."),
                CLISpecParameter.flag("--include-builtins", summary: "Include built-in prompts."),
                databaseOption,
            ],
            output: "QuickPromptBundle JSON."
        ),
        CLISpecCommand(
            ["quick-prompts", "import"],
            summary: "Import a quick-prompts bundle from JSON.",
            readOnly: false,
            arguments: [.argument("path", summary: "Path to the bundle JSON file.")],
            options: [
                CLISpecParameter.option("--mode", valueName: "merge|replace", summary: "Import mode."),
                CLISpecParameter.flag("--dry-run", summary: "Show planned changes without writing."),
                CLISpecParameter.flag("--yes", summary: "Skip replace confirmation."),
                databaseOption,
            ],
            output: "QuickPrompt import summary when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "list"],
            summary: "List saved Transforms with their bound shortcuts.",
            options: [databaseOption],
            output: "Array of TransformDTO objects."
        ),
        CLISpecCommand(
            ["transforms", "show"],
            summary: "Show one Transform's prompt body and bound shortcut.",
            arguments: [.argument("transform", summary: "Transform ID, UUID prefix, or name.")],
            options: [databaseOption],
            output: "TransformDTO object when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "run"],
            summary: "Run a saved Transform against text from a file or stdin.",
            readOnly: false,
            arguments: [.argument("transform", summary: "Transform ID, UUID prefix, or name.")],
            options: llmInlineOptions + [
                CLISpecParameter.option("--input", valueName: "PATH", required: true, summary: "Path to text file; use '-' for stdin."),
                CLISpecParameter.flag("--stream", summary: "Stream tokens; incompatible with --json."),
                databaseOption,
            ],
            output: "LLMResult envelope when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "create"],
            summary: "Create a custom saved Transform with an optional shortcut.",
            readOnly: false,
            options: [
                CLISpecParameter.option("--name", valueName: "NAME", required: true, summary: "Transform name."),
                CLISpecParameter.option("--prompt", valueName: "TEXT", summary: "Prompt body text."),
                CLISpecParameter.option("--from-file", valueName: "PATH", summary: "Read prompt body from a file."),
                CLISpecParameter.option("--shortcut", valueName: "KEYS", summary: "Keyboard shortcut such as opt+1."),
                databaseOption,
            ],
            output: "TransformDTO object when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "delete"],
            summary: "Delete a custom Transform; built-ins are protected.",
            readOnly: false,
            arguments: [.argument("transform", summary: "Transform ID, UUID prefix, or name.")],
            options: [databaseOption],
            output: "Delete result when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "restore-defaults"],
            summary: "Restore built-in Transform defaults.",
            readOnly: false,
            options: [
                CLISpecParameter.option("--transform", valueName: "ID|NAME", summary: "Reset one built-in Transform; omit to re-show hidden built-ins and re-seed missing built-ins without overwriting edits."),
                databaseOption,
            ],
            output: "Restore result when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "history", "list"],
            summary: "List saved Transform runs.",
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of history rows."),
                databaseOption,
            ],
            output: "Array of TransformHistoryDTO objects."
        ),
        CLISpecCommand(
            ["transforms", "history", "show"],
            summary: "Show one saved Transform run.",
            arguments: [.argument("history-id", summary: "History item UUID or UUID prefix.")],
            options: [databaseOption],
            output: "TransformHistoryDTO object when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "history", "delete"],
            summary: "Delete one saved Transform history item.",
            readOnly: false,
            arguments: [.argument("history-id", summary: "History item UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Delete result when --json is used."
        ),
        CLISpecCommand(
            ["transforms", "history", "clear"],
            summary: "Clear all local Transform history.",
            readOnly: false,
            options: [databaseOption],
            output: "Clear result when --json is used."
        ),
        CLISpecCommand(
            ["vocab", "process"],
            summary: "Run deterministic clean text processing on input text.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("text", summary: "Text to process.")],
            options: [
                CLISpecParameter.flag("--copy", summary: "Copy result to clipboard."),
                databaseOption,
            ],
            output: "Processed text."
        ),
        CLISpecCommand(
            ["vocab", "words", "list"],
            summary: "List custom words.",
            options: [
                CLISpecParameter.option("--source", valueName: "all|manual|learned", summary: "Filter by source."),
                databaseOption,
            ],
            output: "Array of CustomWord objects."
        ),
        CLISpecCommand(
            ["vocab", "words", "add"],
            summary: "Add a custom word or correction.",
            readOnly: false,
            jsonMode: "none",
            arguments: [
                .argument("word", summary: "Word or phrase to match."),
                .argument("replacement", required: false, summary: "Replacement text; omit for vocabulary anchor."),
            ],
            options: [databaseOption],
            output: "Human-readable add confirmation."
        ),
        CLISpecCommand(
            ["vocab", "words", "set"],
            summary: "Update a custom word's enabled state.",
            readOnly: false,
            arguments: [.argument("id", summary: "Word UUID or UUID prefix.")],
            options: [
                CLISpecParameter.flag("--enabled", summary: "Enable the word or correction."),
                CLISpecParameter.flag("--disabled", summary: "Disable the word or correction."),
                databaseOption,
            ],
            output: "Write result when --json is used."
        ),
        CLISpecCommand(
            ["vocab", "words", "delete"],
            summary: "Delete a custom word by UUID prefix.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Word UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable delete confirmation."
        ),
        CLISpecCommand(
            ["vocab", "snippets", "list"],
            summary: "List text snippets.",
            options: [databaseOption],
            output: "Array of TextSnippet objects."
        ),
        CLISpecCommand(
            ["vocab", "snippets", "add"],
            summary: "Add a text snippet.",
            readOnly: false,
            jsonMode: "none",
            arguments: [
                .argument("trigger", summary: "Natural-language trigger phrase."),
                .argument("expansion", summary: "Expansion text."),
            ],
            options: [databaseOption],
            output: "Human-readable add confirmation."
        ),
        CLISpecCommand(
            ["vocab", "snippets", "edit"],
            summary: "Edit a text snippet by UUID prefix.",
            readOnly: false,
            arguments: [.argument("id", summary: "Snippet UUID or UUID prefix.")],
            options: [
                CLISpecParameter.option("--trigger", valueName: "TEXT", summary: "Replacement trigger."),
                CLISpecParameter.option("--expansion", valueName: "TEXT", summary: "Replacement expansion."),
                CLISpecParameter.flag("--enabled", summary: "Enable the snippet."),
                CLISpecParameter.flag("--disabled", summary: "Disable the snippet."),
                databaseOption,
            ],
            output: "Write result when --json is used."
        ),
        CLISpecCommand(
            ["vocab", "snippets", "delete"],
            summary: "Delete a text snippet by UUID prefix.",
            readOnly: false,
            jsonMode: "none",
            arguments: [.argument("id", summary: "Snippet UUID or UUID prefix.")],
            options: [databaseOption],
            output: "Human-readable delete confirmation."
        ),
        CLISpecCommand(
            ["vocab", "export"],
            summary: "Export custom words and snippets as a vocabulary bundle.",
            jsonMode: "bundle JSON",
            options: [
                CLISpecParameter.option("--output", valueName: "PATH", summary: "Write bundle to a file; stdout if omitted."),
                databaseOption,
            ],
            output: "VocabularyBundle JSON."
        ),
        CLISpecCommand(
            ["vocab", "import"],
            summary: "Import a vocabulary bundle.",
            readOnly: false,
            options: [
                CLISpecParameter.option("--input", valueName: "PATH", summary: "Read bundle from a file; stdin if omitted."),
                CLISpecParameter.option("--policy", valueName: "skip|replace", summary: "Conflict policy."),
                CLISpecParameter.flag("--dry-run", summary: "Decode and report without writing."),
                databaseOption,
            ],
            output: "Vocabulary import report when --json is used."
        ),
        CLISpecCommand(
            ["vocab", "schema"],
            summary: "Print the vocabulary bundle JSON schema and example.",
            output: "VocabularyBundleSpec object when --json is used."
        ),
        CLISpecCommand(
            ["stats"],
            summary: "Show voice stats dashboard.",
            options: [databaseOption],
            output: "StatsPayload object."
        ),
        CLISpecCommand(
            ["export"],
            summary: "Export a saved transcription to a file or stdout.",
            readOnly: false,
            jsonMode: "--stdout --format json",
            arguments: [.argument("id", summary: "Transcription UUID or UUID prefix.")],
            options: [
                CLISpecParameter.option("--format", valueName: "txt|markdown|srt|vtt|json", summary: "Export format."),
                CLISpecParameter.option("--output", valueName: "PATH", summary: "Output file path."),
                CLISpecParameter.flag("--stdout", summary: "Print to stdout instead of writing a file."),
                databaseOption,
            ],
            output: "Written file path or exported content."
        ),
        CLISpecCommand(
            ["calendar", "upcoming"],
            summary: "List upcoming calendar events visible to MacParakeet.",
            options: [
                CLISpecParameter.option("--days", valueName: "N", summary: "Number of days to look ahead."),
                CLISpecParameter.option("--filter", valueName: "link|participants|all", summary: "Meeting trigger filter."),
            ],
            output: "Array of CalendarEvent objects when --json is used."
        ),
        CLISpecCommand(
            ["meetings", "list"],
            summary: "List recent meeting recordings.",
            options: [
                CLISpecParameter.option("--limit", valueName: "N", summary: "Maximum number of meetings."),
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
            output: "MeetingRecord object with transcript, transcriptSegments, notes, and prompt-result count."
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
            output: "MeetingTranscriptRecord object with transcriptSegments for --format json."
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
            jsonMode: "--stdout --format json",
            arguments: [.argument("meeting", summary: "Meeting UUID, UUID prefix, or exact title.")],
            options: [
                CLISpecParameter.option("--format", valueName: "md|json", summary: "Export format."),
                CLISpecParameter.option("--output", valueName: "PATH", summary: "Output file path; defaults to an auto-generated file."),
                CLISpecParameter.flag("--stdout", summary: "Print export content to stdout."),
                databaseOption,
            ],
            output: "Markdown text or MeetingRecord JSON with prompt-result count when --stdout is present; otherwise writes a file and prints its path."
        ),
    ]
}
