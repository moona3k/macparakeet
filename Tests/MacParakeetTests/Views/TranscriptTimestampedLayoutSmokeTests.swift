import AppKit
import SwiftUI
import XCTest
import MacParakeetCore
@testable import MacParakeet

/// Offscreen layout smoke tests for the timed transcript surface.
///
/// The Library "freeze at 100% CPU" bug was a SwiftUI update loop in the
/// transcript body (see `TranscriptBodyLayout`), so the guard here is not a
/// pixel check but a settling check: hosting the real
/// `TranscriptTimestampedContentView` inside the same container the detail
/// view uses must finish its first layout within a generous budget, survive a
/// programmatic scroll to the bottom and back, and leave the run loop quiet.
/// Hover from a real pointer cannot be simulated offscreen; that stays a
/// manual check.
@MainActor
final class TranscriptTimestampedLayoutSmokeTests: XCTestCase {

    private final class CountingHostingView<Content: View>: NSHostingView<Content> {
        var layoutCount = 0

        override func layout() {
            layoutCount += 1
            super.layout()
        }
    }

    /// Hard ceiling before the whole process is aborted: a livelocked main
    /// thread never returns to XCTest, so a plain assertion could not fire.
    /// Generous on purpose (the tests take ~2 s each) so a slow CI box cannot
    /// trip it; a hang would otherwise block the suite forever.
    private let watchdogSeconds: Double = 120
    private let firstLayoutBudgetSeconds: Double = 10

    private func segments(count: Int, speakers: [String?]) -> [TranscriptSegment] {
        let words = [
            "one", "quarterly", "review", "dashboard", "metrics",
            "agenda", "welcome", "everyone", "today", "product",
        ]
        return (0..<count).map { index in
            // Vary row heights so realized sizes differ from lazy estimates.
            let length = [1, 12, 40, 70][index % 4]
            let text = (0..<length).map { words[$0 % words.count] }.joined(separator: " ") + "."
            return TranscriptSegment(
                startMs: index * 3_500,
                text: text,
                speakerId: speakers[index % speakers.count]
            )
        }
    }

    private func cards(for segments: [TranscriptSegment]) -> [IdentifiedSpeakerTurn] {
        let turns = TranscriptSegmenter.groupIntoSpeakerTurns(
            segments: segments,
            speakerLabelProvider: { $0.map { "Speaker \($0)" } ?? "Unknown" }
        )
        return identifiedSpeakerTurnCards(turns)
    }

    private func timestampLabel(ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Mirrors `TranscriptResultView.transcriptPane`: the lazy/non-lazy choice
    /// comes from the same decision the product uses.
    private func host(
        hasSpeakers: Bool,
        cards: [IdentifiedSpeakerTurn],
        segments: [TranscriptSegment]
    ) -> CountingHostingView<AnyView> {
        let rowCount = hasSpeakers ? cards.reduce(0) { $0 + $1.turn.segments.count } : segments.count
        let body = TranscriptTimestampedContentView(
            hasSpeakers: hasSpeakers,
            identifiedTurnCards: cards,
            segments: segments,
            speakerColorMap: ["S1": .blue, "S2": .green],
            speakerLabelForID: { "Speaker \($0)" },
            speakerLabelContent: { _, label, color, _, _ in
                Text(label).foregroundStyle(color)
            },
            isSegmentActive: { $0 == 1 },
            timestampLabel: { self.timestampLabel(ms: $0) },
            isTimestampSeekable: true,
            onTimestampTap: { _ in }
        )
        let content = ScrollViewReader { _ in
            ScrollView {
                Group {
                    if TranscriptBodyLayout.usesLazyStack(rowCount: rowCount, environment: [:]) {
                        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) { body }
                    } else {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) { body }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        let view = CountingHostingView(rootView: AnyView(content))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(subview) { return found }
        }
        return nil
    }

    private func scroll(_ scrollView: NSScrollView, toBottom: Bool) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let y: CGFloat = document.isFlipped ? (toBottom ? maxY : 0) : (toBottom ? 0 : maxY)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func assertLayoutSettles(
        _ view: CountingHostingView<AnyView>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ceiling = watchdogSeconds
        let watchdog = DispatchWorkItem {
            fatalError("Transcript layout did not settle within \(ceiling)s: main thread is livelocked")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdogSeconds, execute: watchdog)
        defer { watchdog.cancel() }

        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let start = Date()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let firstLayout = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            firstLayout, firstLayoutBudgetSeconds,
            "first layout took \(firstLayout)s", file: file, line: line
        )
        XCTAssertGreaterThan(view.fittingSize.height, 0, file: file, line: line)

        // The freeze reproduced after scrolling down and back up.
        guard let scrollView = findScrollView(view) else {
            XCTFail("no NSScrollView behind the SwiftUI ScrollView", file: file, line: line)
            return
        }
        for _ in 0..<3 {
            for toBottom in [true, false] {
                scroll(scrollView, toBottom: toBottom)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
        }

        let settledCount = view.layoutCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThanOrEqual(
            view.layoutCount - settledCount, 2,
            "layout kept re-running while idle (\(view.layoutCount - settledCount) extra passes)",
            file: file, line: line
        )
    }

    func testSpeakerCardsSettleAfterScrolling() {
        // Two speakers plus a few unlabeled segments, like a short diarized clip.
        let segments = segments(count: 40, speakers: ["S1", "S1", "S2", nil])
        let view = host(hasSpeakers: true, cards: cards(for: segments), segments: [])

        assertLayoutSettles(view)
    }

    func testFlatRowsSettleAfterScrolling() {
        let segments = segments(count: 40, speakers: [nil])
        let view = host(hasSpeakers: false, cards: [], segments: segments)

        assertLayoutSettles(view)
    }

    /// The largest transcript still rendered without a lazy stack: every row
    /// and its selection overlay is materialized on open, so this guards the
    /// cost at the limit, not just the tiny common case.
    func testLimitSizedTranscriptRendersNonLazilyAndSettles() {
        let segments = segments(count: TranscriptBodyLayout.nonLazyRowLimit, speakers: ["S1", "S2"])
        let cards = cards(for: segments)
        XCTAssertFalse(
            TranscriptBodyLayout.usesLazyStack(
                rowCount: cards.reduce(0) { $0 + $1.turn.segments.count },
                environment: [:]
            )
        )
        let view = host(hasSpeakers: true, cards: cards, segments: [])

        assertLayoutSettles(view)
    }

    /// Issue #845 scale: one speaker for ~964 segments becomes 41 bounded
    /// cards in the lazy branch; the lazy stack must only realize what fits.
    func testReporterScaleSingleSpeakerUsesLazyBranchAndSettles() {
        let segments = segments(count: 964, speakers: ["S1"])
        let cards = cards(for: segments)
        XCTAssertTrue(
            TranscriptBodyLayout.usesLazyStack(
                rowCount: cards.reduce(0) { $0 + $1.turn.segments.count },
                environment: [:]
            )
        )
        let view = host(hasSpeakers: true, cards: cards, segments: [])

        assertLayoutSettles(view)
    }
}
