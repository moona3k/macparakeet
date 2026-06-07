import XCTest
@testable import MacParakeetCore

final class DiagnosticLogScopeTests: XCTestCase {
    // Fixed reference time so the 7-day (168 h) window is deterministic.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A log line stamped `hoursAgo` before `now`, matching the writer format.
    private func line(hoursAgo: Double, _ event: String) -> String {
        "\(iso(now.addingTimeInterval(-hoursAgo * 3600))) \(event)"
    }

    private func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Date filtering

    func testRecentDropsLinesOlderThanWindow() {
        let raw = joined([
            line(hoursAgo: 400, "old_event_a"),
            line(hoursAgo: 200, "old_event_b"),
            line(hoursAgo: 2, "recent_event"),
            line(hoursAgo: 0.1, "very_recent_event"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.contains("recent_event"))
        XCTAssertTrue(scoped.contains("very_recent_event"))
        XCTAssertFalse(scoped.contains("old_event_a"))
        XCTAssertFalse(scoped.contains("old_event_b"))
    }

    func testRecentKeepsLineExactlyAtWindowEdge() {
        // A line just inside the 7-day window survives; one just outside does not.
        let raw = joined([
            line(hoursAgo: 168.01, "just_outside"),
            line(hoursAgo: 167.99, "just_inside"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.contains("just_inside"))
        XCTAssertFalse(scoped.contains("just_outside"))
    }

    func testRecentKeepsTrailingNewlineSoOutputIsLineTerminated() {
        let raw = joined([line(hoursAgo: 1, "recent_event")])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.hasSuffix("\n"))
    }

    func testRecentHandlesCRLFLineEndings() {
        // CRLF must split into lines (not collapse into one) so the window
        // filter still works. Output is normalized to LF.
        let raw = [
            line(hoursAgo: 400, "old_crlf_event"),
            line(hoursAgo: 1, "recent_crlf_event"),
        ].joined(separator: "\r\n") + "\r\n"

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.contains("recent_crlf_event"))
        XCTAssertFalse(scoped.contains("old_crlf_event"))
        XCTAssertFalse(scoped.contains("\r"), "CRLF should be normalized to LF in the output")
    }

    func testRecentKeepsInWindowLinesDespiteOutOfOrderTimestamps() {
        // A backward clock correction can place an old line physically after a
        // recent one. The in-window line must survive rather than being cut off
        // when the walk meets the stale line.
        let raw = joined([
            line(hoursAgo: 6, "recent_old_but_in_window"),
            line(hoursAgo: 300, "stale_middle"),
            line(hoursAgo: 2, "recent_new"),
            line(hoursAgo: 1, "recent_newest"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.contains("recent_newest"))
        XCTAssertTrue(scoped.contains("recent_new"))
        XCTAssertTrue(scoped.contains("recent_old_but_in_window"))
        XCTAssertFalse(scoped.contains("stale_middle"))
    }

    // MARK: - Idle-user fallback

    func testRecentFallsBackToTrailingLinesWhenWindowIsEmpty() {
        // Every line is older than the window, but there are few of them, so the
        // fallback keeps them all rather than attaching nothing.
        let raw = joined([
            line(hoursAgo: 240, "stale_a"),
            line(hoursAgo: 200, "stale_b"),
            line(hoursAgo: 180, "stale_c"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.contains("stale_c"))
        XCTAssertTrue(scoped.contains("stale_a"))
    }

    func testRecentFallbackIsCappedToMinTailLines() {
        // All lines are stale (window empty) and there are more than the
        // fallback floor; only the most recent floor-worth survive.
        let total = AudioCaptureDiagnostics.recentUploadMinTailLines + 50
        let lines = (0..<total).map { index in
            // Oldest first; index 0 is the furthest in the past.
            line(hoursAgo: Double(240 + (total - index)), "stale_\(index)")
        }

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(joined(lines), scope: .recent, now: now)
        let keptLineCount = scoped.split(separator: "\n").count

        XCTAssertEqual(keptLineCount, AudioCaptureDiagnostics.recentUploadMinTailLines)
        // The newest stale line is kept; the oldest is dropped.
        XCTAssertTrue(scoped.contains("stale_\(total - 1)"))
        XCTAssertFalse(scoped.contains("stale_0"))
    }

    // MARK: - Size / line caps

    func testRecentEnforcesLineCap() {
        // More recent lines than the line cap allows.
        let total = AudioCaptureDiagnostics.recentUploadMaxLines + 500
        let lines = (0..<total).map { line(hoursAgo: 1, "recent_\($0)") }

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(joined(lines), scope: .recent, now: now)
        let keptLineCount = scoped.split(separator: "\n").count

        XCTAssertLessThanOrEqual(keptLineCount, AudioCaptureDiagnostics.recentUploadMaxLines)
        // The most recent line survives; the oldest is trimmed.
        XCTAssertTrue(scoped.contains("recent_\(total - 1)"))
        XCTAssertFalse(scoped.contains("recent_0"))
    }

    func testRecentEnforcesByteCap() {
        // Each line ~1 KB of recent content; well over the 2 MB byte cap.
        let filler = String(repeating: "x", count: 1000)
        let lines = (0..<4000).map { line(hoursAgo: 1, "recent_\($0)_\(filler)") }

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(joined(lines), scope: .recent, now: now)

        XCTAssertLessThanOrEqual(scoped.utf8.count, AudioCaptureDiagnostics.recentUploadMaxBytes)
        // The most recent content is what survives the tail trim.
        XCTAssertTrue(scoped.contains("recent_3999"))
        XCTAssertFalse(scoped.contains("recent_0_"))
    }

    func testByteCeilingHoldsForSinglePathologicallyLongLine() {
        // One line, no newline, larger than the cap: still bounded.
        let raw = String(repeating: "a", count: AudioCaptureDiagnostics.recentUploadMaxBytes * 2)

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertLessThanOrEqual(scoped.utf8.count, AudioCaptureDiagnostics.recentUploadMaxBytes)
    }

    func testByteCeilingHoldsForMultiByteSingleLine() {
        // A single line of 3-byte characters whose byte length exceeds the cap:
        // the boundary trim must stay within the cap AND not emit replacement
        // characters from a mid-sequence cut.
        let euros = String(
            repeating: "€",
            count: AudioCaptureDiagnostics.recentUploadMaxBytes / 3 + 100
        )

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(euros, scope: .recent, now: now)

        XCTAssertLessThanOrEqual(scoped.utf8.count, AudioCaptureDiagnostics.recentUploadMaxBytes)
        XCTAssertFalse(scoped.contains("\u{FFFD}"), "trim must cut on a UTF-8 boundary")
    }

    // MARK: - No parseable timestamps

    func testRecentKeepsTailWhenNoTimestampsAreParseable() {
        // No line begins with an ISO-8601 timestamp; the time cutoff can never
        // fire, so we degrade to keeping the tail under the caps.
        let lines = (0..<10).map { "freeform diagnostic line \($0) words=\($0)" }

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(joined(lines), scope: .recent, now: now)

        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.contains("freeform diagnostic line 9"))
        XCTAssertTrue(scoped.contains("freeform diagnostic line 0"))
    }

    func testRecentKeepsNonTimestampedLinesAdjacentToRecentEntries() {
        // A timestamp-less line interleaved with recent entries rides along.
        let raw = joined([
            line(hoursAgo: 400, "old_event"),
            line(hoursAgo: 1, "recent_event"),
            "continuation line without timestamp words=3",
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .recent, now: now)

        XCTAssertTrue(scoped.contains("recent_event"))
        XCTAssertTrue(scoped.contains("continuation line without timestamp"))
        XCTAssertFalse(scoped.contains("old_event"))
    }

    // MARK: - Full scope

    func testFullScopeKeepsEntireLog() {
        let raw = joined([
            line(hoursAgo: 500, "ancient_event"),
            line(hoursAgo: 100, "old_event"),
            line(hoursAgo: 1, "recent_event"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .full, now: now)

        XCTAssertTrue(scoped.contains("ancient_event"))
        XCTAssertTrue(scoped.contains("old_event"))
        XCTAssertTrue(scoped.contains("recent_event"))
    }

    func testFullScopeReconstructsLogExactly() {
        let raw = joined([
            line(hoursAgo: 50, "event_a key=1"),
            line(hoursAgo: 49, "event_b key=2"),
        ])

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(raw, scope: .full, now: now)

        XCTAssertEqual(scoped, raw)
    }

    func testFullScopeTailCapsAtOnDiskCeiling() {
        let ceiling = Int(AudioCaptureDiagnostics.diagnosticLogMaxBytes)
        let filler = String(repeating: "y", count: 1000)
        let lines = (0..<(ceiling / 1000 + 100)).map { line(hoursAgo: 1, "event_\($0)_\(filler)") }

        let scoped = AudioCaptureDiagnostics.scopedLogForUpload(joined(lines), scope: .full, now: now)

        XCTAssertLessThanOrEqual(scoped.utf8.count, ceiling)
    }

    // MARK: - Edge cases

    func testEmptyLogProducesEmptyOutput() {
        // A genuinely empty file yields no attachment — this is the contract the
        // feedback view model's empty-log guard relies on.
        XCTAssertEqual(AudioCaptureDiagnostics.scopedLogForUpload("", scope: .recent, now: now), "")
        XCTAssertEqual(AudioCaptureDiagnostics.scopedLogForUpload("", scope: .full, now: now), "")
    }

    func testWhitespaceOnlyLogIsPreservedAsContent() {
        // A lone blank line is content, not an empty file.
        let scoped = AudioCaptureDiagnostics.scopedLogForUpload("\n\n", scope: .recent, now: now)
        XCTAssertFalse(scoped.isEmpty)
    }
}
