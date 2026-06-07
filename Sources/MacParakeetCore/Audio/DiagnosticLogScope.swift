import Foundation

/// How much of `dictation-audio.log` a feedback upload should carry.
///
/// Scoping happens by *recency of whole lines* — never by editing what a line
/// contains. The per-line content is already privacy-scrubbed when it is
/// written (see `AudioCaptureDiagnostics`: no audio, no transcript text,
/// device identity reduced to `present`/`none` + coarse transport). The only
/// thing scope decides is *how far back* the attachment reaches.
public enum DiagnosticLogScope: Sendable {
    /// Default for feedback uploads: the recent tail of the log, bounded by a
    /// time window plus hard size/line caps. Keeps an attachment to a public
    /// issue small and focused on the window around the reported problem.
    case recent

    /// Advanced, user-chosen "include older diagnostics": the whole available
    /// log, bounded only by the on-disk byte ceiling. For intermittent issues
    /// where the relevant capture happened days ago.
    case full
}

extension AudioCaptureDiagnostics {
    /// Time window kept by `.recent` scope. 7 days is the issue's "never more
    /// than a week" ceiling used directly as the default: generous enough that
    /// a report filed days after the fact still carries the relevant capture,
    /// while never dumping the whole multi-week on-disk history. The byte/line
    /// caps below are safety ceilings, not the primary scoping rule — for all
    /// but the heaviest users, the default upload is simply "the last week".
    public static let recentUploadWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Safety byte ceiling for `.recent`, applied after the time window. Set
    /// above what a week of normal use produces so it only bites pathological
    /// volume; the most recent bytes win when it does.
    public static let recentUploadMaxBytes = 2_000_000

    /// Safety line ceiling for `.recent`, applied after the time window.
    public static let recentUploadMaxLines = 20_000

    /// Fallback kept by `.recent` when *nothing* falls inside
    /// `recentUploadWindow` (a user whose last capture was over a week ago).
    /// Rather than attach an empty log, keep this many trailing lines so their
    /// most recent sessions still come through. ~500 lines covers dozens of
    /// recent capture attempts (each is roughly 8–12 lines).
    public static let recentUploadMinTailLines = 500

    /// Returns the slice of a raw diagnostic log that should be attached to a
    /// feedback upload for the given `scope`.
    ///
    /// - `.recent` keeps the lines within `recentUploadWindow`, bounded by
    ///   `recentUploadMaxBytes` / `recentUploadMaxLines`. If the window is empty
    ///   it falls back to the last `recentUploadMinTailLines` lines.
    /// - `.full` keeps everything, tail-capped at `diagnosticLogMaxBytes`.
    ///
    /// Lines whose leading token is not a parseable ISO-8601 timestamp never
    /// count as out-of-window — they ride the size/line caps. A log with no
    /// parseable timestamps at all therefore degrades cleanly to "the last
    /// `recentUploadMaxBytes` / `recentUploadMaxLines`".
    ///
    /// - Parameter now: injected reference time (defaults to the current date)
    ///   so the time window is deterministic in tests.
    public static func scopedLogForUpload(
        _ rawLog: String,
        scope: DiagnosticLogScope,
        now: Date = Date()
    ) -> String {
        // Split on LF, treating CRLF as one separator too: in Swift "\r\n" is a
        // single Character, so a plain "\n" split would miss it and collapse a
        // CRLF log into one line. The output is rejoined with LF.
        var lines = rawLog.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" }
        )
        // A trailing newline yields a final empty element; it is not a line.
        if lines.last == "" {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return "" }

        let maxBytes: Int
        let maxLines: Int
        let cutoff: Date?
        switch scope {
        case .recent:
            maxBytes = recentUploadMaxBytes
            maxLines = recentUploadMaxLines
            cutoff = now.addingTimeInterval(-recentUploadWindow)
        case .full:
            maxBytes = Int(diagnosticLogMaxBytes)
            maxLines = .max
            cutoff = nil
        }

        // Same options the writer uses (`withInternetDateTime` +
        // `withFractionalSeconds`), with a non-fractional fallback for safety.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        // Phase 1 — the recent window (for `.full`, the whole log up to the
        // ceiling). Lines older than the cutoff are skipped, not used to stop
        // the walk, so a non-monotonic log (e.g. a backward clock correction)
        // still keeps every in-window line. Lines without a timestamp ride along.
        var kept = tail(of: lines, maxBytes: maxBytes, maxLines: maxLines) { line in
            guard let cutoff,
                  let timestamp = parseLogLineTimestamp(line, fractional: fractional, plain: plain)
            else { return false }
            return timestamp < cutoff
        }

        // Phase 2 — idle-user fallback. Nothing landed in the window, so keep
        // the most recent lines regardless of age instead of an empty log.
        if kept.isEmpty {
            kept = tail(
                of: lines,
                maxBytes: maxBytes,
                maxLines: min(maxLines, recentUploadMinTailLines)
            ) { _ in false }
        }

        guard !kept.isEmpty else { return "" }
        var result = kept.joined(separator: "\n")
        result.append("\n")

        // Hard byte-ceiling guarantee. `tail` admits its newest line
        // unconditionally, so only a single pathologically long line can push
        // past `maxBytes`. Real entries are short and newline-terminated, so
        // this trim never fires in practice — it just keeps the contract
        // ("recent uploads stay within the cap") true for any input. Cut on a
        // UTF-8 scalar boundary so we never emit replacement characters or
        // overshoot the cap when a multi-byte sequence straddles the boundary.
        if result.utf8.count > maxBytes {
            let utf8 = result.utf8
            var start = utf8.index(utf8.endIndex, offsetBy: -maxBytes)
            while start < utf8.endIndex, utf8[start] & 0xC0 == 0x80 {
                start = utf8.index(after: start)
            }
            result = String(decoding: utf8[start...], as: UTF8.self)
        }
        return result
    }

    /// Walks `lines` newest-first, keeping lines until a hard cap halts it, and
    /// returns them in chronological order. Lines for which `skip` returns true
    /// are passed over without stopping the walk. The newest kept line is
    /// always admitted (so the byte cap can be exceeded only by a single line).
    private static func tail(
        of lines: [Substring],
        maxBytes: Int,
        maxLines: Int,
        skip: (Substring) -> Bool
    ) -> [Substring] {
        var kept: [Substring] = []
        var byteCount = 0
        for line in lines.reversed() {
            if kept.count >= maxLines { break }
            if skip(line) { continue }
            let lineBytes = line.utf8.count + 1 // +1 for the rejoined newline
            if !kept.isEmpty, byteCount + lineBytes > maxBytes { break }
            kept.append(line)
            byteCount += lineBytes
        }
        kept.reverse()
        return kept
    }

    /// Parses the leading ISO-8601 timestamp token of a log line, or `nil` if
    /// the line does not start with one.
    private static func parseLogLineTimestamp(
        _ line: Substring,
        fractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date? {
        let token = line.firstIndex(of: " ").map { String(line[..<$0]) } ?? String(line)
        guard !token.isEmpty else { return nil }
        return fractional.date(from: token) ?? plain.date(from: token)
    }
}
