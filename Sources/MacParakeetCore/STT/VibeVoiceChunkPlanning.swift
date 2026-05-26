import Foundation

/// Pure functions used by `VibeVoiceChunkedTranscriber`. No I/O, no FFmpeg,
/// no model dependencies — all are deterministic given their inputs so they
/// can be exhaustively unit-tested without fixtures or external processes.
internal enum VibeVoiceChunkPlanning {

    /// Parses FFmpeg's `silencedetect` filter stderr output into closed
    /// intervals of source-audio time (seconds).
    ///
    /// Expected line shapes:
    ///   `[silencedetect @ 0x...] silence_start: 4.5`
    ///   `[silencedetect @ 0x...] silence_end: 5.2 | silence_duration: 0.7`
    ///
    /// Orphan `silence_start` lines (no matching `silence_end`) are
    /// dropped — FFmpeg emits one if audio ends during silence. Malformed
    /// numeric values are also skipped.
    static func parseSilenceIntervals(_ stderr: String) -> [ClosedRange<Double>] {
        var pendingStart: Double? = nil
        var result: [ClosedRange<Double>] = []
        // Swift treats `\r\n` as a single Character (grapheme cluster), which
        // means `split(separator: "\n")` would not split CRLF-terminated lines
        // at all. Normalize line endings first so FFmpeg stderr piped through
        // tools that re-emit CRLF still parses correctly.
        let normalized = stderr.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n") {
            if let startStr = line.split(separator: "silence_start:").last.map(String.init),
               line.contains("silence_start:") {
                let trimmed = startStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(trimmed.split(separator: " ").first.map(String.init) ?? trimmed) {
                    pendingStart = value
                } else {
                    pendingStart = nil
                }
            } else if line.contains("silence_end:") {
                let afterTag = line.split(separator: "silence_end:").last.map(String.init) ?? ""
                let firstToken = afterTag.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ").first.map(String.init) ?? ""
                if let endValue = Double(firstToken), let startValue = pendingStart, endValue >= startValue {
                    result.append(startValue...endValue)
                }
                pendingStart = nil
            }
        }
        return result
    }

    /// Computes the intermediate chunk boundary times for an audio file.
    ///
    /// Returns a list of `Double` seconds where chunks split. The boundaries
    /// don't include 0 or `audioSec` — only the cuts between chunks. So for
    /// a 30-min file at 5-min chunks the return is `[300, 600, 900, 1200, 1500]`
    /// which produces 6 chunks.
    ///
    /// If the final chunk would be shorter than `minTailSec`, the last
    /// boundary is dropped so the tail is absorbed into the prior chunk.
    /// Avoids paying chunk-overhead for a tiny final chunk.
    static func computeChunkPlan(
        audioSec: Double,
        chunkLengthSec: Double,
        minTailSec: Double
    ) -> [Double] {
        guard audioSec > chunkLengthSec else { return [] }
        var boundaries: [Double] = []
        var t = chunkLengthSec
        while t < audioSec {
            boundaries.append(t)
            t += chunkLengthSec
        }
        // If the final chunk (from last boundary to audioSec) is too small,
        // drop the last boundary so the tail folds into the prior chunk.
        if let last = boundaries.last, audioSec - last < minTailSec {
            boundaries.removeLast()
        }
        return boundaries
    }
}
