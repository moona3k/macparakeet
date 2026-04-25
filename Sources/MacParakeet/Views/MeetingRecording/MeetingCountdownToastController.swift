import AppKit
import MacParakeetViewModels
import SwiftUI

/// Reasons a countdown toast can disappear, fed back to the coordinator so
/// it knows whether the action ran or the user opted out.
enum MeetingCountdownToastOutcome: Sendable {
    /// Countdown reached the end without user input — fire the default
    /// action (start recording / stop recording).
    case completed
    /// User clicked the secondary "Start Now" button (auto-start only) —
    /// fire the default action immediately.
    case primedEarly
    /// User clicked the primary "Cancel" / "Keep Recording" button.
    case userDismissed
    /// Coordinator called `close()` programmatically (e.g., another event
    /// took precedence). No action should run.
    case programmaticClose
}

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating toast panel + the 60Hz progress timer that drives the
/// view model. Single concurrent toast — calling `show*` while one is
/// already visible closes the previous one with `.programmaticClose` so
/// stacked countdowns don't compete for screen real estate.
@MainActor
final class MeetingCountdownToastController {
    private var panel: NSPanel?
    private var viewModel: MeetingCountdownToastViewModel?
    private var startTime: Date?
    private var timer: Timer?
    private var onOutcome: ((MeetingCountdownToastOutcome) -> Void)?

    /// Show a pre-meeting auto-start countdown. Default duration 5s.
    func showAutoStart(
        title: String,
        body: String,
        duration: TimeInterval = 5,
        onOutcome: @escaping (MeetingCountdownToastOutcome) -> Void
    ) {
        present(
            viewModel: MeetingCountdownToastViewModel(
                style: .autoStart,
                title: title,
                body: body,
                duration: duration
            ),
            onOutcome: onOutcome
        )
    }

    /// Show an end-of-meeting auto-stop countdown. Default duration 30s
    /// gives the user time to extend a meeting that ran over.
    func showAutoStop(
        title: String,
        body: String,
        duration: TimeInterval = 30,
        onOutcome: @escaping (MeetingCountdownToastOutcome) -> Void
    ) {
        present(
            viewModel: MeetingCountdownToastViewModel(
                style: .autoStop,
                title: title,
                body: body,
                duration: duration
            ),
            onOutcome: onOutcome
        )
    }

    /// Force-close any visible toast without firing the default action.
    /// Coordinator uses this when a higher-priority event preempts the
    /// current countdown (e.g., user manually starts recording while the
    /// auto-start countdown is mid-flight).
    func close() {
        finish(.programmaticClose)
    }

    // MARK: - Presentation

    private func present(
        viewModel: MeetingCountdownToastViewModel,
        onOutcome: @escaping (MeetingCountdownToastOutcome) -> Void
    ) {
        // Replace any existing toast — coordinator only ever shows one at
        // a time. The previous outcome callback fires `.programmaticClose`
        // so its caller can clean up.
        if panel != nil {
            finish(.programmaticClose)
        }

        self.viewModel = viewModel
        self.onOutcome = onOutcome
        self.startTime = Date()

        let view = MeetingCountdownToastView(
            viewModel: viewModel,
            onPrimary: { [weak self] in self?.finish(.userDismissed) },
            onSecondary: viewModel.secondaryActionLabel == nil
                ? nil
                : { [weak self] in self?.finish(.primedEarly) }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 130)

        let panel = CountdownPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI renders its own shadow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            // Top-center of the visible frame; sits below the menu bar but
            // above any active app window — makes the countdown impossible
            // to miss without being aggressive.
            let panelSize = hosting.fittingSize.width > 0
                ? hosting.fittingSize
                : NSSize(width: 280, height: 130)
            let frame = screen.visibleFrame
            let x = frame.midX - panelSize.width / 2
            let y = frame.maxY - panelSize.height - 32
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
        }

        panel.orderFrontRegardless()
        self.panel = panel

        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        // 60Hz refresh keeps the progress bar smooth without burning CPU —
        // a 5s auto-start ticks 300 times total. Add to .common so the
        // timer keeps firing during menu/scroll tracking.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let viewModel, let startTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(1, elapsed / viewModel.duration)
        viewModel.progress = progress
        if progress >= 1 {
            finish(.completed)
        }
    }

    private func finish(_ outcome: MeetingCountdownToastOutcome) {
        let callback = onOutcome
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        startTime = nil
        onOutcome = nil
        callback?(outcome)
    }
}
