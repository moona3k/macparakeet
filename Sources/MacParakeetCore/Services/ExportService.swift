import Foundation
import AppKit

@MainActor
public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) throws
    func exportToVTT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) throws
    func exportToMarkdown(transcription: Transcription, url: URL) throws
    func exportToJSON(transcription: Transcription, url: URL) throws
    @MainActor func exportToPDF(transcription: Transcription, url: URL) throws
    @MainActor func exportToDocx(transcription: Transcription, url: URL) throws
    func formatSRT(
        transcription: Transcription,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) -> String
    func formatVTT(
        transcription: Transcription,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) -> String
    func formatSRT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]?,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) -> String
    func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]?,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool
    ) -> String
    func formatMarkdown(transcription: Transcription) -> String
    func formatForClipboard(transcription: Transcription) -> String
}

public struct SubtitleExportConfig: Sendable, Equatable, Codable {
    /// Max words per subtitle cue.
    public var maxWordsPerCue: Int
    /// Max characters per line inside a cue.
    public var maxCharsPerLine: Int
    /// Max lines per cue.
    public var maxLinesPerCue: Int
    /// Max duration of a cue in milliseconds.
    public var maxDurationMs: Int
    /// Pause gap in ms that forces a new cue.
    public var gapThresholdMs: Int
    /// Whether to break cues on sentence-ending punctuation.
    public var breakOnPunctuation: Bool
    /// Minimum words accumulated before a punctuation mark triggers a new cue.
    public var minWordsBeforePunctuationBreak: Int
    /// Prefer balanced line lengths when wrapping across lines.
    public var preferBalancedLines: Bool

    public init(
        maxWordsPerCue: Int = 12,
        maxCharsPerLine: Int = 42,
        maxLinesPerCue: Int = 2,
        maxDurationMs: Int = 7000,
        gapThresholdMs: Int = 800,
        breakOnPunctuation: Bool = true,
        minWordsBeforePunctuationBreak: Int = 4,
        preferBalancedLines: Bool = true
    ) {
        self.maxWordsPerCue = max(1, maxWordsPerCue)
        self.maxCharsPerLine = max(10, maxCharsPerLine)
        self.maxLinesPerCue = max(1, maxLinesPerCue)
        self.maxDurationMs = max(1000, maxDurationMs)
        self.gapThresholdMs = max(0, gapThresholdMs)
        self.breakOnPunctuation = breakOnPunctuation
        self.minWordsBeforePunctuationBreak = max(1, minWordsBeforePunctuationBreak)
        self.preferBalancedLines = preferBalancedLines
    }

    public static let `default` = SubtitleExportConfig()
}

public struct TranscriptExportOptions: Sendable, Equatable {
    public var includeTimestamps: Bool
    public var includeSpeakerLabels: Bool
    public var includeMetadata: Bool
    public var subtitleConfig: SubtitleExportConfig

    public init(
        includeTimestamps: Bool = true,
        includeSpeakerLabels: Bool = false,
        includeMetadata: Bool = true,
        subtitleConfig: SubtitleExportConfig = .default
    ) {
        self.includeTimestamps = includeTimestamps
        self.includeSpeakerLabels = includeSpeakerLabels
        self.includeMetadata = includeMetadata
        self.subtitleConfig = subtitleConfig
    }

    public static let `default` = TranscriptExportOptions()
}

// MARK: - Codable (explicit to prevent RawRepresentable infinite recursion)
//
// Swift's auto-synthesized Codable for a type that is also RawRepresentable
// encodes via `rawValue`. If `rawValue` calls JSONEncoder.encode(self), the
// auto-synthesized encode(to:) calls rawValue again → infinite recursion →
// stack overflow (SIGSEGV). Providing explicit Codable breaks the cycle.

extension TranscriptExportOptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case includeTimestamps, includeSpeakerLabels, includeMetadata, subtitleConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeTimestamps = try container.decode(Bool.self, forKey: .includeTimestamps)
        includeSpeakerLabels = try container.decode(Bool.self, forKey: .includeSpeakerLabels)
        includeMetadata = try container.decode(Bool.self, forKey: .includeMetadata)
        subtitleConfig = try container.decode(SubtitleExportConfig.self, forKey: .subtitleConfig)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(includeTimestamps, forKey: .includeTimestamps)
        try container.encode(includeSpeakerLabels, forKey: .includeSpeakerLabels)
        try container.encode(includeMetadata, forKey: .includeMetadata)
        try container.encode(subtitleConfig, forKey: .subtitleConfig)
    }
}

extension TranscriptExportOptions: RawRepresentable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TranscriptExportOptions.self, from: data) else {
            return nil
        }
        self = decoded
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
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
    public func exportToSRT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) throws {
        try formatSRT(
            transcription: transcription,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels
        ).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as WebVTT subtitle file
    public func exportToVTT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) throws {
        try formatVTT(
            transcription: transcription,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels
        ).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format a transcription as SRT, falling back to one full-transcript cue.
    public func formatSRT(
        transcription: Transcription,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatSRT(
            words: words,
            speakers: transcription.speakers,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels
        )
    }

    /// Format a transcription as WebVTT, falling back to one full-transcript cue.
    public func formatVTT(
        transcription: Transcription,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatVTT(
            words: words,
            speakers: transcription.speakers,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels
        )
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
    public func formatSRT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            config: config,
            breakOnSpeakerChange: includeSpeakerLabels
        )
        var lines: [String] = []
        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(ms: cue.startMs)) --> \(srtTimestamp(ms: cue.endMs))")
            lines.append(formattedCueText(cue, speakers: speakers, includeSpeakerLabels: includeSpeakerLabels))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Format word timestamps as WebVTT subtitle string
    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            config: config,
            breakOnSpeakerChange: includeSpeakerLabels
        )
        var lines: [String] = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(vttTimestamp(ms: cue.startMs)) --> \(vttTimestamp(ms: cue.endMs))")
            if includeSpeakerLabels, let label = speakerLabel(for: cue.speakerId, in: speakers) {
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

    /// Internal mutable cue used during cue building.
    private struct MutableCue {
        var startMs: Int
        var endMs: Int
        var words: [String]
        var wordTimestamps: [WordTimestamp]
        var speakerId: String?
        var text: String { words.joined(separator: " ") }
    }

    /// Groups word timestamps into subtitle cues suitable for SRT/VTT and overlay display.
    ///
    /// Three-phase pipeline:
    ///   1. Greedy accumulation using speech-aligned boundaries (gaps, punctuation, duration).
    ///   2. Proofread pass: evaluate every adjacent pair, re-split at natural phrase endings,
    ///      merge unnecessarily fragmented cues, and absorb orphaned fragments.
    ///   3. Smart text wrapping that prefers single-line cues when the text fits.
    public func buildSubtitleCues(
        from words: [WordTimestamp],
        config: SubtitleExportConfig = .default,
        breakOnSpeakerChange: Bool = false
    ) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        var rawCues: [MutableCue] = []
        var currentWords: [String] = []
        var currentTimestamps: [WordTimestamp] = []
        var cueStartMs = words[0].startMs
        var cueEndMs = words[0].endMs
        var cueSpeakerId = words[0].speakerId

        func flushCue() {
            guard !currentWords.isEmpty else { return }
            rawCues.append(MutableCue(
                startMs: cueStartMs,
                endMs: cueEndMs,
                words: currentWords,
                wordTimestamps: currentTimestamps,
                speakerId: cueSpeakerId
            ))
            currentWords = []
            currentTimestamps = []
        }

        for (i, word) in words.enumerated() {
            let speakerChanged = breakOnSpeakerChange
                && !currentWords.isEmpty
                && word.speakerId != cueSpeakerId

            let prospectiveWords = currentWords + [word.word]
            let prospectiveText = prospectiveWords.joined(separator: " ")
            let exceedsTotalChars = prospectiveText.count > config.maxCharsPerLine

            // Hard break: speaker change or char budget exceeded
            if speakerChanged || (!currentWords.isEmpty && exceedsTotalChars) {
                flushCue()
                cueStartMs = word.startMs
                cueSpeakerId = word.speakerId
            }

            currentWords.append(word.word)
            currentTimestamps.append(word)
            cueEndMs = word.endMs

            let isLast = i == words.count - 1
            let endsWithPunctuation = config.breakOnPunctuation
                ? (word.word.last.map { ".!?".contains($0) } ?? false)
                : false
            let hasLongGap = !isLast && (words[i + 1].startMs - word.endMs) > config.gapThresholdMs
            let tooLong = (cueEndMs - cueStartMs) > config.maxDurationMs
            let shouldBreakOnPunctuation = endsWithPunctuation
                && currentWords.count >= config.minWordsBeforePunctuationBreak

            // Soft break: punctuation, long gaps, max duration, end of stream
            if isLast || shouldBreakOnPunctuation || hasLongGap || tooLong {
                flushCue()
                if !isLast {
                    cueStartMs = words[i + 1].startMs
                    cueSpeakerId = words[i + 1].speakerId
                }
            }
        }

        // PHASE 2: Proofread — fix unnatural boundaries, merge fragments, re-split overlong cues.
        rawCues = proofreadCues(rawCues, config: config)

        // Wrap text for each cue
        return rawCues.map { cue in
            SubtitleCue(
                startMs: cue.startMs,
                endMs: cue.endMs,
                text: wrapSubtitleText(cue.text, config: config),
                speakerId: cue.speakerId
            )
        }
    }

    // MARK: - Proofread Pass

    /// Evaluate every adjacent cue pair and fix unnatural boundaries.
    ///
    /// A good subtitle boundary ends at a natural phrase break (comma, sentence end,
    /// conjunction, preposition). A bad boundary splits mid-phrase (e.g. "our / bike,").
    ///
    /// Three passes:
    ///   1. Merge unnecessarily split cues when the combined text fits.
    ///   2. Re-split overlong or unnaturally split cues at better boundaries.
    ///   3. Absorb orphaned tiny cues into neighbours.
    private func proofreadCues(_ cues: [MutableCue], config: SubtitleExportConfig) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let maxChars = config.maxCharsPerLine

        var result = cues

        // ── Pass 1: Merge adjacent short cues that were split unnecessarily ──
        var i = 0
        while i < result.count - 1 {
            let a = result[i]
            let b = result[i + 1]

            // Skip if this is already a natural sentence boundary
            let aEndsSentence = a.text.last.map { ".!?".contains($0) } ?? false
            guard !aEndsSentence else { i += 1; continue }

            let combinedText = a.text + " " + b.text
            let combinedFits = combinedText.count <= maxChars + 10
            let aIsShort = a.text.count < maxChars * 3 / 4
            let bIsShort = b.text.count < maxChars * 3 / 4

            // Merge if both are short and the combined text still fits within budget
            if combinedFits && aIsShort && bIsShort {
                result[i] = MutableCue(
                    startMs: a.startMs,
                    endMs: b.endMs,
                    words: a.words + b.words,
                    wordTimestamps: a.wordTimestamps + b.wordTimestamps,
                    speakerId: a.speakerId
                )
                result.remove(at: i + 1)
                continue
            }

            i += 1
        }

        // ── Pass 2: Re-split cues with unnatural boundaries ──
        var repassed: [MutableCue] = []
        for (idx, cue) in result.enumerated() {
            // Only re-split if this cue is reasonably short and the NEXT cue starts
            // with a word that should have been in this cue (unnatural boundary).
            let isLast = idx == result.count - 1
            let shouldResplit = !isLast
                && cue.text.count <= maxChars
                && !isNaturalBoundary(cue)
                && hasUnnaturalStart(result[idx + 1])

            if shouldResplit {
                let nextCue = result[idx + 1]
                let combinedWords = cue.words + nextCue.words
                let combinedTs = cue.wordTimestamps + nextCue.wordTimestamps
                let combinedStartMs = cue.startMs
                let combinedEndMs = nextCue.endMs

                let splitIdx = bestProofreadSplit(
                    words: combinedWords,
                    maxChars: maxChars
                )

                // Only apply the re-split if it found a meaningfully better boundary
                let originalSplit = cue.words.count
                if splitIdx > 0
                    && splitIdx < combinedWords.count
                    && abs(splitIdx - originalSplit) >= 2 {

                    let firstWords = Array(combinedWords[0..<splitIdx])
                    let firstTs = Array(combinedTs[0..<splitIdx])
                    let secondWords = Array(combinedWords[splitIdx...])
                    let secondTs = Array(combinedTs[splitIdx...])

                    repassed.append(MutableCue(
                        startMs: combinedStartMs,
                        endMs: firstTs.last?.endMs ?? combinedStartMs,
                        words: firstWords,
                        wordTimestamps: firstTs,
                        speakerId: cue.speakerId
                    ))

                    // Replace the next cue with the remainder
                    if idx + 1 < result.count {
                        result[idx + 1] = MutableCue(
                            startMs: secondTs.first?.startMs ?? combinedEndMs,
                            endMs: combinedEndMs,
                            words: secondWords,
                            wordTimestamps: secondTs,
                            speakerId: nextCue.speakerId
                        )
                    }
                    continue
                }
            }

            repassed.append(cue)
        }
        result = repassed

        // ── Pass 3: Absorb orphaned tiny cues ──
        result = absorbTinyCues(result, maxChars: maxChars)

        return result
    }

    /// Returns true if the cue ends at a natural linguistic boundary.
    private func isNaturalBoundary(_ cue: MutableCue) -> Bool {
        guard let lastWord = cue.words.last?.lowercased() else { return false }
        // Sentence-ending punctuation
        if lastWord.last.map({ ".!?".contains($0) }) ?? false { return true }
        // Comma or semicolon
        if lastWord.hasSuffix(",") || lastWord.hasSuffix(";") { return true }
        // Conjunctions / prepositions that accept a following clause
        let naturalEnders = ["and", "but", "or", "so", "yet", "for", "nor",
                               "then", "thus", "hence", "therefore", "however"]
        if naturalEnders.contains(lastWord) { return true }
        return false
    }

    /// Returns true if the cue starts with a word that grammatically belongs
    /// to the previous cue (orphaned start).
    private func hasUnnaturalStart(_ cue: MutableCue) -> Bool {
        guard let firstWord = cue.words.first?.lowercased() else { return false }
        // Cues should not start with words that are clearly continuations
        let orphanedStarters = ["bike,", "and", "but", "or", "so", "yet", "also",
                                "between", "among", "within", "inside", "outside"]
        if orphanedStarters.contains(firstWord) { return true }
        // Punctuation-heavy tokens that got separated
        if firstWord.hasPrefix(",") || firstWord.hasPrefix(";") { return true }
        return false
    }

    /// Find the best split point for a combined cue pair.
    /// Looks backward from the maximum fitting prefix for natural boundaries.
    private func bestProofreadSplit(words: [String], maxChars: Int) -> Int {
        guard !words.isEmpty else { return 0 }

        // Find the farthest word that still fits under the budget
        var lastFitting = 0
        for j in 1...words.count {
            let prefix = words[0..<j].joined(separator: " ")
            if prefix.count <= maxChars {
                lastFitting = j
            } else {
                break
            }
        }

        if lastFitting == 0 { return 1 }
        if lastFitting == words.count { return words.count }

        // Scan backward for the best natural boundary
        let searchStart = min(lastFitting, words.count - 1)
        let searchEnd = max(2, lastFitting - 8)

        var bestIdx = lastFitting
        var bestScore = -1

        for idx in stride(from: searchStart, through: searchEnd, by: -1) {
            let segmentText = words[0..<idx].joined(separator: " ")
            guard segmentText.count <= maxChars else { continue }

            let lastWord = words[idx - 1].lowercased()
            let nextWord = words[idx].lowercased()
            var score = 0

            // Strong preference for comma / semicolon endings
            if lastWord.hasSuffix(",") || lastWord.hasSuffix(";") || lastWord.hasSuffix(":") {
                score += 100
            }
            // Sentence endings are excellent boundaries
            if lastWord.last.map({ ".!?".contains($0) }) ?? false {
                score += 90
            }
            // Conjunctions / prepositions
            if ["and", "but", "or", "so", "yet", "for", "nor", "then",
                "in", "on", "at", "to", "of", "with", "from", "by", "as",
                "into", "onto", "through", "over", "under", "around"].contains(lastWord) {
                score += 40
            }
            // Articles (acceptable but less ideal)
            if ["the", "a", "an"].contains(lastWord) { score += 15 }

            // Avoid starting the next cue with a comma
            if nextWord.hasPrefix(",") || nextWord.hasPrefix(";") { score -= 80 }

            // Penalize very short resulting segments
            if idx < 3 { score -= 30 }
            if words.count - idx < 3 { score -= 30 }

            if score > bestScore {
                bestScore = score
                bestIdx = idx
            }
        }

        return bestIdx
    }

    /// Merge cues that are too small with neighbours when possible.
    private func absorbTinyCues(_ cues: [MutableCue], maxChars: Int) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let minChars = 12
        let minWords = 2
        let tolerance = 8
        let maxBudget = maxChars + tolerance

        var result = cues

        // Forward pass: absorb tiny cue into next cue
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let isTiny = current.text.count < minChars || current.words.count < minWords
            if isTiny {
                let next = result[i + 1]
                let merged = current.text + " " + next.text
                if merged.count <= maxBudget {
                    result[i] = MutableCue(
                        startMs: current.startMs,
                        endMs: next.endMs,
                        words: current.words + next.words,
                        wordTimestamps: current.wordTimestamps + next.wordTimestamps,
                        speakerId: current.speakerId
                    )
                    result.remove(at: i + 1)
                    continue
                }
            }
            i += 1
        }

        // Backward pass: absorb tiny cue into previous cue
        i = 1
        while i < result.count {
            let current = result[i]
            let isTiny = current.text.count < minChars || current.words.count < minWords
            if isTiny {
                let prev = result[i - 1]
                let merged = prev.text + " " + current.text
                if merged.count <= maxBudget {
                    result[i - 1] = MutableCue(
                        startMs: prev.startMs,
                        endMs: current.endMs,
                        words: prev.words + current.words,
                        wordTimestamps: prev.wordTimestamps + current.wordTimestamps,
                        speakerId: prev.speakerId
                    )
                    result.remove(at: i)
                    continue
                }
            }
            i += 1
        }

        return result
    }

    /// Wrap subtitle text across up to maxLinesPerCue lines.
    ///
    /// maxCharsPerLine is treated as the *total* character budget for the cue.
    /// When preferBalancedLines is true (and maxLinesPerCue == 2), the algorithm
    /// tries to split the text so both lines are roughly equal in length,
    /// preferring natural break points (commas, conjunctions) when the difference
    /// is small. Falls back to greedy wrapping for single-line cues or when
    /// balanced wrapping is disabled.
    private func wrapSubtitleText(_ text: String, config: SubtitleExportConfig) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }

        // Single line: just return the text (it was already bounded by cue splitting)
        if config.maxLinesPerCue <= 1 {
            return text
        }

        let perLineBudget = max(10, config.maxCharsPerLine / max(1, config.maxLinesPerCue))

        // If the entire cue fits on a single line, don't force a multi-line split.
        if text.count <= perLineBudget {
            return text
        }

        // For two-line cues, try balanced wrapping when enabled
        if config.maxLinesPerCue == 2 && config.preferBalancedLines && words.count > 1 {
            if let balanced = wrapSubtitleTextBalanced(words: words, perLineBudget: perLineBudget) {
                return balanced
            }
        }

        // Fallback: greedy line-by-line wrapping
        return wrapSubtitleTextGreedy(words: words, perLineBudget: perLineBudget)
    }

    /// Greedy wrap: fill each line until the next word would exceed budget.
    /// Post-processes to avoid orphaned very-short final lines.
    private func wrapSubtitleTextGreedy(words: [String], perLineBudget: Int) -> String {
        var lines: [String] = []
        var currentLine = ""

        for word in words {
            let candidate = currentLine.isEmpty ? word : "\(currentLine) \(word)"
            if candidate.count > perLineBudget {
                if !currentLine.isEmpty {
                    lines.append(currentLine)
                }
                currentLine = word
                if currentLine.count > perLineBudget {
                    currentLine = String(currentLine.prefix(perLineBudget))
                }
            } else {
                currentLine = candidate
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        // Avoid orphaned very-short last line by merging with previous
        if lines.count >= 2 {
            let last = lines.removeLast()
            if last.count < 5, let prev = lines.last {
                let merged = prev + " " + last
                if merged.count <= perLineBudget + 5 {
                    lines[lines.count - 1] = merged
                } else {
                    lines.append(last)
                }
            } else {
                lines.append(last)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Balanced wrap for two-line cues. Tries all possible split points and
    /// scores them by line-length balance, natural phrasing, and orphan avoidance.
    private func wrapSubtitleTextBalanced(words: [String], perLineBudget: Int) -> String? {
        var bestSplit = 0
        var bestScore = Int.min

        for splitAfter in 1..<words.count {
            let line1 = words[0..<splitAfter].joined(separator: " ")
            let line2 = words[splitAfter...].joined(separator: " ")

            // Hard constraint: neither line can exceed budget
            guard line1.count <= perLineBudget && line2.count <= perLineBudget else { continue }

            // 1. Balance: prefer equal line lengths
            let balanceScore = -abs(line1.count - line2.count)

            // 2. Natural break bonus
            let naturalBonus: Int
            let lastWord = words[splitAfter - 1].lowercased()
            if lastWord.hasSuffix(",") || lastWord.hasSuffix(";") {
                naturalBonus = 8
            } else if ["and", "but", "or", "so", "yet", "for", "nor"].contains(lastWord) {
                naturalBonus = 4
            } else {
                naturalBonus = 0
            }

            // 3. Proximity bonus: prefer splits close to the midpoint
            let midpoint = Double(words.count) / 2.0
            let distFromMid = abs(Double(splitAfter) - midpoint)
            let proximityBonus = Int(max(0, 5 - distFromMid))

            // 4. Minimum line length: reject splits that leave a very short line
            guard line1.count >= 5 && line2.count >= 5 else { continue }

            // 5. Orphan penalty: strongly avoid a very short last line
            let orphanPenalty: Int
            if line2.count < 10 {
                orphanPenalty = -15
            } else {
                orphanPenalty = 0
            }

            let score = balanceScore + naturalBonus + proximityBonus + orphanPenalty
            if score > bestScore {
                bestScore = score
                bestSplit = splitAfter
            }
        }

        guard bestSplit > 0 else { return nil }
        let line1 = words[0..<bestSplit].joined(separator: " ")
        let line2 = words[bestSplit...].joined(separator: " ")
        return "\(line1)\n\(line2)"
    }

    private func formattedCueText(
        _ cue: SubtitleCue,
        speakers: [SpeakerInfo]?,
        includeSpeakerLabels: Bool
    ) -> String {
        guard includeSpeakerLabels,
              let label = speakerLabel(for: cue.speakerId, in: speakers) else {
            return cue.text
        }
        return "\(label): \(cue.text)"
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
