import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// A source label that repeats the active filter is noise. These pin the rule
/// that decides when it is drawn, and — more importantly — pin it to the same
/// `(scope, filter)` pairs the library query itself switches on, so the two
/// cannot drift apart silently.
final class LibrarySourceLabelStyleTests: XCTestCase {

    // MARK: - Mixed contexts keep the label

    func testMixedContextsShowTheFullLabel() {
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .all),
            .visible,
            "All admits every source, so the label is the only source attribution"
        )
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .favorites),
            .visible,
            "Favorites spans sources, so a starred meeting and a starred podcast must stay distinguishable"
        )
    }

    // MARK: - Single-source filters drop it

    func testFiltersPinnedToOneSourceHideTheLabel() {
        for filter in [LibraryFilter.podcast, .local, .meeting] {
            XCTAssertEqual(
                TranscriptionLibraryScope.all.sourceLabelStyle(for: filter),
                .hidden,
                "\(filter.rawValue) admits exactly one source, so the label can only restate the filter"
            )
        }
    }

    func testMeetingsWorkspaceHidesTheLabelUnderEveryFilter() {
        for filter in LibraryFilter.allCases {
            XCTAssertEqual(
                TranscriptionLibraryScope.meetings.sourceLabelStyle(for: filter),
                .hidden,
                "The Meetings workspace shows only meetings, so even Favorites is fully determined there"
            )
        }
    }

    // MARK: - The multi-platform filter keeps its label

    /// Video looks like the obvious place to drop the word, and it is not.
    /// Its platforms share one `play.rectangle.fill` glyph separated only by
    /// tint, so the text is the only thing naming the platform.
    func testVideoFilterUsesBrandMarks() {
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .youtube),
            .brandMarkOnly,
            "Video has narrowed the family, so a platform named by its own logo need not repeat the word"
        )
    }

    // MARK: - Drift guard

    /// The style is only correct because it mirrors how `makeQuery(offset:)`
    /// narrows each pair. Assert the mapping itself, so adding a filter or
    /// re-pointing an existing one fails here rather than silently hiding a
    /// label over a query that still admits several sources.
    func testMappingMatchesEveryQueryNarrowing() {
        let expected: [(TranscriptionLibraryScope, LibraryFilter, LibrarySourceLabelStyle)] = [
            (.all, .all, .visible),
            (.all, .favorites, .visible),
            (.all, .youtube, .brandMarkOnly),
            (.all, .podcast, .hidden),
            (.all, .local, .hidden),
            (.all, .meeting, .hidden),
            (.meetings, .all, .hidden),
            (.meetings, .favorites, .hidden),
            (.meetings, .youtube, .hidden),
            (.meetings, .podcast, .hidden),
            (.meetings, .local, .hidden),
            (.meetings, .meeting, .hidden),
        ]

        for (scope, filter, style) in expected {
            XCTAssertEqual(
                scope.sourceLabelStyle(for: filter),
                style,
                "(\(scope), \(filter.rawValue)) must stay in step with makeQuery's narrowing"
            )
        }
        XCTAssertEqual(
            expected.count,
            2 * LibraryFilter.allCases.count,
            "Every scope and filter pair needs a decided source-label style"
        )
    }
}
