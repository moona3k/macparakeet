import XCTest
@testable import MacParakeetCore

@MainActor
final class SubtitleExportTests: XCTestCase {
    
    func testTranscriptCueBoundaries() throws {
        let words = makeTranscriptWordsWithSpaces()
        let config = SubtitleExportConfig(
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            maxDurationMs: 7000,
            gapThresholdMs: 800,
            breakOnPunctuation: true,
            minWordsBeforePunctuationBreak: 4,
            preferBalancedLines: true
        )
        
        let exportService = ExportService()
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        
        print("\n=== CUE OUTPUT ===")
        for (i, cue) in cues.enumerated() {
            let lineCount = cue.text.components(separatedBy: "\n").count
            let charCount = cue.text.count
            print("Cue \(i+1): \(charCount) chars, \(lineCount) lines")
            print("  \"\(cue.text.replacingOccurrences(of: "\n", with: " | "))\"")
            print("  Time: \(formatTime(cue.startMs))  ->  \(formatTime(cue.endMs))")
            print("")
        }
        print("=== END ===\n")
        
        // Verify no cue starts with orphaned words like "We", "And", "It"
        let badStarters = ["we", "and", "it", "then", "go", "thanks", "thank", "if", "that", "between"]
        for (i, cue) in cues.enumerated() {
            let firstWord = cue.text.split(separator: " ").first?.lowercased() ?? ""
            if badStarters.contains(firstWord) && cue.text.count < 20 {
                XCTFail("Cue \(i+1) starts with orphaned word '\(firstWord)': \(cue.text)")
            }
        }
        
        // Verify no cue ENDS with orphaned conjunctions, determiners, or articles.
        let badEnders = ["and", "but", "or", "so", "yet", "for", "nor", "then",
                         "the", "a", "an",
                         "my", "your", "his", "her", "its", "our", "their",
                         "this", "that", "these", "those", "which", "what", "whose"]
        for (i, cue) in cues.enumerated() {
            let words = cue.text.split(separator: " ").map(String.init)
            guard let lastWord = words.last?.lowercased() else { continue }
            let stripped = lastWord.trimmingCharacters(in: .punctuationCharacters)
            if badEnders.contains(stripped) {
                XCTFail("Cue \(i+1) ends with orphaned word '\(stripped)': \(cue.text)")
            }
        }
        
        // Verify no cue exceeds the total character budget for the configured
        // line count (maxCharsPerLine × maxLinesPerCue = 65 × 2 = 130).
        let totalBudget = config.maxCharsPerLine * config.maxLinesPerCue
        for (i, cue) in cues.enumerated() {
            let flatText = cue.text.replacingOccurrences(of: "\n", with: " ")
            if flatText.count > totalBudget {
                XCTFail("Cue \(i+1) exceeds \(totalBudget) chars (\(flatText.count)): \(flatText)")
            }
            // Also enforce per-line limit
            for (lineIdx, line) in cue.text.components(separatedBy: "\n").enumerated() {
                if line.count > config.maxCharsPerLine {
                    XCTFail("Cue \(i+1) line \(lineIdx+1) exceeds \(config.maxCharsPerLine) chars (\(line.count)): \(line)")
                }
            }
        }
    }
    
    private func formatTime(_ ms: Int) -> String {
        let seconds = ms / 1000
        let mins = seconds / 60
        let secs = seconds % 60
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", mins/60, mins%60, secs, millis)
    }
    
    private func makeTranscriptWordsWithSpaces() -> [WordTimestamp] {
        var words: [WordTimestamp] = []
        var currentMs = 4960
        
        let tokens = [
            "What", "is", "going", "on", "Echelon", "and", "welcome", "in", "to", "your",
            " intervals", "and", "arms", "30.",
            "We", "will", "spend", "the", "next", "30", "minutes", "right", "here", "on", "our",
            "bike,", "mixing", "some", "intervals", "on", "the", "bike",
            "with", "some", "arm", "intervals", "with", "your", "weights.",
            "Let's", "get", "our", "hands", "to", "the", "handlebar,",
            "legs", "are", "moving", "because", "your", "four-minute", "warm-up", "starts", "right", "now.",
            "If", "you", "are", "new", "to", "connect,",
            "I", "want", "to", "welcome", "you", "in.",
            "Thank", "you", "for", "being", "here", "today.",
            "Thanks", "for", "spending", "this", "30", "minutes", "with", "me.",
            "It", "is", "great", "to", "have", "you.",
            "Go", "ahead", "and", "find", "a", "cadence", "somewhere", "between", "80", "and", "90.",
            "Then", "reach", "down", "and", "bring", "your", "resistance", "somewhere", "between", "10", "and", "15.",
            "That", "is", "where", "we", "will", "spend", "the", "first", "half", "of", "our", "warm-up.",
            "And", "over", "the", "course", "of", "this", "four", "minutes,",
            "we'll", "work", "on", "building", "our", "cadence", "and", "our", "resistance",
            "up", "so", "you", "are", "ready", "for", "the", "fun.",
        ]
        
        for token in tokens {
            let duration = max(100, token.count * 80)
            words.append(WordTimestamp(
                word: token,
                startMs: currentMs,
                endMs: currentMs + duration,
                confidence: 0.95
            ))
            currentMs += duration + 50
        }
        
        return words
    }
}
