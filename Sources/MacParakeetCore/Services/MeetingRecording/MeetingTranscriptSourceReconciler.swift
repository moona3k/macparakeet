import Foundation

struct MeetingTranscriptSourceReconciler {
    struct Result: Sendable, Equatable {
        let microphoneWords: [WordTimestamp]
        let removedMicrophoneWordCount: Int
        let removals: [MicrophoneRemoval]
    }

    struct MicrophoneRemoval: Sendable, Equatable {
        let reason: RemovalReason
        let words: [WordTimestamp]
    }

    enum RemovalReason: String, Sendable, Equatable {
        case lowConfidenceSystemDuplicate
        case simultaneousSystemEcho
    }

    private struct WordRun {
        let indexes: [Int]
        let words: [WordTimestamp]
        let tokenWords: [RunToken]

        var tokens: [String] {
            tokenWords.map(\.token)
        }

        var averageConfidence: Double {
            guard !words.isEmpty else { return 0 }
            return words.reduce(0.0) { $0 + $1.confidence } / Double(words.count)
        }

        var startMs: Int? { words.first?.startMs }
        var endMs: Int? { words.last?.endMs }
    }

    private struct RunToken {
        let token: String
        let microphoneIndex: Int
        let word: WordTimestamp
    }

    private struct TokenizedWord {
        let token: String
        let word: WordTimestamp
    }

    private struct SystemEchoReference {
        let tokenWords: [TokenizedWord]

        init(words: [WordTimestamp]) {
            tokenWords = words.compactMap { word in
                guard let token = normalizedToken(word.word) else { return nil }
                return TokenizedWord(token: token, word: word)
            }
        }

        func containsExactSequence(
            _ tokens: [String],
            overlapping run: WordRun,
            toleranceMs: Int
        ) -> Bool {
            guard !tokens.isEmpty, tokenWords.count >= tokens.count else { return false }

            for startIndex in 0...(tokenWords.count - tokens.count) {
                let candidate = tokenWords[startIndex..<(startIndex + tokens.count)].lazy.map(\.token)
                guard candidate.elementsEqual(tokens) else { continue }

                let systemWords = tokenWords[startIndex..<(startIndex + tokens.count)].map(\.word)
                if rangesOverlapWithTolerance(lhs: run.words, rhs: systemWords, toleranceMs: toleranceMs) {
                    return true
                }
            }

            return false
        }

        func fuzzyMatchedMicrophoneWords(
            for run: WordRun,
            toleranceMs: Int
        ) -> [RunToken] {
            guard !tokenWords.isEmpty else { return [] }

            var matchedWords: [RunToken] = []
            var systemIndex = 0

            for microphoneToken in run.tokenWords {
                let windowStart = microphoneToken.word.startMs - toleranceMs
                let windowEnd = microphoneToken.word.endMs + toleranceMs

                while systemIndex < tokenWords.count,
                      tokenWords[systemIndex].word.endMs < windowStart {
                    systemIndex += 1
                }

                var candidateIndex = systemIndex
                while candidateIndex < tokenWords.count,
                      tokenWords[candidateIndex].word.startMs <= windowEnd {
                    if MeetingTranscriptSourceReconciler.tokensRoughlyMatch(
                        microphoneToken.token,
                        tokenWords[candidateIndex].token
                    ) {
                        matchedWords.append(microphoneToken)
                        systemIndex = candidateIndex + 1
                        break
                    }

                    candidateIndex += 1
                }
            }

            return matchedWords
        }

        func temporallyOverlappingMicrophoneTokenCount(
            for run: WordRun,
            toleranceMs: Int
        ) -> Int {
            guard !tokenWords.isEmpty else { return 0 }

            var count = 0
            var systemIndex = 0

            for microphoneToken in run.tokenWords {
                let windowStart = microphoneToken.word.startMs - toleranceMs
                let windowEnd = microphoneToken.word.endMs + toleranceMs

                while systemIndex < tokenWords.count,
                      tokenWords[systemIndex].word.endMs < windowStart {
                    systemIndex += 1
                }

                if systemIndex < tokenWords.count,
                   tokenWords[systemIndex].word.startMs <= windowEnd {
                    count += 1
                }
            }

            return count
        }
    }

    private struct RemovalDecision {
        let reason: RemovalReason
        let indexes: [Int]
        let words: [WordTimestamp]
    }

    private static let runGapMs = 1_200
    private static let duplicateTimingToleranceMs = 600
    private static let duplicateMaxWords = 10
    private static let duplicateLowConfidenceThreshold = 0.65
    private static let duplicateShortConfidenceThreshold = 0.80
    private static let simultaneousEchoMinWords = 5
    private static let simultaneousEchoSimilarity = 0.8
    private static let fuzzyTokenMinLength = 4
    private static let allowedTokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))

    static func reconcile(
        microphoneWords: [WordTimestamp],
        systemWords: [WordTimestamp]
    ) -> Result {
        guard !microphoneWords.isEmpty else {
            return Result(microphoneWords: [], removedMicrophoneWordCount: 0, removals: [])
        }

        let reference = SystemEchoReference(words: systemWords)
        var indexesToDrop = Set<Int>()
        var removals: [MicrophoneRemoval] = []

        for run in contiguousRuns(in: microphoneWords) {
            guard let decision = removalDecision(for: run, reference: reference) else { continue }
            indexesToDrop.formUnion(decision.indexes)
            removals.append(MicrophoneRemoval(reason: decision.reason, words: decision.words))
        }

        guard !indexesToDrop.isEmpty else {
            return Result(microphoneWords: microphoneWords, removedMicrophoneWordCount: 0, removals: [])
        }

        let cleaned = microphoneWords.enumerated().compactMap { index, word in
            indexesToDrop.contains(index) ? nil : word
        }
        return Result(
            microphoneWords: cleaned,
            removedMicrophoneWordCount: indexesToDrop.count,
            removals: removals
        )
    }

    private static func removalDecision(for run: WordRun, reference: SystemEchoReference) -> RemovalDecision? {
        if isLowConfidenceSystemDuplicate(run, reference: reference) {
            return RemovalDecision(reason: .lowConfidenceSystemDuplicate, indexes: run.indexes, words: run.words)
        }

        if let echoWords = simultaneousSystemEchoWords(run, reference: reference) {
            return RemovalDecision(
                reason: .simultaneousSystemEcho,
                indexes: echoWords.map(\.microphoneIndex),
                words: echoWords.map(\.word)
            )
        }

        return nil
    }

    private static func contiguousRuns(in words: [WordTimestamp]) -> [WordRun] {
        guard let first = words.first else { return [] }

        var runs: [WordRun] = []
        var currentIndexes = [0]
        var currentWords = [first]
        var lastEndMs = first.endMs

        for (index, word) in words.enumerated().dropFirst() {
            if word.startMs - lastEndMs > runGapMs {
                runs.append(WordRun(
                    indexes: currentIndexes,
                    words: currentWords,
                    tokenWords: tokenizedMicrophoneWords(currentWords, indexes: currentIndexes)
                ))
                currentIndexes = [index]
                currentWords = [word]
            } else {
                currentIndexes.append(index)
                currentWords.append(word)
            }
            lastEndMs = word.endMs
        }

        runs.append(WordRun(
            indexes: currentIndexes,
            words: currentWords,
            tokenWords: tokenizedMicrophoneWords(currentWords, indexes: currentIndexes)
        ))
        return runs
    }

    private static func isLowConfidenceSystemDuplicate(
        _ run: WordRun,
        reference: SystemEchoReference
    ) -> Bool {
        guard !run.tokens.isEmpty, run.tokens.count <= duplicateMaxWords else {
            return false
        }

        let confidenceAllowsDrop = run.averageConfidence <= duplicateLowConfidenceThreshold
            || (run.tokens.count <= 2 && run.averageConfidence <= duplicateShortConfidenceThreshold)
        guard confidenceAllowsDrop else { return false }

        return reference.containsExactSequence(
            run.tokens,
            overlapping: run,
            toleranceMs: duplicateTimingToleranceMs
        )
    }

    private static func simultaneousSystemEchoWords(
        _ run: WordRun,
        reference: SystemEchoReference
    ) -> [RunToken]? {
        guard run.tokens.count >= simultaneousEchoMinWords else { return nil }

        let overlappingTokenCount = reference.temporallyOverlappingMicrophoneTokenCount(
            for: run,
            toleranceMs: duplicateTimingToleranceMs
        )
        guard overlappingTokenCount >= simultaneousEchoMinWords else { return nil }

        let requiredMatches = Int((Double(overlappingTokenCount) * simultaneousEchoSimilarity).rounded(.up))
        let echoWords = reference.fuzzyMatchedMicrophoneWords(for: run, toleranceMs: duplicateTimingToleranceMs)
        guard echoWords.count >= simultaneousEchoMinWords, echoWords.count >= requiredMatches else {
            return nil
        }

        return echoWords
    }

    private static func tokensRoughlyMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard lhs.count >= fuzzyTokenMinLength, rhs.count >= fuzzyTokenMinLength else { return false }
        return editDistanceIsAtMostOne(lhs, rhs)
    }

    private static func editDistanceIsAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let shorter: [Character]
        let longer: [Character]
        if lhs.count <= rhs.count {
            shorter = Array(lhs)
            longer = Array(rhs)
        } else {
            shorter = Array(rhs)
            longer = Array(lhs)
        }
        guard longer.count - shorter.count <= 1 else { return false }

        if shorter.count == longer.count {
            var mismatches = 0
            for index in shorter.indices where shorter[index] != longer[index] {
                mismatches += 1
                if mismatches > 1 { return false }
            }
            return true
        }

        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < shorter.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                longIndex += 1
            }
        }
        return true
    }

    private static func rangesOverlapWithTolerance(
        lhs: [WordTimestamp],
        rhs: [WordTimestamp],
        toleranceMs: Int
    ) -> Bool {
        guard let lhsStart = lhs.first?.startMs,
              let lhsEnd = lhs.last?.endMs,
              let rhsStart = rhs.first?.startMs,
              let rhsEnd = rhs.last?.endMs else {
            return false
        }

        return lhsStart <= rhsEnd + toleranceMs
            && rhsStart <= lhsEnd + toleranceMs
    }

    private static func tokenizedMicrophoneWords(
        _ words: [WordTimestamp],
        indexes: [Int]
    ) -> [RunToken] {
        zip(indexes, words).compactMap { index, word in
            guard let token = normalizedToken(word.word) else { return nil }
            return RunToken(token: token, microphoneIndex: index, word: word)
        }
    }

    private static func normalizedToken(_ token: String) -> String? {
        let normalized = String(token.lowercased().unicodeScalars.filter { allowedTokenCharacters.contains($0) })
        return normalized.isEmpty ? nil : normalized
    }
}
