import Foundation

/// What an owner has explicitly selected for one share. Nothing here is
/// inferred automatically; a caller (a future coordinator/UI layer) decides
/// selection defaults and passes the result in.
public struct ShareSelection: Sendable, Equatable {
    public var includeSummary: Bool
    public var includeNotes: Bool
    public var includeTranscript: Bool
    public var transcriptOptions: TranscriptExportOptions

    public init(
        includeSummary: Bool,
        includeNotes: Bool,
        includeTranscript: Bool,
        transcriptOptions: TranscriptExportOptions = .default
    ) {
        self.includeSummary = includeSummary
        self.includeNotes = includeNotes
        self.includeTranscript = includeTranscript
        self.transcriptOptions = transcriptOptions
    }
}

public enum ShareProjectionError: Error, Sendable, Equatable {
    /// Every selected component was empty or unavailable, so no section
    /// could be produced.
    case nothingSelected
}

/// Builds an allowlisted `ShareBundle` from local display data. This is the
/// only place selection turns into wire content, and it never serializes a
/// `Transcription` or `Card` wholesale: every field it can emit is explicitly
/// read out below, so audio paths, local IDs, model/provider details, prompts,
/// calendar context, and every other unselected field can never leak through.
public enum ShareProjection {
    /// Projects a full transcription (and its optional summary card) using
    /// the explicit selection. Meeting-like defaults (summary/notes on,
    /// transcript off) and transcript-only defaults (transcript on) are a
    /// UI-layer concern; this call takes the already-decided selection.
    public static func project(
        transcription: Transcription,
        card: Card? = nil,
        selection: ShareSelection,
        title: String? = nil,
        publishedAt: Date = Date()
    ) throws -> ShareBundle {
        var sections: [ShareBundle.Section] = []

        if selection.includeSummary, let card {
            sections.append(contentsOf: summarySections(from: card))
        }

        if selection.includeNotes {
            let notes = (transcription.userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                sections.append(.notes(title: "Notes", markdown: notes))
            }
        }

        if selection.includeTranscript {
            let segments = try transcriptSegments(from: transcription, options: selection.transcriptOptions)
            if !segments.isEmpty {
                sections.append(.transcript(title: "Transcript", segments: segments))
            }
        }

        guard !sections.isEmpty else { throw ShareProjectionError.nothingSelected }

        return try ShareBundle(
            publishedAt: publishedAt,
            title: normalizedTitle(title),
            source: selection.transcriptOptions.includeMetadata ? source(for: transcription) : nil,
            sections: sections
        )
    }

    /// Projects a single explicitly selected passage (for example, a
    /// highlighted excerpt) rather than an entire transcription.
    public static func projectPassage(
        text: String,
        startMs: Int? = nil,
        endMs: Int? = nil,
        speaker: String? = nil,
        sourceKind: ShareBundle.SourceKind = .other,
        displayDate: Date? = nil,
        durationMs: Int? = nil,
        title: String? = nil,
        publishedAt: Date = Date()
    ) throws -> ShareBundle {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShareProjectionError.nothingSelected }

        let segment = try ShareBundle.TranscriptSegment(
            text: trimmed, startMs: startMs, endMs: endMs, speaker: speaker
        )

        return try ShareBundle(
            publishedAt: publishedAt,
            title: normalizedTitle(title),
            source: ShareBundle.Source(kind: sourceKind, displayDate: displayDate, durationMs: durationMs),
            sections: [.transcript(title: "Transcript", segments: [segment])]
        )
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func source(for transcription: Transcription) -> ShareBundle.Source {
        let kind: ShareBundle.SourceKind
        switch transcription.sourceType {
        case .meeting: kind = .meeting
        case .file: kind = .file
        case .youtube: kind = .web
        case .podcast: kind = .podcast
        }
        return ShareBundle.Source(
            kind: kind,
            displayDate: transcription.createdAt,
            durationMs: transcription.durationMs
        )
    }

    /// Splits one `Card` into independently reviewable summary sections
    /// (synopsis/topics, decisions, action items) rather than one opaque blob,
    /// so a future selection UI can toggle them separately. Sections with no
    /// content are omitted rather than emitted empty.
    private static func summarySections(from card: Card) -> [ShareBundle.Section] {
        var sections: [ShareBundle.Section] = []

        let synopsis = card.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !synopsis.isEmpty || !card.topics.isEmpty {
            var lines: [String] = []
            if !synopsis.isEmpty { lines.append(synopsis) }
            if !card.topics.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: card.topics.map { "- \($0)" })
            }
            sections.append(.summary(title: "Summary", markdown: lines.joined(separator: "\n")))
        }

        if !card.decisions.isEmpty {
            let markdown = card.decisions.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append(.summary(title: "Decisions", markdown: markdown))
        }

        if !card.actions.isEmpty {
            let markdown = card.actions.map { action -> String in
                guard let owner = action.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !owner.isEmpty
                else {
                    return "- \(action.text)"
                }
                return "- \(action.text) (\(owner))"
            }.joined(separator: "\n")
            sections.append(.summary(title: "Action items", markdown: markdown))
        }

        return sections
    }

    /// Reads out only display-selected transcript text, optional timing, and
    /// the current speaker label. Untimed transcript-only sources (no word
    /// timestamps, such as plain-text engines) still produce structured
    /// paragraph segments instead of one undifferentiated blob.
    private static func transcriptSegments(
        from transcription: Transcription,
        options: TranscriptExportOptions
    ) throws -> [ShareBundle.TranscriptSegment] {
        let resolvedOptions = options.resolved(
            canIncludeTimestamps: transcription.hasWordTimestamps,
            canIncludeSpeakerLabels: transcription.hasSpeakerLabeledWords
        )

        if transcription.isTranscriptEdited,
            let text = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return try untimedSegments(from: text)
        }

        if let words = transcription.wordTimestamps, !words.isEmpty {
            let paragraphs = TranscriptParagraphBuilder.build(from: words)
            return try paragraphs.compactMap { paragraph -> ShareBundle.TranscriptSegment? in
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speaker =
                    resolvedOptions.includeSpeakerLabels
                    ? speakerLabel(for: paragraph.speakerId, in: transcription.speakers)
                    : nil
                if resolvedOptions.includeTimestamps {
                    return try ShareBundle.TranscriptSegment(
                        text: text, startMs: paragraph.startMs, endMs: paragraph.endMs, speaker: speaker
                    )
                }
                return try ShareBundle.TranscriptSegment(text: text, speaker: speaker)
            }
        }

        let text = (transcription.cleanTranscript ?? transcription.rawTranscript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return try untimedSegments(from: text)
    }

    private static func untimedSegments(from text: String) throws -> [ShareBundle.TranscriptSegment] {
        let paragraphs =
            text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }
        return try paragraphs.map { try ShareBundle.TranscriptSegment(text: $0) }
    }

    private static func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId, let speakers, !speakers.isEmpty else { return nil }
        return speakers.first(where: { $0.id == speakerId })?.label
    }
}
