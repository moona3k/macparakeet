import Foundation
import AppKit

@MainActor
public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL) throws
    func exportToVTT(transcription: Transcription, url: URL) throws
    func exportToMarkdown(transcription: Transcription, url: URL) throws
    func exportToJSON(transcription: Transcription, url: URL) throws
    @MainActor func exportToPDF(transcription: Transcription, url: URL) throws
    @MainActor func exportToDocx(transcription: Transcription, url: URL) throws
    func formatSRT(transcription: Transcription) -> String
    func formatVTT(transcription: Transcription) -> String
    func formatSRT(words: [WordTimestamp], speakers: [SpeakerInfo]?) -> String
    func formatVTT(words: [WordTimestamp], speakers: [SpeakerInfo]?) -> String
    func formatMarkdown(transcription: Transcription) -> String
    func formatForClipboard(transcription: Transcription) -> String
}

public struct TranscriptExportOptions: Sendable, Equatable {
    public var includeTimestamps: Bool
    public var includeSpeakerLabels: Bool
    public var includeMetadata: Bool

    public init(
        includeTimestamps: Bool = true,
        includeSpeakerLabels: Bool = true,
        includeMetadata: Bool = true
    ) {
        self.includeTimestamps = includeTimestamps
        self.includeSpeakerLabels = includeSpeakerLabels
        self.includeMetadata = includeMetadata
    }

    public static let `default` = TranscriptExportOptions()
}

/// Handles exporting transcriptions to files and clipboard.
/// @MainActor because PDF/DOCX paths use NSTextStorage/NSLayoutManager (AppKit, not thread-safe).
@MainActor
public final class ExportService: ExportServiceProtocol, Sendable {
    public init() {}

    private func preferredText(transcription: Transcription) -> String {
        transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
    }

    private func editedTranscriptText(transcription: Transcription) -> String? {
        guard transcription.isTranscriptEdited,
              let text = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private func singleCueSubtitleText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Export transcription as plain text file
    public func exportToTxt(transcription: Transcription, url: URL) throws {
        try exportToTxt(transcription: transcription, url: url, options: .default)
    }

    public func exportToTxt(
        transcription: Transcription,
        url: URL,
        options: TranscriptExportOptions
    ) throws {
        let content = formatPlainText(transcription: transcription, options: options)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as SRT subtitle file
    public func exportToSRT(transcription: Transcription, url: URL) throws {
        try formatSRT(transcription: transcription).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as WebVTT subtitle file
    public func exportToVTT(transcription: Transcription, url: URL) throws {
        try formatVTT(transcription: transcription).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format a transcription as SRT, falling back to one full-transcript cue.
    public func formatSRT(transcription: Transcription) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatSRT(words: words, speakers: transcription.speakers)
    }

    /// Format a transcription as WebVTT, falling back to one full-transcript cue.
    public func formatVTT(transcription: Transcription) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatVTT(words: words, speakers: transcription.speakers)
    }

    /// Export transcription as JSON file
    public func exportToJSON(transcription: Transcription, url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcription)
        try data.write(to: url)
    }

    /// Export transcription as PDF file using Core Graphics PDF context.
    /// Avoids NSPrintOperation which spins a modal run loop and deadlocks
    /// when called from SwiftUI button actions on MainActor.
    /// Must be called on MainActor (uses NSTextStorage, NSLayoutManager, NSGraphicsContext).
    @MainActor public func exportToPDF(transcription: Transcription, url: URL) throws {
        let attrString = try buildRichTranscript(transcription: transcription)

        // US Letter with 1-inch margins
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 72
        let textWidth = pageWidth - margin * 2
        let textHeight = pageHeight - margin * 2

        // Layout the attributed string using a temporary text container
        let textStorage = NSTextStorage(attributedString: attrString)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        defer {
            layoutManager.removeTextContainer(at: 0)
            textStorage.removeLayoutManager(layoutManager)
        }

        // Force full layout
        layoutManager.ensureLayout(for: textContainer)
        let totalHeight = layoutManager.usedRect(for: textContainer).height

        // Create PDF context
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "MacParakeetError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF context"])
        }

        defer { context.closePDF() }

        // Draw pages
        var yOffset: CGFloat = 0
        while yOffset < totalHeight {
            context.beginPage(mediaBox: &mediaBox)

            // Determine the glyph range that fits this page
            let pageRect = NSRect(x: 0, y: yOffset, width: textWidth, height: textHeight)
            let glyphRange = layoutManager.glyphRange(forBoundingRect: pageRect, in: textContainer)

            // Save graphics state, set up coordinate system for this page.
            // We flip the CGContext so y goes top-down (needed for pagination math)
            // and tell NSGraphicsContext it's flipped so AppKit draws glyphs upright.
            let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext

            context.translateBy(x: margin, y: pageHeight - margin)
            context.scaleBy(x: 1, y: -1)

            // Offset for current page slice
            let drawOrigin = NSPoint(x: 0, y: -yOffset)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: drawOrigin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: drawOrigin)

            NSGraphicsContext.restoreGraphicsState()
            context.endPage()

            yOffset += textHeight
        }
    }

    /// Export transcription as DOCX file
    @MainActor public func exportToDocx(transcription: Transcription, url: URL) throws {
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
        try exportToMarkdown(transcription: transcription, url: url, options: .default)
    }

    public func exportToMarkdown(
        transcription: Transcription,
        url: URL,
        options: TranscriptExportOptions
    ) throws {
        let content = formatMarkdown(transcription: transcription, options: options)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format transcription as Markdown string
    public func formatMarkdown(transcription: Transcription) -> String {
        formatMarkdown(transcription: transcription, options: .default)
    }

    public func formatMarkdown(transcription: Transcription, options: TranscriptExportOptions) -> String {
        var lines: [String] = []

        if options.includeMetadata {
            lines.append("# \(transcription.fileName)")
            lines.append("")

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
        }

        if let text = editedTranscriptText(transcription: transcription) {
            lines.append(text)
            lines.append("")
        } else if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            let cues = buildSubtitleCues(from: timestamps)
            if options.includeTimestamps || options.includeSpeakerLabels {
                if options.includeTimestamps {
                    var lastSpeakerId: String? = nil
                    for cue in cues {
                        if options.includeSpeakerLabels,
                           let label = speakerLabel(for: cue.speakerId, in: transcription.speakers),
                           cue.speakerId != lastSpeakerId {
                            lines.append("**\(label)**")
                            lines.append("")
                        }
                        lastSpeakerId = cue.speakerId

                        let ts = formatReadableTimestamp(ms: cue.startMs)
                        lines.append("**[\(ts)]** \(cue.text)")
                        lines.append("")
                    }
                } else {
                    for paragraph in speakerParagraphs(from: cues, speakers: transcription.speakers) {
                        if let label = paragraph.label {
                            lines.append("**\(label)**")
                            lines.append("")
                        }
                        lines.append(paragraph.text)
                        lines.append("")
                    }
                }
            } else {
                let text = preferredText(transcription: transcription)
                lines.append(text.isEmpty ? cues.map(\.text).joined(separator: " ") : text)
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

    public struct SubtitleCue: Sendable {
        public let startMs: Int
        public let endMs: Int
        public let text: String
        public let speakerId: String?
    }

    /// Groups word timestamps into subtitle cues suitable for SRT/VTT and overlay display.
    /// Rules: max ~12 words per cue, break on sentence-ending punctuation,
    /// break on long pauses (>800ms), max ~7 seconds per cue, break on speaker change.
    // Subordinating conjunctions and relative pronouns that open a new dependent clause.
    // Breaking before these words produces more natural subtitle boundaries than breaking
    // mid-clause at an arbitrary character limit.
    private static let clauseStarters: Set<String> = [
        "because", "although", "since", "while", "whereas",
        "unless", "until", "though", "who", "which", "where", "when"
    ]

    // Words that should not END a cue (conjunctions, articles, common prepositions).
    // Leaving these as the last word produces a dangling cue that hurts readability.
    private static let badEnders: Set<String> = [
        "and", "but", "or", "so", "yet", "nor", "for",
        "the", "a", "an",
        "in", "on", "at", "to", "of", "with", "from", "by"
    ]

    // Hard caps used by bad-ender deferral. We are willing to push past the soft 12/7000
    // limits to avoid a bad ending, but not arbitrarily — these caps bound the overshoot.
    private static let hardWordCap = 14
    private static let hardDurationMs = 8000

    // Total character budget for a single-line cue. Cues beyond this are wrapped into two
    // balanced lines via wrapLongCues. Matches the common SRT/VTT safe width.
    private static let maxLineChars = 42

    public func buildSubtitleCues(from words: [WordTimestamp]) -> [SubtitleCue] {
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

            // Break before a subordinating conjunction or relative pronoun that opens a
            // new dependent clause — but only after at least 4 words have accumulated so
            // we don't produce single-word cues.
            let nextIsClauseStart = !isLast
                && currentWords.count >= 4
                && Self.clauseStarters.contains(
                    words[i + 1].word.lowercased().trimmingCharacters(in: .punctuationCharacters))

            // Bad-ender deferral: if this break is only fired by a soft size limit
            // (word count or duration) and the current word is in badEnders, defer the
            // break by one iteration so we don't leave a dangling conjunction/article/
            // preposition at the end of the cue. Bounded by hard caps to avoid runaway.
            let semanticTrigger = (endsWithPunctuation && currentWords.count >= 2)
                || nextIsClauseStart
            let hardTrigger = isLast || hasLongGap
            let softTrigger = tooManyWords || tooLong
            let lastWordKey = word.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isBadEnder = Self.badEnders.contains(lastWordKey)
            let underHardCap = currentWords.count < Self.hardWordCap
                && (cueEndMs - cueStartMs) < Self.hardDurationMs
            let deferForBadEnder = softTrigger
                && !hardTrigger
                && !semanticTrigger
                && isBadEnder
                && underHardCap

            if (isLast || semanticTrigger || hardTrigger || softTrigger) && !deferForBadEnder {
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

        // Enforce reading speed: split cues that exceed 25 CPS, then wrap long cues
        // into two balanced lines for clean SRT/VTT display.
        let paced = enforceReadingSpeed(cues, words: words)
        return wrapLongCues(paced)
    }

    /// Split cues whose text/duration ratio exceeds maxCPS characters per second.
    /// 25 CPS is the safety threshold — the Netflix/BBC guideline is 17 CPS, but that
    /// standard is for display time compliance tools; 25 catches genuinely unreadable
    /// cues without false-positiving on fast-but-readable speech. Cues that can't be
    /// cleanly split (≤ 2 words) are left untouched.
    private func enforceReadingSpeed(_ cues: [SubtitleCue], words: [WordTimestamp], maxCPS: Double = 25.0) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        // Walk words with a single forward index — both cues and words are chronological,
        // so we never need to scan the whole array per cue (O(N) overall).
        var wordIdx = 0
        for cue in cues {
            let durationSec = Double(cue.endMs - cue.startMs) / 1000.0
            guard durationSec > 0.1 else { result.append(cue); continue }

            let cps = Double(cue.text.count) / durationSec
            guard cps > maxCPS else { result.append(cue); continue }

            // Advance past words that precede this cue.
            while wordIdx < words.count && words[wordIdx].startMs < cue.startMs {
                wordIdx += 1
            }
            // Collect words that belong to this cue (same speaker, within time range).
            var cueWords: [WordTimestamp] = []
            var scanIdx = wordIdx
            while scanIdx < words.count && words[scanIdx].endMs <= cue.endMs {
                let w = words[scanIdx]
                if w.speakerId == cue.speakerId { cueWords.append(w) }
                scanIdx += 1
            }
            guard cueWords.count > 2 else { result.append(cue); continue }

            // Score every candidate split index and pick the linguistically best.
            let splitIdx = bestSplitIndex(in: cueWords)
            let firstHalf = cueWords[0..<splitIdx]
            let secondHalf = cueWords[splitIdx...]

            result.append(SubtitleCue(
                startMs: cue.startMs,
                endMs: firstHalf.last!.endMs,
                text: firstHalf.map(\.word).joined(separator: " "),
                speakerId: cue.speakerId
            ))
            result.append(SubtitleCue(
                startMs: secondHalf.first!.startMs,
                endMs: cue.endMs,
                text: secondHalf.map(\.word).joined(separator: " "),
                speakerId: cue.speakerId
            ))
        }
        return result
    }

    /// Score each candidate split index `i` (meaning words[0..<i] | words[i...]) and
    /// return the best one. Favours linguistic boundaries: real punctuation, clause
    /// starters, capitalised words; penalises ending on conjunctions/articles. Distance
    /// from midpoint is a small tiebreaker so two equally-good splits prefer the balanced
    /// one. Falls back to the midpoint if no candidate scores above zero.
    private func bestSplitIndex(in cueWords: [WordTimestamp]) -> Int {
        let mid = cueWords.count / 2
        var bestIdx = mid
        var bestScore = Int.min
        // Valid splits: 1...(count-1) so both halves have at least one word.
        for i in 1..<cueWords.count {
            let prevWord = cueWords[i - 1].word
            let nextWord = cueWords[i].word
            let prevKey = prevWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let nextKey = nextWord.lowercased().trimmingCharacters(in: .punctuationCharacters)

            var score = 0
            if let last = prevWord.last, ".!?".contains(last) { score += 3 }
            if let last = prevWord.last, ",;:".contains(last) { score += 2 }
            if Self.clauseStarters.contains(nextKey) { score += 2 }
            if let first = nextWord.first, first.isUppercase { score += 1 }
            if Self.badEnders.contains(prevKey) { score -= 2 }
            // Distance penalty: -1 per word away from midpoint (tiebreaker).
            score -= abs(i - mid)

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        // If every candidate scored ≤ 0 purely from the distance penalty, fall back
        // to the midpoint — anything else is just a less-balanced version of the same.
        return bestScore > -cueWords.count ? bestIdx : mid
    }

    /// Wrap cues whose text exceeds maxLineChars into two balanced lines separated by `\n`.
    /// Picks the word boundary closest to the character midpoint, with a small bonus for
    /// splits immediately after a comma or before a clause starter. Cues that fit on one
    /// line pass through unchanged.
    private func wrapLongCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            guard cue.text.count > Self.maxLineChars else { return cue }
            let tokens = cue.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { return cue }

            let totalLen = cue.text.count
            let targetLen = totalLen / 2

            // Build prefix character lengths so we can score each split point.
            var prefixLen = 0
            var bestIdx = tokens.count / 2
            var bestScore = Int.min
            for i in 1..<tokens.count {
                prefixLen += tokens[i - 1].count + (i == 1 ? 0 : 1) // +1 for the joining space, except the first hop
                let firstLen = prefixLen
                let secondLen = totalLen - prefixLen - 1 // -1 for the space replaced by \n
                let prevToken = tokens[i - 1]
                let nextToken = tokens[i]
                let nextKey = nextToken.lowercased().trimmingCharacters(in: .punctuationCharacters)

                // Distance from target (lower is better).
                var score = -abs(firstLen - targetLen)
                if let last = prevToken.last, ",;:".contains(last) { score += 4 }
                if Self.clauseStarters.contains(nextKey) { score += 3 }
                // Discourage splits that leave one side wildly oversized.
                if firstLen > Self.maxLineChars || secondLen > Self.maxLineChars { score -= 2 }

                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }

            let firstLine = tokens[0..<bestIdx].joined(separator: " ")
            let secondLine = tokens[bestIdx...].joined(separator: " ")
            return SubtitleCue(
                startMs: cue.startMs,
                endMs: cue.endMs,
                text: "\(firstLine)\n\(secondLine)",
                speakerId: cue.speakerId
            )
        }
    }

    /// Resolve a speakerId to a display label using the speakers mapping.
    /// Returns nil if speakerId is nil or speakers mapping is nil (no diarization).
    func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId, let speakers, !speakers.isEmpty else { return nil }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
    }

    // MARK: - Timestamp Formatting

    /// SRT format: 00:01:23,456
    func srtTimestamp(ms: Int) -> String {
        let ms = max(0, ms)
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// VTT format: 00:01:23.456
    func vttTimestamp(ms: Int) -> String {
        let ms = max(0, ms)
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

    public func formatPlainText(transcription: Transcription, options: TranscriptExportOptions = .default) -> String {
        var lines: [String] = []

        if options.includeMetadata {
            lines.append(transcription.fileName)
            if let durationMs = transcription.durationMs {
                lines.append("Duration: \(durationMs.formattedDuration)")
            }
            lines.append("")
        }

        if let text = editedTranscriptText(transcription: transcription) {
            lines.append(text)
        } else if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            let cues = buildSubtitleCues(from: timestamps)
            if options.includeTimestamps || options.includeSpeakerLabels {
                if options.includeTimestamps {
                    var lastSpeakerId: String? = nil
                    for cue in cues {
                        if options.includeSpeakerLabels,
                           let label = speakerLabel(for: cue.speakerId, in: transcription.speakers),
                           cue.speakerId != lastSpeakerId {
                            if !lines.isEmpty, lines.last != "" {
                                lines.append("")
                            }
                            lines.append("\(label):")
                        }
                        lastSpeakerId = cue.speakerId

                        lines.append("[\(formatReadableTimestamp(ms: cue.startMs))] \(cue.text)")
                    }
                } else {
                    for paragraph in speakerParagraphs(from: cues, speakers: transcription.speakers) {
                        if let label = paragraph.label {
                            if !lines.isEmpty, lines.last != "" {
                                lines.append("")
                            }
                            lines.append("\(label):")
                        }
                        lines.append(paragraph.text)
                    }
                }
            } else {
                let text = preferredText(transcription: transcription)
                lines.append(text.isEmpty ? cues.map(\.text).joined(separator: " ") : text)
            }
        } else {
            let text = preferredText(transcription: transcription)
            if !text.isEmpty {
                lines.append(text)
            }
        }

        return lines.joined(separator: "\n")
    }

    private struct SpeakerParagraph {
        var speakerId: String?
        var label: String?
        var text: String
    }

    private func speakerParagraphs(from cues: [SubtitleCue], speakers: [SpeakerInfo]?) -> [SpeakerParagraph] {
        var paragraphs: [SpeakerParagraph] = []
        for cue in cues {
            let label = speakerLabel(for: cue.speakerId, in: speakers)
            if let last = paragraphs.indices.last,
               paragraphs[last].speakerId == cue.speakerId {
                paragraphs[last].text += " \(cue.text)"
            } else {
                paragraphs.append(SpeakerParagraph(
                    speakerId: cue.speakerId,
                    label: label,
                    text: cue.text
                ))
            }
        }
        return paragraphs
    }

    // MARK: - Rich Text (AppKit)

    @MainActor private func buildRichTranscript(transcription: Transcription) throws -> NSAttributedString {
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
        if let text = editedTranscriptText(transcription: transcription) {
            result.append(NSAttributedString(string: text, attributes: [.font: bodyFont]))
        } else if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
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

    func pdfPageTextTransform(pageHeight: CGFloat, margin: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: margin, y: pageHeight - margin)
            .scaledBy(x: 1, y: -1)
    }
}
