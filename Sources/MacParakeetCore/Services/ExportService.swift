import Foundation
import AppKit
import NaturalLanguage

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
        includeSpeakerLabels: Bool,
        cleanedTranscript: String?
    ) -> String
    func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]?,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool,
        cleanedTranscript: String?
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
    /// Pause gap in ms.
    ///
    /// When the export pipeline can derive a cleaned transcript and run
    /// `SubtitleSentenceSegmenter`, this value governs only the
    /// `mergeOrphanedCues` / `mergeAdjacentCuesForTwoLine` eligibility — it
    /// does NOT cut cues mid-sentence. A separate hard-pause threshold (3 s)
    /// inside `buildSubtitleCues` handles true utterance gaps.
    ///
    /// On the legacy (no-cleaned-transcript) path this still also serves as
    /// the cue-flush threshold for backward compatibility.
    public var gapThresholdMs: Int
    /// Whether to break cues on sentence-ending punctuation.
    public var breakOnPunctuation: Bool
    /// Minimum words accumulated before a punctuation mark triggers a new cue.
    public var minWordsBeforePunctuationBreak: Int
    /// Prefer balanced line lengths when wrapping across lines.
    public var preferBalancedLines: Bool

    /// Whether to use LLM refinement for subtitle boundary quality.
    public var useLLMRefinement: Bool
    /// Maximum reading speed in characters per second. Cues exceeding this will be split.
    /// Professional standard (Netflix, BBC): 17.0. Set to 0 to disable.
    public var maxCPS: Double
    /// Milliseconds added to the end of every cue before gap enforcement runs.
    /// Compensates for acoustic decay — Parakeet timestamps the amplitude crossing
    /// point, but the audible sound continues briefly after that. Typical: 40–80 ms.
    /// Default: 0 (no change). `enforceMinGap` trims any overlap introduced.
    public var endTimeBufferMs: Int
    /// When non-nil, cue start/end times are snapped to the nearest video frame
    /// boundary at this frame rate (e.g. 24.0, 25.0, 29.97, 30.0).
    /// startMs snaps down; endMs snaps up, so cues never appear late or leave early.
    /// Default: nil (millisecond precision, no snapping).
    public var snapToFrameRate: Double?

    public init(
        maxWordsPerCue: Int = 12,
        maxCharsPerLine: Int = 42,
        maxLinesPerCue: Int = 2,
        maxDurationMs: Int = 7000,
        gapThresholdMs: Int = 800,
        breakOnPunctuation: Bool = true,
        minWordsBeforePunctuationBreak: Int = 4,
        preferBalancedLines: Bool = true,
        useLLMRefinement: Bool = false,
        maxCPS: Double = 17.0,
        endTimeBufferMs: Int = 0,
        snapToFrameRate: Double? = nil
    ) {
        self.maxWordsPerCue = max(1, maxWordsPerCue)
        self.maxCharsPerLine = max(10, maxCharsPerLine)
        self.maxLinesPerCue = max(1, maxLinesPerCue)
        self.maxDurationMs = max(1000, maxDurationMs)
        self.gapThresholdMs = max(0, gapThresholdMs)
        self.breakOnPunctuation = breakOnPunctuation
        self.minWordsBeforePunctuationBreak = max(1, minWordsBeforePunctuationBreak)
        self.preferBalancedLines = preferBalancedLines
        self.useLLMRefinement = useLLMRefinement
        self.maxCPS = max(0, maxCPS)
        self.endTimeBufferMs = max(0, endTimeBufferMs)
        self.snapToFrameRate = snapToFrameRate
    }

    public static let `default` = SubtitleExportConfig()
}

// Explicit Codable conformance so new optional fields (endTimeBufferMs, snapToFrameRate)
// decode gracefully from configs stored before those fields existed.
extension SubtitleExportConfig {
    private enum CodingKeys: String, CodingKey {
        case maxWordsPerCue, maxCharsPerLine, maxLinesPerCue, maxDurationMs,
             gapThresholdMs, breakOnPunctuation, minWordsBeforePunctuationBreak,
             preferBalancedLines, useLLMRefinement, maxCPS,
             endTimeBufferMs, snapToFrameRate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxWordsPerCue               = try c.decode(Int.self, forKey: .maxWordsPerCue)
        maxCharsPerLine              = try c.decode(Int.self, forKey: .maxCharsPerLine)
        maxLinesPerCue               = try c.decode(Int.self, forKey: .maxLinesPerCue)
        maxDurationMs                = try c.decode(Int.self, forKey: .maxDurationMs)
        gapThresholdMs               = try c.decode(Int.self, forKey: .gapThresholdMs)
        breakOnPunctuation           = try c.decode(Bool.self, forKey: .breakOnPunctuation)
        minWordsBeforePunctuationBreak = try c.decode(Int.self, forKey: .minWordsBeforePunctuationBreak)
        preferBalancedLines          = try c.decode(Bool.self, forKey: .preferBalancedLines)
        useLLMRefinement             = try c.decode(Bool.self, forKey: .useLLMRefinement)
        maxCPS                       = try c.decode(Double.self, forKey: .maxCPS)
        endTimeBufferMs              = try c.decodeIfPresent(Int.self, forKey: .endTimeBufferMs) ?? 0
        snapToFrameRate              = try c.decodeIfPresent(Double.self, forKey: .snapToFrameRate)
    }
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

    /// Async variant with optional LLM refinement.
    public func exportToSRT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil
    ) async throws {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            let srt = "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
            try srt.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            let srt = "1\n00:00:00,000 --> \(srtTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
            try srt.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let text = try await formatSRT(
            words: words,
            speakers: transcription.speakers,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels,
            llmService: llmService,
            onRefinementProgress: onRefinementProgress,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Async variant with optional LLM refinement.
    public func exportToVTT(
        transcription: Transcription,
        url: URL,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil
    ) async throws {
        if let text = editedTranscriptText(transcription: transcription) {
            let duration = transcription.durationMs ?? 0
            let vtt = "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
            try vtt.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            let text = preferredText(transcription: transcription)
            let duration = transcription.durationMs ?? 0
            let vtt = "WEBVTT\n\n\(vttTimestamp(ms: 0)) --> \(vttTimestamp(ms: duration))\n\(singleCueSubtitleText(text))\n"
            try vtt.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let text = try await formatVTT(
            words: words,
            speakers: transcription.speakers,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels,
            llmService: llmService,
            onRefinementProgress: onRefinementProgress,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
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
            includeSpeakerLabels: includeSpeakerLabels,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
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
            includeSpeakerLabels: includeSpeakerLabels,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
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
        includeSpeakerLabels: Bool = false,
        cleanedTranscript: String? = nil
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
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

    /// Async variant of formatSRT with optional LLM refinement.
    public func formatSRT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        cleanedTranscript: String? = nil
    ) async throws -> String {
        var cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
            config: config,
            breakOnSpeakerChange: includeSpeakerLabels
        )

        if config.useLLMRefinement, let llmService = llmService {
            let refiner = SubtitleLLMRefiner(llmService: llmService)
            cues = try await refiner.refine(cues: cues, config: config, onProgress: onRefinementProgress)
        }

        var lines: [String] = []
        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(ms: cue.startMs)) --> \(srtTimestamp(ms: cue.endMs))")
            lines.append(formattedCueText(cue, speakers: speakers, includeSpeakerLabels: includeSpeakerLabels))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Async variant of formatVTT with optional LLM refinement.
    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        cleanedTranscript: String? = nil
    ) async throws -> String {
        var cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
            config: config,
            breakOnSpeakerChange: includeSpeakerLabels
        )

        if config.useLLMRefinement, let llmService = llmService {
            let refiner = SubtitleLLMRefiner(llmService: llmService)
            cues = try await refiner.refine(cues: cues, config: config, onProgress: onRefinementProgress)
        }

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

    /// Format word timestamps as WebVTT subtitle string
    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        cleanedTranscript: String? = nil
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
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
            let cues = buildSubtitleCues(
                from: timestamps,
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
            )
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
        var forcedText: String? = nil
        var text: String { forcedText ?? words.joined(separator: " ") }
    }

    /// Builds subtitle cues from word-level timestamps.
    ///
    /// Core principle: timing gaps in speech are the most reliable natural boundaries.
    /// When a speaker pauses (gap between words > threshold), that's where a subtitle
    /// should end. For continuous speech without gaps, we split at linguistic boundaries
    /// (commas, conjunctions, prepositions) while staying within the character budget.
    /// Sanitize raw word timestamps before cue building:
    /// - Clamps any word's endMs so it does not exceed the next word's startMs
    ///   (overlaps corrupt CPS calculations and gap detection).
    /// - Ensures every word has at least 1 ms of duration (prevents divide-by-zero
    ///   in reading-speed enforcement).
    private func sanitizeWordTimestamps(_ words: [WordTimestamp]) -> [WordTimestamp] {
        guard !words.isEmpty else { return words }
        // Step 1: split fused letter+digit tokens (`arms30.` → `arms 30.`).
        // Runs first so downstream CPS calculations and line-length budgets
        // see the correct character counts.
        var result = WordNumberSplitter.splitWords(words)
        let last = result.count - 1
        for i in 0..<last {
            // Ensure non-zero duration
            if result[i].endMs <= result[i].startMs {
                result[i].endMs = result[i].startMs + 1
            }
            // Clamp so this word does not overlap the next
            if result[i].endMs > result[i + 1].startMs {
                result[i].endMs = result[i + 1].startMs
            }
        }
        // Last word: only zero-duration fix (no next word to clamp against)
        if result[last].endMs <= result[last].startMs {
            result[last].endMs = result[last].startMs + 1
        }
        return result
    }

    public func buildSubtitleCues(
        from words: [WordTimestamp],
        cleanedTranscript: String? = nil,
        config: SubtitleExportConfig = .default,
        breakOnSpeakerChange: Bool = false
    ) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        // Sanitize raw timestamps: fix overlaps and zero-duration words
        let words = sanitizeWordTimestamps(words)

        // Trim whitespace from word tokens (Whisper sometimes emits leading/trailing spaces)
        let trimmedWords = words.map { w in
            WordTimestamp(
                word: w.word.trimmingCharacters(in: .whitespacesAndNewlines),
                startMs: w.startMs,
                endMs: w.endMs,
                confidence: w.confidence,
                speakerId: w.speakerId
            )
        }

        // Merge hyphenated and apostrophe fragments (e.g. "warm" + "-up" → "warm-up")
        var mergedWords: [WordTimestamp] = []
        for word in trimmedWords {
            if mergedWords.isEmpty {
                mergedWords.append(word)
            } else {
                let last = mergedWords[mergedWords.count - 1]
                if word.word.hasPrefix("-") || word.word.hasPrefix("–") || word.word.hasPrefix("—") || word.word.hasPrefix("'") || word.word.hasPrefix("’") {
                    mergedWords[mergedWords.count - 1] = WordTimestamp(
                        word: last.word + word.word,
                        startMs: last.startMs,
                        endMs: word.endMs,
                        confidence: min(last.confidence, word.confidence),
                        speakerId: last.speakerId
                    )
                } else {
                    mergedWords.append(word)
                }
            }
        }

        // Sentence-aware pre-pass: when a cleaned transcript is supplied (or
        // the caller wants NL-driven boundaries), compute sentence units up
        // front. The main loop then force-flushes at each unit boundary,
        // which replaces the old "flush on any 800 ms gap" behaviour.
        // `sentenceUnitEndForWord[i] == true` means word i is the last word
        // of its sentence unit; flush after appending it.
        let useSentenceUnits = cleanedTranscript != nil
        var sentenceUnitEndForWord: [Bool] = []
        if useSentenceUnits {
            sentenceUnitEndForWord = Array(repeating: false, count: mergedWords.count)
            // `longPauseMs` defaults to 1500 — large enough that natural
            // breaths don't create boundaries, small enough that genuine
            // stop-and-start utterances do.
            let units = SubtitleSentenceSegmenter.segment(
                words: mergedWords,
                cleanedText: cleanedTranscript,
                longPauseMs: max(1500, config.gapThresholdMs * 2)
            )
            for u in units where u.endIndex < sentenceUnitEndForWord.count {
                sentenceUnitEndForWord[u.endIndex] = true
            }
        }

        // The "hard pause" safety net for the new path: even within a single
        // sentence unit, a multi-second silence forces a cue boundary. This
        // catches the rare case where NLTokenizer + long-pause fallback both
        // miss a true utterance gap.
        let hardPauseMs = 3000

        // Track word-level state
        var cues: [MutableCue] = []
        var currentWords: [WordTimestamp] = []
        var currentStartMs = words[0].startMs
        var currentSpeakerId = words[0].speakerId

        func flushCue(endIndex: Int) {
            guard !currentWords.isEmpty else { return }
            let endMs = words[min(endIndex, words.count - 1)].endMs
            cues.append(MutableCue(
                startMs: currentStartMs,
                endMs: endMs,
                words: currentWords.map(\.word),
                wordTimestamps: currentWords,
                speakerId: currentSpeakerId
            ))
            currentWords = []
        }

        for i in 0..<mergedWords.count {
            let word = mergedWords[i]
            let isLast = i == mergedWords.count - 1
            let hasNext = i < mergedWords.count - 1

            // Check speaker change
            let speakerChanged = breakOnSpeakerChange
                && !currentWords.isEmpty
                && word.speakerId != currentSpeakerId

            // Check timing gap. On the legacy path (no sentence units) this
            // is the 800 ms `gapThresholdMs` flush. On the new path it is
            // demoted to the much larger `hardPauseMs` so only multi-second
            // silences force a mid-sentence cue boundary.
            let gapFlushThreshold = useSentenceUnits ? hardPauseMs : config.gapThresholdMs
            let hasLongGap = hasNext && (mergedWords[i + 1].startMs - word.endMs) > gapFlushThreshold

            // Check duration limit
            let tooLong = word.endMs - currentStartMs > config.maxDurationMs

            // Build prospective text including this word
            let prospective = currentWords + [word]
            let prospectiveText = prospective.map(\.word).joined(separator: " ")
            let exceedsBudget = prospectiveText.count > config.maxCharsPerLine

            // --- SENTENCE BOUNDARY DETECTION ---
            // A sentence-ending punctuation mark (period, exclamation, question)
            // followed by a capitalized word is ALWAYS a cue boundary.
            let endsWithSentencePunctuation = config.breakOnPunctuation
                && (word.word.last.map { ".!?".contains($0) } ?? false)
            let nextWordIsSentenceStarter = hasNext
                && isSentenceStarter(mergedWords[i + 1].word)
            let isSentenceBoundary = endsWithSentencePunctuation
                && nextWordIsSentenceStarter

            // PHASE 1: Hard limits — speaker change, gap, or duration exceeded
            if speakerChanged || tooLong {
                if !currentWords.isEmpty {
                    flushCue(endIndex: i - 1)
                }
                currentStartMs = word.startMs
                currentSpeakerId = word.speakerId
                currentWords = [word]
                continue
            }

            // PHASE 1.5: Sentence-unit boundary (new path only).
            // `SubtitleSentenceSegmenter` has already pre-computed which words
            // sit at the end of a natural sentence unit. Trust it: append the
            // word and flush. This replaces the old "flush on any 800 ms gap"
            // logic that produced 1-word orphans every time a speaker took a
            // breath mid-clause.
            if useSentenceUnits && i < sentenceUnitEndForWord.count && sentenceUnitEndForWord[i] {
                currentWords.append(word)
                flushCue(endIndex: i)
                if hasNext {
                    currentStartMs = mergedWords[i + 1].startMs
                    currentSpeakerId = mergedWords[i + 1].speakerId
                }
                continue
            }

            // Long gap: the gap is AFTER this word, so this word belongs to the
            // current cue. Append it, flush, then start the next cue at i+1.
            // On the new sentence-unit path `gapFlushThreshold` is `hardPauseMs`
            // (3 s) — only true utterance gaps escape; normal pauses inside a
            // sentence stay inside one cue.
            if hasLongGap {
                currentWords.append(word)
                flushCue(endIndex: i)
                if hasNext {
                    currentStartMs = mergedWords[i + 1].startMs
                    currentSpeakerId = mergedWords[i + 1].speakerId
                }
                continue
            }

            // PHASE 2: Sentence boundary — flush before absorbing next sentence,
            // but only if the cue fits within budget. If it exceeds budget, let
            // PHASE 3 handle the split first.
            if isSentenceBoundary && prospectiveText.count <= config.maxCharsPerLine {
                currentWords.append(word)
                flushCue(endIndex: i)
                if hasNext {
                    currentStartMs = mergedWords[i + 1].startMs
                    currentSpeakerId = mergedWords[i + 1].speakerId
                }
                continue
            }

            // PHASE 2.5: Clause-start boundary — break before subordinating conjunctions
            // and relative pronouns that introduce a new dependent clause, even without
            // sentence-ending punctuation. Guards: breakOnPunctuation, min word count,
            // and must fit within budget so Phase 3 can handle overflow separately.
            let clauseStarters = Set(["because", "although", "since", "while", "whereas",
                                      "unless", "until", "though", "who", "which", "where", "when"])
            let nextIsClauseStart = hasNext
                && clauseStarters.contains(
                    mergedWords[i + 1].word.lowercased()
                        .trimmingCharacters(in: .punctuationCharacters))
            let shouldBreakForClause = config.breakOnPunctuation
                && nextIsClauseStart
                && currentWords.count >= config.minWordsBeforePunctuationBreak
                && prospectiveText.count <= config.maxCharsPerLine

            if shouldBreakForClause {
                currentWords.append(word)
                flushCue(endIndex: i)
                if hasNext {
                    currentStartMs = mergedWords[i + 1].startMs
                    currentSpeakerId = mergedWords[i + 1].speakerId
                }
                continue
            }

            // PHASE 3: Budget exceeded — find best boundary including this word
            if exceedsBudget && !currentWords.isEmpty {
                // Look ahead: if a sentence boundary is within the next 2 words,
                // allow a slight overflow (up to 20% over budget) to reach it naturally.
                var nearSentenceBoundary = false
                for offset in 1...2 {
                    let peekIdx = i + offset
                    guard peekIdx < mergedWords.count else { break }
                    let peekWord = mergedWords[peekIdx]
                    let hasNextPeek = peekIdx < mergedWords.count - 1
                    let peekEndsSentence = config.breakOnPunctuation
                        && (peekWord.word.last.map { ".!?".contains($0) } ?? false)
                    let nextIsStarter = hasNextPeek
                        && isSentenceStarter(mergedWords[peekIdx + 1].word)
                    if peekEndsSentence && nextIsStarter {
                        let extendedText = (prospective + mergedWords[(i + 1)...peekIdx]).map(\.word).joined(separator: " ")
                        if extendedText.count <= config.maxCharsPerLine {
                            nearSentenceBoundary = true
                        }
                        break
                    }
                }

                if !nearSentenceBoundary {
                    // Search backward for the best boundary in the FULL prospective cue
                    let boundaryIndex = findBestBoundaryBackward(
                        words: prospective,
                        maxChars: config.maxCharsPerLine
                    )

                    if boundaryIndex >= 0 && boundaryIndex < prospective.count - 1 {
                        // Everything before the boundary becomes a cue
                        let cueWords = Array(prospective[0...boundaryIndex])
                        cues.append(MutableCue(
                            startMs: currentStartMs,
                            endMs: cueWords.last?.endMs ?? word.endMs,
                            words: cueWords.map(\.word),
                            wordTimestamps: cueWords,
                            speakerId: currentSpeakerId
                        ))

                        // Everything after the boundary stays as current words
                        let remaining = Array(prospective[(boundaryIndex + 1)...])
                        currentWords = remaining
                        currentStartMs = remaining.first?.startMs ?? word.startMs
                    } else {
                        // No good split — flush what we have, keep current word for next
                        flushCue(endIndex: currentWords.count - 1)
                        currentWords = [word]
                        currentStartMs = word.startMs
                    }
                    continue
                }
                // If near a sentence boundary, fall through to append word
                // and let the sentence boundary phase catch it on the next iteration.
            }

            // PHASE 4: Clause-level punctuation (comma, semicolon) with min words guard
            let endsWithClausePunctuation = config.breakOnPunctuation
                && (word.word.last.map { ",;:".contains($0) } ?? false)
            let shouldBreakOnClause = endsWithClausePunctuation
                && currentWords.count >= config.minWordsBeforePunctuationBreak

            if shouldBreakOnClause {
            }

            currentWords.append(word)

            if shouldBreakOnClause {
                flushCue(endIndex: i)
                if hasNext {
                    currentStartMs = mergedWords[i + 1].startMs
                    currentSpeakerId = mergedWords[i + 1].speakerId
                }
            }

            // PHASE 5: End of stream
            if isLast && !currentWords.isEmpty {
                flushCue(endIndex: i)
            }
        }

        // Post-process: merge tiny orphaned cues
        cues = mergeOrphanedCues(cues, maxChars: config.maxCharsPerLine, maxLines: config.maxLinesPerCue, gapThresholdMs: config.gapThresholdMs)
        // Post-process: merge adjacent short cues into two-line blocks
        // (skipped when the user explicitly asked for single-line cues).
        if config.maxLinesPerCue >= 2 {
            cues = mergeAdjacentCuesForTwoLine(cues, maxChars: config.maxCharsPerLine, gapThresholdMs: config.gapThresholdMs)
        }
        // Post-process: split cues that exceed the maximum reading speed
        if config.maxCPS > 0 {
            cues = enforceReadingSpeed(cues, config: config)
            // Second orphan-merge pass: enforceReadingSpeed can produce new tiny
            // fragments when the only clean split leaves a short tail. Absorb any
            // that remain before the final timestamp passes.
            cues = mergeOrphanedCues(cues, maxChars: config.maxCharsPerLine, maxLines: config.maxLinesPerCue, gapThresholdMs: config.gapThresholdMs)
        }

        // Post-process: extend cue endMs by endTimeBufferMs to cover acoustic decay.
        // Runs before gap enforcement so any overlaps get cleaned up.
        if config.endTimeBufferMs > 0 {
            cues = applyEndTimeBuffer(cues, config: config)
        }

        // Post-process: snap timestamps to video frame boundaries (NLE export).
        if let fps = config.snapToFrameRate, fps > 0 {
            cues = applyFrameSnap(cues, fps: fps)
        }

        // Final pass: enforce monotonic non-overlapping timestamps.
        // Word-level sanitization prevents word overlaps, but cue-level overlaps
        // can still occur when consecutive cues are built from different timing
        // sources (e.g. a gap-flush followed by a next cue whose startMs is
        // slightly before the previous cue's endMs due to Parakeet jitter).
        cues = enforceMonotonicCues(cues)

        return cues.map { cue in
            SubtitleCue(
                startMs: cue.startMs,
                endMs: cue.endMs,
                text: wrapSubtitleText(cue.text, config: config),
                speakerId: cue.speakerId
            )
        }
    }

    /// Detect if a word starts a new sentence (capitalized, or short pronouns).
    private func isSentenceStarter(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        let firstIsUppercase = first.isUppercase
        let shortStarters = ["i", "we", "you", "they", "he", "she", "it", "the", "a", "an", "this", "that", "these", "those", "my", "our", "your", "their", "his", "her", "its", "go", "then", "thanks", "thank", "if", "and", "but", "or", "so", "yet", "now", "today", "let"]
        let lower = word.lowercased()
        return firstIsUppercase || shortStarters.contains(lower)
    }

    /// Find the best boundary by scanning backward from the end of the words array.
    /// Returns the index of the LAST word in the first segment (the cue to flush).
    ///
    /// Scoring philosophy: both resulting cues should feel like complete thoughts.
    /// We heavily penalize boundaries that leave conjunctions, articles, determiners,
    /// or prepositions dangling at the end of a cue, or that start the next cue
    /// with those same orphaned words. True punctuation marks are the gold standard.
    private func findBestBoundaryBackward(words: [WordTimestamp], maxChars: Int) -> Int {
        guard words.count > 2 else { return 0 }

        let badEnders = Set([
            "and", "but", "or", "so", "yet", "for", "nor", "then", "because", "although", "while", "whereas",
            "the", "a", "an",
            "my", "your", "his", "her", "its", "our", "their", "this", "that", "these", "those", "what", "which", "whose",
            "some", "any", "each", "every", "either", "neither", "both", "all", "no", "another", "such", "only", "own", "same", "other", "few", "many", "much", "several", "most", "more", "less",
            "in", "on", "at", "to", "of", "with", "from", "by", "as", "into", "onto", "about", "under", "over", "through", "during", "before", "after", "above", "below", "up", "down", "out", "off", "near", "like", "until", "since", "within", "without", "against", "among", "between", "toward", "towards",
            "i", "we", "you", "they", "he", "she", "it", "me", "us", "him", "her", "them", "mine", "yours", "ours", "hers", "theirs"
        ])

        let badStarters = Set([
            "and", "but", "or", "so", "yet", "for", "nor", "then", "because", "although", "while", "whereas",
            "the", "a", "an",
            "in", "on", "at", "to", "of", "with", "from", "by", "as", "into", "onto", "about", "under", "over", "through", "during", "before", "after", "above", "below", "up", "down", "out", "off", "near", "like", "until", "since", "within", "without", "against", "among", "between", "toward", "towards"
        ])

        let clauseStarters = Set(["because", "although", "since", "while", "whereas",
                                   "unless", "until", "though", "who", "which", "where", "when"])
        var candidates: [(index: Int, score: Int)] = []

        for splitIdx in stride(from: words.count - 2, through: 0, by: -1) {
            let firstText = words[0...splitIdx].map(\.word).joined(separator: " ")
            let secondText = words[(splitIdx + 1)...].map(\.word).joined(separator: " ")

            guard firstText.count <= maxChars && secondText.count <= maxChars else { continue }

            let lastWordRaw = words[splitIdx].word
            let lastWord = lastWordRaw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let nextWordRaw = words[splitIdx + 1].word
            let nextWord = nextWordRaw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            var score = 0

            // Real punctuation bonuses
            if words[splitIdx].word.last.map({ ".!?".contains($0) }) ?? false {
                score += 300
            }
            if words[splitIdx].word.hasSuffix(",") || words[splitIdx].word.hasSuffix(";") || words[splitIdx].word.hasSuffix(":") {
                score += 150
            }

            // Semantic completeness: noun/verb suffixes
            let nounSuffixes = ["ing", "tion", "sion", "ment", "ness", "ity", "ty", "er", "or", "ist", "ism", "age", "ure", "ence", "ance", "ome", "ide", "ine", "ese"]
            let verbSuffixes = ["ed", "en", "ize", "ise"]
            if nounSuffixes.contains(where: { lastWord.hasSuffix($0) }) || verbSuffixes.contains(where: { lastWord.hasSuffix($0) }) {
                score += 50
            }
            // Numbers
            if lastWordRaw.rangeOfCharacter(from: .decimalDigits) != nil && lastWordRaw.last?.isNumber == true {
                score += 40
            }
            // Capitalized words (proper nouns, names) feel complete
            if let first = lastWordRaw.first, first.isUppercase {
                score += 60
            }

            // Penalties for BAD boundary words
            if badEnders.contains(lastWord) {
                score -= 250
            }
            if lastWord.count == 1 {
                score -= 150
            }
            // Penalty for splitting hyphenated compounds or phrasal units
            if lastWordRaw.contains("-") && nextWordRaw.contains("-") {
                score -= 100
            }

            // Penalties for BAD starters
            if badStarters.contains(nextWord) {
                score -= 100
            }
            if nextWordRaw.hasPrefix(",") || nextWordRaw.hasPrefix(";") || nextWordRaw.hasPrefix(":") {
                score -= 150
            }

            // Bonus for breaking before a clause-starting word. These words naturally
            // open a dependent clause and make a clean subtitle entry point. The +175
            // offsets the badStarters -100 penalty above and adds a net +75 preference.
            if clauseStarters.contains(nextWord) {
                score += 175
            }

            // Length sanity
            let firstWordCount = splitIdx + 1
            let secondWordCount = words.count - splitIdx - 1
            if firstWordCount < 4 { score -= 100 }
            else if firstWordCount < 6 { score -= 40 }

            if secondWordCount < 4 { score -= 100 }
            else if secondWordCount < 6 { score -= 40 }

            // Number-range guard: don't split "between X and Y", "X to Y", "from X to Y"
            let lowerWords = words.map { $0.word.lowercased() }
            // Check if this split breaks a number range pattern
            if splitIdx >= 1 && splitIdx + 1 < words.count {
                let w0 = lowerWords[splitIdx - 1]
                let w1 = lowerWords[splitIdx]
                let w2 = lowerWords[splitIdx + 1]
                let _ = (splitIdx + 2 < words.count) ? lowerWords[splitIdx + 2] : nil
                // "between X and Y" → don't split at "and"
                if w0 == "between" && w1 == "and" && w2.rangeOfCharacter(from: .decimalDigits) != nil {
                    score -= 150
                }
                // "X to Y" or "from X to Y" → don't split at "to"
                if w1 == "to" && w2.rangeOfCharacter(from: .decimalDigits) != nil {
                    if w0.rangeOfCharacter(from: .decimalDigits) != nil || w0 == "from" {
                        score -= 150
                    }
                }
                // "X and Y" where both are numbers → don't split at "and"
                if w1 == "and" && w0.rangeOfCharacter(from: .decimalDigits) != nil && w2.rangeOfCharacter(from: .decimalDigits) != nil {
                    score -= 150
                }
            }

            // Phrasal-verb guard: don't split verb + particle pairs
            let particles = ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around", "through", "across", "along", "apart", "aside", "behind", "by", "forward", "into", "past", "to"]
            if splitIdx >= 1 && splitIdx + 1 < words.count {
                let boundaryWord = lowerWords[splitIdx]
                let nextWord = lowerWords[splitIdx + 1]
                // Common phrasal verbs: verb + particle
                let commonPhrasalVerbs: [String: [String]] = [
                    "welcome": ["in", "back"],
                    "take": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                    "hold": ["on", "up", "down", "out", "off", "over", "back"],
                    "bring": ["in", "on", "up", "down", "out", "off", "over", "back"],
                    "get": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "go": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "come": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "turn": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "pick": ["up", "on", "out", "over"],
                    "put": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                    "set": ["up", "down", "off", "out", "back"],
                    "sit": ["in", "on", "up", "down", "out", "back"],
                    "stand": ["in", "on", "up", "down", "out", "back"],
                    "slow": ["down", "up"],
                    "speed": ["up", "down"],
                    "warm": ["up", "down"],
                    "cool": ["down", "off"],
                    "reach": ["out", "up", "down", "over"],
                    "jump": ["in", "on", "up", "down", "out", "over"],
                    "look": ["in", "on", "up", "down", "out", "over", "away", "back", "around"],
                    "check": ["in", "on", "up", "out", "over"],
                    "work": ["in", "on", "up", "out", "over", "through"],
                    "move": ["in", "on", "up", "down", "out", "over", "away", "back", "around"],
                    "pull": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                    "push": ["in", "on", "up", "down", "out", "off", "over", "through"],
                    "run": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "walk": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                    "catch": ["up", "on", "out"],
                    "cut": ["in", "down", "off", "out", "up"],
                    "break": ["in", "down", "off", "out", "up"],
                    "call": ["in", "on", "up", "out", "off", "back"],
                    "fall": ["in", "down", "off", "out", "back", "behind"],
                    "give": ["in", "up", "away", "back", "out"],
                    "hand": ["in", "on", "over", "out", "back"],
                    "keep": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                    "leave": ["in", "on", "out", "off", "over", "behind"],
                    "let": ["in", "on", "up", "down", "out", "off", "over"],
                    "make": ["out", "up", "over"],
                    "pay": ["in", "on", "up", "out", "off", "back"],
                    "play": ["in", "on", "up", "down", "out", "off", "over", "around"],
                    "point": ["in", "on", "up", "down", "out", "off", "over", "at"],
                    "show": ["in", "on", "up", "down", "out", "off", "over", "around"],
                    "shut": ["in", "on", "up", "down", "out", "off", "over"],
                    "speak": ["in", "on", "up", "down", "out", "off", "over", "about"],
                    "start": ["in", "on", "up", "down", "out", "off", "over"],
                    "stop": ["in", "on", "up", "down", "out", "off", "over"],
                    "throw": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                    "try": ["in", "on", "up", "down", "out", "off", "over"],
                    "use": ["in", "on", "up", "down", "out", "off", "over"],
                    "watch": ["in", "on", "up", "down", "out", "off", "over"]
                ]
                if let allowedParticles = commonPhrasalVerbs[boundaryWord], allowedParticles.contains(nextWord) {
                    score -= 100
                }
                // Generic particle after verb
                if particles.contains(nextWord) {
                    score -= 30
                }
            }

            // Gap bonus: reward splits at points where the speaker naturally paused.
            // A 500 ms silence yields +100 — significant but below a comma (+150) or
            // sentence boundary (+300), so linguistic cues still win when present.
            let gapMs = max(0, words[splitIdx + 1].startMs - words[splitIdx].endMs)
            score += min(gapMs / 5, 100)

            // Prefer balanced
            let totalLen = firstText.count + secondText.count
            let idealLen = totalLen / 2
            let firstDiff = abs(firstText.count - idealLen)
            let secondDiff = abs(secondText.count - idealLen)
            score -= (firstDiff + secondDiff) / 2

            candidates.append((splitIdx, score))
        }

        // Hard constraint: prefer boundaries that don't end with bad words
        let goodCandidates = candidates.filter { idx, _ in
            let lastWord = words[idx].word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !badEnders.contains(lastWord)
        }

        if let best = goodCandidates.max(by: { $0.score < $1.score }) {
            return best.index
        }

        let fallback = candidates.max(by: { $0.score < $1.score })
        return fallback?.index ?? 0
    }

    /// Post-process: split cues whose reading speed exceeds config.maxCPS.
    /// Uses the same boundary scorer as the main cue-building loop. If no clean
    /// split exists (e.g. only 2 words), the cue is left untouched.
    private func enforceReadingSpeed(_ cues: [MutableCue], config: SubtitleExportConfig) -> [MutableCue] {
        var result: [MutableCue] = []

        for cue in cues {
            let durationSec = Double(cue.endMs - cue.startMs) / 1000.0
            guard durationSec > 0.1 else {
                result.append(cue)
                continue
            }

            // Respect cues that mergeAdjacentCuesForTwoLine intentionally
            // packed into a two-line block. Splitting them here would just
            // recreate the original fragments — undoing the packing pass.
            if cue.forcedText != nil {
                result.append(cue)
                continue
            }

            let cps = Double(cue.text.count) / durationSec
            guard cps > config.maxCPS && cue.wordTimestamps.count > 2 else {
                result.append(cue)
                continue
            }

            let boundaryIndex = findBestBoundaryBackward(
                words: cue.wordTimestamps,
                maxChars: config.maxCharsPerLine
            )

            if boundaryIndex > 0 && boundaryIndex < cue.wordTimestamps.count - 1 {
                let firstWords = Array(cue.wordTimestamps[0...boundaryIndex])
                let secondWords = Array(cue.wordTimestamps[(boundaryIndex + 1)...])
                // Do not split if either piece would be an orphan (< 3 words).
                // Producing a 1–2 word fragment undoes mergeOrphanedCues work and
                // creates the very tiny cues we're trying to avoid.
                guard firstWords.count >= 3 && secondWords.count >= 3 else {
                    result.append(cue)
                    continue
                }
                result.append(MutableCue(
                    startMs: cue.startMs,
                    endMs: firstWords.last!.endMs,
                    words: firstWords.map(\.word),
                    wordTimestamps: firstWords,
                    speakerId: cue.speakerId
                ))
                result.append(MutableCue(
                    startMs: secondWords.first!.startMs,
                    endMs: cue.endMs,
                    words: secondWords.map(\.word),
                    wordTimestamps: secondWords,
                    speakerId: cue.speakerId
                ))
            } else {
                result.append(cue)
            }
        }

        return result
    }

    /// Post-process: extend every cue's endMs by `config.endTimeBufferMs`.
    ///
    /// Parakeet timestamps a word's end at the acoustic threshold crossing, but the
    /// audible sound continues briefly (formant decay, consonant release). Adding a
    /// small buffer keeps cues visible through the full duration of the last word.
    ///
    /// If the buffer would push a cue's endMs past the next cue's startMs, clamp it
    /// so there is at least a 1 ms gap (preventing invalid SRT ordering).
    private func applyEndTimeBuffer(_ cues: [MutableCue], config: SubtitleExportConfig) -> [MutableCue] {
        guard config.endTimeBufferMs > 0 else { return cues }
        var result = cues
        for i in 0..<result.count {
            let buffered = result[i].endMs + config.endTimeBufferMs
            if i + 1 < result.count {
                // Do not overlap the next cue (leave at least 1 ms gap)
                result[i].endMs = min(buffered, result[i + 1].startMs - 1)
            } else {
                result[i].endMs = buffered
            }
        }
        return result
    }

    /// Post-process: snap cue timestamps to video frame boundaries.
    ///
    /// startMs rounds DOWN (cue appears no later than intended).
    /// endMs rounds UP (cue disappears no earlier than intended).
    private func applyFrameSnap(_ cues: [MutableCue], fps: Double) -> [MutableCue] {
        let frameMs = 1000.0 / fps
        func snap(_ ms: Int, rule: FloatingPointRoundingRule) -> Int {
            Int((Double(ms) / frameMs).rounded(rule) * frameMs)
        }
        return cues.map { cue in
            MutableCue(
                startMs: snap(cue.startMs, rule: .down),
                endMs:   snap(cue.endMs,   rule: .up),
                words: cue.words,
                wordTimestamps: cue.wordTimestamps,
                speakerId: cue.speakerId,
                forcedText: cue.forcedText
            )
        }
    }

    /// Post-process: ensure cue N's endMs does not exceed cue N+1's startMs.
    ///
    /// Word-level sanitization prevents word overlaps, but cue-level overlaps
    /// can still appear due to Parakeet timestamp jitter — e.g. after a
    /// gap-triggered flush the preceding cue's endMs may sit a few ms after
    /// the next cue's startMs. SRT/VTT players silently misrender overlapping
    /// cues. This pass clamps each cue's endMs to (nextStartMs - 1) when
    /// an overlap is detected, ensuring a strictly non-overlapping sequence.
    private func enforceMonotonicCues(_ cues: [MutableCue]) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        var result = cues
        for i in 0..<result.count - 1 {
            if result[i].endMs >= result[i + 1].startMs {
                result[i].endMs = result[i + 1].startMs - 1
            }
            // Also ensure each cue has positive duration
            if result[i].endMs <= result[i].startMs {
                result[i].endMs = result[i].startMs + 1
            }
        }
        return result
    }

    /// Post-process: merge cues that are too small with neighbours when possible.
    private func mergeOrphanedCues(_ cues: [MutableCue], maxChars: Int, maxLines: Int = 2, gapThresholdMs: Int = 800) -> [MutableCue] {
        guard cues.count > 1 else { return cues }

        let minChars = 15
        // Keep minWords at 3 so it doesn't reabsorb the 3-word tail
        // enforceReadingSpeed's orphan-guard intentionally leaves behind.
        let minWords = 3
        // `maxChars` is the TOTAL cue budget (across all rendered lines).
        // A small tolerance lets us absorb a 1–2 char overage when the
        // alternative is an orphaned 1-word cue, which is far worse.
        let maxBudget = maxChars + 10

        func crossesLongGapForTiny(_ a: MutableCue, _ b: MutableCue) -> Bool {
            (b.startMs - a.endMs) > gapThresholdMs
        }

        var result = cues

        // Iterate forward + backward passes until no more merges happen.
        // A single pair of passes can leave new orphans (e.g. a 3-cue chain
        // where the middle was tiny — once merged into the next, the prev
        // becomes a new candidate). Repeating to fixpoint avoids that.
        var didMerge = true
        var safetyIterations = 0
        while didMerge && safetyIterations < 8 {
            didMerge = false
            safetyIterations += 1

            // Forward pass: absorb tiny cue into next cue
            var i = 0
            while i < result.count - 1 {
                let current = result[i]
                let isTiny = current.text.count < minChars || current.words.count < minWords
                if isTiny {
                    let next = result[i + 1]
                    let merged = current.text + " " + next.text
                    if merged.count <= maxBudget && !crossesLongGapForTiny(current, next) {
                        result[i] = MutableCue(
                            startMs: current.startMs,
                            endMs: next.endMs,
                            words: current.words + next.words,
                            wordTimestamps: current.wordTimestamps + next.wordTimestamps,
                            speakerId: current.speakerId
                        )
                        result.remove(at: i + 1)
                        didMerge = true
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
                    if merged.count <= maxBudget && !crossesLongGapForTiny(prev, current) {
                        result[i - 1] = MutableCue(
                            startMs: prev.startMs,
                            endMs: current.endMs,
                            words: prev.words + current.words,
                            wordTimestamps: prev.wordTimestamps + current.wordTimestamps,
                            speakerId: prev.speakerId
                        )
                        result.remove(at: i)
                        didMerge = true
                        continue
                    }
                }
                i += 1
            }
        }

        return result
    }

    /// Post-process: merge adjacent short cues into two-line blocks when
    /// the combined text fits within the total character budget.
    private func mergeAdjacentCuesForTwoLine(_ cues: [MutableCue], maxChars: Int, gapThresholdMs: Int = 800) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let tolerance = 8
        var result = cues
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let next = result[i + 1]
            // Combined text with newline separator (pre-formatted 2-line)
            let mergedText = current.text + "\n" + next.text
            let mergedCount = mergedText.count
            // Also accept a space-joined version for length check
            let spaceMerged = current.text + " " + next.text
            let spaceCount = spaceMerged.count

            // Phrasal-verb bonus: if the boundary completes a phrasal verb,
            // allow a slightly larger effective budget.
            let phrasalBonus: Int
            let commonPhrasalVerbs: [String: [String]] = [
                "welcome": ["in", "back"],
                "take": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                "hold": ["on", "up", "down", "out", "off", "over", "back"],
                "bring": ["in", "on", "up", "down", "out", "off", "over", "back"],
                "get": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "go": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "come": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "turn": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "pick": ["up", "on", "out", "over"],
                "put": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                "set": ["up", "down", "off", "out", "back"],
                "sit": ["in", "on", "up", "down", "out", "back"],
                "stand": ["in", "on", "up", "down", "out", "back"],
                "slow": ["down", "up"],
                "speed": ["up", "down"],
                "warm": ["up", "down"],
                "cool": ["down", "off"],
                "reach": ["out", "up", "down", "over"],
                "jump": ["in", "on", "up", "down", "out", "over"],
                "look": ["in", "on", "up", "down", "out", "over", "away", "back", "around"],
                "check": ["in", "on", "up", "out", "over"],
                "work": ["in", "on", "up", "out", "over", "through"],
                "move": ["in", "on", "up", "down", "out", "over", "away", "back", "around"],
                "pull": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                "push": ["in", "on", "up", "down", "out", "off", "over", "through"],
                "run": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "walk": ["in", "on", "up", "down", "out", "off", "over", "away", "back", "around"],
                "catch": ["up", "on", "out"],
                "cut": ["in", "down", "off", "out", "up"],
                "break": ["in", "down", "off", "out", "up"],
                "call": ["in", "on", "up", "out", "off", "back"],
                "fall": ["in", "down", "off", "out", "back", "behind"],
                "give": ["in", "up", "away", "back", "out"],
                "hand": ["in", "on", "over", "out", "back"],
                "keep": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                "leave": ["in", "on", "out", "off", "over", "behind"],
                "let": ["in", "on", "up", "down", "out", "off", "over"],
                "make": ["out", "up", "over"],
                "pay": ["in", "on", "up", "out", "off", "back"],
                "play": ["in", "on", "up", "down", "out", "off", "over", "around"],
                "point": ["in", "on", "up", "down", "out", "off", "over", "at"],
                "show": ["in", "on", "up", "down", "out", "off", "over", "around"],
                "shut": ["in", "on", "up", "down", "out", "off", "over"],
                "speak": ["in", "on", "up", "down", "out", "off", "over", "about"],
                "start": ["in", "on", "up", "down", "out", "off", "over"],
                "stop": ["in", "on", "up", "down", "out", "off", "over"],
                "throw": ["in", "on", "up", "down", "out", "off", "over", "away", "back"],
                "try": ["in", "on", "up", "down", "out", "off", "over"],
                "use": ["in", "on", "up", "down", "out", "off", "over"],
                "watch": ["in", "on", "up", "down", "out", "off", "over"]
            ]
            let lastWord = current.words.last?.lowercased() ?? ""
            let firstWord = next.words.first?.lowercased() ?? ""
            if let particles = commonPhrasalVerbs[lastWord], particles.contains(firstWord) {
                phrasalBonus = 10
            } else {
                phrasalBonus = 0
            }
            // `maxCharsPerLine` is the TOTAL character budget for a cue
            // (across all lines), not a per-line cap. Two short cues are only
            // packed when their combined text fits within that total budget.
            // Phrasal-verb joins get a small extra allowance so we don't
            // refuse a tidy merge that's barely over budget.
            let hasPhrasalBonus = phrasalBonus > 0
            let effectiveMax = hasPhrasalBonus ? maxChars + tolerance + phrasalBonus : maxChars + tolerance

            // Merge if EITHER the 2-line pre-formatted OR space-joined fits in budget,
            // and both individual cues are short enough to benefit from merging.
            let crossesGap = (next.startMs - current.endMs) > gapThresholdMs
            let shouldMerge = (mergedCount <= effectiveMax || spaceCount <= effectiveMax)
                && current.text.count <= maxChars
                && next.text.count <= maxChars
                && current.words.count + next.words.count <= 20  // sanity cap
                && !crossesGap
            if shouldMerge {
                result[i] = MutableCue(
                    startMs: current.startMs,
                    endMs: next.endMs,
                    words: current.words + next.words,
                    wordTimestamps: current.wordTimestamps + next.wordTimestamps,
                    speakerId: current.speakerId
                )
                // Pre-format as two lines so wrapSubtitleText won't touch it
                result[i].forcedText = mergedText
                result.remove(at: i + 1)
                continue
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
    /// Wrap subtitle text across up to maxLinesPerCue lines.
    ///
    /// maxCharsPerLine is treated as the *total* character budget for the cue.
    /// If the cue text fits on a single line (within the total budget), it is NOT
    /// forced into multiple lines. Only cues that exceed the total budget are split,
    /// and the split targets roughly equal line lengths based on the actual text size.
    func wrapSubtitleText(_ text: String, config: SubtitleExportConfig) -> String {
        Self.wrapSubtitleTextStatic(text, config: config)
    }

    /// Pure line-wrapping helper callable from non-main contexts (e.g.
    /// `SubtitleLLMRefiner`). Keep in sync with `wrapSubtitleText`.
    ///
    /// Treats `config.maxCharsPerLine` as the **total** character budget for
    /// the cue across all rendered lines (NOT a per-line cap). The total is
    /// distributed across at most `config.maxLinesPerCue` lines; if the input
    /// somehow exceeds the total, lines beyond `maxLinesPerCue` are folded
    /// back onto the final line.
    nonisolated static func wrapSubtitleTextStatic(_ text: String, config: SubtitleExportConfig) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let words = cleaned.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return cleaned }

        // Single line only
        if config.maxLinesPerCue <= 1 {
            return cleaned
        }

        // If the cue fits in the per-line budget (≈ total / lines), keep one line.
        let perLineBudget = max(10, config.maxCharsPerLine / config.maxLinesPerCue)
        if cleaned.count <= perLineBudget {
            return cleaned
        }

        // Otherwise distribute across up to maxLinesPerCue lines, each
        // targeting `text.count / maxLinesPerCue` chars for balance.
        let targetLineLength = max(perLineBudget, Int(ceil(Double(cleaned.count) / Double(config.maxLinesPerCue))))

        if config.maxLinesPerCue == 2 && config.preferBalancedLines && words.count > 1 {
            if let balanced = wrapSubtitleTextBalanced(words: words, perLineBudget: targetLineLength, maxLineLength: config.maxCharsPerLine) {
                return clampLines(balanced, maxLines: config.maxLinesPerCue)
            }
        }

        return clampLines(
            wrapSubtitleTextGreedy(words: words, perLineBudget: targetLineLength, maxLines: config.maxLinesPerCue),
            maxLines: config.maxLinesPerCue
        )
    }

    /// Defence in depth — if any upstream wrap step produced more than the
    /// configured number of lines, fold the overflow into the final line so
    /// the cue still renders as a valid N-line block.
    nonisolated private static func clampLines(_ text: String, maxLines: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxLines else { return text }
        let kept = lines.prefix(maxLines - 1).map { $0 }
        let overflow = lines.dropFirst(maxLines - 1).joined(separator: " ")
        return (kept + [overflow]).joined(separator: "\n")
    }

    /// Greedy wrap: fill each line until the next word would exceed budget.
    /// Post-processes to avoid orphaned very-short final lines.
    nonisolated private static func wrapSubtitleTextGreedy(words: [String], perLineBudget: Int, maxLines: Int) -> String {
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
    nonisolated private static func wrapSubtitleTextBalanced(words: [String], perLineBudget: Int, maxLineLength: Int) -> String? {
        var bestSplit = 0
        var bestScore = Int.min

        for splitAfter in 1..<words.count {
            let line1 = words[0..<splitAfter].joined(separator: " ")
            let line2 = words[splitAfter...].joined(separator: " ")

            // Hard constraint: neither line can exceed budget
            guard line1.count <= maxLineLength && line2.count <= maxLineLength else { continue }

            // Minimum line length: reject splits that leave a very short line
            guard line1.count >= 5 && line2.count >= 5 else { continue }

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

            // 4. Orphan penalty: strongly avoid a very short last line
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
            let cues = buildSubtitleCues(
                from: timestamps,
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
            )
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
            let cues = buildSubtitleCues(
                from: timestamps,
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript
            )
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
