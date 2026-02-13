import Foundation

public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL) throws
    func exportToVTT(transcription: Transcription, url: URL) throws
    func exportToMarkdown(transcription: Transcription, url: URL) throws
    func formatSRT(words: [WordTimestamp]) -> String
    func formatVTT(words: [WordTimestamp]) -> String
    func formatMarkdown(transcription: Transcription) -> String
    func formatForClipboard(transcription: Transcription) -> String
}

/// Handles exporting transcriptions to files and clipboard.
public final class ExportService: ExportServiceProtocol, Sendable {
    public init() {}

    private func preferredText(transcription: Transcription) -> String {
        transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
    }

    /// Export transcription as plain text file
    public func exportToTxt(transcription: Transcription, url: URL) throws {
        let content = formatPlainText(transcription: transcription)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as SRT subtitle file
    public func exportToSRT(transcription: Transcription, url: URL) throws {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            // Fall back to full transcript as a single cue
            let text = preferredText(transcription: transcription)
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
            let text = preferredText(transcription: transcription)
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

    /// Export transcription as Markdown file
    public func exportToMarkdown(transcription: Transcription, url: URL) throws {
        let content = formatMarkdown(transcription: transcription)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format transcription as Markdown string
    public func formatMarkdown(transcription: Transcription) -> String {
        var lines: [String] = []

        // Title
        lines.append("# \(transcription.fileName)")
        lines.append("")

        // Metadata table
        var meta: [String] = []
        if let durationMs = transcription.durationMs {
            meta.append("**Duration:** \(durationMs.formattedDuration)")
        }
        if let sourceURL = transcription.sourceURL {
            meta.append("**Source:** [\(sourceURL)](\(sourceURL))")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        meta.append("**Transcribed:** \(formatter.string(from: transcription.createdAt))")
        if let language = transcription.language {
            meta.append("**Language:** \(language)")
        }

        if !meta.isEmpty {
            lines.append(contentsOf: meta)
            lines.append("")
        }

        lines.append("---")
        lines.append("")

        // Transcript body
        if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            let cues = buildSubtitleCues(from: timestamps)
            for cue in cues {
                let ts = formatReadableTimestamp(ms: cue.startMs)
                lines.append("**[\(ts)]** \(cue.text)")
                lines.append("")
            }
        } else {
            let text = preferredText(transcription: transcription)
            if !text.isEmpty {
                lines.append(text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format transcription text for clipboard copy
    public func formatForClipboard(transcription: Transcription) -> String {
        preferredText(transcription: transcription)
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

    /// Human-readable format: 1:23 or 1:01:23
    func formatReadableTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
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
        let text = preferredText(transcription: transcription)
        if !text.isEmpty {
            lines.append(text)
        }

        return lines.joined(separator: "\n")
    }
}
