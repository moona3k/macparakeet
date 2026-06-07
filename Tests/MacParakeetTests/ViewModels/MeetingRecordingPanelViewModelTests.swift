import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingPanelViewModelTests: XCTestCase {
    func testInitialStateIsHidden() {
        let viewModel = MeetingRecordingPanelViewModel()

        XCTAssertEqual(viewModel.state, .hidden)
        XCTAssertEqual(viewModel.elapsedSeconds, 0)
        XCTAssertTrue(viewModel.previewLines.isEmpty)
        XCTAssertFalse(viewModel.canStop)
    }

    func testFormattedElapsedUsesMinutesAndSeconds() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.elapsedSeconds = 125

        XCTAssertEqual(viewModel.formattedElapsed, "2:05")
    }

    func testRecordingStateAllowsStopAndUpdatesSegments() {
        let viewModel = MeetingRecordingPanelViewModel()
        let lines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the meeting panel",
                source: .microphone
            )
        ]

        viewModel.state = .recording
        viewModel.micLevel = 0.6
        viewModel.systemLevel = 0.3
        viewModel.updatePreviewLines(lines)

        XCTAssertTrue(viewModel.canStop)
        XCTAssertTrue(viewModel.showsAudioLevels)
        XCTAssertEqual(viewModel.previewLines, lines)
        XCTAssertEqual(viewModel.statusTitle, "Recording")
        XCTAssertFalse(viewModel.showsLaggingIndicator)
    }

    func testWordCountUpdatesWhenExistingSegmentGrows() {
        let viewModel = MeetingRecordingPanelViewModel()
        let initialLines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the panel",
                source: .microphone
            )
        ]
        let updatedLines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the panel with more words",
                source: .microphone
            ),
            MeetingRecordingPreviewLine(
                id: "2",
                timestamp: "0:07",
                speakerLabel: "Them",
                text: "Reply",
                source: .system
            )
        ]

        viewModel.updatePreviewLines(initialLines)
        XCTAssertEqual(viewModel.wordCount, 3)

        viewModel.updatePreviewLines(updatedLines)

        XCTAssertEqual(viewModel.wordCount, 7)
    }

    func testChatTranscriptCanUseRichPreviewContext() {
        let viewModel = MeetingRecordingPanelViewModel(
            transcriptAIContextModeProvider: { .richTranscript }
        )
        viewModel.updatePreviewLines([
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the meeting panel",
                source: .microphone
            ),
            MeetingRecordingPreviewLine(
                id: "2",
                timestamp: "0:08",
                speakerLabel: "Others",
                text: "Reply from the call",
                source: .system
            )
        ])

        XCTAssertEqual(
            viewModel.chatTranscript,
            """
            [0:05] Me: Testing the meeting panel
            [0:08] Others: Reply from the call
            """
        )
    }

    func testChatTranscriptCanUsePlainPreviewContext() {
        let viewModel = MeetingRecordingPanelViewModel(
            transcriptAIContextModeProvider: { .plainTranscript }
        )
        viewModel.updatePreviewLines([
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the meeting panel",
                source: .microphone
            ),
            MeetingRecordingPreviewLine(
                id: "2",
                timestamp: "0:08",
                speakerLabel: "Others",
                text: "Reply from the call",
                source: .system
            )
        ])

        XCTAssertEqual(
            viewModel.chatTranscript,
            """
            Testing the meeting panel
            Reply from the call
            """
        )
    }

    func testTranscribingAndErrorStatesUpdateStatusSurface() {
        let viewModel = MeetingRecordingPanelViewModel()

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.canStop)
        XCTAssertEqual(viewModel.statusTitle, "Transcribing")
        XCTAssertTrue(viewModel.showsElapsedTime)

        viewModel.state = .error("Boom")
        XCTAssertEqual(viewModel.statusTitle, "Meeting interrupted", "Phase 4 copy refinement: 'Recording Error' → 'Meeting interrupted'")
        XCTAssertTrue(viewModel.statusMessage.hasPrefix("Boom"), "Detail leads")
        XCTAssertTrue(viewModel.statusMessage.contains("Library"), "Wrapper points the user at the Library for recovery")
        XCTAssertEqual(
            viewModel.compactErrorRecoveryMessage,
            "Meeting interrupted. Open Library to retry transcription or export captured audio."
        )
        XCTAssertFalse(viewModel.showsElapsedTime)
    }

    func testErrorStateWithEmptyMessageHasReadableFallback() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .error("")

        XCTAssertTrue(
            viewModel.statusMessage.hasPrefix("An unexpected error occurred."),
            "Empty error string falls back to a readable sentence rather than a leading newline"
        )
        XCTAssertTrue(viewModel.statusMessage.contains("Library"))
    }

    func testErrorStateTrimsWhitespaceFromTechnicalDetail() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .error("   Network timeout   ")

        XCTAssertTrue(viewModel.statusMessage.hasPrefix("Network timeout"))
    }

    func testLaggingRecordingStateUpdatesStatusSurface() {
        let viewModel = MeetingRecordingPanelViewModel()

        viewModel.state = .recording
        viewModel.updatePreviewLines([], isTranscriptionLagging: true)

        XCTAssertTrue(viewModel.showsLaggingIndicator)
        XCTAssertTrue(viewModel.statusMessage.contains("catching up"))
        XCTAssertEqual(viewModel.transcriptEmptyStateTitle, "Catching up...")
        XCTAssertEqual(
            viewModel.transcriptEmptyStateDetail,
            "Final transcript will still include the full meeting."
        )

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.showsLaggingIndicator)
    }

    func testLiveTranscriptStatusDrivesEmptyTranscriptCopy() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording

        viewModel.updateLiveTranscriptStatus(.startingAudio)
        XCTAssertEqual(viewModel.transcriptEmptyStateTitle, "Starting audio...")
        XCTAssertNil(viewModel.transcriptEmptyStateDetail)

        viewModel.updateLiveTranscriptStatus(.preparingSpeechModel(message: "Speech model: Loading model into memory..."))
        XCTAssertEqual(viewModel.transcriptEmptyStateTitle, "Preparing speech model...")
        XCTAssertEqual(viewModel.transcriptEmptyStateDetail, "Loading model into memory...")

        viewModel.updateLiveTranscriptStatus(.previewUnavailable)
        XCTAssertEqual(viewModel.transcriptEmptyStateTitle, "Live preview unavailable")
        XCTAssertEqual(
            viewModel.transcriptEmptyStateDetail,
            "Audio keeps recording; retry transcription from Library if needed."
        )

        viewModel.updateLiveTranscriptStatus(.listening)
        XCTAssertEqual(viewModel.transcriptEmptyStateTitle, "Listening...")
        XCTAssertNil(viewModel.transcriptEmptyStateDetail)
    }

    func testTranscriptContentLocksOutAdvisoryEmptyStatus() {
        let viewModel = MeetingRecordingPanelViewModel()
        let lines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Words arrived",
                source: .microphone
            )
        ]

        viewModel.updatePreviewLines(lines)
        viewModel.updateLiveTranscriptStatus(.preparingSpeechModel(message: "Loading"))

        XCTAssertEqual(viewModel.liveTranscriptStatus, .live)
        XCTAssertEqual(viewModel.previewLines, lines)
    }

    func testResetClearsTranscriptPreview() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        viewModel.elapsedSeconds = 42
        viewModel.isMicrophoneMuted = true
        viewModel.canToggleMicrophoneMute = true
        viewModel.updatePreviewLines(
            [
                MeetingRecordingPreviewLine(
                    id: "1",
                    timestamp: "0:42",
                    speakerLabel: "Them",
                    text: "Reset should clear this",
                    source: .system
                )
            ],
            isTranscriptionLagging: true
        )
        viewModel.selectedTab = .ask

        viewModel.reset()

        XCTAssertEqual(viewModel.state, .hidden)
        XCTAssertEqual(viewModel.elapsedSeconds, 0)
        XCTAssertEqual(viewModel.micLevel, 0)
        XCTAssertEqual(viewModel.systemLevel, 0)
        XCTAssertFalse(viewModel.isMicrophoneMuted)
        XCTAssertFalse(viewModel.canToggleMicrophoneMute)
        XCTAssertTrue(viewModel.previewLines.isEmpty)
        XCTAssertFalse(viewModel.isTranscriptionLagging)
        XCTAssertEqual(viewModel.liveTranscriptStatus, .listening)
        XCTAssertEqual(viewModel.selectedTab, .notes, "reset() returns the panel to the default Notes tab (ADR-020 §2)")
    }

    func testSelectedTabDefaultsToNotes() {
        let viewModel = MeetingRecordingPanelViewModel()

        XCTAssertEqual(
            viewModel.selectedTab, .notes,
            "Notes is the primary 'active' surface and the default landing tab (ADR-020 §1, §2)"
        )
    }

    func testLivePanelTabAllCasesOrderedNotesTranscriptAsk() {
        XCTAssertEqual(
            MeetingRecordingPanelViewModel.LivePanelTab.allCases,
            [.notes, .transcript, .ask],
            "Tab order is Notes / Transcript / Ask — left-to-right matches ⌘1 / ⌘2 / ⌘3"
        )
    }

    func testNotesViewModelExistsAndIsObservable() {
        let viewModel = MeetingRecordingPanelViewModel()

        // Sanity: the composed notes VM is non-nil and starts empty.
        XCTAssertEqual(viewModel.notesViewModel.notesText, "")
        XCTAssertEqual(viewModel.notesViewModel.wordCount, 0)
    }

    func testResetClearsComposedNotesViewModel() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.notesViewModel.notesBinding.wrappedValue = "Some notes"

        viewModel.reset()

        XCTAssertEqual(viewModel.notesViewModel.notesText, "")
    }

    func testNotesAndTranscriptTabsHaveNoBadgeInAnyState() {
        let viewModel = MeetingRecordingPanelViewModel()

        // ADR-020 §1 amendments (2026-05-02): all three tabs render as plain nouns.
        // Notes was decoration (the writing surface itself shows the words; the
        // soft-cap footer covers the only actionable word-count moment).
        // Transcript was the 6th instance of recording state already broadcast
        // by the panel header (orb / "Recording" / elapsed timer / transcript
        // word count / Stop).
        let states: [MeetingRecordingPanelViewModel.PanelState] = [
            .hidden, .recording, .transcribing, .error("test")
        ]
        for state in states {
            viewModel.state = state

            XCTAssertNil(
                viewModel.badge(for: .notes),
                "Notes tab should be plain in state \(state) — the pane itself surfaces the words"
            )
            XCTAssertNil(
                viewModel.badge(for: .transcript),
                "Transcript tab should be plain in state \(state) — header carries the recording signal"
            )
        }

        // Drive notes content > 0 to confirm the badge stays nil even when
        // word count is non-zero (defends against accidentally re-introducing
        // a notesBadge property that fires on user input).
        viewModel.notesViewModel.notesBinding.wrappedValue = "hello world"
        XCTAssertNil(
            viewModel.badge(for: .notes),
            "Notes tab stays plain even with content — word count is not surfaced on the tab strip"
        )
    }

    func testAskTabHasNoStringBadgeAndExposesStreamingFlagInstead() {
        let viewModel = MeetingRecordingPanelViewModel()

        XCTAssertNil(
            viewModel.badge(for: .ask),
            "Ask tab no longer carries a numeric badge — message count is decoration, not information"
        )
        XCTAssertFalse(viewModel.isAskStreaming, "Default Ask state is idle (no breathing dot)")

        viewModel.chatViewModel.isStreaming = true
        XCTAssertTrue(
            viewModel.isAskStreaming,
            "isAskStreaming mirrors chatViewModel.isStreaming so the tab dot animates while an answer is forming"
        )

        viewModel.chatViewModel.isStreaming = false
        XCTAssertFalse(
            viewModel.isAskStreaming,
            "Strictly bound to streaming — the dot vanishes the instant streaming ends so it can't decay into a stale notification badge"
        )
    }

    // MARK: - Pause / resume (issue #235)

    func testStatusTitleReflectsPausedState() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        XCTAssertEqual(viewModel.statusTitle, "Recording")

        viewModel.isPaused = true
        XCTAssertEqual(viewModel.statusTitle, "Paused")

        viewModel.isPaused = false
        XCTAssertEqual(viewModel.statusTitle, "Recording")
    }

    func testCanTogglePauseTracksRecordingPanelState() {
        let viewModel = MeetingRecordingPanelViewModel()
        XCTAssertFalse(viewModel.canTogglePause, "No toggle from .hidden")

        viewModel.state = .recording
        XCTAssertTrue(viewModel.canTogglePause)

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.canTogglePause)

        viewModel.state = .error("boom")
        XCTAssertFalse(viewModel.canTogglePause)
    }

    func testShowsAudioLevelsHidesWhilePaused() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        XCTAssertTrue(viewModel.showsAudioLevels)

        viewModel.isPaused = true
        XCTAssertFalse(
            viewModel.showsAudioLevels,
            "While paused, levels are zeroed by the service — orb would render flat. Fall back to status dot instead."
        )
    }

    func testResetClearsPausedFlag() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        viewModel.isPaused = true

        viewModel.reset()

        XCTAssertFalse(viewModel.isPaused)
    }
}
