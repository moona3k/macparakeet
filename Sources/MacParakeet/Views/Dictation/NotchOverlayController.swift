import AppKit
import MacParakeetCore
import SwiftUI

// MARK: - Screen adapter

/// Builds the pure `OverlayDisplay` values from `NSScreen` (Apple APIs only:
/// `safeAreaInsets`, `auxiliaryTopLeftArea/RightArea`, `CGDisplayIsBuiltin`).
@MainActor
enum NotchScreens {
    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Auxiliary rects are documented in screen coordinates; if a build hands
    /// back display-local values, shift them into the global space.
    private static func global(_ rect: CGRect?, in frame: CGRect) -> CGRect? {
        guard let rect else { return nil }
        if frame.origin != .zero, !frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.midX, y: rect.midY)) {
            return rect.offsetBy(dx: frame.minX, dy: frame.minY)
        }
        return rect
    }

    static func display(for screen: NSScreen) -> OverlayDisplay? {
        guard let id = displayID(of: screen) else { return nil }
        let frame = screen.frame
        let cutout = DisplayCutout.classify(
            frame: frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: global(screen.auxiliaryTopLeftArea, in: frame),
            auxiliaryTopRight: global(screen.auxiliaryTopRightArea, in: frame),
            isBuiltIn: CGDisplayIsBuiltin(id) != 0
        )
        return OverlayDisplay(id: id, cutout: cutout)
    }

    /// The menu-bar display is `NSScreen.screens.first` (not `NSScreen.main`).
    static func resolve(placement: DictationOverlayPlacement) -> OverlaySurface {
        let screens = NSScreen.screens
        return OverlaySurfaceResolver.resolve(
            placement: placement,
            displays: screens.compactMap(display(for:)),
            menuBarDisplayID: screens.first.flatMap(displayID(of:))
        )
    }

    static func screen(withID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// True when the current setting resolves to the notch panel (the idle pill hides then).
    static func notchIsActive() -> Bool {
        let placement = DictationOverlayPlacement.current()
        guard placement == .notch else { return false }
        if case .notchPanel = resolve(placement: placement) { return true }
        return false
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// AppKit must not push the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class NotchTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Layout model

/// What the SwiftUI shape needs from the controller. Frame changes are driven
/// by state changes only, never per audio frame.
@MainActor
@Observable
final class NotchLayoutModel {
    var notchSize: CGSize
    /// Current shape width target (bar only, excludes the sheet).
    var barWidth: CGFloat
    var sheet: NotchSheet = .none
    var expanded = false
    init(notchSize: CGSize) {
        self.notchSize = notchSize
        self.barWidth = notchSize.width
    }
}

enum NotchSheet: Equatable {
    case none
    case controls
    case message(String)

    var height: CGFloat {
        switch self {
        case .none: return 0
        case .controls: return 40
        case .message: return 44
        }
    }
}

// MARK: - Controller

/// Black panel merged with the camera notch. Same session lifecycle as
/// `DictationOverlayController`; the coordinator creates one per session.
@MainActor
final class NotchOverlayController: DictationOverlayControlling {
    private let viewModel: DictationOverlayViewModel
    private var geometry: NotchGeometry
    private let displayID: UInt32
    private let layout: NotchLayoutModel
    private var panel: NSPanel?
    private var shrinkTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var isObserving = false

    /// Above the menu bar so the black shape covers the notch strip.
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    init?(viewModel: DictationOverlayViewModel) {
        guard case .notchPanel(let id, let geometry) = NotchScreens.resolve(placement: .notch) else { return nil }
        self.viewModel = viewModel
        self.geometry = geometry
        self.displayID = id
        self.layout = NotchLayoutModel(notchSize: geometry.notchRect.size)
    }

    func show() {
        if panel != nil { return }
        viewModel.anchorsToTop = true
        syncLayout()

        let frame = targetFrame()
        let panel = NotchPanel(
            contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(NotchPresentation(viewModel: viewModel).accessibilityLabel)

        let hosting = NSHostingView(rootView: NotchOverlayView(viewModel: viewModel, layout: layout))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let tracker = NotchTrackingView(frame: hosting.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in self?.viewModel.isHovered = true }
        tracker.onExit = { [weak self] in self?.viewModel.isHovered = false }
        hosting.addSubview(tracker)

        panel.setFrame(frame, display: false)
        panel.orderFront(nil)
        self.panel = panel
        NotchOccupancy.shared.dictationActive = true
        observe()
        // Expand on the next runloop turn so the width change animates from the notch.
        DispatchQueue.main.async { [layout] in layout.expanded = true }
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        NotchOccupancy.shared.dictationActive = false
        shrinkTask?.cancel()
        // Collapse back into the notch, then remove the window.
        layout.expanded = false
        layout.sheet = .none
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 60 : 220))
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    func reposition() {
        guard panel != nil else { return }
        guard case .notchPanel(let id, let geometry) = NotchScreens.resolve(placement: .notch), id == displayID else {
            // The notched screen is gone or no longer carries the menu bar.
            // Stay where we are; the next session re-resolves (and falls back).
            return
        }
        self.geometry = geometry
        layout.notchSize = geometry.notchRect.size
        applyFrame()
    }

    func resignKeyWindow() { panel?.resignKey() }

    // MARK: Layout

    private func desiredSheet() -> NotchSheet {
        switch viewModel.state {
        case .error(let message):
            return .message(Self.shortMessage(message))
        case .recording where viewModel.recordingMode == .persistent && viewModel.isHovered:
            return .controls
        default:
            return .none
        }
    }

    private static func shortMessage(_ message: String) -> String {
        message.count > 80 ? String(message.prefix(77)) + "..." : message
    }

    private func syncLayout() {
        let presentation = NotchPresentation(viewModel: viewModel)
        layout.barWidth = geometry.clampedWidth(presentation.shapeWidth(notchWidth: geometry.notchRect.width))
        layout.sheet = desiredSheet()
    }

    private func targetFrame() -> NSRect {
        geometry.panelFrame(
            expandedWidth: layout.barWidth,
            height: geometry.notchRect.height + layout.sheet.height)
    }

    /// Grow immediately; shrink after the shape's own animation has finished so
    /// the window never clips it.
    private func applyFrame() {
        guard let panel else { return }
        syncLayout()
        let target = targetFrame()
        if target.width >= panel.frame.width {
            shrinkTask?.cancel()
            panel.setFrame(target, display: true)
        } else {
            panel.setFrame(
                NSRect(x: target.minX - (panel.frame.width - target.width) / 2, y: target.minY,
                    width: panel.frame.width, height: target.height),
                display: true)
            shrinkTask?.cancel()
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                panel.setFrame(self.targetFrame(), display: true)
            }
        }
        panel.setAccessibilityLabel(NotchPresentation(viewModel: viewModel).accessibilityLabel)
    }

    /// Re-run layout when the state, hover, timer-label or error changes. The
    /// observation is one-shot and re-armed, so an idle notch holds no timers.
    private func observe() {
        guard panel != nil, !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = viewModel.pillStateKey
            _ = viewModel.isHovered
            _ = viewModel.recordingMode
            _ = viewModel.recordingElapsedSeconds / 60  // minute rollover only changes the label
            if case .error(let m) = viewModel.state { _ = m }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObserving = false
                self.applyFrame()
                self.observe()
            }
        }
    }
}

// MARK: - View

private struct NotchOverlayView: View {
    let viewModel: DictationOverlayViewModel
    let layout: NotchLayoutModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: NotchPresentation { NotchPresentation(viewModel: viewModel) }

    var body: some View {
        let width = layout.expanded ? layout.barWidth : layout.notchSize.width
        VStack(spacing: 0) {
            bar(width: width)
            sheet(width: width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: width)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85),
            value: layout.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func bar(width: CGFloat) -> some View {
        ZStack {
            // Square bottom corners while a sheet hangs below, so the two read as one shape.
            let radius: CGFloat = layout.sheet == .none ? 12 : 0
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(Color.black)
            HStack(spacing: 0) {
                leading
                    .frame(maxWidth: .infinity, alignment: .center)
                Color.clear.frame(width: layout.notchSize.width)
                trailing
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .opacity(layout.expanded ? 1 : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.18), value: layout.expanded)
        }
        .frame(width: width, height: layout.notchSize.height)
    }

    // MARK: Zones

    @ViewBuilder private var leading: some View {
        switch presentation.glyph {
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                NotchWaveform(viewModel: viewModel)
                    .frame(width: 44)
            }
        case .countdown:
            countdownRing
        case .processing, .formatting:
            ProgressView().controlSize(.small).colorScheme(.dark)
        case .success:
            glyph("checkmark.circle.fill", .green)
        case .noSpeech:
            glyph("mic.slash.fill", .white.opacity(0.7))
        case .error:
            glyph("exclamationmark.triangle.fill", .orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch presentation.glyph {
        case .recording:
            NotchElapsedLabel(viewModel: viewModel)
        case .countdown:
            Button(action: { viewModel.onUndo?() }) {
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo cancel")
        default:
            EmptyView()
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
    }

    private var countdownRing: some View {
        let duration = viewModel.cancelCountdownDuration > 0 ? viewModel.cancelCountdownDuration : 1
        return ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: CGFloat(viewModel.cancelTimeRemaining / duration))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: viewModel.cancelTimeRemaining)
            Text("\(Int(ceil(viewModel.cancelTimeRemaining)))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .onTapGesture { viewModel.onCancel?() }
        .accessibilityLabel("Discard now")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Sheet

    @ViewBuilder private func sheet(width: CGFloat) -> some View {
        switch layout.sheet {
        case .none:
            EmptyView()
        case .controls:
            HStack(spacing: 10) {
                sheetButton("Cancel", hint: "Esc", systemImage: "xmark") { viewModel.onCancel?() }
                sheetButton("Stop", hint: nil, systemImage: "stop.fill") { viewModel.onStop?() }
            }
            .frame(width: width, height: layout.sheet.height)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        case .message(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .frame(width: width, height: layout.sheet.height)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
                .transition(.opacity)
        }
    }

    private func sheetButton(_ title: String, hint: String?, systemImage: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint.map { "Shortcut \($0)" } ?? "")
    }
}


/// Own views so the 20+ Hz audio level (and the 1 Hz timer) invalidate only
/// themselves, not the whole notch body.
private struct NotchWaveform: View {
    let viewModel: DictationOverlayViewModel
    var body: some View {
        WaveformView(audioLevel: viewModel.audioLevel, barCount: 10)
            .scaleEffect(0.8)
    }
}

private struct NotchElapsedLabel: View {
    let viewModel: DictationOverlayViewModel
    var body: some View {
        Text(viewModel.formattedElapsed)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
    }
}
