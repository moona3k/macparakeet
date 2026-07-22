import AppKit
import Foundation
import MacParakeetCore

enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt, md, srt, vtt, dapt, docx, pdf, json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: "Text"
        case .md: "Markdown"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .dapt: "DAPT Transcript"
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
        case .dapt: "DAPT"
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
        case .dapt: "chevron.left.forwardslash.chevron.right"
        case .docx: "doc.richtext"
        case .pdf: "doc.viewfinder"
        case .json: "curlybraces"
        }
    }

    var supportsTranscriptOptions: Bool {
        self == .txt || self == .md
    }

    var usesAppKitRenderer: Bool {
        self == .docx || self == .pdf
    }

    var fileExtension: String {
        self == .dapt ? "dapt.xml" : rawValue
    }
}

struct BulkTranscriptExportResult: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let format: TranscriptExportFormat
    let requestedCount: Int
    let exportedURLs: [URL]
    let failedCount: Int
    let firstErrorDescription: String?

    var exportedCount: Int {
        exportedURLs.count
    }

    var isCompleteSuccess: Bool {
        requestedCount > 0 && failedCount == 0 && exportedCount == requestedCount
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
        do {
            let baseStem = TranscriptSegmenter.sanitizedExportStem(from: source.effectiveDisplayTitle)
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
        } catch {
            Telemetry.send(
                .exportFailed(
                    format: format.rawValue,
                    errorType: TelemetryErrorClassifier.classify(error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            throw error
        }
    }

    static func exportTranscriptToDownloads(
        transcription: Transcription,
        format: TranscriptExportFormat,
        options: TranscriptExportOptions = .default
    ) throws -> URL {
        do {
            let stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.effectiveDisplayTitle)
            let downloadsURL = try downloadsDirectory()
            let fileURL = nextAvailableURL(in: downloadsURL, stem: stem, format: format)
            try exportTranscript(transcription: transcription, format: format, options: options, to: fileURL)

            Telemetry.send(.exportUsed(format: format.rawValue))
            return fileURL
        } catch {
            Telemetry.send(
                .exportFailed(
                    format: format.rawValue,
                    errorType: TelemetryErrorClassifier.classify(error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            throw error
        }
    }

    nonisolated static func exportTranscriptsToDirectory(
        transcriptions: [Transcription],
        format: TranscriptExportFormat,
        options: TranscriptExportOptions = .default,
        directory: URL,
        onFileExported: (@Sendable (URL) async -> Void)? = nil
    ) async throws -> BulkTranscriptExportResult {
        try Task.checkCancellation()

        let accessedSecurityScope = directory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var exportedFiles: [CreatedExportFile] = []
        var failedCount = 0
        var firstErrorDescription: String?
        defer {
            if exportedFiles.isEmpty, !directoryExisted {
                removeEmptyDirectoryIfPresent(at: directory)
            }
        }

        do {
            let exportService = ExportService()
            for transcription in transcriptions {
                try Task.checkCancellation()
                await Task.yield()

                let stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.effectiveDisplayTitle)
                let fileURL = nextAvailableURL(in: directory, stem: stem, format: format)
                let resolvedOptions = resolvedOptions(
                    for: transcription,
                    format: format,
                    preferredOptions: options
                )

                do {
                    try await exportTranscriptForBulk(
                        transcription: transcription,
                        format: format,
                        options: resolvedOptions,
                        to: fileURL,
                        using: exportService
                    )
                    exportedFiles.append(CreatedExportFile(url: fileURL))
                    if let onFileExported {
                        await onFileExported(fileURL)
                    }
                } catch is CancellationError {
                    // Cancellation is not a per-item file failure — let it
                    // propagate out of the batch so the caller can stop cleanly.
                    throw CancellationError()
                } catch {
                    failedCount += 1
                    if firstErrorDescription == nil {
                        firstErrorDescription = error.localizedDescription
                    }
                }
            }
        } catch is CancellationError {
            removeCreatedFilesIfPresent(exportedFiles)
            if !directoryExisted {
                removeEmptyDirectoryIfPresent(at: directory)
            }
            throw CancellationError()
        }

        let exportedURLs = exportedFiles.map(\.url)
        if !exportedURLs.isEmpty {
            Telemetry.send(.exportUsed(format: format.rawValue))
        }
        if failedCount > 0 {
            Telemetry.send(
                .exportFailed(
                    format: format.rawValue,
                    errorType: exportedURLs.isEmpty ? "bulk_total_failure" : "bulk_partial_failure",
                    errorDetail: firstErrorDescription
                ))
        }

        return BulkTranscriptExportResult(
            directory: directory,
            format: format,
            requestedCount: transcriptions.count,
            exportedURLs: exportedURLs,
            failedCount: failedCount,
            firstErrorDescription: firstErrorDescription
        )
    }

    private static func downloadsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func exportTranscript(
        transcription: Transcription,
        format: TranscriptExportFormat,
        options: TranscriptExportOptions,
        to fileURL: URL
    ) throws {
        try exportTranscriptOnMainActor(
            transcription: transcription,
            format: format,
            options: options,
            to: fileURL,
            using: ExportService()
        )
    }

    nonisolated private static func exportTranscriptForBulk(
        transcription: Transcription,
        format: TranscriptExportFormat,
        options: TranscriptExportOptions,
        to fileURL: URL,
        using exportService: ExportService
    ) async throws {
        guard format.usesAppKitRenderer else {
            try exportNonAppKitTranscript(
                transcription: transcription,
                format: format,
                options: options,
                to: fileURL,
                using: exportService
            )
            return
        }

        // PDF/DOCX rendering uses AppKit. Hop per file instead of wrapping the
        // whole batch so cancellation and UI work can interleave between files.
        try await MainActor.run {
            try exportTranscriptOnMainActor(
                transcription: transcription,
                format: format,
                options: options,
                to: fileURL,
                using: exportService
            )
        }
    }

    @MainActor private static func exportTranscriptOnMainActor(
        transcription: Transcription,
        format: TranscriptExportFormat,
        options: TranscriptExportOptions,
        to fileURL: URL,
        using exportService: ExportService
    ) throws {
        switch format {
        case .docx: try exportService.exportToDocx(transcription: transcription, url: fileURL)
        case .pdf: try exportService.exportToPDF(transcription: transcription, url: fileURL)
        default:
            try exportNonAppKitTranscript(
                transcription: transcription,
                format: format,
                options: options,
                to: fileURL,
                using: exportService
            )
        }
    }

    nonisolated private static func exportNonAppKitTranscript(
        transcription: Transcription,
        format: TranscriptExportFormat,
        options: TranscriptExportOptions,
        to fileURL: URL,
        using exportService: ExportService
    ) throws {
        switch format {
        case .txt: try exportService.exportToTxt(transcription: transcription, url: fileURL, options: options)
        case .md: try exportService.exportToMarkdown(transcription: transcription, url: fileURL, options: options)
        case .srt: try exportService.exportToSRT(transcription: transcription, url: fileURL)
        case .vtt: try exportService.exportToVTT(transcription: transcription, url: fileURL)
        case .dapt: try exportService.exportToDAPT(transcription: transcription, url: fileURL)
        case .json: try exportService.exportToJSON(transcription: transcription, url: fileURL)
        case .docx, .pdf:
            preconditionFailure(
                "\(format.shortName) export must run on the main actor; this path should never be reached."
            )
        }
    }

    nonisolated private static func removeEmptyDirectoryIfPresent(at directory: URL) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            contents.isEmpty
        else {
            return
        }

        try? FileManager.default.removeItem(at: directory)
    }

    private struct CreatedExportFile: Sendable {
        let url: URL
        let cleanupIdentity: ExportedFileCleanupIdentity?

        init(url: URL) {
            self.url = url
            cleanupIdentity = Self.identity(for: url)
        }

        func isStillSameFile() -> Bool {
            guard let cleanupIdentity else { return false }
            return Self.identity(for: url) == cleanupIdentity
        }

        private static func identity(for url: URL) -> ExportedFileCleanupIdentity? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let identity = ExportedFileCleanupIdentity(
                systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                size: (attributes[.size] as? NSNumber)?.uint64Value,
                modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            )
            return identity.hasAnyValue ? identity : nil
        }
    }

    private struct ExportedFileCleanupIdentity: Equatable, Sendable {
        let systemNumber: UInt64?
        let fileNumber: UInt64?
        let size: UInt64?
        let modificationTime: TimeInterval?

        var hasAnyValue: Bool {
            systemNumber != nil || fileNumber != nil || size != nil || modificationTime != nil
        }
    }

    nonisolated private static func removeCreatedFilesIfPresent(_ files: [CreatedExportFile]) {
        for file in files where file.isStillSameFile() {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    nonisolated private static func resolvedOptions(
        for transcription: Transcription,
        format: TranscriptExportFormat,
        preferredOptions: TranscriptExportOptions
    ) -> TranscriptExportOptions {
        guard format.supportsTranscriptOptions else { return .default }
        let hasAlignedTimestamps = transcription.hasWordTimestamps && !transcription.isTranscriptEdited
        let hasSpeakerLabels = transcription.hasSpeakerLabeledWords && !transcription.isTranscriptEdited
        return preferredOptions.resolved(
            canIncludeTimestamps: hasAlignedTimestamps,
            canIncludeSpeakerLabels: hasSpeakerLabels
        )
    }

    nonisolated private static func nextAvailableURL(
        in directory: URL,
        stem: String,
        format: TranscriptExportFormat
    ) -> URL {
        var url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        return url
    }
}
