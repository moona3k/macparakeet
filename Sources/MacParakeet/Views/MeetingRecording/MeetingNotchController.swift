import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Surface contract the meeting coordinator drives. The classic floating pill and
/// the notch wing both conform, so the coordinator never branches on placement.
@MainActor
protocol MeetingPillControlling: AnyObject {
    var onClick: (() -> Void)? { get set }
    var onStopRecording: (() -> Void)? { get set }
    var onOpenApp: (() -> Void)? { get set }
    var onCancelRecording: (() -> Void)? { get set }
    var onPauseToggle: (() -> Void)? { get set }
    var isVisible: Bool { get }
    func show()
    func hide(preserveFrameForNextShow: Bool)
    func updateLiveAudioLevel(_ level: Float)
    func refreshState()
}

extension MeetingPillControlling {
    func hide() { hide(preserveFrameForNextShow: false) }
}

extension MeetingRecordingPillController: MeetingPillControlling {}

/// Shared "who is using the notch right now" flag. Dictation owns both sides of
/// the notch while it is up; the meeting wing yields to it. Observation-driven,
/// no timers.
@MainActor @Observable
final class NotchOccupancy {
    static let shared = NotchOccupancy()
    /// The dictation surface currently using the notch. A token (not a Bool) so an
    /// older session finishing its collapse can't hand the notch back while a newer one is up.
    private(set) var dictationOwner: ObjectIdentifier?
    var dictationActive: Bool { dictationOwner != nil }

    func claim(by owner: AnyObject) { dictationOwner = ObjectIdentifier(owner) }
    func release(by owner: AnyObject) {
        if dictationOwner == ObjectIdentifier(owner) { dictationOwner = nil }
    }
}

/// Meeting recording as a black wing on the LEFT of the camera notch: status
/// glyph + elapsed time (+ source-health warning). Dictation grows both sides
/// of the notch on top of it, so the wing hides while dictation is active.
/// Only built when the notch placement resolves to a real notch.
@MainActor
final class MeetingNotchController: MeetingPillControlling {
    var onClick: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    /// Called when a display change leaves no usable notch, so the coordinator can swap in the classic pill.
    var onNotchUnavailable: (() -> Void)?
    var isVisible: Bool { panel != nil }

    private let viewModel: MeetingRecordingPillViewModel
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    /// Wing content width left of the notch, and how far the panel tucks under it.
    private static let wingWidth: CGFloat = 78
    private static let tuck: CGFloat = 16

    /// Failable: only where the notch placement resolves to a real notch.
    init?(viewModel: MeetingRecordingPillViewModel) {
        guard case .notchPanel = NotchScreens.resolve(placement: .notch) else { return nil }
        self.viewModel = viewModel
    }

    /// True when a meeting should use the notch wing (setting + hardware).
    static func isAvailable() -> Bool { NotchScreens.notchIsActive() }

    private func frame(for geometry: NotchGeometry) -> NSRect {
        let width = min(Self.wingWidth, geometry.sideExtensionLimit)
        let notch = geometry.notchRect
        return NSRect(
            x: notch.minX - width, y: notch.minY, width: width + Self.tuck, height: notch.height)
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }
        guard case .notchPanel(_, let geometry) = NotchScreens.resolve(placement: .notch) else { return }
        let frame = frame(for: geometry)
        let panel = NotchPanel(
            contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NotchOverlayController.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = MeetingNotchWingView(
            viewModel: viewModel, occupancy: NotchOccupancy.shared, tuck: Self.tuck,
            onTap: { [weak self] in self?.onClick?() },
            onPause: { [weak self] in self?.onPauseToggle?() },
            onStop: { [weak self] in self?.onStopRecording?() },
            onOpen: { [weak self] in self?.onOpenApp?() },
            onCancel: { [weak self] in self?.onCancelRecording?() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.orderFront(nil)
        self.panel = panel
        // Event-driven: resolution or display changes only. No timers.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    private func screenParametersChanged() {
        guard panel != nil else { return }
        if case .notchPanel = NotchScreens.resolve(placement: .notch) {
            reposition()
        } else {
            hide()
            onNotchUnavailable?()
        }
    }

    func hide(preserveFrameForNextShow: Bool = false) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    func updateLiveAudioLevel(_ level: Float) {}  // The wing shows no level meter; keeps CPU at zero.
    func refreshState() {}  // The view observes the view model directly.

    func reposition() {
        guard let panel, case .notchPanel(_, let geometry) = NotchScreens.resolve(placement: .notch) else { return }
        panel.setFrame(frame(for: geometry), display: true)
    }
}

// MARK: - View

private struct MeetingNotchWingView: View {
    let viewModel: MeetingRecordingPillViewModel
    let occupancy: NotchOccupancy
    let tuck: CGFloat
    let onTap: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            UnevenRoundedRectangle(bottomLeadingRadius: 12)
                .fill(Color.black)
            MeetingNotchWingContent(viewModel: viewModel)
                .padding(.leading, 12)
                .padding(.trailing, tuck)
        }
        .opacity(occupancy.dictationActive ? 0 : 1)
        .allowsHitTesting(!occupancy.dictationActive)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            switch viewModel.state {
            case .recording, .paused:
                if viewModel.canTogglePause { Button(viewModel.isPaused ? "Resume" : "Pause", action: onPause) }
                Button("Stop recording", action: onStop)
                Button("Open MacParakeet", action: onOpen)
                Button("Discard recording…", role: .destructive, action: onCancel)
            default:
                Button("Open MacParakeet", action: onOpen)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Own view so the 1 Hz elapsed tick invalidates only the wing content.
private struct MeetingNotchWingContent: View {
    let viewModel: MeetingRecordingPillViewModel

    static func accessibilityLabel(for vm: MeetingRecordingPillViewModel) -> String {
        let base: String
        switch vm.state {
        case .idle: base = "Meeting recorder"
        case .starting: base = "Meeting starting"
        case .recording: base = "Recording meeting, \(vm.formattedElapsed)"
        case .paused: base = "Meeting paused, \(vm.formattedElapsed)"
        case .completing: base = "Saving meeting"
        case .transcribing: base = "Transcribing meeting"
        case .completed: base = "Meeting saved"
        case .error: base = "Meeting recording error"
        }
        if let warning = vm.mirroredVisibleSourceHealthWarning { return "\(base). \(warning.label)" }
        return base
    }

    var body: some View {
        HStack(spacing: 6) {
            glyph
            if showsTime {
                Text(viewModel.formattedElapsed)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(viewModel.isPaused ? 0.6 : 0.9))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: viewModel))
    }

    private var showsTime: Bool {
        switch viewModel.state {
        case .recording, .paused: return true
        default: return false
        }
    }

    @ViewBuilder private var glyph: some View {
        if let warning = viewModel.mirroredVisibleSourceHealthWarning {
            Image(systemName: warning.symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.orange)
        } else {
            switch viewModel.state {
            case .recording: Circle().fill(Color.red).frame(width: 7, height: 7)
            case .paused: Image(systemName: "pause.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            case .starting, .completing, .transcribing: ProgressView().controlSize(.small).colorScheme(.dark)
            case .completed: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.green)
            case .error: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.orange)
            case .idle: EmptyView()
            }
        }
    }
}
