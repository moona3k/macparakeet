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
        cleanedTranscript: String?,
        engineSegments: [STTSegment]?
    ) -> String
    func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]?,
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool,
        cleanedTranscript: String?,
        engineSegments: [STTSegment]?
    ) -> String
    func formatMarkdown(transcription: Transcription) -> String
    func formatForClipboard(transcription: Transcription) -> String
}

/// Progress event from the subtitle export pipeline.
///
/// LLM-driven exports run in TWO phases — first the layout planner
/// picks cue boundaries from raw words (chunk-by-chunk), then the
/// reviewer walks adjacent cue pairs voting keep/merge/shift. The
/// UI shows separate progress bars for each so the user knows
/// what's actually happening (and that the export hasn't stalled
/// just because the bar paused between phases).
public struct SubtitleExportProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable, Codable {
        /// `SubtitleLLMLayoutPlanner` — N chunks of ~80 words each.
        case layout
        /// `SubtitleLLMReviewer` — N-1 cue pairs.
        case review
    }
    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public typealias SubtitleExportProgressHandler = @Sendable (SubtitleExportProgress) -> Void

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

    /// When `true`, the export pipeline runs `NumberNormalizer` over every
    /// cue's final wrapped text, converting unambiguous spelled-out cardinals
    /// to digits ("eighty-five to ninety" -> "85 to 90"). Default: false.
    /// Mirrors the Vocabulary "Numbers" toggle so users who want it in their
    /// dictation output also get it in their subtitle exports.
    public var normalizeNumbers: Bool

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
        snapToFrameRate: Double? = nil,
        normalizeNumbers: Bool = false
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
        self.normalizeNumbers = normalizeNumbers
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
             endTimeBufferMs, snapToFrameRate, normalizeNumbers
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
        normalizeNumbers             = try c.decodeIfPresent(Bool.self, forKey: .normalizeNumbers) ?? false
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
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        onExportProgress: SubtitleExportProgressHandler? = nil
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
            onExportProgress: onExportProgress,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
            engineSegments: transcription.transcriptSegments
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
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        onExportProgress: SubtitleExportProgressHandler? = nil
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
            onExportProgress: onExportProgress,
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
            engineSegments: transcription.transcriptSegments
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
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
            engineSegments: transcription.transcriptSegments
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
            cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
            engineSegments: transcription.transcriptSegments
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
        cleanedTranscript: String? = nil,
        engineSegments: [STTSegment]? = nil
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
            engineSegments: engineSegments,
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

    /// Async variant of formatSRT.
    ///
    /// When `config.useLLMRefinement` is true and `llmService` is supplied,
    /// the LLM-driven layout planner picks the cue boundaries (see
    /// `SubtitleLLMLayoutPlanner`). On any per-chunk failure the
    /// deterministic builder runs as a silent fallback for the whole
    /// transcript, so the export always succeeds.
    public func formatSRT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        onExportProgress: SubtitleExportProgressHandler? = nil,
        cleanedTranscript: String? = nil,
        engineSegments: [STTSegment]? = nil
    ) async throws -> String {
        let cues = await produceSubtitleCues(
            words: words,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels,
            llmService: llmService,
            onLegacyProgress: onRefinementProgress,
            onExportProgress: onExportProgress,
            cleanedTranscript: cleanedTranscript,
            engineSegments: engineSegments
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

    /// Async variant of formatVTT. See `formatSRT` async for the LLM
    /// layout / deterministic-fallback behaviour.
    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        llmService: LLMServiceProtocol?,
        onRefinementProgress: SubtitleLLMRefiner.ProgressHandler? = nil,
        onExportProgress: SubtitleExportProgressHandler? = nil,
        cleanedTranscript: String? = nil,
        engineSegments: [STTSegment]? = nil
    ) async throws -> String {
        let cues = await produceSubtitleCues(
            words: words,
            config: config,
            includeSpeakerLabels: includeSpeakerLabels,
            llmService: llmService,
            onLegacyProgress: onRefinementProgress,
            onExportProgress: onExportProgress,
            cleanedTranscript: cleanedTranscript,
            engineSegments: engineSegments
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

    /// Single source of truth for the LLM-layout vs deterministic-layout
    /// decision, used by both `formatSRT (async)` and `formatVTT (async)`.
    ///
    /// LLM path:
    /// 1. Build sentence units (cleanedTranscript / engineSegments / fallback).
    /// 2. Hand them + the word array to `SubtitleLLMLayoutPlanner`.
    /// 3. If every chunk laid out cleanly, run the timing post-passes
    ///    (`endTimeBuffer`, `frameSnap`, `enforceMonotonicCues`) over the
    ///    planner's cues and wrap each cue's text. Done.
    /// 4. If ANY chunk fell back, throw the LLM cues away and run the
    ///    deterministic builder over the full transcript instead. The
    ///    deterministic path already applies all post-processing, so we
    ///    return its result directly.
    private func produceSubtitleCues(
        words: [WordTimestamp],
        config: SubtitleExportConfig,
        includeSpeakerLabels: Bool,
        llmService: LLMServiceProtocol?,
        onLegacyProgress: SubtitleLLMRefiner.ProgressHandler?,
        onExportProgress: SubtitleExportProgressHandler?,
        cleanedTranscript: String?,
        engineSegments: [STTSegment]?
    ) async -> [SubtitleCue] {
        let deterministic: () -> [SubtitleCue] = {
            self.buildSubtitleCues(
                from: words,
                cleanedTranscript: cleanedTranscript,
                engineSegments: engineSegments,
                config: config,
                breakOnSpeakerChange: includeSpeakerLabels
            )
        }

        guard config.useLLMRefinement, let llmService = llmService else {
            return deterministic()
        }

        // Compute sentence units from the same source the deterministic
        // builder would have used. Prefer engine segments when present.
        let sanitized = sanitizeWordTimestamps(words)
        let units: [SentenceUnit]
        if let segments = engineSegments, !segments.isEmpty {
            units = sentenceUnitsFromEngineSegments(segments, words: sanitized)
        } else {
            units = SubtitleSentenceSegmenter.segment(
                words: sanitized,
                cleanedText: cleanedTranscript,
                longPauseMs: max(1500, config.gapThresholdMs * 2)
            )
        }

        let planner = SubtitleLLMLayoutPlanner(llmService: llmService)
        // Bridge planner progress to BOTH the legacy handler (so older
        // callers that only know about the layout phase still work)
        // and the new combined handler (which the GUI uses to drive
        // its two-bar export overlay).
        let layoutProgress: SubtitleLLMLayoutPlanner.ProgressHandler = { completed, total in
            onLegacyProgress?(completed, total)
            onExportProgress?(SubtitleExportProgress(
                phase: .layout, completed: completed, total: total
            ))
        }
        let chunkResults = await planner.plan(
            words: sanitized,
            units: units,
            config: config,
            speakerId: nil,
            onProgress: layoutProgress
        )

        // Any chunk fell back to nil → use deterministic for the whole
        // transcript. Mixing per-chunk LLM output with per-chunk
        // deterministic output is possible but complicates the
        // post-processing; full fallback is simpler and the user
        // already opted into one or the other quality bar.
        guard !chunkResults.contains(where: { $0.didFallBack }) else {
            return deterministic()
        }

        // Stitch chunk cues + timing post-processing.
        let llmCues = chunkResults.flatMap { $0.cues ?? [] }
        // When LLM service is configured, run the review pass between
        // the rebalance and timing passes. Reviewer progress fires
        // through the new combined handler only — the legacy handler
        // never knew about phase 2.
        return await applyTimingPostProcessingWithReview(
            llmCues,
            config: config,
            llmService: llmService,
            onReviewProgress: { completed, total in
                onExportProgress?(SubtitleExportProgress(
                    phase: .review, completed: completed, total: total
                ))
            }
        )
    }

    /// Run `endTimeBuffer`, `frameSnap`, `enforceMonotonicCues`, and
    /// `wrapSubtitleText` on a list of already-laid-out cues. Used by the
    /// LLM-layout path; the deterministic builder runs these inline.
    /// Post-process LLM-laid-out cues with the same merge + timing
    /// passes the deterministic builder uses, minus `enforceReadingSpeed`
    /// (consistent with the sentence-aware path).
    ///
    /// The LLM tends to over-fragment — real-world telemetry shows it
    /// producing ~5 cues for a 99-char sentence where 2 would suffice,
    /// and occasionally splitting mid-number-range like "between 80 /
    /// and 90.". Running `mergeOrphanedCues` and friends on its output
    /// consolidates short orphans into their neighbours without
    /// throwing away the LLM's better boundary choices elsewhere.
    /// Test-only entry point that exposes the LLM cue post-processing
    /// pipeline (`mergeOrphanedCues` + `mergeAdjacentCuesForTwoLine` +
    /// `absorbShortNeighbours` + timing passes + wrap). The behaviour is
    /// identical to the in-pipeline call site; the only reason it's
    /// nonprivate is so a regression test can drive realistic SRT
    /// scenarios (LLM-fragmented cadence callouts, etc.) without having
    /// to mock the whole layout planner.
    func applyTimingPostProcessingForTesting(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        applyTimingPostProcessing(cues, config: config)
    }

    private func applyTimingPostProcessing(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        let mutable = mergeAndRebalancePasses(cues, config: config)
        return applyTimingAndWrap(mutable, config: config)
    }

    /// Async variant that runs the LLM reviewer between the rebalance
    /// passes and the timing passes. Used by the LLM-layout path when
    /// `config.useLLMRefinement` is on AND an LLM service is configured.
    ///
    /// The reviewer looks at each adjacent cue pair, votes
    /// keep/merge/shift, and we apply each valid suggestion before
    /// running timing + wrap. Failures (bad JSON, invalid action,
    /// budget violation) are silently skipped — the pair stays as
    /// the rebalance passes left it.
    private func applyTimingPostProcessingWithReview(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig,
        llmService: LLMServiceProtocol,
        onReviewProgress: SubtitleLLMReviewer.ProgressHandler? = nil
    ) async -> [SubtitleCue] {
        var mutable = mergeAndRebalancePasses(cues, config: config)
        mutable = await applyLLMReview(
            mutable,
            config: config,
            llmService: llmService,
            onReviewProgress: onReviewProgress
        )
        // Re-run the rebalance passes AFTER the reviewer to clean up
        // any new bad-enders / trailing fragments / cardinal-unit
        // splits the LLM may have introduced. The rebalance passes
        // are idempotent — running them on already-clean cues is a
        // no-op — but the reviewer can legitimately create a fresh
        // bad pattern (SRT 33 regression: reviewer suggested merges
        // that left "We", "have", "because" stranded at cue tails).
        // Without this second cleanup pass, the damage would land in
        // the final SRT.
        mutable = rebalanceTrailingSentenceFragment(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceCardinalUnitPairs(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceBadEnders(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceBadStarters(mutable, maxChars: config.maxCharsPerLine)
        return applyTimingAndWrap(mutable, config: config)
    }

    /// Shared first phase: convert public `SubtitleCue` → internal
    /// `MutableCue`, then run the merge passes and deterministic
    /// rebalance passes. No timing changes, no text wrap.
    private func mergeAndRebalancePasses(
        _ cues: [SubtitleCue],
        config: SubtitleExportConfig
    ) -> [MutableCue] {
        // Convert to MutableCue. The merge passes read `.text` (derived
        // from `.words`), so populating `.words` by splitting the LLM
        // text on spaces gives them what they need without us needing
        // the original word timestamps.
        var mutable = cues.map { c in
            MutableCue(
                startMs: c.startMs,
                endMs: c.endMs,
                words: c.text.split(separator: " ").map(String.init),
                wordTimestamps: [],
                speakerId: c.speakerId,
                forcedText: nil
            )
        }
        // Same merge sequence as `buildSubtitleCues` (sans
        // `enforceReadingSpeed` — see the sentence-unit path).
        mutable = mergeOrphanedCues(
            mutable,
            maxChars: config.maxCharsPerLine,
            maxLines: config.maxLinesPerCue,
            gapThresholdMs: config.gapThresholdMs
        )
        if config.maxLinesPerCue >= 2 {
            mutable = mergeAdjacentCuesForTwoLine(
                mutable,
                maxChars: config.maxCharsPerLine,
                gapThresholdMs: config.gapThresholdMs
            )
        }
        mutable = absorbShortNeighbours(
            mutable,
            maxChars: config.maxCharsPerLine,
            gapThresholdMs: config.gapThresholdMs
        )
        // Post-LLM rebalance passes. The merge passes above handle "cue
        // too short to display"; these handle "cue ends/starts on the
        // wrong word" — e.g. cue ends with `the`/`our`/`and` (bad
        // ender) or cue ends with a cardinal and the next cue starts
        // with a measurement unit (`...next 30` / `minutes...`).
        // Both are deterministic and engine-agnostic — they fix
        // whatever the LLM emitted regardless of which model produced
        // the split.
        //
        // Order matters: cardinal+unit runs FIRST because moving a
        // cardinal forward can expose a new bad-ender at the tail of
        // the previous cue (SRT 25 cue 5: moving "four" left "your"
        // dangling). Bad-ender pass then picks that up.
        // Bad-starter mirrors bad-ender from the other side — slides
        // the OPENING words of cue N+1 back into cue N when they're
        // function words ("of", "because", "and") that read better
        // attached to the prior phrase.
        //
        // Trailing-sentence-fragment runs even before cardinal+unit:
        // it's a structural fix (sentence boundaries should be cue
        // boundaries) and the other passes assume sentences don't
        // straddle the cue boundary by more than a function word.
        // SRT 31 cue 10 was the smoking gun: "It is great to have
        // you. Go" / "ahead and find a cadence somewhere between 80
        // and 90." — the LLM put one word from the NEXT sentence at
        // the tail of cue N.
        mutable = rebalanceTrailingSentenceFragment(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceCardinalUnitPairs(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceBadEnders(mutable, maxChars: config.maxCharsPerLine)
        mutable = rebalanceBadStarters(mutable, maxChars: config.maxCharsPerLine)
        return mutable
    }

    /// Shared final phase: end-time buffer, frame snap, monotonic
    /// enforcement, then wrap each cue's text. Converts back to
    /// `SubtitleCue` for the caller.
    private func applyTimingAndWrap(
        _ cues: [MutableCue],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        var mutable = cues
        if config.endTimeBufferMs > 0 {
            mutable = applyEndTimeBuffer(mutable, config: config)
        }
        if let fps = config.snapToFrameRate, fps > 0 {
            mutable = applyFrameSnap(mutable, fps: fps)
        }
        mutable = enforceMonotonicCues(mutable)
        // Final map: wrap the merged cue's text (which is the joined
        // word list, or `forcedText` if `mergeAdjacentCuesForTwoLine`
        // set it). Wrap respects existing `\n` so forced-two-line cues
        // stay as authored.
        return mutable.map { mut in
            SubtitleCue(
                startMs: mut.startMs,
                endMs: mut.endMs,
                text: wrapSubtitleText(mut.text, config: config),
                speakerId: mut.speakerId
            )
        }
    }

    /// Collect suggestions from `SubtitleLLMReviewer`, then apply each
    /// valid one to the cue list. Each suggestion is re-validated
    /// against the CURRENT cue state (previous applications can shift
    /// what's possible). Failures are silently skipped — the pair
    /// stays as the rebalance passes left it.
    private func applyLLMReview(
        _ cues: [MutableCue],
        config: SubtitleExportConfig,
        llmService: LLMServiceProtocol,
        onReviewProgress: SubtitleLLMReviewer.ProgressHandler? = nil
    ) async -> [MutableCue] {
        guard cues.count >= 2 else { return cues }
        let snapshot = cues.map {
            SubtitleLLMReviewer.ReviewableCue(
                startMs: $0.startMs, endMs: $0.endMs, text: $0.text
            )
        }
        let reviewer = SubtitleLLMReviewer(llmService: llmService)
        let suggestions = await reviewer.review(
            cues: snapshot,
            config: config,
            onProgress: onReviewProgress
        )
        return applyReviewSuggestions(cues, suggestions: suggestions, config: config)
    }

    /// Test-only entry point: drive `applyReviewSuggestions` from a
    /// pre-built suggestion list without going through the LLM. Lets
    /// the regression tests pin specific shift/merge scenarios
    /// deterministically. Takes/returns public `SubtitleCue` so the
    /// test suite doesn't need access to the private `MutableCue`.
    func applyReviewSuggestionsForTesting(
        _ cues: [SubtitleCue],
        suggestions: [SubtitleLLMReviewer.ReviewSuggestion],
        config: SubtitleExportConfig
    ) -> [SubtitleCue] {
        let mutable = cues.map {
            MutableCue(
                startMs: $0.startMs,
                endMs: $0.endMs,
                words: $0.text.split(separator: " ").map(String.init),
                wordTimestamps: [],
                speakerId: $0.speakerId,
                forcedText: nil
            )
        }
        let applied = applyReviewSuggestions(mutable, suggestions: suggestions, config: config)
        return applied.map {
            SubtitleCue(
                startMs: $0.startMs,
                endMs: $0.endMs,
                text: $0.text,
                speakerId: $0.speakerId
            )
        }
    }

    /// Walk suggestions in pair-index order, applying each one that
    /// still validates against the (possibly shifted) cue list.
    private func applyReviewSuggestions(
        _ cues: [MutableCue],
        suggestions: [SubtitleLLMReviewer.ReviewSuggestion],
        config: SubtitleExportConfig
    ) -> [MutableCue] {
        var result = cues
        // Track how many cues have been removed/added relative to the
        // original indices, so we can map a suggestion's `pairIndex`
        // (an index into the snapshot the reviewer saw) into the
        // current `result` indices.
        var offset = 0
        for suggestion in suggestions.sorted(by: { $0.pairIndex < $1.pairIndex }) {
            let currentI = suggestion.pairIndex + offset
            // Bounds check after offset adjustment.
            guard currentI >= 0 && currentI + 1 < result.count else { continue }
            let outcome = applyOne(
                action: suggestion.action,
                a: result[currentI],
                b: result[currentI + 1],
                maxChars: config.maxCharsPerLine
            )
            switch outcome {
            case .keep:
                continue
            case .merged(let merged):
                result[currentI] = merged
                result.remove(at: currentI + 1)
                offset -= 1
            case .shifted(let newA, let newB):
                result[currentI] = newA
                result[currentI + 1] = newB
                // Word count unchanged; offset stays.
            case .rejected:
                continue
            }
        }
        return result
    }

    private enum ApplyOutcome {
        case keep
        case merged(MutableCue)
        case shifted(MutableCue, MutableCue)
        case rejected
    }

    /// Validate the action against the current cue state, return the
    /// resulting cues (or `.rejected` if validation fails).
    ///
    /// The validator deliberately mirrors the rebalance passes'
    /// constraints — anything the rebalance passes would refuse to
    /// emit, the reviewer can't emit either. Without this mirror, the
    /// reviewer can undo work the deterministic passes did (SRT 33
    /// regression: reviewer merged a cue's trailing sentence start
    /// back in, creating "30. We" / "will spend..." — the exact
    /// pattern `rebalanceTrailingSentenceFragment` exists to prevent).
    private func applyOne(
        action: ReviewAction,
        a: MutableCue,
        b: MutableCue,
        maxChars: Int
    ) -> ApplyOutcome {
        // Hard upper bound — never let the LLM-reviewed cues balloon
        // past what the wrap pass can handle gracefully. 2× per-line
        // budget covers a comfortable 2-line cue.
        let maxBudget = max(maxChars * 2, maxChars + 30)
        // Same utterance-gap floor the other rebalance passes use.
        let maxGapMs = 500
        // Minimum chars in a "kept" cue after a shift, so we don't
        // strand a 5-char fragment by accident.
        let minChars = 10
        // Shared bad-ender set with the rebalance passes. If a
        // suggested action would leave cue N's new tail on one of
        // these words, reject — the rebalance passes would have
        // moved it forward anyway.
        let badEnders = SubtitleLLMLayoutPlanner.autoSplitBadEnders
            .union(Self.softBadEnders)

        switch action {
        case .keep:
            return .keep

        case .merge:
            // Reject merges across a long pause — those are two
            // genuinely separate utterances no matter what the LLM
            // thinks.
            if b.startMs - a.endMs > maxGapMs { return .rejected }
            let combinedWords = a.words + b.words
            let combinedText = combinedWords.joined(separator: " ")
            if combinedText.count > maxBudget { return .rejected }
            // Hard cap on word count to keep 2-line cues readable.
            if combinedWords.count > 16 { return .rejected }
            // Reject merges that would pack a trailing-sentence-
            // fragment into the combined cue. Real failure (SRT 33
            // cue 1): merging "What is going on..." + "We will spend"
            // produced "...arms 30. We" with "We" stranded. The
            // pattern is: after merging, the combined cue contains
            // a `.!?` followed by 1–3 trailing words that don't end
            // a sentence themselves.
            if hasTrailingSentenceFragment(words: combinedWords) {
                return .rejected
            }
            // Reject merges across an existing sentence boundary
            // when the merged cue would end up with a complete
            // sentence packed against the start of the next. Less
            // strict than the trailing-fragment check — this catches
            // the "two complete thoughts crammed together" pattern.
            if mergePacksMultipleSentences(a: a, b: b) {
                return .rejected
            }
            let merged = MutableCue(
                startMs: a.startMs,
                endMs: b.endMs,
                words: combinedWords,
                wordTimestamps: a.wordTimestamps + b.wordTimestamps,
                speakerId: a.speakerId,
                forcedText: nil
            )
            return .merged(merged)

        case .shiftToA(let n):
            // Move first n words of B to end of A.
            guard n >= 1, n <= 3, b.words.count > n else { return .rejected }
            if b.startMs - a.endMs > maxGapMs { return .rejected }
            let moved = Array(b.words.prefix(n))
            let newA = MutableCue(
                startMs: a.startMs,
                endMs: a.endMs,
                words: a.words + moved,
                wordTimestamps: a.wordTimestamps,
                speakerId: a.speakerId,
                forcedText: nil
            )
            let newB = MutableCue(
                startMs: b.startMs,
                endMs: b.endMs,
                words: Array(b.words.dropFirst(n)),
                wordTimestamps: b.wordTimestamps,
                speakerId: b.speakerId,
                forcedText: nil
            )
            if newA.text.count > maxBudget { return .rejected }
            if newB.text.count < minChars { return .rejected }
            // Reject if cue A's new tail is a bad ender (matching
            // the rebalance passes' constraint).
            if endsOnBadEnder(words: newA.words, badEnders: badEnders) {
                return .rejected
            }
            // Reject if cue A's new tail is the start of a new
            // sentence — that's the trailing-sentence-fragment
            // pattern we have a deterministic pass for.
            if hasTrailingSentenceFragment(words: newA.words) {
                return .rejected
            }
            // Reject if the moved word(s) include a hyphenated suffix
            // ("-up", "-down"). Splitting "warm-up" so that "-up"
            // stays in cue B leaves "warm" stranded on cue A's tail
            // (SRT 33 cue 12/13: "...our warm" / "-up and...").
            if movedWordsBeginWithHyphen(moved) {
                return .rejected
            }
            return .shifted(newA, newB)

        case .shiftToB(let n):
            // Move last n words of A to start of B.
            guard n >= 1, n <= 3, a.words.count > n else { return .rejected }
            if b.startMs - a.endMs > maxGapMs { return .rejected }
            let moved = Array(a.words.suffix(n))
            let newA = MutableCue(
                startMs: a.startMs,
                endMs: a.endMs,
                words: Array(a.words.dropLast(n)),
                wordTimestamps: a.wordTimestamps,
                speakerId: a.speakerId,
                forcedText: nil
            )
            let newB = MutableCue(
                startMs: b.startMs,
                endMs: b.endMs,
                words: moved + b.words,
                wordTimestamps: b.wordTimestamps,
                speakerId: b.speakerId,
                forcedText: nil
            )
            if newA.text.count < minChars { return .rejected }
            if newB.text.count > maxBudget { return .rejected }
            // Reject if cue A's new tail is a bad ender (same
            // constraint as shiftToA). Most likely path here: the
            // LLM voted shiftToB to "fix" something but the move
            // leaves cue A ending on a function word the rebalance
            // passes would've caught.
            if endsOnBadEnder(words: newA.words, badEnders: badEnders) {
                return .rejected
            }
            return .shifted(newA, newB)
        }
    }

    /// Does the cue's tail look like "[sentence-end] word1 [word2]"
    /// where word1/2 don't end a sentence themselves? Mirror of the
    /// detection in `rebalanceTrailingSentenceFragment`.
    private func hasTrailingSentenceFragment(words: [String]) -> Bool {
        guard words.count >= 2 else { return false }
        // Last word ending sentence cleanly → not a fragment, exit.
        if let last = words.last?.last, ".!?".contains(last) { return false }
        // Walk backward from second-to-last looking for a sentence end.
        for j in stride(from: words.count - 2, through: 0, by: -1) {
            if let c = words[j].last, ".!?".contains(c) {
                let trailing = words.count - 1 - j
                return trailing >= 1 && trailing <= 3
            }
        }
        return false
    }

    /// Would merging cue A and cue B pack two complete sentences into
    /// one cue? Heuristic: both A and B end with `.!?` and A is at
    /// least one full sentence on its own. Real failure (SRT 33 cue
    /// 102): "Beautiful." + "Round 1 is done." + "We are now moving
    /// on to round 2." all collapsed into one cue.
    private func mergePacksMultipleSentences(a: MutableCue, b: MutableCue) -> Bool {
        let aEndsSentence = a.words.last?.last.map { ".!?".contains($0) } ?? false
        let bEndsSentence = b.words.last?.last.map { ".!?".contains($0) } ?? false
        // If neither ends a sentence, the merge can't pack multiple
        // sentences (it might just be continuing one).
        guard aEndsSentence && bEndsSentence else { return false }
        // Both end in `.!?` and both are substantial — merging packs
        // two complete thoughts.
        return a.words.count >= 2 && b.words.count >= 2
    }

    /// True if the cue's last word (stripped of punctuation) sits in
    /// the bad-enders set AND doesn't end in `.!?` (which would mean
    /// it's a clean sentence terminator, not a bad ender). Same
    /// fix as `rebalanceBadStarters`' strong-punct guard.
    private func endsOnBadEnder(words: [String], badEnders: Set<String>) -> Bool {
        guard let lastRaw = words.last else { return false }
        // Sentence terminator = clean break, never a bad ender.
        if let c = lastRaw.last, ".!?".contains(c) { return false }
        let stripped = lastRaw
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        return badEnders.contains(stripped)
    }

    /// True if any of the moved words starts with `-` (a hyphenated
    /// suffix like "-up", "-down", "-minute"). Real failure (SRT 33
    /// cue 12/13): the reviewer's shift left "warm" on cue A's tail
    /// and "-up and over the course..." on cue B's head. The hyphen
    /// makes it obvious the word was broken.
    private func movedWordsBeginWithHyphen(_ moved: [String]) -> Bool {
        moved.contains { $0.hasPrefix("-") }
    }

    /// Format word timestamps as WebVTT subtitle string
    public func formatVTT(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        config: SubtitleExportConfig = .default,
        includeSpeakerLabels: Bool = false,
        cleanedTranscript: String? = nil,
        engineSegments: [STTSegment]? = nil
    ) -> String {
        let cues = buildSubtitleCues(
            from: words,
            cleanedTranscript: cleanedTranscript,
            engineSegments: engineSegments,
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
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
                engineSegments: transcription.transcriptSegments
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
    /// Map engine-emitted `TranscriptSegment`s (Whisper's native output)
    /// onto the `[WordTimestamp]` array as `SentenceUnit`s.
    ///
    /// Strategy: for each word, find the engine segment whose `[startMs,
    /// endMs]` range covers the word's midpoint. Walk the array; whenever
    /// the assigned segment-id changes, emit a unit boundary. Words that
    /// don't fall in any segment (rare — overlap glitches) inherit the
    /// previous word's segment, so coverage is total.
    ///
    /// Coverage invariant: every input word ends up inside exactly one
    /// `SentenceUnit`, and units are contiguous (matches Track A's invariant
    /// so the downstream loop treats both paths identically).
    private func sentenceUnitsFromEngineSegments(
        _ segments: [STTSegment],
        words: [WordTimestamp]
    ) -> [SentenceUnit] {
        guard !words.isEmpty, !segments.isEmpty else { return [] }

        // Pre-sort segments by start time (Whisper emits them in order, but
        // defend against the rare out-of-order chunk merge).
        let sorted = segments.sorted { $0.startMs < $1.startMs }

        // For each word, pick the segment whose range contains its midpoint;
        // fall back to the closest segment by start time.
        var wordSegmentIndex = [Int](repeating: 0, count: words.count)
        var lastIndex = 0
        for (i, w) in words.enumerated() {
            let mid = (w.startMs + w.endMs) / 2
            // Linear scan from lastIndex — segments are sorted and word
            // index advances monotonically, so amortized O(N+M).
            while lastIndex + 1 < sorted.count && sorted[lastIndex + 1].startMs <= mid {
                lastIndex += 1
            }
            wordSegmentIndex[i] = lastIndex
        }

        // Walk word→segment assignments and emit a unit each time the
        // assigned segment changes.
        var units: [SentenceUnit] = []
        var unitStart = 0
        for i in 1..<words.count {
            if wordSegmentIndex[i] != wordSegmentIndex[i - 1] {
                let text = words[unitStart...(i - 1)].map(\.word).joined(separator: " ")
                let last = words[i - 1].word
                let strong = last.last.map { ".!?".contains($0) } ?? false
                units.append(SentenceUnit(
                    startIndex: unitStart,
                    endIndex: i - 1,
                    text: text,
                    endsWithStrongPunctuation: strong
                ))
                unitStart = i
            }
        }
        // Final trailing unit.
        let text = words[unitStart...(words.count - 1)].map(\.word).joined(separator: " ")
        let last = words[words.count - 1].word
        let strong = last.last.map { ".!?".contains($0) } ?? false
        units.append(SentenceUnit(
            startIndex: unitStart,
            endIndex: words.count - 1,
            text: text,
            endsWithStrongPunctuation: strong
        ))
        return units
    }

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
        engineSegments: [STTSegment]? = nil,
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

        // Sentence-aware pre-pass.
        // Two ways to get sentence-unit boundaries:
        //  1. The STT engine emitted them (`engineSegments`) — Whisper does
        //     this natively. Authoritative; use directly.
        //  2. A cleaned transcript is available; run NLTokenizer on the
        //     joined word stream and derive boundaries deterministically
        //     (Track A path).
        // Either way, the main loop force-flushes at each unit boundary,
        // replacing the old "flush on any 800 ms gap" behaviour.
        let useSentenceUnits = engineSegments != nil || cleanedTranscript != nil
        var sentenceUnitEndForWord: [Bool] = []
        if useSentenceUnits {
            sentenceUnitEndForWord = Array(repeating: false, count: mergedWords.count)
            let units: [SentenceUnit]
            if let segments = engineSegments, !segments.isEmpty {
                units = sentenceUnitsFromEngineSegments(segments, words: mergedWords)
            } else {
                // `longPauseMs` defaults to 1500 — large enough that natural
                // breaths don't create boundaries, small enough that genuine
                // stop-and-start utterances do.
                units = SubtitleSentenceSegmenter.segment(
                    words: mergedWords,
                    cleanedText: cleanedTranscript,
                    longPauseMs: max(1500, config.gapThresholdMs * 2)
                )
            }
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
                // Look ahead: if a natural punctuation break is within the
                // next few words, allow a small overflow to reach it
                // instead of splitting mid-clause.
                //
                //   - Sentence end (.!? followed by capital): allow up to
                //     20 % overflow within 3 words.
                //   - Comma / clause break (`,` `;` `:`): allow up to 12 %
                //     overflow within 3 words.
                //
                // The "reach a natural break" branch consumes the word(s)
                // up to (and including) that punctuation, then flushes —
                // so the next cue starts on a clean phrase.
                var nearNaturalBreak = false
                let sentenceOverflowBudget = (config.maxCharsPerLine * 120) / 100
                let commaOverflowBudget = (config.maxCharsPerLine * 112) / 100
                for offset in 1...3 {
                    let peekIdx = i + offset
                    guard peekIdx < mergedWords.count else { break }
                    let peekWord = mergedWords[peekIdx]
                    let hasNextPeek = peekIdx < mergedWords.count - 1
                    let peekEndsSentence = config.breakOnPunctuation
                        && (peekWord.word.last.map { ".!?".contains($0) } ?? false)
                    let nextIsStarter = hasNextPeek
                        && isSentenceStarter(mergedWords[peekIdx + 1].word)
                    let peekEndsClause = config.breakOnPunctuation
                        && (peekWord.word.last.map { ",;:".contains($0) } ?? false)
                    let extendedText = (prospective + mergedWords[(i + 1)...peekIdx]).map(\.word).joined(separator: " ")
                    if peekEndsSentence && nextIsStarter && extendedText.count <= sentenceOverflowBudget {
                        nearNaturalBreak = true
                        break
                    }
                    if peekEndsClause && extendedText.count <= commaOverflowBudget {
                        nearNaturalBreak = true
                        break
                    }
                }

                if !nearNaturalBreak {
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
        // Absorb short cues into neighbours when the combined text fits the
        // total budget. Catches the residual fragments that slip past
        // `mergeOrphanedCues` (which only fires when one cue is strictly
        // tiny) — pairs like "we'll work on building" (22 chars) + "our
        // cadence and our resistance" (30 chars), neither tiny on its own
        // but easily mergeable into a single 53-char cue.
        //
        // Runs BEFORE `enforceReadingSpeed` and marks merged cues with
        // `forcedText`. The reading-speed pass skips `forcedText` cues
        // (existing guard) so a deliberately-merged cue is not re-split
        // even if its CPS exceeds the configured ceiling — the user has
        // told us repeatedly that fragmentation reads worse than a fast
        // single caption.
        cues = absorbShortNeighbours(
            cues,
            maxChars: config.maxCharsPerLine,
            gapThresholdMs: config.gapThresholdMs
        )

        // Post-process: split cues that exceed the maximum reading speed.
        //
        // Skipped on the sentence-aware path: when we have a cleaned
        // transcript or engine segments we trust the natural-language unit
        // boundaries, and re-splitting a fast-spoken sentence here would
        // recreate the very fragmentation the rest of the pipeline is
        // trying to avoid. A slightly fast cue reads better than a torn-up
        // sentence — confirmed by repeated user feedback.
        if config.maxCPS > 0 && !useSentenceUnits {
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

            // Real punctuation bonuses.
            //
            // Punctuation is the single strongest signal that a split lands
            // on a natural caption boundary. We want it to dominate over
            // budget-fill scoring so a split like "What is going on,
            // Echelon," wins over a budget-maximising "...intervals in".
            if words[splitIdx].word.last.map({ ".!?".contains($0) }) ?? false {
                score += 500
            }
            if words[splitIdx].word.hasSuffix(",") || words[splitIdx].word.hasSuffix(";") || words[splitIdx].word.hasSuffix(":") {
                score += 400
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

            // Prefer fuller first cues over strict 50/50 balance.
            //
            // The old "balance" criterion rewarded splits where both halves
            // were equal length — which produced shorter, more numerous cues
            // (e.g. a 67-char sentence with a 65-char budget would be split
            // into two ~33-char cues instead of one ~52-char + ~13-char).
            // Captions read better with one full cue followed by a shorter
            // tail than with two medium fragments.
            //
            // Reward proximity to the budget on the FIRST half. Penalty
            // grows linearly with unused budget. A small penalty also stays
            // on the SECOND half so it doesn't dwarf 1-word tails.
            let unusedBudget = max(0, maxChars - firstText.count)
            score -= unusedBudget / 2
            if secondText.count < 5 { score -= 50 }

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

    /// Final cue packing pass.
    ///
    /// `mergeOrphanedCues` only merges a cue that is *strictly* tiny
    /// (< 15 chars OR < 3 words). `mergeAdjacentCuesForTwoLine` only
    /// merges when both cues already fit individually under `maxChars`.
    /// Neither catches the very common case where two medium-but-short
    /// cues both fit in the total budget but stay separate — e.g.
    /// `"we'll work on building"` (22 chars) + `"our cadence and our
    /// resistance"` (30 chars), which together (53 chars) sit happily
    /// under a 65-char total budget yet appeared as two cues in test
    /// SRT (14).
    ///
    /// This pass scans for any pair where at least one cue uses less
    /// than ~60 % of the budget AND the combined text fits, and packs
    /// them. Iterates to a fixpoint so chains of small cues fully
    /// coalesce. Marks merged cues with `forcedText` so the downstream
    /// `applyFrameSnap`/`enforceMonotonicCues` passes preserve them
    /// verbatim.
    private func absorbShortNeighbours(
        _ cues: [MutableCue],
        maxChars: Int,
        gapThresholdMs: Int = 800
    ) -> [MutableCue] {
        guard cues.count > 1 else { return cues }

        // Anything below this fraction of the budget is treated as
        // "short" and tries to absorb its neighbour. 60 % gives a clear
        // visual signal: a 65-char-budget cue with 20–35 chars is short,
        // a 40+ char cue is already pulling its weight.
        let shortThreshold = max(20, maxChars * 60 / 100)
        // Two-line cue budget plus a small tolerance. The "+8" matches
        // `mergeAdjacentCuesForTwoLine`'s tolerance and lets a 53-char
        // merge land cleanly in a 65-char-budget cue.
        let budgetCap = maxChars + 8

        var result = cues
        var changed = true
        var safetyIterations = 0
        while changed && safetyIterations < 8 {
            changed = false
            safetyIterations += 1
            var i = 0
            while i < result.count - 1 {
                let current = result[i]
                let next = result[i + 1]
                let currentShort = current.text.count < shortThreshold
                let nextShort = next.text.count < shortThreshold
                if !currentShort && !nextShort {
                    i += 1
                    continue
                }
                // Don't merge across a real silence — that's two
                // utterances even if both happen to be short.
                //
                // Same floor as `mergeOrphanedCues`: a user-set
                // `gapThresholdMs: 0` shouldn't promote 30–200 ms
                // word-timing artifacts to "real silence".
                if (next.startMs - current.endMs) > max(gapThresholdMs, 500) {
                    i += 1
                    continue
                }
                // Don't merge across a sentence boundary when the
                // current cue is a TAIL of a longer sentence (e.g.
                // "arms 30." in SRT (15) — the rest of "What is going
                // on, Echelon, and welcome in to your intervals in arms
                // 30." landed in the preceding cue). Packing a tail with
                // the head of the NEXT sentence reads as two distinct
                // thoughts crammed into one block.
                //
                // A "tail" is recognised by: current cue ends with `.!?`
                // AND current cue does NOT start with a sentence starter
                // (so it's a continuation, not a self-contained sentence
                // like "Hi there." or "Yes.").
                let currentEndsSentence = current.words.last?.last.map { ".!?".contains($0) } ?? false
                let nextStartsSentence = isSentenceStarter(next.words.first ?? "")
                let currentStartsSentence = isSentenceStarter(current.words.first ?? "")
                if currentEndsSentence && nextStartsSentence && !currentStartsSentence {
                    i += 1
                    continue
                }
                let spaceJoined = current.text + " " + next.text
                let lineJoined = current.text + "\n" + next.text
                guard spaceJoined.count <= budgetCap else {
                    i += 1
                    continue
                }
                // Cap the total word count so we don't pack absurdly
                // many cues into one (10–12 short words ≈ comfortable
                // 2-line subtitle; 25 words would be unreadable).
                guard current.words.count + next.words.count <= 16 else {
                    i += 1
                    continue
                }
                var merged = MutableCue(
                    startMs: current.startMs,
                    endMs: next.endMs,
                    words: current.words + next.words,
                    wordTimestamps: current.wordTimestamps + next.wordTimestamps,
                    speakerId: current.speakerId
                )
                // Preserve a two-line layout when the combined text
                // doesn't fit on one line, otherwise let the wrap pass
                // decide.
                if spaceJoined.count > maxChars {
                    merged.forcedText = lineJoined
                }
                result[i] = merged
                result.remove(at: i + 1)
                changed = true
                // Stay at the same i so the just-merged cue can absorb
                // further neighbours if they're still short.
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
    // MARK: - Post-LLM rebalance

    /// Slide trailing words from cue N into cue N+1 when cue N ends on a
    /// "bad ender" — `and`, `the`, `of`, `our`, `should`, etc. The LLM
    /// is told not to do this in the prompt but doesn't reliably obey
    /// abstract rules; this pass cleans up what's left.
    ///
    /// Rules:
    ///   - Only move 1 or 2 trailing words at a time (we don't want to
    ///     reshape sentences, just push the offending word forward).
    ///   - Don't make cue N empty.
    ///   - Don't push cue N+1 over budget (with the same +10 tolerance
    ///     as the merge passes).
    ///   - Don't introduce a NEW bad ender at the new tail.
    ///   - Don't move across a long gap (>500 ms) — that's a real
    ///     utterance boundary, not a layout slip.
    private func rebalanceBadEnders(_ cues: [MutableCue], maxChars: Int) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        // Hard list: conjunctions, articles, prepositions, auxiliaries,
        // short pronouns — words that almost never belong at a cue end.
        // Soft list: common transitive verbs that often need an object
        // (give, take, make, find...). Both get the same rebalance
        // treatment; the soft list just expands coverage to catch
        // verb-object splits like "It is great to have" / "you. ...".
        let badEnders = SubtitleLLMLayoutPlanner.autoSplitBadEnders
            .union(Self.softBadEnders)
        let maxBudget = maxChars + 10
        let maxGapMs = 500
        // 10 char floor (was 12). "It is great" (11) is a valid reading
        // unit; the looser floor lets a 2-word move into the next cue
        // succeed when the previous cue is left at exactly that length.
        let minCurrentChars = 10

        var result = cues
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let next = result[i + 1]

            // Need at least 2 words in current to safely move one away.
            guard current.words.count >= 2 else { i += 1; continue }

            // Strip trailing punctuation when classifying the last word —
            // "should." is a complete sentence, not a bad ender.
            let lastRaw = current.words.last ?? ""
            let endsWithStrongPunct = lastRaw.last.map { ".!?".contains($0) } ?? false
            if endsWithStrongPunct { i += 1; continue }
            let lastStripped = lastRaw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard badEnders.contains(lastStripped) else { i += 1; continue }

            // Real utterance gap → leave alone.
            if next.startMs - current.endMs > maxGapMs { i += 1; continue }

            // Try moving 1, 2, then 3 words. The 3-word ceiling matters
            // for chained bad-enders ("into it I" — SRT 25 cue 26) where
            // shrinking by 1 or 2 leaves a NEW bad ender at the tail.
            // 3-word moves are also bounded by the per-cue char budget,
            // so we don't risk over-stuffing the next cue.
            var moved = false
            for moveCount in 1...min(3, current.words.count - 1) {
                let pivot = current.words.count - moveCount
                let movedWords = Array(current.words[pivot...])
                let remainingWords = Array(current.words[0..<pivot])
                let newCurrentText = remainingWords.joined(separator: " ")
                let newNextText = (movedWords + next.words).joined(separator: " ")

                // Budget check.
                if newNextText.count > maxBudget { continue }
                // Don't create a new bad ender at the new tail of cue N.
                let newLast = remainingWords.last?
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased() ?? ""
                if badEnders.contains(newLast) { continue }
                // Don't leave cue N too short — see `minCurrentChars`.
                if newCurrentText.count < minCurrentChars { continue }

                result[i] = MutableCue(
                    startMs: current.startMs,
                    endMs: current.endMs,
                    words: remainingWords,
                    wordTimestamps: current.wordTimestamps,
                    speakerId: current.speakerId
                )
                result[i + 1] = MutableCue(
                    startMs: next.startMs,
                    endMs: next.endMs,
                    words: movedWords + next.words,
                    wordTimestamps: next.wordTimestamps,
                    speakerId: next.speakerId
                )
                moved = true
                break
            }
            // Re-check current position even after a move — the new
            // last word might still be a bad ender we can fix further.
            if !moved { i += 1 }
        }
        return result
    }

    /// Detect a mid-cue sentence terminator (`. ! ?`) followed by
    /// 1–3 trailing words that DON'T themselves end a sentence, and
    /// slide those trailing words to the start of cue N+1.
    ///
    /// Real failure case (SRT 31 cue 10/11):
    ///   "It is great to have you. Go"
    ///   "ahead and find a cadence somewhere between 80 and 90."
    /// The LLM packed the first word of the next sentence ("Go")
    /// onto the tail of cue N, splitting the natural phrase "Go
    /// ahead" across the cue boundary. The bad-ender pass doesn't
    /// fire because "Go" isn't a function word; the bad-starter pass
    /// doesn't fire because "ahead" isn't in `badStarters`. The
    /// structurally-right thing is to put the sentence terminator AT
    /// the cue boundary — cue N ends with "you.", cue N+1 begins
    /// with "Go ahead..."
    ///
    /// Budget cap is generous (2× `maxCharsPerLine`) because cue
    /// N+1 is a 2-line layout candidate — the wrap pass downstream
    /// breaks naturally at the absorbed-fragment boundary, so even
    /// a 60-char single-line target tolerates an 80-char two-line
    /// cue here without harm.
    private func rebalanceTrailingSentenceFragment(
        _ cues: [MutableCue],
        maxChars: Int
    ) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let maxBudget = max(maxChars * 2, maxChars + 30)
        let maxGapMs = 500
        let maxTrailingWords = 3
        // Cue N must keep enough text to read as its own cue (don't
        // strand a 5-char "Yes." just to fix cue N+1's prefix).
        let minRemainingChars = 12

        var result = cues
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let next = result[i + 1]

            // Need at least 3 words: 1+ sentence end + at least 1
            // trailing word, plus margin so the cue doesn't collapse.
            guard current.words.count >= 3 else { i += 1; continue }

            // Walk backward from the SECOND-TO-LAST word to find the
            // last word that ends in strong punctuation. We skip the
            // very last word so a cue that already ends cleanly
            // ("...have you.") isn't disturbed.
            var lastSentenceEnd = -1
            for j in stride(from: current.words.count - 2, through: 0, by: -1) {
                if let c = current.words[j].last, ".!?".contains(c) {
                    lastSentenceEnd = j
                    break
                }
            }
            guard lastSentenceEnd >= 0 else { i += 1; continue }

            let trailingCount = current.words.count - 1 - lastSentenceEnd
            guard trailingCount >= 1 && trailingCount <= maxTrailingWords else {
                i += 1; continue
            }

            let trailingWords = Array(current.words[(lastSentenceEnd + 1)...])
            let remainingWords = Array(current.words[0...lastSentenceEnd])

            // The fragment itself must NOT end in `.!?` — if it does,
            // it's a self-contained mini-sentence (like "Oh yes.") and
            // belongs where it is.
            if let last = trailingWords.last?.last, ".!?".contains(last) {
                i += 1; continue
            }

            if next.startMs - current.endMs > maxGapMs { i += 1; continue }

            let newCurrentText = remainingWords.joined(separator: " ")
            guard newCurrentText.count >= minRemainingChars else { i += 1; continue }

            let newNextWords = trailingWords + next.words
            let newNextText = newNextWords.joined(separator: " ")
            guard newNextText.count <= maxBudget else { i += 1; continue }

            result[i] = MutableCue(
                startMs: current.startMs,
                endMs: current.endMs,
                words: remainingWords,
                wordTimestamps: current.wordTimestamps,
                speakerId: current.speakerId
            )
            result[i + 1] = MutableCue(
                startMs: next.startMs,
                endMs: next.endMs,
                words: newNextWords,
                wordTimestamps: next.wordTimestamps,
                speakerId: next.speakerId
            )
            i += 1
        }
        return result
    }

    /// Detect a split between a spelled-out cardinal at the end of cue N
    /// and a measurement unit at the start of cue N+1 (`...your four` /
    /// `minute warm-up`) and slide the cardinal forward so the pair
    /// stays together. The number-normalisation pass that runs in the
    /// wrap step can then read "four minute" as one unit and digitize
    /// it ("4-minute").
    ///
    /// Also catches the Whisper-tokenized case where the unit starts
    /// with a leading hyphen (`-minute`) — same fix.
    private func rebalanceCardinalUnitPairs(_ cues: [MutableCue], maxChars: Int) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let cardinals: Set<String> = [
            "one", "two", "three", "four", "five",
            "six", "seven", "eight", "nine"
        ]
        // Mirrors NumberNormalizer.measurementUnits — kept inline so this
        // pass doesn't depend on that module's private alternation.
        let units: Set<String> = [
            "minute", "minutes", "second", "seconds", "hour", "hours",
            "day", "days", "week", "weeks", "month", "months",
            "year", "years",
            "pound", "pounds", "ounce", "ounces", "gram", "grams",
            "foot", "feet", "inch", "inches",
            "mile", "miles", "meter", "meters", "yard", "yards",
            "step", "steps", "rep", "reps", "count", "counts",
            "set", "sets", "round", "rounds",
            "degree", "degrees"
        ]
        let maxBudget = maxChars + 10
        let maxGapMs = 500

        var result = cues
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let next = result[i + 1]

            guard current.words.count >= 2,
                  let firstNextRaw = next.words.first else { i += 1; continue }

            let lastRaw = current.words.last ?? ""
            let lastStripped = lastRaw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            // Strip a leading hyphen so Whisper's "-minute" still
            // classifies as the unit "minute".
            let firstStripped = firstNextRaw
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()

            // Accept either spelled-out cardinals ("four") OR digit
            // cardinals ("4"). Parakeet/Whisper emit digits directly for
            // most numbers, and the LLM gets the digit form in the
            // chunk's word array. Real failure case (D41D14D8 / iter2
            // cue 8/9): the LLM split "...because your 4 minute" /
            // "warm-up starts right now." — we want "4 minute warm-up"
            // to stay glued so `NumberNormalizer` can join it as
            // "4-minute warm-up" in the wrap step.
            let lastIsDigitCardinal = lastStripped.count <= 2
                && lastStripped.allSatisfy { $0.isNumber }
            let isCardinal = cardinals.contains(lastStripped) || lastIsDigitCardinal
            guard isCardinal,
                  units.contains(firstStripped) else { i += 1; continue }

            if next.startMs - current.endMs > maxGapMs { i += 1; continue }

            // Move the cardinal from cue N to cue N+1.
            let remainingCurrent = Array(current.words.dropLast())
            let pushed = [lastRaw] + next.words
            let newNextText = pushed.joined(separator: " ")
            if newNextText.count > maxBudget { i += 1; continue }
            // Cue N must remain at least 1 word.
            if remainingCurrent.isEmpty { i += 1; continue }

            result[i] = MutableCue(
                startMs: current.startMs,
                endMs: current.endMs,
                words: remainingCurrent,
                wordTimestamps: current.wordTimestamps,
                speakerId: current.speakerId
            )
            result[i + 1] = MutableCue(
                startMs: next.startMs,
                endMs: next.endMs,
                words: pushed,
                wordTimestamps: next.wordTimestamps,
                speakerId: next.speakerId
            )
            i += 1
        }
        return result
    }

    /// Common transitive verbs that often take an object and read
    /// awkwardly when a cue ends on them ("It is great to have" /
    /// "you. ..."). These get the same rebalance treatment as the
    /// hard bad-enders BUT only when the move is genuinely free —
    /// we don't want to disrupt cues like "We give." or "I told."
    /// where the verb ends a complete short sentence.
    private static let softBadEnders: Set<String> = [
        "give", "gives", "gave",
        "take", "takes", "took",
        "make", "makes", "made",
        "bring", "brings", "brought",
        "find", "finds", "found",
        "want", "wants", "wanted",
        "let", "lets",
        "keep", "keeps", "kept",
        "put", "puts",
        "tell", "tells", "told",
        "show", "shows", "showed",
        "send", "sends", "sent",
        "get", "gets", "got",
        "see", "sees", "saw",
        "feel", "feels", "felt",
        "need", "needs", "needed"
    ]

    /// Dedicated bad-STARTER set — much smaller than bad-enders.
    /// Words that almost always read as a stranded fragment when they
    /// open a cue (preposition + article + subordinator). Excludes
    /// conjunctions like `and`/`but`/`so` and pronouns/auxiliaries
    /// which CAN legitimately start a sentence in transcribed speech.
    private static let badStarters: Set<String> = [
        "of", "the", "a", "an",
        "to", "at", "with", "from", "by", "into", "onto", "for",
        "because", "although", "while", "since", "until", "though"
    ]

    /// Cardinals + measurement units used by `rebalanceCardinalUnitPairs`.
    /// Surfaced here so `rebalanceBadStarters` can check whether a
    /// candidate move would tear apart a cardinal+unit pair the
    /// previous pass just glued together.
    private static let cardinalWords: Set<String> = [
        "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine"
    ]
    private static let unitWords: Set<String> = [
        "minute", "minutes", "second", "seconds", "hour", "hours",
        "day", "days", "week", "weeks", "month", "months",
        "year", "years",
        "pound", "pounds", "ounce", "ounces", "gram", "grams",
        "foot", "feet", "inch", "inches",
        "mile", "miles", "meter", "meters", "yard", "yards",
        "step", "steps", "rep", "reps", "count", "counts",
        "set", "sets", "round", "rounds",
        "degree", "degrees"
    ]

    /// Mirror of `rebalanceBadEnders` but operating on cue N+1's
    /// HEAD. If cue N+1 starts with a word from `badStarters` (the
    /// dedicated smaller set), slide the first 1-3 words backward
    /// into cue N. Constraints:
    ///   - Cue N must accept the new tail within budget.
    ///   - Don't introduce a NEW bad ender on cue N's new tail.
    ///   - Don't empty cue N+1 or leave it shorter than 12 chars.
    ///   - Don't strand a NEW bad starter on cue N+1.
    ///   - Don't separate a cardinal+unit pair that the earlier
    ///     `rebalanceCardinalUnitPairs` deliberately joined (would
    ///     re-fragment `4 minute` → `4` / `minute`).
    ///   - Don't cross a long utterance gap (> 500 ms).
    private func rebalanceBadStarters(_ cues: [MutableCue], maxChars: Int) -> [MutableCue] {
        guard cues.count > 1 else { return cues }
        let starters = Self.badStarters
        let badEnders = SubtitleLLMLayoutPlanner.autoSplitBadEnders
            .union(Self.softBadEnders)
        let maxBudget = maxChars + 10
        let maxGapMs = 500

        var result = cues
        var i = 0
        while i < result.count - 1 {
            let current = result[i]
            let next = result[i + 1]

            guard next.words.count >= 2 else { i += 1; continue }

            let firstRaw = next.words.first ?? ""
            let firstStripped = firstRaw
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            guard starters.contains(firstStripped) else { i += 1; continue }

            if next.startMs - current.endMs > maxGapMs { i += 1; continue }

            var moved = false
            // 4-word max so chained bad-enders ("into it, I" all bad)
            // can be cleared in one move. SRT 28 cue 25 needed this:
            // "Now before we jump" / "into it, I wanna give..." with
            // moveCount=3 leaves "I" at tail; moveCount=4 lands on
            // "wanna" which is clean.
            for moveCount in 1...min(4, next.words.count - 1) {
                let movedWords = Array(next.words[0..<moveCount])
                let remainingWords = Array(next.words[moveCount...])
                let newCurrentText = (current.words + movedWords).joined(separator: " ")
                let newNextText = remainingWords.joined(separator: " ")

                if newCurrentText.count > maxBudget { continue }
                // Don't move so much that cue N's NEW tail is a bad
                // ender — that just trades one problem for another.
                // A word ending in strong punctuation (".!?") is a
                // sentence terminator, NOT a bad ender — even if
                // stripping the punctuation reveals a function word
                // like "you". Real failure case (iter5 cue 13/14):
                // moving "to have you." back would leave cue N ending
                // with "you." — `badEnders.contains("you")` was true
                // so the pass kept going to moveCount=4, dragging the
                // start of the NEXT sentence ("Go") back too. Result:
                // "...have you. Go" + "ahead and find..." instead of
                // the structurally-correct "...have you." + "Go ahead
                // and find...". Skip the bad-ender check when the new
                // tail already ends a sentence cleanly.
                let newCurrentLastRaw = movedWords.last ?? ""
                let newCurrentEndsSentence = newCurrentLastRaw.last
                    .map { ".!?".contains($0) } ?? false
                let newCurrentLast = newCurrentLastRaw
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased()
                if !newCurrentEndsSentence
                    && badEnders.contains(newCurrentLast) { continue }
                if newNextText.count < 12 { continue }
                // Don't strand a new bad starter on cue N+1.
                let newNextFirst = remainingWords.first?
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased() ?? ""
                if starters.contains(newNextFirst) { continue }
                // Don't separate a cardinal from its measurement unit
                // (e.g. moving "because your four" back would leave
                // "minute warm-up..." as cue N+1's head — re-breaks
                // the pair that `rebalanceCardinalUnitPairs` joined).
                // Same guard for digit cardinals ("4 minute") since
                // `rebalanceCardinalUnitPairs` now accepts both forms.
                let newCurrentLastIsDigit = newCurrentLast.count <= 2
                    && !newCurrentLast.isEmpty
                    && newCurrentLast.allSatisfy { $0.isNumber }
                let newCurrentLastIsCardinal = Self.cardinalWords.contains(newCurrentLast)
                    || newCurrentLastIsDigit
                if newCurrentLastIsCardinal
                    && Self.unitWords.contains(newNextFirst) { continue }

                result[i] = MutableCue(
                    startMs: current.startMs,
                    endMs: current.endMs,
                    words: current.words + movedWords,
                    wordTimestamps: current.wordTimestamps,
                    speakerId: current.speakerId
                )
                result[i + 1] = MutableCue(
                    startMs: next.startMs,
                    endMs: next.endMs,
                    words: remainingWords,
                    wordTimestamps: next.wordTimestamps,
                    speakerId: next.speakerId
                )
                moved = true
                break
            }
            if !moved { i += 1 }
        }
        return result
    }

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

        // Keep at 15: bumping to 18 would catch "Beautiful work."
        // (15-char orphan) but collides with `enforceReadingSpeed` —
        // that pass intentionally splits high-CPS cues into ~17-char
        // pieces, and orphan-merge would just absorb them right back.
        // See `testGapPreferredSplitPicksLargestPause`.
        let minChars = 15
        // Keep minWords at 3 so it doesn't reabsorb the 3-word tail
        // enforceReadingSpeed's orphan-guard intentionally leaves behind.
        let minWords = 3
        // `maxChars` is the TOTAL cue budget (across all rendered lines).
        // A small tolerance lets us absorb a 1–2 char overage when the
        // alternative is an orphaned 1-word cue, which is far worse.
        let maxBudget = maxChars + 10

        // Apply a sensible floor to the gap check so a user-set
        // `gapThresholdMs: 0` (which exists in real configs) can't block
        // every merge — typical inter-word gaps are 30–200 ms artifacts,
        // not real utterance pauses, and treating them as "too long"
        // leaves single-word orphan cues like "82 80" / "five." in the
        // output where "82 85. Oh yeah." should have been.
        // 500 ms is well below the long-pause threshold used elsewhere
        // (3 s) and above the typical word-spacing artifact.
        let effectiveGap = max(gapThresholdMs, 500)
        func crossesLongGapForTiny(_ a: MutableCue, _ b: MutableCue) -> Bool {
            (b.startMs - a.endMs) > effectiveGap
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
            //
            // Same floor as `mergeOrphanedCues`: a strict user-set
            // `gapThresholdMs: 0` shouldn't treat sub-second word-timing
            // gaps as utterance pauses.
            let crossesGap = (next.startMs - current.endMs) > max(gapThresholdMs, 500)
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
        // Cue text is joined from `[WordTimestamp]` and bypasses
        // `TextProcessingPipeline.cleanWhitespace`, so Parakeet's
        // punctuation-glued tokens (`down,16`, `jog.100`, `85,90,95`) need
        // the same space-insertion pass applied here. Unconditional — the
        // jams look bad regardless of the user's number toggle.
        let unstuck = splitStickyPunctuationDigits(in: text)

        // Whisper's BPE sometimes emits hyphenated compounds as two tokens
        // with a leading hyphen on the second half — joining with spaces
        // gives `warm -up`, `four -minute`, `90 -degree`. Stitch them back
        // into clean hyphenated form. Unconditional cleanup; the artifact
        // looks bad whether or not number normalization is on.
        let dehyphenated = collapseWhisperHyphenArtifacts(in: unstuck)

        // Number normalisation runs *before* wrapping so the wrapped output
        // can take advantage of the shorter digit form when measuring against
        // the per-line budget. (Pure string transform — does not change word
        // count or timing.)
        let prenormalised = config.normalizeNumbers ? NumberNormalizer.normalize(dehyphenated) : dehyphenated
        let cleaned = prenormalised.replacingOccurrences(of: "\n", with: " ")
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

    /// Insert a missing space when Parakeet emits glued tokens like
    /// `down,16`, `jog.100`, `85,90,95`, `it.70`. Mirrors the rule pair in
    /// `TextProcessingPipeline.cleanWhitespace`, but runs on the cue text
    /// (which is built directly from word timestamps and never sees the
    /// deterministic pipeline).
    ///
    /// Two narrow rules, both anchored to a preceding alphanumeric:
    ///   (a) after `,;:` followed by a letter or digit — safe in
    ///       transcribed prose where commas don't appear inside
    ///       abbreviations ("85,90,95" → "85, 90, 95").
    ///   (b) after `.!?` followed by a digit — leaves "I.B.M." alone
    ///       while still fixing "jog.100" → "jog. 100".
    nonisolated static func splitStickyPunctuationDigits(in text: String) -> String {
        var result = text
        let range = { NSRange(result.startIndex..., in: result) }
        if let regex = try? NSRegularExpression(pattern: "(?<=[\\p{L}\\d])([,;:])(\\p{L}|\\d)") {
            result = regex.stringByReplacingMatches(
                in: result, range: range(), withTemplate: "$1 $2"
            )
        }
        if let regex = try? NSRegularExpression(pattern: "(?<=[\\p{L}\\d])([.!?])(\\d)") {
            result = regex.stringByReplacingMatches(
                in: result, range: range(), withTemplate: "$1 $2"
            )
        }
        return result
    }

    /// Stitch Whisper's hyphen-tokenization artifacts: a token starting
    /// with a hyphen (e.g. `-minute`, `-up`, `-degree`) preceded by a
    /// regular word with a single space between them. The intended
    /// display is the hyphenated compound (`four-minute`, `warm-up`,
    /// `90-degree`), so collapse the `"<letter> -<letter>"` shape into
    /// `"<letter>-<letter>"`.
    ///
    /// The pattern is anchored on a preceding word character so a
    /// genuine sentence-leading dash (`- This is a list item`) at the
    /// start of a cue isn't touched.
    nonisolated static func collapseWhisperHyphenArtifacts(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(\\w) -(\\w)",
            options: []
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1-$2"
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
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
                engineSegments: transcription.transcriptSegments
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
                cleanedTranscript: transcription.cleanTranscript ?? transcription.rawTranscript,
                engineSegments: transcription.transcriptSegments
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
