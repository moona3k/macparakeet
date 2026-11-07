import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class NotchPresentationTests: XCTestCase {
    private typealias State = DictationOverlayViewModel.OverlayState
    private typealias Kind = DictationOverlayViewModel.SessionKind

    private func make(
        _ state: State,
        kind: Kind = .dictation,
        elapsed: Int = 0,
        remaining: Double = 0
    ) -> NotchPresentation {
        NotchPresentation(
            state: state,
            sessionKind: kind,
            elapsedSeconds: elapsed,
            cancelSecondsRemaining: remaining
        )
    }

    // MARK: - Glyph and accessibility label per state

    func testReadyMapsToIdleGlyphAndLabel() {
        let p = make(.ready)
        XCTAssertEqual(p.glyph, .idle)
        XCTAssertEqual(p.accessibilityLabel, "Dictation ready")
    }

    func testRecordingLabelShowsMinutesAndSeconds() {
        let p = make(.recording, elapsed: 75)
        XCTAssertEqual(p.glyph, .recording)
        XCTAssertEqual(p.accessibilityLabel, "Recording, 1:15")
    }

    func testRecordingLabelPadsSecondsToTwoDigits() {
        let p = make(.recording, elapsed: 5)
        XCTAssertEqual(p.glyph, .recording)
        XCTAssertEqual(p.accessibilityLabel, "Recording, 0:05")
    }

    func testCommandRecordingLabelUsesCommandWording() {
        let p = make(.recording, kind: .command, elapsed: 5)
        XCTAssertEqual(p.glyph, .recording)
        XCTAssertEqual(p.accessibilityLabel, "Recording command, 0:05")
    }

    func testCancelledRoundsFractionalSecondsUpToPlural() {
        let p = make(.cancelled(timeRemaining: 3.2), remaining: 3.2)
        XCTAssertEqual(p.glyph, .countdown)
        XCTAssertEqual(p.accessibilityLabel, "Recording cancelled. Undo available for 4 seconds")
    }

    func testCancelledWithOneSecondUsesSingularWording() {
        let p = make(.cancelled(timeRemaining: 1.0), remaining: 1.0)
        XCTAssertEqual(p.glyph, .countdown)
        XCTAssertEqual(p.accessibilityLabel, "Recording cancelled. Undo available for 1 second")
    }

    func testProcessingLabels() {
        let dictation = make(.processing)
        XCTAssertEqual(dictation.glyph, .processing)
        XCTAssertEqual(dictation.accessibilityLabel, "Transcribing")

        let command = make(.processing, kind: .command)
        XCTAssertEqual(command.glyph, .processing)
        XCTAssertEqual(command.accessibilityLabel, "Processing command")
    }

    func testFormattingLabels() {
        let dictation = make(.formatting)
        XCTAssertEqual(dictation.glyph, .formatting)
        XCTAssertEqual(dictation.accessibilityLabel, "Polishing transcript")

        let command = make(.formatting, kind: .command)
        XCTAssertEqual(command.glyph, .formatting)
        XCTAssertEqual(command.accessibilityLabel, "Applying command")
    }

    func testSuccessMapsToDone() {
        let p = make(.success)
        XCTAssertEqual(p.glyph, .success)
        XCTAssertEqual(p.accessibilityLabel, "Done")
    }

    func testNoSpeechMapsToNoSpeechDetected() {
        let p = make(.noSpeech)
        XCTAssertEqual(p.glyph, .noSpeech)
        XCTAssertEqual(p.accessibilityLabel, "No speech detected")
    }

    func testErrorMapsToDictationError() {
        let p = make(.error("x"))
        XCTAssertEqual(p.glyph, .error)
        XCTAssertEqual(p.accessibilityLabel, "Dictation error")
    }

    // MARK: - Side extension

    func testSideExtensionPerState() {
        XCTAssertEqual(make(.ready).sideExtension, 0)
        XCTAssertEqual(make(.recording).sideExtension, 100)
        XCTAssertEqual(make(.cancelled(timeRemaining: 3)).sideExtension, 100)
        XCTAssertEqual(make(.processing).sideExtension, 44)
        XCTAssertEqual(make(.formatting).sideExtension, 44)
        XCTAssertEqual(make(.success).sideExtension, 44)
        XCTAssertEqual(make(.noSpeech).sideExtension, 44)
        XCTAssertEqual(make(.error("x")).sideExtension, 44)
    }

    func testShapeWidthAddsBothSideExtensions() {
        let notchWidth: CGFloat = 184
        let states: [State] = [
            .ready,
            .recording,
            .cancelled(timeRemaining: 3),
            .processing,
            .formatting,
            .success,
            .noSpeech,
            .error("x"),
        ]
        for state in states {
            let p = make(state)
            XCTAssertEqual(
                p.shapeWidth(notchWidth: notchWidth),
                notchWidth + 2 * p.sideExtension,
                "shapeWidth for \(state)"
            )
        }
    }

    func testIdleShapeWidthStaysAtNotchWidth() {
        XCTAssertEqual(make(.ready).shapeWidth(notchWidth: 184), 184)
    }

    // MARK: - Exhaustiveness

    func testEveryStateHasItsOwnDistinctGlyph() {
        let glyphs: [NotchPresentation.Glyph] = [
            make(.ready).glyph,
            make(.recording).glyph,
            make(.cancelled(timeRemaining: 3)).glyph,
            make(.processing).glyph,
            make(.formatting).glyph,
            make(.success).glyph,
            make(.noSpeech).glyph,
            make(.error("x")).glyph,
        ]
        // Glyph is Equatable only (not Hashable), so compare pairwise.
        XCTAssertEqual(glyphs.count, 8)
        for i in glyphs.indices {
            for j in glyphs.indices where j > i {
                XCTAssertNotEqual(glyphs[i], glyphs[j], "states \(i) and \(j) share a glyph")
            }
        }
    }
}
