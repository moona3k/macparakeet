import CoreGraphics
import Foundation

/// Pure mapping from the dictation overlay state to what the notch shows:
/// a glyph kind, a VoiceOver label and how far the shape grows beside the
/// camera. No AppKit/SwiftUI, so it is unit-tested directly.
struct NotchPresentation: Equatable {
    enum Glyph: Equatable {
        case idle
        case recording
        case countdown
        case processing
        case formatting
        case success
        case noSpeech
        case error
    }

    let glyph: Glyph
    let accessibilityLabel: String
    /// Growth beyond the notch on each side, in points (before the geometry cap).
    let sideExtension: CGFloat

    static let recordingSide: CGFloat = 100
    static let countdownSide: CGFloat = 100
    static let compactSide: CGFloat = 44

    @MainActor
    init(viewModel: DictationOverlayViewModel) {
        self.init(
            state: viewModel.state,
            sessionKind: viewModel.sessionKind,
            elapsedSeconds: viewModel.recordingElapsedSeconds,
            cancelSecondsRemaining: viewModel.cancelTimeRemaining
        )
    }

    init(
        state: DictationOverlayViewModel.OverlayState,
        sessionKind: DictationOverlayViewModel.SessionKind,
        elapsedSeconds: Int,
        cancelSecondsRemaining: Double
    ) {
        let isCommand = sessionKind == .command
        switch state {
        case .ready:
            self.init(glyph: .idle, label: "Dictation ready", side: 0)
        case .recording:
            let minutes = elapsedSeconds / 60
            let seconds = elapsedSeconds % 60
            let time = String(format: "%d:%02d", minutes, seconds)
            self.init(
                glyph: .recording,
                label: "\(isCommand ? "Recording command" : "Recording"), \(time)",
                side: Self.recordingSide)
        case .cancelled:
            let remaining = max(0, Int(cancelSecondsRemaining.rounded(.up)))
            self.init(
                glyph: .countdown,
                label: "Recording cancelled. Undo available for \(remaining) \(remaining == 1 ? "second" : "seconds")",
                side: Self.countdownSide)
        case .processing:
            self.init(
                glyph: .processing, label: isCommand ? "Processing command" : "Transcribing",
                side: Self.compactSide)
        case .formatting:
            self.init(
                glyph: .formatting, label: isCommand ? "Applying command" : "Polishing transcript",
                side: Self.compactSide)
        case .success:
            self.init(glyph: .success, label: "Done", side: Self.compactSide)
        case .noSpeech:
            self.init(glyph: .noSpeech, label: "No speech detected", side: Self.compactSide)
        case .error:
            self.init(glyph: .error, label: "Dictation error", side: Self.compactSide)
        }
    }

    private init(glyph: Glyph, label: String, side: CGFloat) {
        self.glyph = glyph
        self.accessibilityLabel = label
        self.sideExtension = side
    }

    /// Total shape width for a notch of `notchWidth`; `.idle` stays at the notch width.
    func shapeWidth(notchWidth: CGFloat) -> CGFloat { notchWidth + 2 * sideExtension }
}
