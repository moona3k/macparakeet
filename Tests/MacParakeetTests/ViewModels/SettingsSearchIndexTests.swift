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

    func testLivePreviewQueryFindsDictationPreviewSetting() {
        let results = SettingsSearchIndex.matches("live preview")

        XCTAssertTrue(
            results.contains(where: { $0.id == "dictation.live.preview" }),
            "Live preview should land on the dictation preview setting"
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
        XCTAssertTrue(results.contains(where: { $0.id == "system.storage" }))
    }

    func testTranscriptOnlyQueryFindsStorageRetention() {
        let results = SettingsSearchIndex.matches("transcript only")

        XCTAssertTrue(
            results.contains(where: { $0.id == "system.storage" }),
            "Transcript-only meeting audio retention should land on Storage"
        )
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
        // The AI Formatter card (header + fallback prompt) is always visible,
        // so the entry is indexed in both flag states; only the profile
        // keywords are flag-conditional.
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "ai.formatter" })
        XCTAssertEqual(entry.cardAnchor, "ai.formatter")
        XCTAssertEqual(
            entry.keywords.contains("app profiles"),
            AppFeatures.aiFormatterProfilesEnabled,
            "Profile keywords should track the feature flag"
        )
    }

    func testTranscriptAIContextQueriesFindTranscriptContextEntry() throws {
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "ai.transcriptContext" })
        XCTAssertEqual(entry.cardAnchor, "ai.transcriptContext")

        for query in ["rich transcript", "plain transcript", "speaker labels", "diarization", "meeting context"] {
            let ids = Set(SettingsSearchIndex.matches(query).map(\.id))
            XCTAssertTrue(ids.contains("ai.transcriptContext"), "Query \(query) should find Transcript Context for AI")
        }
    }

    func testMeetingTitleQueriesFindMeetingTitlesEntry() throws {
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "ai.meetingTitles" })
        XCTAssertEqual(entry.cardAnchor, "ai.meetingTitles")

        for query in ["meeting title", "auto-title", "automatic title", "recording title"] {
            let ids = Set(SettingsSearchIndex.matches(query).map(\.id))
            XCTAssertTrue(ids.contains("ai.meetingTitles"), "Query \(query) should find Meeting Titles")
        }
    }

    func testAIFormatterSmartDefaultsQueriesFindFormatterEntry() {
        // "formatter" must find the always-visible card in both flag states;
        // profile-specific queries only resolve when profiles are enabled.
        XCTAssertTrue(
            Set(SettingsSearchIndex.matches("formatter").map(\.id)).contains("ai.formatter"),
            "Query formatter should find the AI Formatter card"
        )

        for query in ["smart defaults", "app profiles"] {
            let ids = Set(SettingsSearchIndex.matches(query).map(\.id))

            if AppFeatures.aiFormatterProfilesEnabled {
                XCTAssertTrue(ids.contains("ai.formatter"), "Query \(query) should find AI Formatter")
            } else {
                XCTAssertFalse(ids.contains("ai.formatter"), "Query \(query) should not reveal hidden AI Formatter profiles")
            }
        }
    }

    func testCohereComputeQueriesFindCoherePerformanceEntry() throws {
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "engine.cohereModel" })
        // Anchored to the always-present selector because the Cohere
        // Performance card only renders while Cohere is the active engine.
        XCTAssertEqual(entry.cardAnchor, "engine.selector")

        for query in ["cohere", "gpu", "compute", "neural engine", "fastest", "balanced"] {
            let ids = Set(SettingsSearchIndex.matches(query).map(\.id))
            XCTAssertTrue(ids.contains("engine.cohereModel"), "Query \(query) should find Cohere Performance")
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
        let meetingGatedIds: Set<String> = [
            "meeting",
            "meeting.autoStop",
            "meeting.calendar",
            "system.permissions.screen"
        ]
        let calendarGatedIds: Set<String> = ["meeting.calendar"]
        let autoStopGatedIds: Set<String> = ["meeting.autoStop"]
        let presentIds = Set(SettingsSearchIndex.entries.map(\.id))
        let intersection = presentIds.intersection(meetingGatedIds)

        if AppFeatures.meetingRecordingEnabled {
            // Calendar entry drops out independently when calendarEnabled
            // is off, and auto-stop drops out independently while staged.
            let expected = AppFeatures.calendarEnabled
                ? meetingGatedIds
                : meetingGatedIds.subtracting(calendarGatedIds)
            let expectedWithAutoStop = AppFeatures.meetingAutoStopEnabled
                ? expected
                : expected.subtracting(autoStopGatedIds)
            XCTAssertEqual(
                intersection,
                expectedWithAutoStop,
                "Meeting-gated entries should match the active flag combination"
            )
        } else {
            XCTAssertTrue(
                intersection.isEmpty,
                "No meeting-gated entries should appear when the flag is off"
            )
        }
    }

    func testMeetingAutoStopQueriesHonorFeatureFlag() {
        for query in ["auto-stop", "auto stop", "meeting ended", "zoom closed"] {
            let ids = Set(SettingsSearchIndex.matches(query).map(\.id))

            if AppFeatures.meetingAutoStopEnabled {
                XCTAssertTrue(ids.contains("meeting.autoStop"), "Query \(query) should find meeting auto-stop")
            } else {
                XCTAssertFalse(ids.contains("meeting.autoStop"), "Query \(query) should not reveal hidden auto-stop")
            }
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
