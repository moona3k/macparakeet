import AppKit
import Foundation
import MacParakeetCore

enum TranscriptExportFormat: String {
    case txt, md, srt, vtt, docx, pdf, json
}

@MainActor
enum TranscriptResultActions {
    static func copyText(_ text: String, source: TelemetryCopySource = .transcription) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Telemetry.send(.copyToClipboard(source: source))
    }

    static func exportPromptResultToDownloads(
        promptResult: PromptResult,
        source: Transcription,
        format: TranscriptExportFormat
    ) throws -> URL {
        let baseStem = TranscriptSegmenter.sanitizedExportStem(from: source.fileName)
        let promptNameSafe = promptResult.promptName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let promptComponent = promptNameSafe.isEmpty ? "result" : promptNameSafe
        let stem = "\(baseStem)-\(promptComponent)"

        let downloadsURL = try downloadsDirectory()
        let fileURL = nextAvailableURL(in: downloadsURL, stem: stem, format: format)

        try promptResult.content.write(to: fileURL, atomically: true, encoding: .utf8)
        Telemetry.send(.exportUsed(format: format.rawValue))
        return fileURL
    }

    static func exportTranscriptToDownloads(
        transcription: Transcription,
        format: TranscriptExportFormat
    ) throws -> URL {
        let stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        let downloadsURL = try downloadsDirectory()
        let fileURL = nextAvailableURL(in: downloadsURL, stem: stem, format: format)
        let exportService = ExportService()

        switch format {
        case .txt: try exportService.exportToTxt(transcription: transcription, url: fileURL)
        case .md: try exportService.exportToMarkdown(transcription: transcription, url: fileURL)
        case .srt: try exportService.exportToSRT(transcription: transcription, url: fileURL)
        case .vtt: try exportService.exportToVTT(transcription: transcription, url: fileURL)
        case .docx: try exportService.exportToDocx(transcription: transcription, url: fileURL)
        case .pdf: try exportService.exportToPDF(transcription: transcription, url: fileURL)
        case .json: try exportService.exportToJSON(transcription: transcription, url: fileURL)
        }

        Telemetry.send(.exportUsed(format: format.rawValue))
        return fileURL
    }

    private static func downloadsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func nextAvailableURL(
        in directory: URL,
        stem: String,
        format: TranscriptExportFormat
    ) -> URL {
        var url = directory.appendingPathComponent("\(stem).\(format.rawValue)")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem) (\(counter)).\(format.rawValue)")
            counter += 1
        }
        return url
    }
}
