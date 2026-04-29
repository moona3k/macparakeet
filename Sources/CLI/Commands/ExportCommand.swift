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

    func run() async throws {
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
            return await exportService.formatSRT(transcription: transcription)
        case .vtt:
            return await exportService.formatVTT(transcription: transcription)
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
            try await exportService.exportToSRT(transcription: transcription, url: url)
        case .vtt:
            try await exportService.exportToVTT(transcription: transcription, url: url)
        case .json:
            try await exportService.exportToJSON(transcription: transcription, url: url)
        }
    }
}
