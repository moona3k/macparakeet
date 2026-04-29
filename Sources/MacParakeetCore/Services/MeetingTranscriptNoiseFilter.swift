import Foundation

struct MeetingTranscriptNoiseFilter {
    struct CleanupResult: Sendable, Equatable {
        let microphoneWords: [WordTimestamp]
        let removedMicrophoneWordCount: Int
    }

    private struct IndexedRun {
        let indexes: [Int]
        let words: [WordTimestamp]
    }

    private static let fillerTokens: Set<String> = [
        "ah",
        "eh",
        "er",
        "hm",
        "hmm",
        "mm",
        "mhm",
        "mmhmm",
        "uh",
        "uhh",
        "um",
        "umm",
    ]
    private static let runGapMs = 1_200
    private static let duplicateTimingToleranceMs = 600
    private static let duplicateMaxWords = 10
    private static let duplicateLowConfidenceThreshold = 0.65
    private static let duplicateShortConfidenceThreshold = 0.80
    private static let allowedTokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))

    static func cleanFinalMicrophoneWords(
        microphoneWords: [WordTimestamp],
        systemWords: [WordTimestamp]
    ) -> CleanupResult {
        guard !microphoneWords.isEmpty else {
            return CleanupResult(microphoneWords: [], removedMicrophoneWordCount: 0)
        }

        let systemTokenWords = normalizedSystemTokenWords(from: systemWords)
        var indexesToDrop = Set<Int>()
        for run in contiguousRuns(in: microphoneWords) {
            if isFillerOnly(run.words) {
                indexesToDrop.formUnion(run.indexes)
                continue
            }

            if isObviousSystemDuplicate(microphoneRun: run.words, systemTokenWords: systemTokenWords) {
                indexesToDrop.formUnion(run.indexes)
            }
        }

        guard !indexesToDrop.isEmpty else {
            return CleanupResult(microphoneWords: microphoneWords, removedMicrophoneWordCount: 0)
        }

        let cleaned = microphoneWords.enumerated().compactMap { index, word in
            indexesToDrop.contains(index) ? nil : word
        }
        return CleanupResult(
            microphoneWords: cleaned,
            removedMicrophoneWordCount: indexesToDrop.count
        )
    }

    private static func contiguousRuns(in words: [WordTimestamp]) -> [IndexedRun] {
        guard let first = words.first else { return [] }

        var runs: [IndexedRun] = []
        var currentIndexes = [0]
        var currentWords = [first]
        var lastEndMs = first.endMs

        for (index, word) in words.enumerated().dropFirst() {
            if word.startMs - lastEndMs > runGapMs {
                runs.append(IndexedRun(indexes: currentIndexes, words: currentWords))
                currentIndexes = [index]
                currentWords = [word]
            } else {
                currentIndexes.append(index)
                currentWords.append(word)
            }
            lastEndMs = word.endMs
        }

        runs.append(IndexedRun(indexes: currentIndexes, words: currentWords))
        return runs
    }

    private static func isFillerOnly(_ words: [WordTimestamp]) -> Bool {
        let tokens = normalizedTokens(words)
        return !tokens.isEmpty && tokens.allSatisfy { fillerTokens.contains($0) }
    }

    private static func isObviousSystemDuplicate(
        microphoneRun: [WordTimestamp],
        systemTokenWords: [(token: String, word: WordTimestamp)]
    ) -> Bool {
        let micTokens = normalizedTokens(microphoneRun)
        guard !micTokens.isEmpty,
              micTokens.count <= duplicateMaxWords,
              systemTokenWords.count >= micTokens.count else {
            return false
        }

        let averageConfidence = microphoneRun.reduce(0.0) { $0 + $1.confidence } / Double(microphoneRun.count)
        let confidenceAllowsDrop = averageConfidence <= duplicateLowConfidenceThreshold
            || (micTokens.count <= 2 && averageConfidence <= duplicateShortConfidenceThreshold)
        guard confidenceAllowsDrop else { return false }

        for startIndex in 0...(systemTokenWords.count - micTokens.count) {
            let candidate = systemTokenWords[startIndex..<(startIndex + micTokens.count)].lazy.map(\.token)
            guard candidate.elementsEqual(micTokens) else { continue }

            let systemWindow = systemTokenWords[startIndex..<(startIndex + micTokens.count)].map(\.word)
            if rangesOverlapWithTolerance(lhs: microphoneRun, rhs: systemWindow) {
                return true
            }
        }

        return false
    }

    private static func rangesOverlapWithTolerance(
        lhs: [WordTimestamp],
        rhs: [WordTimestamp]
    ) -> Bool {
        guard let lhsStart = lhs.first?.startMs,
              let lhsEnd = lhs.last?.endMs,
              let rhsStart = rhs.first?.startMs,
              let rhsEnd = rhs.last?.endMs else {
            return false
        }

        return lhsStart <= rhsEnd + duplicateTimingToleranceMs
            && rhsStart <= lhsEnd + duplicateTimingToleranceMs
    }

    private static func normalizedTokens(_ words: [WordTimestamp]) -> [String] {
        words.compactMap { normalizedToken($0.word) }
    }

    private static func normalizedSystemTokenWords(from words: [WordTimestamp]) -> [(token: String, word: WordTimestamp)] {
        words.compactMap { word -> (token: String, word: WordTimestamp)? in
            guard let token = normalizedToken(word.word) else { return nil }
            return (token, word)
        }
    }

    private static func normalizedToken(_ token: String) -> String? {
        let normalized = String(token.lowercased().unicodeScalars.filter { allowedTokenCharacters.contains($0) })
        return normalized.isEmpty ? nil : normalized
    }
}
