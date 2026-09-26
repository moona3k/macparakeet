import ArgumentParser
import Foundation
import MacParakeetCore

struct AskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Experimental Ask workspace (developer builds only). Outputs JSON.",
        subcommands: [
            AskListCommand.self, AskNewCommand.self, AskShowCommand.self, AskRenameCommand.self,
            AskDeleteCommand.self, AskSourcesCommand.self, AskSelectCommand.self,
            AskDraftCommand.self, AskSendCommand.self, AskEvidenceCommand.self,
        ]
    )
}

private struct AskDatabaseOptions: ParsableArguments {
    @Option(help: "Path to SQLite database (defaults to the app database).") var database: String?
    @Flag(help: "Enable experimental Ask in a developer build; unavailable in release builds.")
    var enableAskWorkspace = false

    func requireAvailable() throws {
        let arguments = enableAskWorkspace ? [AppFeatures.askWorkspaceDeveloperLaunchArgument] : []
        guard AppFeatures.isAskWorkspaceAvailable(arguments: arguments) else {
            throw ValidationError(
                "Ask workspace is disabled. Developer builds require --enable-ask-workspace; release builds cannot enable it."
            )
        }
    }

    func service() throws -> AskWorkspaceService {
        try requireAvailable()
        return AskWorkspaceService(
            databaseManager: try makeDatabaseManager(database: database), client: LLMClient(),
            contextResolver: StaticLLMExecutionContextResolver(context: nil)
        )
    }
}

private func askUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw ValidationError("Use the complete UUID returned by Ask.") }
    return id
}

private struct AskListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved Ask conversations.")
    @OptionGroup var database: AskDatabaseOptions
    func run() async throws {
        try await emitJSONOrRethrow(json: true) { try printJSON(await database.service().conversations()) }
    }
}

private struct AskNewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new", abstract: "Create a conversation with selected recording UUIDs.")
    @OptionGroup var database: AskDatabaseOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Recording UUIDs, up to 32.") var source: [String] = []
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            try printJSON(await database.service().create(sourceIDs: source.map(askUUID)))
        }
    }
}

private struct AskShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Read a conversation and its revision.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument var id: String
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            guard let value = try await database.service().conversation(id: askUUID(id)) else {
                throw AskWorkspaceError.missingConversation
            }
            try printJSON(value)
        }
    }
}

private struct AskRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a saved conversation.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument var id: String
    @Argument var title: String
    @Option(help: "Expected conversation revision from show/list.") var revision: Int
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            try printJSON(await database.service().rename(id: askUUID(id), title: title, expectedRevision: revision))
        }
    }
}

private struct AskDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Delete only this Ask conversation; recordings are preserved.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument var id: String
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            let uuid = try askUUID(id)
            try await database.service().delete(id: uuid)
            try printJSON(["deleted": uuid.uuidString])
        }
    }
}

private struct AskSourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources", abstract: "Search recording metadata for context selection.")
    @OptionGroup var database: AskDatabaseOptions
    @Option var search: String = ""
    @Option(help: "meeting, file, youtube, or podcast.") var type: String?
    @Option(help: "Only recordings since an ISO-8601 timestamp or date.") var since: String?
    @Option(help: "Only recordings until an ISO-8601 timestamp or date.") var until: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Existing label UUIDs; matches any selected label.") var label:
        [String] = []
    @Option var limit: Int = 50
    @Option var offset: Int = 0
    @Flag(help: "List available labels instead of recordings.") var labels = false

    func validate() throws {
        guard (1...100).contains(limit), offset >= 0 else {
            throw ValidationError("Use --limit 1...100 and --offset >= 0.")
        }
        if let type, Transcription.SourceType(rawValue: type) == nil {
            throw ValidationError("Unknown recording type.")
        }
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            let service = try database.service()
            if labels { try printJSON(await service.labels()); return }
            let filter = AskSourceFilter(
                searchText: search, sourceType: type.flatMap(Transcription.SourceType.init(rawValue:)),
                since: try since.map { try parseSearchDate($0, boundary: .since) },
                until: try until.map { try parseSearchDate($0, boundary: .until) },
                labelIDs: Set(try label.map(askUUID)), limit: limit, offset: offset
            )
            try printJSON(await service.sources(filter: filter))
        }
    }
}

private struct AskSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select", abstract: "Replace selected sources and start a fresh context section.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument var id: String
    @Option(help: "Expected conversation revision.") var revision: Int
    @Option(name: .long, parsing: .upToNextOption, help: "Recording UUIDs. Omit to clear selection.") var source:
        [String] = []
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            try printJSON(
                await database.service().selectSources(
                    id: askUUID(id), sourceIDs: source.map(askUUID), expectedRevision: revision
                ))
        }
    }
}

private struct AskDraftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft", abstract: "Save an unsent question.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument var id: String
    @Argument var text: String
    @Option(help: "Expected conversation revision.") var revision: Int
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            try printJSON(await database.service().saveDraft(id: askUUID(id), draft: text, expectedRevision: revision))
        }
    }
}

private struct AskSendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send", abstract: "Investigate selected recordings using the chosen provider and Pi.")
    @OptionGroup var database: AskDatabaseOptions
    @OptionGroup var llm: LLMInlineOptions
    @Argument var id: String
    @Option(name: .shortAndLong) var question: String
    @Option(help: "Expected conversation revision.") var revision: Int
    @Flag(help: "Allow selected recording context to be sent to the explicitly configured remote provider.")
    var allowRemote = false
    @Flag(help: "Emit activity/text events and a final conversation as NDJSON.") var stream = false

    func validate() throws {
        if ["cli", "localcli"].contains(llm.provider.lowercased()) {
            throw ValidationError(
                "Ask requires a direct model provider; command-line agent providers are not supported.")
        }
    }

    func run() async throws {
        var incomplete = false
        try await emitJSONOrRethrow(json: true) {
            try database.requireAvailable()
            let execution = try llm.buildExecutionContext()
            let service = AskWorkspaceService(
                databaseManager: try makeDatabaseManager(database: database.database), client: execution.client,
                contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
            )
            let disclosure = try await service.provider()
            let stream = stream
            let result = try await service.send(
                id: askUUID(id), question: question, expectedRevision: revision,
                approvedProviderID: allowRemote ? disclosure.id : nil,
                onEvent: { event in
                    guard stream else { return }
                    let fields: [String: String]
                    switch event {
                    case .activity(let value): fields = ["type": "activity", "text": value]
                    case .text(let value): fields = ["type": "text", "text": value]
                    }
                    if let data = try? JSONEncoder().encode(fields) {
                        try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0a]))
                    }
                }
            )
            if stream {
                struct Terminal: Encodable { let type = "conversation"; let conversation: AskConversation }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(Terminal(conversation: result))
                try FileHandle.standardOutput.write(contentsOf: data + Data([0x0a]))
            } else {
                try printJSON(result)
            }
            incomplete = result.messages.last?.status != .complete
        }
        if incomplete { throw ExitCode.failure }
    }
}

private struct AskEvidenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evidence", abstract: "Resolve a citation against its current recording revision.")
    @OptionGroup var database: AskDatabaseOptions
    @Argument(help: "Recording UUID from an answer citation.") var source: String
    @Option(help: "Source revision hash from the citation.") var sourceRevision: String
    @Option(help: "Zero-based passage index from the citation.") var segment: Int
    func run() async throws {
        try await emitJSONOrRethrow(json: true) {
            try printJSON(
                await database.service().evidence(
                    AskEvidenceReference(
                        sourceID: askUUID(source), sourceRevision: sourceRevision, segmentIndex: segment
                    )))
        }
    }
}
