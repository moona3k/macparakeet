import AppKit
import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm",
        abstract: "Run and validate local LLM workflows.",
        subcommands: [
            Generate.self,
            Refine.self,
            CommandTransform.self,
            Chat.self,
            SmokeTest.self,
        ]
    )
}

struct LLMRuntimeOptions: ParsableArguments {
    @Option(help: "Model identifier.")
    var model: String = MLXLLMService.defaultModelID

    @Option(help: "Model revision.")
    var revision: String = "main"

    @Option(help: "Temperature.")
    var temperature: Float = 0.6

    @Option(help: "Top-P.")
    var topP: Float = 0.95

    @Option(help: "Maximum output tokens.")
    var maxTokens: Int = 512

    @Option(help: "Timeout in seconds.")
    var timeout: Double = 120

    @Option(help: "Optional system prompt override.")
    var system: String?

    @Flag(help: "Print prompt and exit without running model.")
    var dryRun: Bool = false

    @Flag(help: "Include model and timing metadata.")
    var stats: Bool = false

    func generationOptions() -> LLMGenerationOptions {
        LLMGenerationOptions(
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens > 0 ? maxTokens : nil,
            timeoutSeconds: timeout > 0 ? timeout : nil
        )
    }
}

enum RefineModeArgument: String, ExpressibleByArgument {
    case formal
    case email
    case code

    var coreMode: LLMRefinementMode {
        switch self {
        case .formal: return .formal
        case .email: return .email
        case .code: return .code
        }
    }
}

extension LLMCommand {
    struct Generate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: "Generate text from a direct prompt."
        )

        @Argument(help: "Prompt text.")
        var prompt: String

        @OptionGroup
        var runtime: LLMRuntimeOptions

        @Flag(name: .long, help: "Copy result to clipboard.")
        var copy: Bool = false

        func run() async throws {
            let request = LLMRequest(
                prompt: prompt,
                systemPrompt: runtime.system,
                options: runtime.generationOptions()
            )
            try await execute(request: request, runtime: runtime, copy: copy)
        }
    }

    struct Refine: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "refine",
            abstract: "Refine text using deterministic cleanup + local LLM."
        )

        @Argument(help: "Refinement mode: formal, email, code.")
        var mode: RefineModeArgument

        @Argument(help: "Text to refine.")
        var text: String

        @Option(help: "Path to SQLite database file (defaults to app DB).")
        var database: String?

        @Flag(help: "Skip deterministic pre-clean and send input directly to LLM.")
        var skipClean: Bool = false

        @OptionGroup
        var runtime: LLMRuntimeOptions

        @Flag(name: .long, help: "Copy result to clipboard.")
        var copy: Bool = false

        func run() async throws {
            let cleanInput: String
            if skipClean {
                cleanInput = text
            } else {
                cleanInput = try prepareDeterministicText(from: text, database: database)
            }

            let task = LLMTask.refine(mode: mode.coreMode, input: cleanInput)
            let request = LLMRequest(
                prompt: LLMPromptBuilder.userPrompt(for: task),
                systemPrompt: runtime.system ?? LLMPromptBuilder.systemPrompt(for: task),
                options: runtime.generationOptions()
            )
            try await execute(request: request, runtime: runtime, copy: copy)
        }
    }

    struct CommandTransform: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "command",
            abstract: "Apply a spoken-style command to text."
        )

        @Argument(help: "Command text, e.g. 'Translate to Spanish'.")
        var command: String

        @Argument(help: "Selected text to transform.")
        var selectedText: String

        @OptionGroup
        var runtime: LLMRuntimeOptions

        @Flag(name: .long, help: "Copy result to clipboard.")
        var copy: Bool = false

        func run() async throws {
            let task = LLMTask.commandTransform(command: command, selectedText: selectedText)
            let request = LLMRequest(
                prompt: LLMPromptBuilder.userPrompt(for: task),
                systemPrompt: runtime.system ?? LLMPromptBuilder.systemPrompt(for: task),
                options: runtime.generationOptions()
            )
            try await execute(request: request, runtime: runtime, copy: copy)
        }
    }

    struct Chat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "chat",
            abstract: "Single-turn local chat (optionally grounded by transcript context)."
        )

        @Argument(help: "Question to ask the local model.")
        var question: String

        @Option(name: .long, help: "Optional transcript text file to append as context.")
        var transcriptFile: String?

        @OptionGroup
        var runtime: LLMRuntimeOptions

        @Flag(name: .long, help: "Copy result to clipboard.")
        var copy: Bool = false

        func run() async throws {
            let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                throw CLIError.invalidQuestion
            }

            let transcriptContext = try LLMChatPromptComposer.loadTranscriptContext(
                from: transcriptFile
            )
            let payload = LLMChatPromptComposer.compose(
                question: question,
                transcriptContext: transcriptContext
            )

            let request = LLMRequest(
                prompt: payload.prompt,
                systemPrompt: runtime.system ?? payload.defaultSystemPrompt,
                options: runtime.generationOptions()
            )

            try await execute(request: request, runtime: runtime, copy: copy)
        }
    }

    struct SmokeTest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "smoke-test",
            abstract: "Quick local model readiness test."
        )

        @OptionGroup
        var runtime: LLMRuntimeOptions

        func run() async throws {
            let request = LLMRequest(
                prompt: "Reply with exactly: OK",
                systemPrompt: runtime.system ?? "Return exactly one token: OK",
                options: runtime.generationOptions()
            )

            if runtime.dryRun {
                print("SYSTEM:")
                print(request.systemPrompt ?? "(none)")
                print()
                print("PROMPT:")
                print(request.prompt)
                return
            }

            let service = MLXLLMService(modelID: runtime.model, revision: runtime.revision)
            let response = try await service.generate(request: request)
            let normalized = response.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard normalized.contains("OK") else {
                throw CLIError.localLLMSmokeTestFailed(response.text)
            }

            print("LLM smoke test passed.")
            if runtime.stats {
                print("model=\(response.modelID)")
                print(String(format: "duration=%.2fs", response.durationSeconds))
            }
        }
    }
}

struct LLMChatPromptPayload: Sendable {
    let prompt: String
    let defaultSystemPrompt: String
}

enum LLMChatPromptComposer {
    static let defaultSystemPrompt = """
    You are a concise assistant.
    Answer directly and avoid unnecessary verbosity.
    """

    static func compose(question: String, transcriptContext: String?) -> LLMChatPromptPayload {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transcriptContext,
           !transcriptContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let task = LLMTask.transcriptChat(question: trimmedQuestion, transcript: transcriptContext)
            return LLMChatPromptPayload(
                prompt: LLMPromptBuilder.userPrompt(for: task),
                defaultSystemPrompt: LLMPromptBuilder.systemPrompt(for: task)
            )
        }

        return LLMChatPromptPayload(
            prompt: trimmedQuestion,
            defaultSystemPrompt: defaultSystemPrompt
        )
    }

    static func loadTranscriptContext(from path: String?) throws -> String? {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: rawPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.transcriptFileNotFound(rawPath)
        }

        do {
            let transcript = try String(contentsOf: fileURL, encoding: .utf8)
            let assembled = TranscriptContextAssembler.assemble(transcript: transcript)
            let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            throw CLIError.transcriptFileReadFailed(rawPath, underlying: error)
        }
    }
}

private func execute(request: LLMRequest, runtime: LLMRuntimeOptions, copy: Bool) async throws {
    if runtime.dryRun {
        print("SYSTEM:")
        print(request.systemPrompt ?? "(none)")
        print()
        print("PROMPT:")
        print(request.prompt)
        return
    }

    let service = MLXLLMService(modelID: runtime.model, revision: runtime.revision)
    let response = try await service.generate(request: request)
    print(response.text)

    if copy {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(response.text, forType: .string)
        print("(copied to clipboard)")
    }

    if runtime.stats {
        print()
        print("model=\(response.modelID)")
        print(String(format: "duration=%.2fs", response.durationSeconds))
    }
}

private func prepareDeterministicText(from text: String, database: String?) throws -> String {
    try AppPaths.ensureDirectories()

    let dbPathOpt = database?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedDBPath = (dbPathOpt?.isEmpty == false) ? dbPathOpt! : AppPaths.databasePath
    if resolvedDBPath != AppPaths.databasePath {
        let dir = URL(fileURLWithPath: resolvedDBPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let dbManager = try DatabaseManager(path: resolvedDBPath)
    let wordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
    let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

    let words = try wordRepo.fetchEnabled()
    let snippets = try snippetRepo.fetchEnabled()
    let pipeline = TextProcessingPipeline()
    let result = pipeline.process(text: text, customWords: words, snippets: snippets)

    if !result.expandedSnippetIDs.isEmpty {
        try snippetRepo.incrementUseCount(ids: result.expandedSnippetIDs)
    }

    return result.text
}
