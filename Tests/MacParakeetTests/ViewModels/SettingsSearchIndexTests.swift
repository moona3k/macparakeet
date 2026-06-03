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

    func testClipboardFallbackQueryFindsDictationClipboardSetting() {
        let results = SettingsSearchIndex.matches("remote")

        XCTAssertTrue(
            results.contains(where: { $0.id == "dictation.keep.clipboard" }),
            "Remote clipboard workflows should find the dictation clipboard retention setting"
        )
    }

    func testDarkModeQueryFindsAppearanceSetting() {
        let results = SettingsSearchIndex.matches("dark mode")

        XCTAssertTrue(
            results.contains(where: { $0.id == "system.appearance" }),
            "Dark mode should land on the Appearance card"
        )
    }

    func testTitleMatches() {
        let results = SettingsSearchIndex.matches("Speech Recognition")
        XCTAssertTrue(results.contains(where: { $0.id == "engine.selector" }))
    }

    func testSubtitleMatches() {
        let results = SettingsSearchIndex.matches("meeting audio")
        XCTAssertTrue(results.contains(where: { $0.id == "meeting" }))
    }

    func testCalendarQueriesHonorCalendarFeatureFlag() {
        for query in ["calendar", "auto-start", "auto start", "reminders"] {
            let results = SettingsSearchIndex.matches(query)
            let ids = Set(results.map(\.id))

            if AppFeatures.calendarEnabled {
                XCTAssertTrue(ids.contains("meeting.calendar"), "Query \(query) should find the calendar row")
            } else {
                XCTAssertFalse(ids.contains("meeting"), "Query \(query) should not reveal the hidden meeting card")
                XCTAssertFalse(ids.contains("meeting.calendar"), "Query \(query) should not reveal the hidden calendar row")
            }
        }
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

    func testAIFormatterSearchEntryUsesFormatterAnchor() throws {
        let entry = SettingsSearchIndex.entries.first { $0.id == "ai.formatter" }
        if AppFeatures.aiFormatterProfilesEnabled {
            XCTAssertEqual(try XCTUnwrap(entry).cardAnchor, "ai.formatter")
        } else {
            XCTAssertNil(entry)
        }
    }

    func testEveryTabHasAtLeastOneEntry() {
        let tabs = Set(SettingsSearchIndex.entries.map(\.tab))
        XCTAssertEqual(tabs, Set(SettingsTab.allCases), "Every tab should be reachable via search")
    }

    func testMeetingEntriesGatedOnFeatureFlag() {
        // The flags are compile-time constants, so only one arm runs in
        // any given build. Asserting both directions documents the
        // contract and forces a deliberate update if the gate semantics
        // change. Ids: card + sub-card + cross-tab permission row.
        let meetingGatedIds: Set<String> = ["meeting", "meeting.calendar", "system.permissions.screen"]
        let calendarGatedIds: Set<String> = ["meeting.calendar"]
        let presentIds = Set(SettingsSearchIndex.entries.map(\.id))
        let intersection = presentIds.intersection(meetingGatedIds)

        if AppFeatures.meetingRecordingEnabled {
            // Calendar entry drops out independently when calendarEnabled
            // is off, even though meeting recording is on.
            let expected = AppFeatures.calendarEnabled
                ? meetingGatedIds
                : meetingGatedIds.subtracting(calendarGatedIds)
            XCTAssertEqual(
                intersection,
                expected,
                "Meeting-gated entries should match the active flag combination"
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
