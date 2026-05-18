import AppKit
import Foundation
import MacParakeetCore

enum TranscriptExportFormat: String, CaseIterable, Identifiable {
    case txt, md, srt, vtt, docx, pdf, json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: "Text"
        case .md: "Markdown"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .docx: "Word Document"
        case .pdf: "PDF"
        case .json: "JSON"
        }
    }

    var shortName: String {
        switch self {
        case .txt: "Text"
        case .md: "Markdown"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .docx: "DOCX"
        case .pdf: "PDF"
        case .json: "JSON"
        }
    }

    var iconName: String {
        switch self {
        case .txt: "doc.text"
        case .md: "text.document"
        case .srt: "captions.bubble"
        case .vtt: "captions.bubble.fill"
        case .docx: "doc.richtext"
        case .pdf: "doc.viewfinder"
        case .json: "curlybraces"
        }
    }

    var supportsTranscriptOptions: Bool {
        self == .txt || self == .md
    }

    var isSubtitleFormat: Bool {
        self == .srt || self == .vtt
    }
}

/// Persisted export UI state (format + caption options).
enum TranscriptExportPreferences {
    private static let optionsKey = "transcriptExportOptions"
    private static let optionsVersionKey = "transcriptExportOptionsVersion"
    private static let lastFormatKey = "lastTranscriptExportFormat"
    /// Bump when export defaults change so saved prefs migrate once.
    private static let currentOptionsVersion = 3

    static func loadOptions() -> TranscriptExportOptions {
        if let string = UserDefaults.standard.string(forKey: optionsKey),
           var options = TranscriptExportOptions(rawValue: string) {
            if UserDefaults.standard.integer(forKey: optionsVersionKey) < currentOptionsVersion {
                options.includeSpeakerLabels = false
                saveOptions(options)
                UserDefaults.standard.set(currentOptionsVersion, forKey: optionsVersionKey)
            }
            return options
        }
        UserDefaults.standard.set(currentOptionsVersion, forKey: optionsVersionKey)
        return .default
    }

    static func saveOptions(_ options: TranscriptExportOptions) {
        UserDefaults.standard.set(options.rawValue, forKey: optionsKey)
        UserDefaults.standard.set(currentOptionsVersion, forKey: optionsVersionKey)
    }

    static func loadLastFormat() -> TranscriptExportFormat? {
        guard let raw = UserDefaults.standard.string(forKey: lastFormatKey) else { return nil }
        return TranscriptExportFormat(rawValue: raw)
    }

    static func saveLastFormat(_ format: TranscriptExportFormat) {
        UserDefaults.standard.set(format.rawValue, forKey: lastFormatKey)
    }
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
        format: TranscriptExportFormat,
        options: TranscriptExportOptions = .default
    ) throws -> URL {
        let stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        let downloadsURL = try downloadsDirectory()
        let fileURL = nextAvailableURL(in: downloadsURL, stem: stem, format: format)
        let exportService = ExportService()

        switch format {
        case .txt: try exportService.exportToTxt(transcription: transcription, url: fileURL, options: options)
        case .md: try exportService.exportToMarkdown(transcription: transcription, url: fileURL, options: options)
        case .srt:
            try exportService.exportToSRT(
                transcription: transcription,
                url: fileURL,
                config: options.subtitleConfig,
                includeSpeakerLabels: options.includeSpeakerLabels
            )
        case .vtt:
            try exportService.exportToVTT(
                transcription: transcription,
                url: fileURL,
                config: options.subtitleConfig,
                includeSpeakerLabels: options.includeSpeakerLabels
            )
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
