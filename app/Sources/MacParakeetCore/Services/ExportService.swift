import Foundation

public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func formatForClipboard(transcription: Transcription) -> String
}

/// Handles exporting transcriptions to files and clipboard.
public final class ExportService: ExportServiceProtocol, Sendable {
    public init() {}

    /// Export transcription as plain text file
    public func exportToTxt(transcription: Transcription, url: URL) throws {
        let content = formatPlainText(transcription: transcription)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format transcription text for clipboard copy
    public func formatForClipboard(transcription: Transcription) -> String {
        transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
    }

    // MARK: - Private

    private func formatPlainText(transcription: Transcription) -> String {
        var lines: [String] = []

        // Header
        lines.append(transcription.fileName)
        if let durationMs = transcription.durationMs {
            lines.append("Duration: \(durationMs.formattedDuration)")
        }
        lines.append("")

        // Transcript
        if let text = transcription.rawTranscript ?? transcription.cleanTranscript {
            lines.append(text)
        }

        return lines.joined(separator: "\n")
    }

}
