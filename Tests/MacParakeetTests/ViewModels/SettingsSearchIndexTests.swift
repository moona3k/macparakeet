import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class SettingsSearchIndexTests: XCTestCase {
    func testEmptyQueryReturnsNoResults() {
        XCTAssertTrue(SettingsSearchIndex.matches("").isEmpty)
    }

    func testWhitespaceOnlyQueryReturnsNoResults() {
        XCTAssertTrue(SettingsSearchIndex.matches("   ").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.matches("\t\n").isEmpty)
    }

    func testQueryIsCaseInsensitive() {
        let lower = SettingsSearchIndex.matches("microphone")
        let upper = SettingsSearchIndex.matches("MICROPHONE")
        let mixed = SettingsSearchIndex.matches("MicroPhone")
        XCTAssertEqual(lower.map(\.id), upper.map(\.id))
        XCTAssertEqual(lower.map(\.id), mixed.map(\.id))
        XCTAssertFalse(lower.isEmpty, "'microphone' should match at least the Audio Input or Permissions entries")
    }

    func testQueryIsTrimmedBeforeMatching() {
        let trimmed = SettingsSearchIndex.matches("hotkey")
        let untrimmed = SettingsSearchIndex.matches("  hotkey  ")
        XCTAssertEqual(trimmed.map(\.id), untrimmed.map(\.id))
    }

    func testKeywordSynonymsMatch() {
        // "mic" is a keyword on Audio Input but not in any title/subtitle.
        let results = SettingsSearchIndex.matches("mic")
        XCTAssertTrue(
            results.contains(where: { $0.id == "audio.input" }),
            "Audio Input should match 'mic' via its keyword list"
        )
    }

    func testTitleMatches() {
        let results = SettingsSearchIndex.matches("Speech Recognition")
        XCTAssertTrue(results.contains(where: { $0.id == "engine.selector" }))
    }

    func testSubtitleMatches() {
        // "calendar auto-start" appears in the meeting card subtitle.
        let results = SettingsSearchIndex.matches("auto-start")
        XCTAssertTrue(results.contains(where: { $0.id == "meeting" }))
    }

    func testRowEntryHasBreadcrumbSubtitle() {
        let results = SettingsSearchIndex.matches("screen recording")
        let rowEntry = results.first { $0.id == "system.permissions.screen" }
        XCTAssertNotNil(rowEntry)
        XCTAssertEqual(rowEntry?.subtitle, "in Permissions")
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(SettingsSearchIndex.matches("xyzzyqqq").isEmpty)
    }

    func testEntryIdsAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate entry ids would break ScrollViewReader navigation")
    }

    func testEveryEntryHasNonEmptyTitle() {
        for entry in SettingsSearchIndex.entries {
            XCTAssertFalse(entry.title.isEmpty, "Entry \(entry.id) has empty title")
        }
    }

    func testEveryEntryHasNonEmptyAnchor() {
        for entry in SettingsSearchIndex.entries {
            XCTAssertFalse(entry.cardAnchor.isEmpty, "Entry \(entry.id) has empty cardAnchor")
        }
    }

    func testEveryTabHasAtLeastOneEntry() {
        let tabs = Set(SettingsSearchIndex.entries.map(\.tab))
        XCTAssertEqual(tabs, Set(SettingsTab.allCases), "Every tab should be reachable via search")
    }

    func testMeetingEntriesGatedOnFeatureFlag() {
        // The flag is a compile-time constant, so only one arm runs in
        // any given build. Asserting both directions documents the
        // contract and forces a deliberate update if the gate semantics
        // change. Ids: card + sub-card + cross-tab permission row.
        let meetingGatedIds: Set<String> = ["meeting", "meeting.calendar", "system.permissions.screen"]
        let presentIds = Set(SettingsSearchIndex.entries.map(\.id))
        let intersection = presentIds.intersection(meetingGatedIds)

        if AppFeatures.meetingRecordingEnabled {
            XCTAssertEqual(
                intersection,
                meetingGatedIds,
                "All meeting-gated entries should be present when the flag is on"
            )
        } else {
            XCTAssertTrue(
                intersection.isEmpty,
                "No meeting-gated entries should appear when the flag is off"
            )
        }
    }

    func testResultsArePreservedInIndexOrder() {
        // Results come from `entries.filter`, so two entries that both match
        // a broad query must appear in the same order they appear in the
        // index. Stability matters because the UI doesn't re-sort.
        let results = SettingsSearchIndex.matches("whisper")
        let indexOrder = SettingsSearchIndex.entries.map(\.id)
        let resultsInIndexOrder = results.map(\.id).map { id in indexOrder.firstIndex(of: id)! }
        XCTAssertEqual(resultsInIndexOrder, resultsInIndexOrder.sorted())
    }
}
