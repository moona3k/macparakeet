import Foundation
import AppKit

@MainActor
public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL) throws
    func exportToSRT(transcription: Transcription, url: URL, config: SubtitleExportConfig) throws
    func exportToVTT(transcription: Transcription, url: URL) throws
    func exportToVTT(transcription: Transcription, url: URL, config: SubtitleExportConfig) throws
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

/// Tunable parameters that shape SRT/VTT cue building. Defaults mirror the values
/// the pipeline used before this struct existed; preset constants reproduce the
/// conventions of common subtitle authoring tools (Adobe Premiere defaults,
/// Netflix Timed Text Style Guide, BBC Subtitle Guidelines, YouTube auto-captions).
public struct SubtitleExportConfig: Sendable, Equatable {
    /// Character budget per displayed line. Cues exceeding this are wrapped (or split
    /// when `maxLines == 1`).
    public var maxLineChars: Int
    /// 1 = produce single-line cues only (long cues are split into multiple cues).
    /// 2 = wrap long cues into two balanced lines separated by `\n`.
    public var maxLines: Int
    /// Reading speed ceiling. Cues exceeding this characters-per-second value are
    /// split at the best linguistic boundary.
    public var maxCPS: Double
    /// Minimum on-screen duration. Cues shorter than this are extended into the
    /// following gap (never overlapping the next cue).
    public var minCueDurationMs: Int
    /// Hard upper bound on cue duration; soft duration trigger sits at ~7/8 of this.
    public var maxCueDurationMs: Int
    /// Minimum gap preserved between consecutive cues. Closer pairs have the earlier
    /// cue's `endMs` trimmed back (bounded by `minCueDurationMs`).
    public var minGapMs: Int
    /// Word count that triggers a soft break (look-back boundary search applies).
    public var softWordCap: Int
    /// Word count that forces a break even when the current word would be a bad ender.
    public var hardWordCap: Int

    public init(
        maxLineChars: Int = 42,
        maxLines: Int = 2,
        maxCPS: Double = 25.0,
        minCueDurationMs: Int = 800,
        maxCueDurationMs: Int = 8000,
        minGapMs: Int = 67,
        softWordCap: Int = 12,
        hardWordCap: Int = 14
    ) {
        self.maxLineChars = maxLineChars
        self.maxLines = maxLines
        self.maxCPS = maxCPS
        self.minCueDurationMs = minCueDurationMs
        self.maxCueDurationMs = maxCueDurationMs
        self.minGapMs = minGapMs
        self.softWordCap = softWordCap
        self.hardWordCap = hardWordCap
    }

    /// Current pipeline defaults. Matches behavior prior to config plumbing.
    public static let `default` = SubtitleExportConfig()

    /// Netflix Timed Text Style Guide: 42 chars/line, 17 CPS, 5/6s display window,
    /// 2-frame gap at 24fps (~83ms).
    public static let netflix = SubtitleExportConfig(
        maxLineChars: 42,
        maxLines: 2,
        maxCPS: 17.0,
        minCueDurationMs: 833,
        maxCueDurationMs: 7000,
        minGapMs: 83,
        softWordCap: 12,
        hardWordCap: 14
    )

    /// BBC Subtitle Guidelines: narrower 37-char lines, 17 CPS, 1s minimum duration.
    public static let bbc = SubtitleExportConfig(
        maxLineChars: 37,
        maxLines: 2,
        maxCPS: 17.0,
        minCueDurationMs: 1000,
        maxCueDurationMs: 8000,
        minGapMs: 80,
        softWordCap: 12,
        hardWordCap: 14
    )

    /// Looser pacing closer to YouTube auto-captions: no minimum duration or gap,
    /// slightly wider word caps.
    public static let youtube = SubtitleExportConfig(
        maxLineChars: 42,
        maxLines: 2,
        maxCPS: 25.0,
        minCueDurationMs: 0,
        maxCueDurationMs: 8000,
        minGapMs: 0,
        softWordCap: 14,
        hardWordCap: 16
    )
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
        try exportToSRT(transcription: transcription, url: url, config: .default)
    }

    public func exportToSRT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig
    ) throws {
        try formatSRT(transcription: transcription, config: config)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Export transcription as WebVTT subtitle file
    public func exportToVTT(transcription: Transcription, url: URL) throws {
        try exportToVTT(transcription: transcription, url: url, config: .default)
    }

    public func exportToVTT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig
    ) throws {
        try formatVTT(transcription: transcription, config: config)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format a transcription as SRT, falling back to one full-transcript cue.
    public func formatSRT(transcription: Transcription) -> String {
        formatSRT(transcription: transcription, config: .default)
    }

    public func formatSRT(transcription: Transcription, config: SubtitleExportConfig) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatSRT(words: words, speakers: transcription.speakers, config: config)
    }

    /// Format a transcription as WebVTT, falling back to one full-transcript cue.
    public func formatVTT(transcription: Transcription) -> String {
        formatVTT(transcription: transcription, config: .default)
    }

    public func formatVTT(transcription: Transcription, config: SubtitleExportConfig) -> String {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            return "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
        }
        return formatVTT(words: words, speakers: transcription.speakers, config: config)
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
        formatSRT(words: words, speakers: speakers, config: .default)
    }

    public func formatSRT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig
    ) -> String {
        let cues = buildSubtitleCues(from: words, config: config)
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
        formatVTT(words: words, speakers: speakers, config: .default)
    }

    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig
    ) -> String {
        let cues = buildSubtitleCues(from: words, config: config)
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

    // Coordinating conjunctions: prefer to START a new cue/line with these rather than
    // end one with them. Breaking BEFORE a coordinator preserves the conjunction's link
    // to the clause it introduces.
    private static let coordinatingConjunctions: Set<String> = [
        "and", "but", "or", "so", "yet", "nor"
    ]

    /// Normalises raw word tokens before cue building. Three cleanups:
    /// 1. Strip leading/trailing whitespace from each word's text. Whisper/Parakeet emit
    ///    tokens with a leading space (" Hello") which, when joined with " ", produce
    ///    double-spaced output AND inflate character counts enough to trip the CPS guard.
    /// 2. Merge tokens that begin with a hyphen ("-up", "-minute") into the preceding
    ///    word. The transcription engine sometimes splits hyphenated compounds across
    ///    tokens; treating them as a single word avoids cues like "warm" / "-up." pairs.
    /// 3. Carry the previous word's speakerId forward when a token has none. Some engines
    ///    intermittently drop speakerId mid-utterance, producing label-less cues
    ///    downstream. Treat a missing id as continuation of the same speaker.
    /// Empty tokens (after trimming) are dropped.
    private func sanitizeWordTokens(_ words: [WordTimestamp]) -> [WordTimestamp] {
        // Pre-split fused letter+digit tokens (`next30` → `next` + `30`) before
        // the rest of sanitisation runs. Doing it up front means downstream
        // logic — hyphen merging, character counting for CPS, line wrapping —
        // sees the same word stream a human would expect.
        let split = WordNumberSplitter.splitWords(words)
        var result: [WordTimestamp] = []
        result.reserveCapacity(split.count)
        var lastSpeakerId: String? = nil
        for w in split {
            let trimmed = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let resolvedSpeaker = w.speakerId ?? lastSpeakerId
            // Hyphen-continuation: glue onto the previous token.
            if trimmed.hasPrefix("-"), let prev = result.last {
                result[result.count - 1] = WordTimestamp(
                    word: prev.word + trimmed,
                    startMs: prev.startMs,
                    endMs: w.endMs,
                    confidence: min(prev.confidence, w.confidence),
                    speakerId: prev.speakerId
                )
                continue
            }
            result.append(WordTimestamp(
                word: trimmed,
                startMs: w.startMs,
                endMs: w.endMs,
                confidence: w.confidence,
                speakerId: resolvedSpeaker
            ))
            if let s = resolvedSpeaker { lastSpeakerId = s }
        }
        return result
    }

    public func buildSubtitleCues(from rawWords: [WordTimestamp]) -> [SubtitleCue] {
        buildSubtitleCues(from: rawWords, config: .default)
    }

    public func buildSubtitleCues(
        from rawWords: [WordTimestamp],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        guard !rawWords.isEmpty else { return [] }
        // Sanitise tokens up front: strip surrounding whitespace (Whisper/Parakeet emit
        // tokens like " Hello" with leading spaces) and merge hyphen-prefix continuations
        // (" -up", " -minute") back onto the previous token. Without this, joining with
        // " " produces double spaces and inflates character counts enough to trip the
        // CPS guard on perfectly normal cues, causing spurious mid-sentence splits.
        let words = sanitizeWordTokens(rawWords)
        guard !words.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        // Track word strings + per-word start/end times in parallel so the look-back
        // boundary search can produce a clean truncated cue and seed the leftover
        // words into the next cue with correct timing.
        var currentWords: [String] = []
        var currentStarts: [Int] = []
        var currentEnds: [Int] = []
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
                currentStarts = []
                currentEnds = []
                cueStartMs = word.startMs
                cueSpeakerId = word.speakerId
            }

            currentWords.append(word.word)
            currentStarts.append(word.startMs)
            currentEnds.append(word.endMs)
            cueEndMs = word.endMs

            let isLast = i == words.count - 1
            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = !isLast && (words[i + 1].startMs - word.endMs) > 800
            let tooManyWords = currentWords.count >= config.softWordCap
            // Soft duration trigger sits at ~7/8 of the hard cap so bad-ender deferral
            // has room to overshoot without blowing the hard ceiling.
            let softDurationMs = (config.maxCueDurationMs * 7) / 8
            let tooLong = (cueEndMs - cueStartMs) > softDurationMs

            // Single-word imperative break: if this word ends a sentence AND the next
            // word starts a new sentence (capital letter), allow flushing even at
            // count == 1. Catches fitness cueing like "Squat. Up. Down." which would
            // otherwise be merged because of the count >= 2 floor.
            let nextStartsCapital = !isLast
                && (words[i + 1].word.first?.isUppercase ?? false)
            let sentenceBreak = endsWithPunctuation && (
                currentWords.count >= 2
                || (currentWords.count >= 1 && nextStartsCapital)
            )

            // Break before a subordinating conjunction or relative pronoun that opens a
            // new dependent clause — but only after at least 4 words have accumulated so
            // we don't produce single-word cues.
            let nextIsClauseStart = !isLast
                && currentWords.count >= 4
                && Self.clauseStarters.contains(
                    words[i + 1].word.lowercased().trimmingCharacters(in: .punctuationCharacters))

            // Classify the trigger so we can decide whether to look back for a better
            // boundary or defer for a bad-ender. Semantic and hard triggers fire as-is;
            // soft triggers (word count / duration) get the look-back treatment.
            let semanticTrigger = sentenceBreak || nextIsClauseStart
            let hardTrigger = isLast || hasLongGap
            let softTrigger = tooManyWords || tooLong
            let lastWordKey = word.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isBadEnder = Self.badEnders.contains(lastWordKey)
            let underHardCap = currentWords.count < config.hardWordCap
                && (cueEndMs - cueStartMs) < config.maxCueDurationMs
            let deferForBadEnder = softTrigger
                && !hardTrigger
                && !semanticTrigger
                && isBadEnder
                && underHardCap

            if (isLast || semanticTrigger || hardTrigger || softTrigger) && !deferForBadEnder {
                // Look-back boundary search: only for pure soft triggers where no
                // semantic/hard reason forces a break at the current word. If a comma,
                // coordinating conjunction, or clause starter sits within the recent
                // window, retroactively split there and seed the leftover into the next
                // cue. Keeps long fitness sentences ("Keep your back straight, engage
                // your core, and breathe out") from breaking mid-phrase.
                let lookBack: Int? = (softTrigger && !semanticTrigger && !hardTrigger)
                    ? findLookBackBoundary(words: currentWords)
                    : nil

                if let p = lookBack {
                    // Flush [0...p] as the cue.
                    let cueText = currentWords[0...p].joined(separator: " ")
                    cues.append(SubtitleCue(
                        startMs: cueStartMs,
                        endMs: currentEnds[p],
                        text: cueText,
                        speakerId: cueSpeakerId
                    ))
                    // Leftover [(p+1)...] seeds the next cue.
                    currentWords = Array(currentWords[(p + 1)...])
                    currentStarts = Array(currentStarts[(p + 1)...])
                    currentEnds = Array(currentEnds[(p + 1)...])
                    cueStartMs = currentStarts.first ?? cueStartMs
                    cueEndMs = currentEnds.last ?? cueEndMs
                } else {
                    cues.append(SubtitleCue(
                        startMs: cueStartMs,
                        endMs: cueEndMs,
                        text: currentWords.joined(separator: " "),
                        speakerId: cueSpeakerId
                    ))
                    currentWords = []
                    currentStarts = []
                    currentEnds = []
                    if !isLast {
                        cueStartMs = words[i + 1].startMs
                        cueSpeakerId = words[i + 1].speakerId
                    }
                }
            }
        }

        // Pipeline: pace -> wrap (or split for single-line) -> extend short cues ->
        // trim overlapping cues to preserve the minimum inter-cue gap.
        let paced = enforceReadingSpeed(cues, words: words, config: config)
        let wrapped = wrapLongCues(paced, config: config)
        let durationEnforced = enforceMinDuration(wrapped, config: config)
        return enforceMinGap(durationEnforced, config: config)
    }

    /// Split cues whose text/duration ratio exceeds maxCPS characters per second.
    /// 25 CPS is the safety threshold — the Netflix/BBC guideline is 17 CPS, but that
    /// standard is for display time compliance tools; 25 catches genuinely unreadable
    /// cues without false-positiving on fast-but-readable speech. Cues that can't be
    /// cleanly split (≤ 2 words) are left untouched.
    private func enforceReadingSpeed(
        _ cues: [SubtitleCue],
        words: [WordTimestamp],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        let maxCPS = config.maxCPS
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
    /// starters, coordinating conjunctions, capitalised words; penalises ending on
    /// conjunctions/articles. Distance from midpoint is a small tiebreaker so two
    /// equally-good splits prefer the balanced one. Falls back to the midpoint if no
    /// candidate scores above zero.
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
            // Coordinating conjunctions start a new clause cleanly — prefer to split
            // immediately before them.
            if Self.coordinatingConjunctions.contains(nextKey) { score += 2 }
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

    /// When a soft-limit break is about to fire, scan the recent `currentWords` for a
    /// more natural boundary (comma/semicolon/colon, coordinating conjunction, or
    /// clause starter) within the look-back window. Returns the index of the last word
    /// to KEEP in the current cue, so caller flushes `[0...returned]` and re-seeds
    /// `[(returned+1)...]` into the next cue. Returns nil if no scoring boundary exists.
    /// Window size 6 catches typical fitness-style sentences with a comma 4-5 words
    /// before the 12-word soft limit fires.
    private func findLookBackBoundary(words: [String]) -> Int? {
        let lastIdx = words.count - 1
        // Need at least 2 words to have a meaningful split (1 in cue, 1 leftover).
        guard lastIdx >= 1 else { return nil }
        let windowStart = max(0, lastIdx - 6)

        var bestIdx: Int? = nil
        var bestScore = 0
        // Candidate split-after positions p: flush [0...p], leftover [(p+1)...lastIdx].
        // We don't allow p == lastIdx (no leftover) — that's just the default flush.
        for p in windowStart..<lastIdx {
            var score = 0
            // Word at p ending with clause-level punctuation is the strongest signal.
            if let last = words[p].last, ",;:".contains(last) { score += 3 }
            let nextKey = words[p + 1]
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            // Break BEFORE a coordinator or clause starter so it leads the next cue.
            if Self.coordinatingConjunctions.contains(nextKey) { score += 2 }
            if Self.clauseStarters.contains(nextKey) { score += 2 }

            if score > bestScore {
                bestScore = score
                bestIdx = p
            }
        }
        return bestIdx
    }

    /// Wrap (or split, when `config.maxLines == 1`) cues whose text exceeds the per-line
    /// character budget. Picks the word boundary closest to the character midpoint, with
    /// bonuses for splits after a comma or before a clause starter / coordinating
    /// conjunction. Cues that fit on one line pass through unchanged.
    private func wrapLongCues(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        let maxLineChars = config.maxLineChars
        var result: [SubtitleCue] = []
        result.reserveCapacity(cues.count)
        for cue in cues {
            guard cue.text.count > maxLineChars else { result.append(cue); continue }
            let tokens = cue.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { result.append(cue); continue }

            let totalLen = cue.text.count
            let targetLen = totalLen / 2

            // Build prefix character lengths so we can score each split point.
            var prefixLen = 0
            var bestIdx = tokens.count / 2
            var bestScore = Int.min
            var firstHalfLen = 0
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
                // Coordinating conjunctions (and/but/or) read more naturally at the
                // start of line 2 than dangling at the end of line 1.
                if Self.coordinatingConjunctions.contains(nextKey) { score += 3 }
                // Discourage splits that leave one side wildly oversized.
                if firstLen > maxLineChars || secondLen > maxLineChars { score -= 2 }

                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                    firstHalfLen = firstLen
                }
            }

            let firstLine = tokens[0..<bestIdx].joined(separator: " ")
            let secondLine = tokens[bestIdx...].joined(separator: " ")

            if config.maxLines <= 1 {
                // Single-line mode: emit two consecutive cues instead of wrapping.
                // Divide the time span proportionally to character length so each
                // cue's on-screen duration roughly matches its text weight.
                let cueDuration = cue.endMs - cue.startMs
                let firstCharShare = Double(firstHalfLen) / Double(max(1, totalLen - 1))
                let firstDuration = Int((Double(cueDuration) * firstCharShare).rounded())
                let splitMs = cue.startMs + max(0, min(cueDuration, firstDuration))
                result.append(SubtitleCue(
                    startMs: cue.startMs,
                    endMs: splitMs,
                    text: firstLine,
                    speakerId: cue.speakerId
                ))
                result.append(SubtitleCue(
                    startMs: splitMs,
                    endMs: cue.endMs,
                    text: secondLine,
                    speakerId: cue.speakerId
                ))
            } else {
                result.append(SubtitleCue(
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                    text: "\(firstLine)\n\(secondLine)",
                    speakerId: cue.speakerId
                ))
            }
        }
        return result
    }

    /// Extend cues whose display duration is shorter than `minCueDurationMs`. Extension
    /// is capped by the next cue's start (minus `minGapMs`) so we never overlap. Cues
    /// that can't be extended without overlapping pass through unchanged — we don't
    /// merge into the next cue because that would undo the upstream cue-shaping work.
    private func enforceMinDuration(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        guard config.minCueDurationMs > 0 else { return cues }
        var result = cues
        for i in result.indices {
            let cue = result[i]
            let duration = cue.endMs - cue.startMs
            guard duration < config.minCueDurationMs else { continue }
            let desiredEnd = cue.startMs + config.minCueDurationMs
            let ceiling: Int = {
                if i + 1 < result.count {
                    return result[i + 1].startMs - config.minGapMs
                }
                return Int.max
            }()
            let newEnd = max(cue.endMs, min(desiredEnd, ceiling))
            if newEnd != cue.endMs {
                result[i] = SubtitleCue(
                    startMs: cue.startMs,
                    endMs: newEnd,
                    text: cue.text,
                    speakerId: cue.speakerId
                )
            }
        }
        return result
    }

    /// Trim consecutive cues that sit closer than `minGapMs` apart. Bounded so we never
    /// shrink a cue below `minCueDurationMs` — when both constraints can't be honoured
    /// we keep the cue at its minimum duration and accept the smaller gap.
    func enforceMinGap(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        guard config.minGapMs > 0, cues.count > 1 else { return cues }
        var result = cues
        for i in 0..<(result.count - 1) {
            let prev = result[i]
            let next = result[i + 1]
            let gap = next.startMs - prev.endMs
            guard gap < config.minGapMs else { continue }
            let desiredEnd = next.startMs - config.minGapMs
            let floor = prev.startMs + config.minCueDurationMs
            let newEnd = max(floor, desiredEnd)
            // Only apply the trim if it actually moves us — avoids no-op writes when
            // shrinking would violate the minimum duration.
            if newEnd < prev.endMs {
                result[i] = SubtitleCue(
                    startMs: prev.startMs,
                    endMs: newEnd,
                    text: prev.text,
                    speakerId: prev.speakerId
                )
            }
        }
        return result
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
