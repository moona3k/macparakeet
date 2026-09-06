import ArgumentParser
import Foundation
import MacParakeetCore

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case txt
    case markdown
    case srt
    case vtt
    case dapt
    case json

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .dapt: return "dapt.xml"
        case .json: return "json"
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a transcription to a file.",
        discussion: "Supported formats: txt, markdown, srt, vtt, dapt, json."
    )

    @Argument(help: "The UUID (or prefix) of the transcription to export.")
    var id: String

    @Option(name: .shortAndLong, help: "Output format: txt, markdown, srt, vtt, dapt, json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Output file path (defaults to current directory with auto-generated name).")
    var output: String?

    @Flag(help: "Print to stdout instead of writing a file.")
    var stdout: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        try emitJSONOrRethrow(json: stdout && format == .json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let attributionReader = SpeakerAttributionReadService(dbQueue: dbManager.dbQueue)

            let transcription = try findTranscription(id: id, repo: repo)
            let projection = try attributionReader.resolve(transcription: transcription)
            let exportService = ExportService()

            if stdout {
                let content = try formatContent(projection: projection, exportService: exportService)
                print(content)
            } else {
                let outputURL = resolveOutputURL(transcription: transcription)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeExport(projection: projection, exportService: exportService, url: outputURL)
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

    private func formatContent(
        projection: SpeakerAttributionProjection,
        exportService: ExportService
    ) throws -> String {
        switch format {
        case .txt:
            return exportService.formatPlainText(projection: projection)
        case .markdown:
            return exportService.formatMarkdown(projection: projection)
        case .srt:
            return exportService.formatSRT(projection: projection)
        case .vtt:
            return exportService.formatVTT(projection: projection)
        case .dapt:
            return exportService.formatDAPT(projection: projection)
        case .json:
            return try projectedJSON(projection)
        }
    }

    private func writeExport(
        projection: SpeakerAttributionProjection,
        exportService: ExportService,
        url: URL
    ) throws {
        switch format {
        case .txt:
            try exportService.exportToTxt(transcription: projection.effectiveTranscription, url: url)
        case .markdown:
            try exportService.exportToMarkdown(transcription: projection.effectiveTranscription, url: url)
        case .srt:
            try exportService.exportToSRT(transcription: projection.effectiveTranscription, url: url)
        case .vtt:
            try exportService.exportToVTT(transcription: projection.effectiveTranscription, url: url)
        case .dapt:
            try exportService.exportToDAPT(transcription: projection.effectiveTranscription, url: url)
        case .json:
            try Data(projectedJSON(projection).utf8).write(to: url, options: .atomic)
        }
    }

    private func projectedJSON(_ projection: SpeakerAttributionProjection) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(projection.effectiveTranscription)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["speakerCorrectionsApplied"] = projection.correctionsApplied
        object["speakerCorrectionRevision"] = projection.correctionRevision
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }
}
