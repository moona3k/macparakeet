import ArgumentParser
import Foundation
import MacParakeetCore

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case txt
    case markdown
    case srt
    case vtt
    case json

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .json: return "json"
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a transcription to a file.",
        discussion: "Supported formats: txt, markdown, srt, vtt, json."
    )

    @Argument(help: "The UUID (or prefix) of the transcription to export.")
    var id: String

    @Option(name: .shortAndLong, help: "Output format: txt, markdown, srt, vtt, json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Output file path (defaults to current directory with auto-generated name).")
    var output: String?

    @Flag(help: "Print to stdout instead of writing a file.")
    var stdout: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Flag(name: .long, help: "Convert spelled-out cardinals to digits in SRT/VTT cue text.")
    var normalizeNumbers: Bool = false

    @Flag(name: .long, help: "Use the LLM layout planner for SRT/VTT cue boundaries (reads the same stored LLM provider config as the app).")
    var llmRefinement: Bool = false

    /// SubtitleExportConfig with the CLI flag overlay applied. Used by the
    /// SRT/VTT branches; the other formats ignore it.
    private var subtitleConfig: SubtitleExportConfig {
        var c = SubtitleExportConfig.default
        c.normalizeNumbers = normalizeNumbers
        c.useLLMRefinement = llmRefinement
        return c
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: stdout && format == .json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

            let transcription = try findTranscription(id: id, repo: repo)
            let exportService = await ExportService()

            if stdout {
                let content = await formatContent(transcription: transcription, exportService: exportService)
                print(content)
            } else {
                let outputURL = resolveOutputURL(transcription: transcription)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await writeExport(transcription: transcription, exportService: exportService, url: outputURL)
                print("Exported to \(outputURL.path)")
            }
        }
    }

    func resolveOutputURL(transcription: Transcription) -> URL {
        if let output {
            return URL(fileURLWithPath: expandTilde(output))
        }
        let baseName = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        let fileName = "\(baseName).\(format.fileExtension)"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)
    }

    private func formatContent(transcription: Transcription, exportService: ExportService) async -> String {
        switch format {
        case .txt:
            return await exportService.formatForClipboard(transcription: transcription)
        case .markdown:
            return await exportService.formatMarkdown(transcription: transcription)
        case .srt:
            return await exportService.formatSRT(transcription: transcription, config: subtitleConfig)
        case .vtt:
            return await exportService.formatVTT(transcription: transcription, config: subtitleConfig)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(transcription),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{}"
        }
    }

    private func writeExport(transcription: Transcription, exportService: ExportService, url: URL) async throws {
        switch format {
        case .txt:
            try await exportService.exportToTxt(transcription: transcription, url: url)
        case .markdown:
            try await exportService.exportToMarkdown(transcription: transcription, url: url)
        case .srt:
            if llmRefinement {
                let llmService = buildLLMServiceFromGUIDefaults()
                try await exportService.exportToSRT(
                    transcription: transcription,
                    url: url,
                    config: subtitleConfig,
                    llmService: llmService
                )
            } else {
                try await exportService.exportToSRT(transcription: transcription, url: url, config: subtitleConfig)
            }
        case .vtt:
            if llmRefinement {
                let llmService = buildLLMServiceFromGUIDefaults()
                try await exportService.exportToVTT(
                    transcription: transcription,
                    url: url,
                    config: subtitleConfig,
                    llmService: llmService
                )
            } else {
                try await exportService.exportToVTT(transcription: transcription, url: url, config: subtitleConfig)
            }
        case .json:
            try await exportService.exportToJSON(transcription: transcription, url: url)
        }
    }

    /// LLMConfigStore defaults to `UserDefaults.standard`, which for a
    /// bundle-less CLI binary resolves to a different domain than the
    /// GUI app's. The GUI saves its provider config under either
    /// `com.macparakeet.dev` (debug build) or `com.macparakeet.MacParakeet`
    /// (release). Try both, prefer whichever has a saved config.
    private func buildLLMServiceFromGUIDefaults() -> LLMService {
        let candidates = [
            "com.macparakeet.dev",
            "com.macparakeet.MacParakeet",
        ]
        for suite in candidates {
            guard let defaults = UserDefaults(suiteName: suite) else { continue }
            if defaults.data(forKey: "llm_provider_config") != nil {
                let store = LLMConfigStore(defaults: defaults)
                return LLMService(
                    client: RoutingLLMClient(),
                    contextResolver: StoredLLMExecutionContextResolver(
                        configStore: store,
                        cliConfigStore: LocalCLIConfigStore()
                    )
                )
            }
        }
        // No GUI config found — fall through to default-everything
        // (which will throw `notConfigured` per chunk).
        return LLMService()
    }
}
