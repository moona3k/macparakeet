import Foundation

/// Computes a presentation-independent diff between two immutable prompt versions.
public enum PromptDiffService {
    public static func diff(from oldVersion: PromptVersion, to newVersion: PromptVersion) -> PromptVersionDiff {
        PromptVersionDiff(
            markdown: markdownDiff(from: oldVersion.content, to: newVersion.content),
            inferenceSettings: inferenceSettingsDiff(
                from: oldVersion.inferenceSettings,
                to: newVersion.inferenceSettings
            ),
            modelOverride: valueChange(from: oldVersion.modelOverride, to: newVersion.modelOverride)
        )
    }

    public static func markdownDiff(from oldMarkdown: String, to newMarkdown: String) -> PromptMarkdownDiff {
        let oldLines = lines(in: oldMarkdown)
        let newLines = lines(in: newMarkdown)
        let operations = sequenceDiff(old: oldLines, new: newLines)

        var oldLineNumber = 1
        var newLineNumber = 1
        let lineDiffs = operations.map { operation -> PromptMarkdownLineDiff in
            defer {
                switch operation {
                case .unchanged, .modified:
                    oldLineNumber += 1
                    newLineNumber += 1
                case .removed:
                    oldLineNumber += 1
                case .added:
                    newLineNumber += 1
                }
            }

            switch operation {
            case .unchanged(let text):
                let segment = PromptDiffTextSegment(
                    kind: .unchanged,
                    text: text,
                    characterRange: 0..<text.count
                )
                return PromptMarkdownLineDiff(
                    kind: .unchanged,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    oldText: text,
                    newText: text,
                    oldSegments: [segment],
                    newSegments: [segment]
                )

            case .modified(let oldText, let newText):
                let segments = wordDiff(from: oldText, to: newText)
                return PromptMarkdownLineDiff(
                    kind: .modified,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    oldText: oldText,
                    newText: newText,
                    oldSegments: segments.old,
                    newSegments: segments.new
                )

            case .removed(let text):
                return PromptMarkdownLineDiff(
                    kind: .removed,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil,
                    oldText: text,
                    newText: nil,
                    oldSegments: [
                        PromptDiffTextSegment(
                            kind: .removed,
                            text: text,
                            characterRange: 0..<text.count
                        )
                    ],
                    newSegments: []
                )

            case .added(let text):
                return PromptMarkdownLineDiff(
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber,
                    oldText: nil,
                    newText: text,
                    oldSegments: [],
                    newSegments: [
                        PromptDiffTextSegment(
                            kind: .added,
                            text: text,
                            characterRange: 0..<text.count
                        )
                    ]
                )
            }
        }

        return PromptMarkdownDiff(lines: lineDiffs)
    }

    public static func inferenceSettingsDiff(
        from oldSettings: PromptInferenceSettings?,
        to newSettings: PromptInferenceSettings?
    ) -> [PromptInferenceSettingChange] {
        let oldSettings = oldSettings?.normalized ?? PromptInferenceSettings()
        let newSettings = newSettings?.normalized ?? PromptInferenceSettings()

        return PromptInferenceSettings.Field.allCases.compactMap { field in
            let oldValue = value(for: field, in: oldSettings)
            let newValue = value(for: field, in: newSettings)
            guard oldValue != newValue else { return nil }
            return PromptInferenceSettingChange(field: field, oldValue: oldValue, newValue: newValue)
        }
    }

    private static func valueChange<Value: Equatable & Sendable>(
        from oldValue: Value,
        to newValue: Value
    ) -> PromptDiffValueChange<Value>? {
        guard oldValue != newValue else { return nil }
        return PromptDiffValueChange(oldValue: oldValue, newValue: newValue)
    }

    private static func value(
        for field: PromptInferenceSettings.Field,
        in settings: PromptInferenceSettings
    ) -> PromptInferenceSettingValue? {
        switch field {
        case .temperature:
            return settings.temperature.map(PromptInferenceSettingValue.decimal)
        case .topP:
            return settings.topP.map(PromptInferenceSettingValue.decimal)
        case .topK:
            return settings.topK.map(PromptInferenceSettingValue.integer)
        case .maxTokens:
            return settings.maxTokens.map(PromptInferenceSettingValue.integer)
        case .thinkingMode:
            return .thinkingMode(settings.thinkingMode)
        case .reasoningEffort:
            return settings.reasoningEffort.map(PromptInferenceSettingValue.reasoningEffort)
        }
    }

    private static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func wordDiff(
        from oldText: String,
        to newText: String
    ) -> (old: [PromptDiffTextSegment], new: [PromptDiffTextSegment]) {
        let oldTokens = tokens(in: oldText)
        let newTokens = tokens(in: newText)
        if exceedsMatrixLimit(oldTokens.count, newTokens.count) {
            return (
                [
                    PromptDiffTextSegment(
                        kind: .removed,
                        text: oldText,
                        characterRange: 0..<oldText.count
                    )
                ],
                [
                    PromptDiffTextSegment(
                        kind: .added,
                        text: newText,
                        characterRange: 0..<newText.count
                    )
                ]
            )
        }
        let common = longestCommonSubsequence(oldTokens.map(\.text), newTokens.map(\.text))

        var oldSegments: [PromptDiffTextSegment] = []
        var newSegments: [PromptDiffTextSegment] = []
        var oldIndex = 0
        var newIndex = 0

        for match in common {
            while oldIndex < match.oldIndex {
                append(oldTokens[oldIndex], kind: .removed, to: &oldSegments)
                oldIndex += 1
            }
            while newIndex < match.newIndex {
                append(newTokens[newIndex], kind: .added, to: &newSegments)
                newIndex += 1
            }

            append(oldTokens[oldIndex], kind: .unchanged, to: &oldSegments)
            append(newTokens[newIndex], kind: .unchanged, to: &newSegments)
            oldIndex += 1
            newIndex += 1
        }

        while oldIndex < oldTokens.count {
            append(oldTokens[oldIndex], kind: .removed, to: &oldSegments)
            oldIndex += 1
        }
        while newIndex < newTokens.count {
            append(newTokens[newIndex], kind: .added, to: &newSegments)
            newIndex += 1
        }

        return (oldSegments, newSegments)
    }

    private static func append(
        _ token: Token,
        kind: PromptDiffSegmentKind,
        to segments: inout [PromptDiffTextSegment]
    ) {
        if let last = segments.last, last.kind == kind, last.characterRange.upperBound == token.range.lowerBound {
            segments[segments.count - 1] = PromptDiffTextSegment(
                kind: kind,
                text: last.text + token.text,
                characterRange: last.characterRange.lowerBound..<token.range.upperBound
            )
        } else {
            segments.append(
                PromptDiffTextSegment(kind: kind, text: token.text, characterRange: token.range)
            )
        }
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start = 0
        var offset = 0
        var currentKind: TokenKind?
        var currentText = ""

        func finishToken() {
            guard !currentText.isEmpty else { return }
            tokens.append(
                Token(text: currentText, range: start..<offset, kind: currentKind ?? .symbol)
            )
            currentText = ""
        }

        for character in text {
            let kind = tokenKind(for: character)
            if kind == .symbol {
                finishToken()
                tokens.append(
                    Token(text: String(character), range: offset..<(offset + 1), kind: .symbol)
                )
                currentKind = nil
                offset += 1
                continue
            }
            if currentKind != kind {
                finishToken()
                start = offset
                currentKind = kind
            }
            currentText.append(character)
            offset += 1
        }
        finishToken()
        return tokens
    }

    private static func tokenKind(for character: Character) -> TokenKind {
        if character.isWhitespace {
            return .whitespace
        }
        if character.unicodeScalars.contains(where: { scalar in
            scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
                || scalar == "_"
        }) {
            return .word
        }
        return .symbol
    }

    private static func sequenceDiff(old: [String], new: [String]) -> [LineOperation] {
        // Prompt bodies are normally small. This fallback prevents an accidentally
        // pasted document from allocating an unbounded dynamic-programming matrix.
        if exceedsMatrixLimit(old.count, new.count) {
            return zipLongLines(old: old, new: new)
        }

        // Tokenize each line once, rather than twice for every matrix cell.
        let oldWords = old.map(words)
        let newWords = new.map(words)
        var distance = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        for oldIndex in 0...old.count { distance[oldIndex][0] = oldIndex }
        for newIndex in 0...new.count { distance[0][newIndex] = newIndex }

        if !old.isEmpty, !new.isEmpty {
            for oldIndex in 1...old.count {
                for newIndex in 1...new.count {
                    if old[oldIndex - 1] == new[newIndex - 1] {
                        distance[oldIndex][newIndex] = distance[oldIndex - 1][newIndex - 1]
                    } else {
                        let substitutionCost = lineSubstitutionCost(
                            from: oldWords[oldIndex - 1],
                            to: newWords[newIndex - 1]
                        )
                        distance[oldIndex][newIndex] = min(
                            distance[oldIndex - 1][newIndex - 1] + substitutionCost,
                            min(
                                distance[oldIndex - 1][newIndex] + 1,
                                distance[oldIndex][newIndex - 1] + 1
                            )
                        )
                    }
                }
            }
        }

        var operations: [LineOperation] = []
        var oldIndex = old.count
        var newIndex = new.count
        while oldIndex > 0 || newIndex > 0 {
            if oldIndex > 0, newIndex > 0,
                old[oldIndex - 1] == new[newIndex - 1],
                distance[oldIndex][newIndex] == distance[oldIndex - 1][newIndex - 1]
            {
                operations.append(.unchanged(old[oldIndex - 1]))
                oldIndex -= 1
                newIndex -= 1
            } else if oldIndex > 0, newIndex > 0,
                distance[oldIndex][newIndex]
                    == distance[oldIndex - 1][newIndex - 1]
                    + lineSubstitutionCost(from: oldWords[oldIndex - 1], to: newWords[newIndex - 1])
            {
                operations.append(.modified(old: old[oldIndex - 1], new: new[newIndex - 1]))
                oldIndex -= 1
                newIndex -= 1
            } else if oldIndex > 0,
                distance[oldIndex][newIndex] == distance[oldIndex - 1][newIndex] + 1
            {
                operations.append(.removed(old[oldIndex - 1]))
                oldIndex -= 1
            } else {
                operations.append(.added(new[newIndex - 1]))
                newIndex -= 1
            }
        }
        return operations.reversed()
    }

    /// Pairing related lines is cheaper than an independent removal and insertion.
    private static func lineSubstitutionCost(from oldWords: Set<String>, to newWords: Set<String>) -> Int {
        oldWords.isDisjoint(with: newWords) ? 2 : 1
    }

    private static func words(in line: String) -> Set<String> {
        Set(tokens(in: line).filter { $0.kind == .word }.map(\.text))
    }

    private static func zipLongLines(old: [String], new: [String]) -> [LineOperation] {
        let sharedCount = min(old.count, new.count)
        var operations: [LineOperation] = (0..<sharedCount).map { index in
            old[index] == new[index]
                ? .unchanged(old[index])
                : .modified(old: old[index], new: new[index])
        }
        operations.append(contentsOf: old.dropFirst(sharedCount).map(LineOperation.removed))
        operations.append(contentsOf: new.dropFirst(sharedCount).map(LineOperation.added))
        return operations
    }

    private static func exceedsMatrixLimit(_ firstCount: Int, _ secondCount: Int) -> Bool {
        guard firstCount > 0 else { return false }
        return secondCount > 1_000_000 / firstCount
    }

    private static func longestCommonSubsequence<Element: Equatable>(
        _ old: [Element],
        _ new: [Element]
    ) -> [(oldIndex: Int, newIndex: Int)] {
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        if !old.isEmpty, !new.isEmpty {
            for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: new.count - 1, through: 0, by: -1) {
                    if old[oldIndex] == new[newIndex] {
                        lengths[oldIndex][newIndex] = lengths[oldIndex + 1][newIndex + 1] + 1
                    } else {
                        lengths[oldIndex][newIndex] = max(
                            lengths[oldIndex + 1][newIndex],
                            lengths[oldIndex][newIndex + 1]
                        )
                    }
                }
            }
        }

        var result: [(oldIndex: Int, newIndex: Int)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex] == new[newIndex] {
                result.append((oldIndex, newIndex))
                oldIndex += 1
                newIndex += 1
            } else if lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return result
    }
}

public struct PromptVersionDiff: Sendable, Equatable {
    public let markdown: PromptMarkdownDiff
    public let inferenceSettings: [PromptInferenceSettingChange]
    public let modelOverride: PromptDiffValueChange<String?>?

    public init(
        markdown: PromptMarkdownDiff,
        inferenceSettings: [PromptInferenceSettingChange],
        modelOverride: PromptDiffValueChange<String?>?
    ) {
        self.markdown = markdown
        self.inferenceSettings = inferenceSettings
        self.modelOverride = modelOverride
    }

    public var hasChanges: Bool {
        markdown.hasChanges || !inferenceSettings.isEmpty || modelOverride != nil
    }
}

public struct PromptMarkdownDiff: Sendable, Equatable {
    public let lines: [PromptMarkdownLineDiff]

    public init(lines: [PromptMarkdownLineDiff]) {
        self.lines = lines
    }

    public var hasChanges: Bool {
        lines.contains { $0.kind != .unchanged }
    }
}

public enum PromptDiffLineKind: String, Sendable, Equatable {
    case unchanged
    case added
    case removed
    case modified
}

public struct PromptMarkdownLineDiff: Sendable, Equatable {
    public let kind: PromptDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let oldText: String?
    public let newText: String?
    public let oldSegments: [PromptDiffTextSegment]
    public let newSegments: [PromptDiffTextSegment]

    public init(
        kind: PromptDiffLineKind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        oldText: String?,
        newText: String?,
        oldSegments: [PromptDiffTextSegment],
        newSegments: [PromptDiffTextSegment]
    ) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.oldText = oldText
        self.newText = newText
        self.oldSegments = oldSegments
        self.newSegments = newSegments
    }
}

public enum PromptDiffSegmentKind: String, Sendable, Equatable {
    case unchanged
    case added
    case removed
}

public struct PromptDiffTextSegment: Sendable, Equatable {
    public let kind: PromptDiffSegmentKind
    public let text: String

    /// Zero-based range in extended grapheme clusters within the corresponding line.
    public let characterRange: Range<Int>

    public init(kind: PromptDiffSegmentKind, text: String, characterRange: Range<Int>) {
        self.kind = kind
        self.text = text
        self.characterRange = characterRange
    }
}

public struct PromptInferenceSettingChange: Sendable, Equatable {
    public let field: PromptInferenceSettings.Field
    public let oldValue: PromptInferenceSettingValue?
    public let newValue: PromptInferenceSettingValue?

    public init(
        field: PromptInferenceSettings.Field,
        oldValue: PromptInferenceSettingValue?,
        newValue: PromptInferenceSettingValue?
    ) {
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public enum PromptInferenceSettingValue: Sendable, Equatable {
    case decimal(Double)
    case integer(Int)
    case thinkingMode(PromptInferenceSettings.ThinkingMode)
    case reasoningEffort(PromptInferenceSettings.ReasoningEffort)
}

public struct PromptDiffValueChange<Value: Equatable & Sendable>: Sendable, Equatable {
    public let oldValue: Value
    public let newValue: Value

    public init(oldValue: Value, newValue: Value) {
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

private extension PromptDiffService {
    enum LineOperation {
        case unchanged(String)
        case added(String)
        case removed(String)
        case modified(old: String, new: String)
    }

    enum TokenKind: Equatable {
        case word
        case whitespace
        case symbol
    }

    struct Token {
        let text: String
        let range: Range<Int>
        let kind: TokenKind
    }
}
