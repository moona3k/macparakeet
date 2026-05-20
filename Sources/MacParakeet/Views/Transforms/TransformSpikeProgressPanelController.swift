import AppKit
import MacParakeetCore
import SwiftUI

/// Non-activating panel that hosts the Transform progress UI. The type names
/// still carry the original spike label, but this is the productized hotkey
/// progress surface.
///
/// NSPanel notes:
/// - `canBecomeKey` is `false` so triggering the hotkey doesn't yank focus
///   from the user's frontmost app (which is the whole point — we paste back
///   into their text field).
/// - `.nonactivatingPanel | .borderless` matches the dictation + meeting
///   recording pill chrome elsewhere in the app.
private final class TransformsSpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum TransformProgressPanelLayout {
    static let bottomOffset: CGFloat = 12
    /// Stable transparent host width. The visible capsule animates inside
    /// this frame so routine state changes do not fight AppKit window
    /// resizing. Error copy can still expand inside this host.
    static let panelWidth: CGFloat = 360
    static let baselineHeight: CGFloat = 64
    static let labelMaxWidth: CGFloat = 280
}

@MainActor
@Observable
final class TransformSpikeProgressViewModel {
    var phase: Phase = .working

    enum Phase: Equatable {
        case working
        case done
        case failed(message: String)
    }
}

@MainActor
final class TransformSpikeProgressPanelController {
    private var panel: NSPanel?
    private var host: NSHostingView<TransformSpikeProgressView>?
    private var viewModel: TransformSpikeProgressViewModel?
    private var autoDismissTask: Task<Void, Never>?

    /// Open (or reuse) the panel showing the in-progress indicator. Idempotent
    /// — calling `show` while a panel is visible just resets state.
    func show() {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        if let viewModel {
            viewModel.phase = .working
            resetPanelToBaseline(animated: false)
            return
        }

        let vm = TransformSpikeProgressViewModel()
        self.viewModel = vm

        let host = NSHostingView(rootView: TransformSpikeProgressView(viewModel: vm))
        let initialSize = NSSize(
            width: TransformProgressPanelLayout.panelWidth,
            height: TransformProgressPanelLayout.baselineHeight
        )
        host.frame = NSRect(origin: .zero, size: initialSize)
        self.host = host

        let panel = TransformsSpikePanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI renders its own shadow via cardShadow.
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0

        positionPanel(panel, size: initialSize, animated: false)

        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Swap the loader for a "Done" affordance, auto-dismiss after 1.2s.
    func done(message _: String = "Done") {
        guard let viewModel else { return }
        viewModel.phase = .done
        scheduleAutoDismiss(after: .milliseconds(1200))
    }

    /// Swap the loader for an error affordance, auto-dismiss after 4s.
    func fail(message: String) {
        if viewModel == nil {
            // Spike-grade: surface the error briefly even if show() never ran.
            show()
        }
        viewModel?.phase = .failed(message: message)
        scheduleRelayout()
        scheduleAutoDismiss(after: .milliseconds(4000))
    }

    /// Tear the panel down with a brief fade. Cancel-then-restart from the
    /// coordinator goes through `show()`, not `close()`, so this is reserved
    /// for terminal dismissal.
    func close() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let panelRef = panel else { return }
        panel = nil
        host = nil
        viewModel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            panelRef.orderOut(nil)
        })
    }

    private func resetPanelToBaseline(animated: Bool) {
        guard let panel else { return }
        positionPanel(
            panel,
            size: NSSize(
                width: TransformProgressPanelLayout.panelWidth,
                height: TransformProgressPanelLayout.baselineHeight
            ),
            animated: animated
        )
    }

    /// Yield once so SwiftUI processes the observed phase change, then
    /// re-measure the hosting view and animate the panel into the right
    /// frame. Resilient to copy length: longer error strings wrap inside the
    /// stable panel width and the panel grows vertically to fit.
    private func scheduleRelayout() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.relayoutPanel()
        }
    }

    private func relayoutPanel() {
        guard let panel, let host else { return }
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let measured = host.fittingSize
        let height: CGFloat
        if measured.width > 0 && measured.height > 0 {
            height = max(measured.height, TransformProgressPanelLayout.baselineHeight)
        } else {
            height = TransformProgressPanelLayout.baselineHeight
        }
        positionPanel(
            panel,
            size: NSSize(width: TransformProgressPanelLayout.panelWidth, height: height),
            animated: true
        )
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize, animated: Bool) {
        guard let screen = Self.screenForPanel() else {
            panel.setContentSize(size)
            return
        }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + TransformProgressPanelLayout.bottomOffset
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func scheduleAutoDismiss(after delay: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private static func screenForPanel() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - View

private struct TransformSpikeProgressView: View {
    var viewModel: TransformSpikeProgressViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Icon-only phases (.working, .done) get equal padding so the Capsule renders
        // as a perfect circle — matches the dictation overlay's success
        // state. Failure copy gets the wider oblong-pill padding.
        let label = currentLabel
        let isIconOnly = label == nil
        let horizontalPadding: CGFloat = isIconOnly ? 10 : 14
        let verticalPadding: CGFloat = isIconOnly ? 10 : 11
        let spacing: CGFloat = isIconOnly ? 0 : 11
        let contentAnimation: Animation? = reduceMotion
            ? nil
            : .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.04)
        let phaseAnimation: Animation? = reduceMotion
            ? nil
            : .easeInOut(duration: 0.24)

        return ZStack {
            HStack(spacing: spacing) {
                indicator
                    .frame(width: 22, height: 22)
                    .id(indicatorIdentity)
                    .transition(
                        .scale(scale: 0.65, anchor: .center)
                            .combined(with: .opacity)
                    )

                if let label {
                    labelText(label)
                        .id(labelIdentity)
                        .transition(
                            .opacity
                                .combined(with: .move(edge: .trailing))
                        )
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.meetingPillBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
            )
            .cardShadow(DesignSystem.Shadows.meetingPill)
            .padding(10)  // give the SwiftUI shadow room inside the NSPanel frame
            .animation(contentAnimation, value: label != nil)
            .animation(phaseAnimation, value: phaseIdentity)
        }
        .frame(width: TransformProgressPanelLayout.panelWidth, alignment: .center)
        .frame(minHeight: TransformProgressPanelLayout.baselineHeight, alignment: .center)
        .clipped()
    }

    @ViewBuilder
    private func labelText(_ label: String) -> some View {
        Text(label)
            .font(DesignSystem.Typography.meetingPillStatus)
            .foregroundStyle(DesignSystem.Colors.meetingPillText)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: TransformProgressPanelLayout.labelMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var indicator: some View {
        switch viewModel.phase {
        case .working:
            RhodoneaScribeLoader(
                tint: DesignSystem.Colors.accent,
                paused: reduceMotion,
                accessibilityLabel: "Transforming selected text"
            )
            .frame(width: 22, height: 22)
        case .done:
            CheckmarkView(tint: DesignSystem.Colors.successGreen)
        case .failed:
            FailingTriangleView(tint: DesignSystem.Colors.warningAmber)
        }
    }

    /// Working and done stay icon-only: the loader communicates in-flight
    /// work, and the green checkmark communicates completion.
    private var currentLabel: String? {
        switch viewModel.phase {
        case .working: return nil
        case .done: return nil
        case .failed(let message): return message
        }
    }

    private var indicatorIdentity: String {
        switch viewModel.phase {
        case .working: return "working"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private var labelIdentity: String {
        currentLabel ?? ""
    }

    private var phaseIdentity: Int {
        switch viewModel.phase {
        case .working: return 0
        case .done: return 1
        case .failed: return 2
        }
    }
}

// MARK: - Checkmark (Done state)

/// Apple-style success checkmark — same atom the dictation overlay uses for
/// completion (`DictationOverlayView.AnimatedCheckmarkView`). Ring strokes
/// around first, then the check strokes in. Re-implemented inline rather than
/// promoted to a shared component during the spike; a follow-up should
/// extract this into `Views/Components/` so dictation, meeting, and transforms
/// share one brand atom for "the thing happened."
private struct CheckmarkView: View {
    var tint: Color
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.20), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.25)) {
                checkTrim = 1
            }
        }
    }

    private struct CheckmarkShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
            return path
        }
    }
}

// MARK: - Failing Triangle (Fail state)

/// Triangle outline strokes in, then a centered bang fades up. Keeps the
/// affordance warm (amber, not red) — failures are recoverable, the user just
/// needs to retry or fix configuration.
private struct FailingTriangleView: View {
    var tint: Color
    @State private var triangleTrim: CGFloat = 0
    @State private var bangOpacity: Double = 0

    var body: some View {
        ZStack {
            TriangleShape()
                .trim(from: 0, to: triangleTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            Text("!")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .opacity(bangOpacity)
                .offset(y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) {
                triangleTrim = 1
            }
            withAnimation(.easeOut(duration: 0.20).delay(0.22)) {
                bangOpacity = 1
            }
        }
    }

    private struct TriangleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let inset: CGFloat = 1
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            path.closeSubpath()
            return path
        }
    }
}
