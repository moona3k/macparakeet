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

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.showsLaggingIndicator)
    }

    func testResetClearsTranscriptPreview() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        viewModel.elapsedSeconds = 42
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
        XCTAssertTrue(viewModel.previewLines.isEmpty)
        XCTAssertFalse(viewModel.isTranscriptionLagging)
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
}
