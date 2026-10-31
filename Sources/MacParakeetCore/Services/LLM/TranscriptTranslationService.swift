import Foundation

public protocol TranscriptTranslating: Sendable {
    /// Translates `segments` in order. `onBatch` is called with each newly
    /// translated run of segments so callers can show progress; the returned
    /// array has exactly one entry per input segment.
    func translate(
        _ segments: [TranslationSourceSegment],
        to language: TranslationLanguage,
        onBatch: @Sendable ([TranslatedSegment]) async -> Void
    ) async throws -> [TranslatedSegment]
}

public extension TranscriptTranslating {
    func translate(
        _ segments: [TranslationSourceSegment],
        to language: TranslationLanguage
    ) async throws -> [TranslatedSegment] {
        try await translate(segments, to: language, onBatch: { _ in })
    }
}

public extension TranscriptTranslating {
    /// Translates Markdown (a summary or other prompt result) line by line so
    /// headings, lists, and spacing keep their structure. Blank lines, rules,
    /// and fenced code blocks are passed through untouched.
    func translateMarkdown(_ markdown: String, to language: TranslationLanguage) async throws -> String {
        var lines = markdown.components(separatedBy: "\n")
        var translatable: [(index: Int, indent: String, text: String, trailingWhitespace: String)] = []
        var codeFence: (marker: Character, length: Int)?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = codeFence {
                let markerCount = trimmed.prefix(while: { $0 == fence.marker }).count
                if markerCount >= fence.length,
                    trimmed.dropFirst(markerCount).allSatisfy(\.isWhitespace)
                {
                    codeFence = nil
                }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let markerCount = trimmed.prefix(while: { $0 == marker }).count
                let info = trimmed.dropFirst(markerCount)
                // Backtick fence info strings cannot themselves contain a
                // backtick. A closing fence must match the opener's marker and
                // be at least as long, with only whitespace after its run.
                if markerCount >= 3, marker != "`" || !info.contains("`") {
                    codeFence = (marker, markerCount)
                    continue
                }
            }
            guard trimmed.contains(where: \.isLetter) else { continue }
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let trailingWhitespace = String(line.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            translatable.append((index, indent, trimmed, trailingWhitespace))
        }
        guard !translatable.isEmpty else { return markdown }

        let translated = try await translate(
            translatable.map { TranslationSourceSegment(text: $0.text) },
            to: language
        )
        for (source, result) in zip(translatable, translated) {
            lines[source.index] = source.indent + result.text + source.trailingWhitespace
        }
        return lines.joined(separator: "\n")
    }
}

public enum TranscriptTranslationError: Error, LocalizedError, Equatable {
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .incompleteResponse:
            return "The AI provider returned an incomplete translation. Try again, or switch to a stronger model."
        }
    }
}

/// Translates transcript segments through the configured LLM provider.
///
/// Segments are sent in numbered batches so a long conversation is never
/// truncated by the provider's context budget, and so every translated line
/// maps back to exactly one source segment (and its timing).
public struct TranscriptTranslationService: TranscriptTranslating {
    /// Sized to stay well inside the smallest provider context budget
    /// (LM Studio) with room for the translated output.
    static let maxBatchCharacters = 2_400
    static let maxBatchSegments = 40

    private let llmService: LLMServiceProtocol

    public init(llmService: LLMServiceProtocol) {
        self.llmService = llmService
    }

    public func translate(
        _ segments: [TranslationSourceSegment],
        to language: TranslationLanguage,
        onBatch: @Sendable ([TranslatedSegment]) async -> Void
    ) async throws -> [TranslatedSegment] {
        var translated: [TranslatedSegment] = []
        translated.reserveCapacity(segments.count)

        for range in Self.batchRanges(for: segments) {
            try Task.checkCancellation()
            let batch = Array(segments[range])
            let texts = try await translateBatch(batch.map(\.text), to: language)
            try Task.checkCancellation()
            let results = zip(batch, texts).map { source, text in
                TranslatedSegment(
                    startMs: source.startMs,
                    endMs: source.endMs,
                    speakerId: source.speakerId,
                    text: text
                )
            }
            translated.append(contentsOf: results)
            await onBatch(results)
            try Task.checkCancellation()
        }
        return translated
    }

    // MARK: - Batching

    static func batchRanges(for segments: [TranslationSourceSegment]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var characters = 0
        for (index, segment) in segments.enumerated() {
            let count = segment.text.count
            let isFull =
                index > start
                && (characters + count > maxBatchCharacters || index - start >= maxBatchSegments)
            if isFull {
                ranges.append(start..<index)
                start = index
                characters = 0
            }
            characters += count
        }
        if start < segments.count {
            ranges.append(start..<segments.count)
        }
        return ranges
    }

    // MARK: - One batch

    private func translateBatch(_ texts: [String], to language: TranslationLanguage) async throws -> [String] {
        // batchRanges isolates an oversized segment. Split that one input into
        // bounded requests, then reassemble it before publishing progress so
        // timing, speaker identity, and one-result-per-segment remain intact.
        if texts.count == 1, let text = texts.first, text.count > Self.maxBatchCharacters {
            var translatedParts: [String] = []
            var remainder = text[...]
            while !remainder.isEmpty {
                try Task.checkCancellation()
                let hardEnd =
                    remainder.index(
                        remainder.startIndex, offsetBy: Self.maxBatchCharacters, limitedBy: remainder.endIndex)
                    ?? remainder.endIndex
                let end: String.Index
                if hardEnd != remainder.endIndex,
                    let space = remainder[..<hardEnd].lastIndex(where: \.isWhitespace),
                    space != remainder.startIndex
                {
                    end = remainder.index(after: space)
                } else {
                    end = hardEnd
                }
                let part = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                remainder = remainder[end...]
                guard !part.isEmpty else { continue }
                translatedParts += try await translateBatch([part], to: language)
            }
            try Task.checkCancellation()
            return [translatedParts.joined(separator: " ")]
        }

        var results = try await requestTranslations(of: texts, to: language)

        // Models occasionally merge or drop a line. Ask again for just the
        // missing ones before giving up on the batch.
        let missing = texts.indices.filter { results[$0] == nil }
        if !missing.isEmpty {
            try Task.checkCancellation()
            let retried = try await requestTranslations(of: missing.map { texts[$0] }, to: language)
            for (offset, index) in missing.enumerated() {
                results[index] = retried[offset]
            }
        }

        return try texts.indices.map { index in
            guard let text = results[index] else {
                throw TranscriptTranslationError.incompleteResponse
            }
            return text
        }
    }

    private func requestTranslations(
        of texts: [String],
        to language: TranslationLanguage
    ) async throws -> [Int: String] {
        let response = try await llmService.translateDetailed(
            text: Self.numberedLines(texts),
            instructions: Self.systemPrompt(for: language)
        ).output
        return Self.parseNumberedLines(response, expectedCount: texts.count)
    }

    // MARK: - Prompt format

    static func systemPrompt(for language: TranslationLanguage) -> String {
        """
        You are a professional translator. Translate each numbered line of this conversation transcript into \(language.displayName) (\(language.nativeName)).

        Rules:
        - Output exactly one line per input line, in the same order, each starting with the same [number] marker.
        - Translate only. Do not add, merge, split, omit, summarize, or explain anything.
        - Keep names, numbers, and technical terms accurate.
        - Keep any Markdown markers (#, -, *, **, >, numbered-list prefixes, links, table pipes) exactly where they are.
        - Use natural, fluent \(language.displayName) as a native speaker would say it.
        - If a line is already in \(language.displayName), return it unchanged.
        - Output nothing except the numbered translated lines.
        """
    }

    static func numberedLines(_ texts: [String]) -> String {
        texts.enumerated().map { index, text in
            let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return "[\(index + 1)] \(singleLine)"
        }.joined(separator: "\n")
    }

    /// Parses `[n] text` lines into a zero-based index map. Lines without a
    /// marker continue the previous entry; anything before the first marker
    /// (a preamble) is ignored, as are markers outside `1...expectedCount`.
    static func parseNumberedLines(_ response: String, expectedCount: Int) -> [Int: String] {
        var results: [Int: String] = [:]
        var currentIndex: Int?

        for rawLine in response.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let (number, text) = splitMarker(line) {
                guard (1...max(expectedCount, 1)).contains(number), expectedCount > 0 else {
                    currentIndex = nil
                    continue
                }
                // First occurrence wins so a repeated marker cannot overwrite
                // or extend an earlier, correctly placed line.
                guard results[number - 1] == nil else {
                    currentIndex = nil
                    continue
                }
                currentIndex = number - 1
                if !text.isEmpty {
                    results[number - 1] = text
                }
            } else if let index = currentIndex, let existing = results[index] {
                results[index] = existing + " " + line
            }
        }
        return results
    }

    private static func splitMarker(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let digits = line[line.index(after: line.startIndex)..<close]
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        // `wholeNumberValue` also accepts Persian/Arabic-Indic digits, which
        // models sometimes use for the marker when translating into Persian.
        var number = 0
        for digit in digits {
            guard let value = digit.wholeNumberValue else { return nil }
            number = number * 10 + value
        }
        let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (number, text)
    }
}
