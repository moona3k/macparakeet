import Foundation

public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL) throws
    func exportToVTT(transcription: Transcription, url: URL) throws
    func formatSRT(words: [WordTimestamp]) -> String
    func formatVTT(words: [WordTimestamp]) -> String
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

    /// Export transcription as SRT subtitle file
    public func exportToSRT(transcription: Transcription, url: URL) throws {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            // Fall back to full transcript as a single cue
            let text = transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
            let duration = transcription.durationMs ?? 0
            let content = "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(text)\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let content = formatSRT(words: words)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as WebVTT subtitle file
    public func exportToVTT(transcription: Transcription, url: URL) throws {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
            let duration = transcription.durationMs ?? 0
            let content = "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(text)\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let content = formatVTT(words: words)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format word timestamps as SRT subtitle string
    public func formatSRT(words: [WordTimestamp]) -> String {
        let cues = buildSubtitleCues(from: words)
        var lines: [String] = []
        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(ms: cue.startMs)) --> \(srtTimestamp(ms: cue.endMs))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Format word timestamps as WebVTT subtitle string
    public func formatVTT(words: [WordTimestamp]) -> String {
        let cues = buildSubtitleCues(from: words)
        var lines: [String] = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(vttTimestamp(ms: cue.startMs)) --> \(vttTimestamp(ms: cue.endMs))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Format transcription text for clipboard copy
    public func formatForClipboard(transcription: Transcription) -> String {
        transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
    }

    // MARK: - Subtitle Cue Building

    struct SubtitleCue {
        let startMs: Int
        let endMs: Int
        let text: String
    }

    /// Groups word timestamps into subtitle cues suitable for SRT/VTT.
    /// Rules: max ~12 words per cue, break on sentence-ending punctuation,
    /// break on long pauses (>800ms), max ~7 seconds per cue.
    func buildSubtitleCues(from words: [WordTimestamp]) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        var currentWords: [String] = []
        var cueStartMs = words[0].startMs
        var cueEndMs = words[0].endMs

        for (i, word) in words.enumerated() {
            currentWords.append(word.word)
            cueEndMs = word.endMs

            let isLast = i == words.count - 1
            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = !isLast && (words[i + 1].startMs - word.endMs) > 800
            let tooManyWords = currentWords.count >= 12
            let tooLong = (cueEndMs - cueStartMs) > 7000

            if isLast || (endsWithPunctuation && currentWords.count >= 2) || hasLongGap || tooManyWords || tooLong {
                cues.append(SubtitleCue(
                    startMs: cueStartMs,
                    endMs: cueEndMs,
                    text: currentWords.joined(separator: " ")
                ))
                currentWords = []
                if !isLast {
                    cueStartMs = words[i + 1].startMs
                }
            }
        }

        return cues
    }

    // MARK: - Timestamp Formatting

    /// SRT format: 00:01:23,456
    func srtTimestamp(ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// VTT format: 00:01:23.456
    func vttTimestamp(ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    // MARK: - Plain Text

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
