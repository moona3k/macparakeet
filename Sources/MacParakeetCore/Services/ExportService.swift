import Foundation
import AppKit

public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL) throws
    func exportToVTT(transcription: Transcription, url: URL) throws
    func exportToMarkdown(transcription: Transcription, url: URL) throws
    func exportToJSON(transcription: Transcription, url: URL) throws
    func exportToPDF(transcription: Transcription, url: URL) throws
    func exportToDocx(transcription: Transcription, url: URL) throws
    func formatSRT(words: [WordTimestamp], speakers: [SpeakerInfo]?) -> String
    func formatVTT(words: [WordTimestamp], speakers: [SpeakerInfo]?) -> String
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
        let content = formatSRT(words: words, speakers: transcription.speakers)
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
        let content = formatVTT(words: words, speakers: transcription.speakers)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as JSON file
    public func exportToJSON(transcription: Transcription, url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcription)
        try data.write(to: url)
    }

    /// Export transcription as PDF file
    public func exportToPDF(transcription: Transcription, url: URL) throws {
        let attrString = try buildRichTranscript(transcription: transcription)
        
        // On macOS, the easiest way to generate a PDF from an attributed string 
        // without a visible window is using a print operation to a PDF destination.
        // This must be run on the main thread because of AppKit.
        try MainActor.assumeIsolated {
            let printInfo = NSPrintInfo.shared
            printInfo.jobDisposition = .save
            printInfo.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)
            
            // Create a view to host the text for printing
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
            textView.textStorage?.setAttributedString(attrString)
            
            let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
            printOp.showsPrintPanel = false
            printOp.showsProgressPanel = false
            
            if !printOp.run() {
                throw NSError(domain: "MacParakeetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PDF"])
            }
        }
    }

    /// Export transcription as DOCX file
    public func exportToDocx(transcription: Transcription, url: URL) throws {
        let attrString = try buildRichTranscript(transcription: transcription)
        let range = NSRange(location: 0, length: attrString.length)
        
        let data = try attrString.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: url)
    }

    /// Format word timestamps as SRT subtitle string
    public func formatSRT(words: [WordTimestamp], speakers: [SpeakerInfo]? = nil) -> String {
        let cues = buildSubtitleCues(from: words)
        var lines: [String] = []
        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(ms: cue.startMs)) --> \(srtTimestamp(ms: cue.endMs))")
            if let label = speakerLabel(for: cue.speakerId, in: speakers) {
                lines.append("\(label): \(cue.text)")
            } else {
                lines.append(cue.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Format word timestamps as WebVTT subtitle string
    public func formatVTT(words: [WordTimestamp], speakers: [SpeakerInfo]? = nil) -> String {
        let cues = buildSubtitleCues(from: words)
        var lines: [String] = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(vttTimestamp(ms: cue.startMs)) --> \(vttTimestamp(ms: cue.endMs))")
            if let label = speakerLabel(for: cue.speakerId, in: speakers) {
                lines.append("<v \(label)>\(cue.text)</v>")
            } else {
                lines.append(cue.text)
            }
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
            var lastSpeakerId: String? = nil
            for cue in cues {
                let ts = formatReadableTimestamp(ms: cue.startMs)
                if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers),
                   cue.speakerId != lastSpeakerId {
                    lines.append("**\(label)**")
                    lines.append("")
                }
                lastSpeakerId = cue.speakerId
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
        let speakerId: String?
    }

    /// Groups word timestamps into subtitle cues suitable for SRT/VTT.
    /// Rules: max ~12 words per cue, break on sentence-ending punctuation,
    /// break on long pauses (>800ms), max ~7 seconds per cue, break on speaker change.
    func buildSubtitleCues(from words: [WordTimestamp]) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        var currentWords: [String] = []
        var cueStartMs = words[0].startMs
        var cueEndMs = words[0].endMs
        var cueSpeakerId = words[0].speakerId

        for (i, word) in words.enumerated() {
            // Break on speaker change before adding the word
            let speakerChanged = !currentWords.isEmpty && word.speakerId != cueSpeakerId
            if speakerChanged {
                cues.append(SubtitleCue(
                    startMs: cueStartMs,
                    endMs: cueEndMs,
                    text: currentWords.joined(separator: " "),
                    speakerId: cueSpeakerId
                ))
                currentWords = []
                cueStartMs = word.startMs
                cueSpeakerId = word.speakerId
            }

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
                    text: currentWords.joined(separator: " "),
                    speakerId: cueSpeakerId
                ))
                currentWords = []
                if !isLast {
                    cueStartMs = words[i + 1].startMs
                    cueSpeakerId = words[i + 1].speakerId
                }
            }
        }

        return cues
    }

    /// Resolve a speakerId to a display label using the speakers mapping.
    /// Returns nil if speakerId is nil or speakers mapping is nil (no diarization).
    func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId, let speakers else { return nil }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
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

        // Transcript with speaker labels at turn changes
        if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty,
           transcription.speakers != nil {
            let cues = buildSubtitleCues(from: timestamps)
            var lastSpeakerId: String? = nil
            for cue in cues {
                if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers),
                   cue.speakerId != lastSpeakerId {
                    lines.append("")
                    lines.append("\(label):")
                }
                lastSpeakerId = cue.speakerId
                lines.append(cue.text)
            }
        } else {
            let text = preferredText(transcription: transcription)
            if !text.isEmpty {
                lines.append(text)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Rich Text (AppKit)

    private func buildRichTranscript(transcription: Transcription) throws -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.boldSystemFont(ofSize: 24)
        let headerFont = NSFont.boldSystemFont(ofSize: 14)
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let timestampFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        // Title
        result.append(NSAttributedString(string: transcription.fileName + "\n\n", attributes: [.font: titleFont]))

        // Metadata
        var metaLines: [String] = []
        if let durationMs = transcription.durationMs {
            metaLines.append("Duration: \(durationMs.formattedDuration)")
        }
        if let sourceURL = transcription.sourceURL {
            metaLines.append("Source: \(sourceURL)")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        metaLines.append("Transcribed: \(formatter.string(from: transcription.createdAt))")
        
        if !metaLines.isEmpty {
            let metaText = metaLines.joined(separator: "\n") + "\n\n"
            result.append(NSAttributedString(string: metaText, attributes: [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }

        // Horizontal line equivalent
        result.append(NSAttributedString(string: "----------------------------------------------------------\n\n", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))

        // Content
        if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            let cues = buildSubtitleCues(from: timestamps)
            var lastSpeakerId: String? = nil
            for cue in cues {
                if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers),
                   cue.speakerId != lastSpeakerId {
                    let speakerAttr = NSAttributedString(string: "\(label)\n", attributes: [.font: headerFont, .foregroundColor: NSColor.labelColor])
                    result.append(speakerAttr)
                }
                lastSpeakerId = cue.speakerId

                let ts = "[" + formatReadableTimestamp(ms: cue.startMs) + "] "
                let attrTs = NSAttributedString(string: ts, attributes: [.font: timestampFont, .foregroundColor: NSColor.secondaryLabelColor])
                result.append(attrTs)

                let attrText = NSAttributedString(string: cue.text + "\n\n", attributes: [.font: bodyFont])
                result.append(attrText)
            }
        } else {
            let text = preferredText(transcription: transcription)
            result.append(NSAttributedString(string: text, attributes: [.font: bodyFont]))
        }

        return result
    }
}
