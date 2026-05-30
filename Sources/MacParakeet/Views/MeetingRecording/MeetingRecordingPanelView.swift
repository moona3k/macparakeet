import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingRecordingPanelView: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel
    @State private var autoScroll = true
    /// Tab currently under the cursor — drives the hover-revealed `⌘N` chip
    /// next to the tab label. Discoverability for the keyboard shortcuts
    /// without permanent chrome on the tab bar.
    @State private var hoveredTab: MeetingRecordingPanelViewModel.LivePanelTab? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            paneContent
            // Stop lives in the header so it's reachable from every tab. Notes
            // and Ask own their own bottom UI (Notes shows a soft-cap footer
            // when relevant; Ask owns its composer + follow-up pills); only
            // Transcript needs the Copy + auto-scroll footer.
            if viewModel.selectedTab == .transcript {
                Divider()
                footer
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 520)
        .background(DesignSystem.Colors.surface)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch viewModel.selectedTab {
        case .notes:
            LiveNotesPaneView(
                viewModel: viewModel.notesViewModel,
                elapsedSeconds: viewModel.elapsedSeconds,
                isPaused: viewModel.isPaused
            )
        case .transcript:
            transcriptContent
        case .ask:
            LiveAskPaneView(
                viewModel: viewModel.chatViewModel,
                quickPromptsViewModel: viewModel.quickPromptsViewModel
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MeetingRecordingPanelViewModel.LivePanelTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 4)
    }

    private func tabButton(_ tab: MeetingRecordingPanelViewModel.LivePanelTab) -> some View {
        let isActive = viewModel.selectedTab == tab
        let shortcutNumber: Int = {
            switch tab {
            case .notes: return 1
            case .transcript: return 2
            case .ask: return 3
            }
        }()
        let shortcut = KeyEquivalent(Character("\(shortcutNumber)"))
        let shortcutDisplay = "⌘\(shortcutNumber)"
        let badge = viewModel.badge(for: tab)
        let isStreaming = (tab == .ask) && viewModel.isAskStreaming
        let shortcutHint = (hoveredTab == tab) ? shortcutDisplay : nil
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                tabLabel(
                    title: tab.title,
                    badge: badge,
                    isStreaming: isStreaming,
                    shortcutHint: shortcutHint,
                    isActive: isActive
                )
                Capsule()
                    .fill(isActive ? DesignSystem.Colors.accent : Color.clear)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        // Race-safe hover tracking. When the cursor moves between tabs both
        // the leaving tab's `false` and the entering tab's `true` fire — the
        // `hoveredTab == tab` guard prevents the leaver from wiping the
        // entrant's claim if they arrive in either order.
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.20)) {
                if hovering {
                    hoveredTab = tab
                } else if hoveredTab == tab {
                    hoveredTab = nil
                }
            }
        }
        .help(tabTooltip(title: tab.title, badge: badge, isStreaming: isStreaming, shortcut: shortcutDisplay))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isStreaming ? "Responding" : "Switches to the \(tab.title) tab")
    }

    private func tabTooltip(title: String, badge: String?, isStreaming: Bool, shortcut: String) -> String {
        let base: String = {
            if isStreaming { return "\(title) · Responding…" }
            if let badge { return "\(title) · \(badge)" }
            return title
        }()
        return "\(base) (\(shortcut))"
    }

    /// State-bearing tab label per ADR-020 §1. `ViewThatFits` picks the
    /// richest variant the cell width allows: rich (noun [⌘N] · badge, or
    /// noun [⌘N] dot for streaming) at default panel widths, plain noun at
    /// the 360px floor. The `·` separator is dropped before the streaming
    /// dot — a symbol doesn't need text-style punctuation in front of it.
    /// Tooltip carries the full label so the state never disappears
    /// entirely — see `.help(...)` on the parent button.
    ///
    /// `isStreaming` takes precedence over `badge` because LLM-in-flight is
    /// the most actionable state — and today only the Ask tab uses it.
    /// `shortcutHint` is non-nil only while the tab is hovered; the chip
    /// fades in next to the noun, before the state separator, so it groups
    /// with the tab identity rather than with the live state.
    @ViewBuilder
    private func tabLabel(
        title: String,
        badge: String?,
        isStreaming: Bool,
        shortcutHint: String?,
        isActive: Bool
    ) -> some View {
        let weight: Font.Weight = isActive ? .medium : .regular
        let foreground: Color = isActive
            ? DesignSystem.Colors.textPrimary
            : DesignSystem.Colors.textTertiary
        let hasTrailing = isStreaming || badge != nil

        if hasTrailing || shortcutHint != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: weight))
                        .foregroundStyle(foreground)

                    if let shortcutHint {
                        Text(shortcutHint)
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.7))
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    if hasTrailing {
                        // The `·` separator only earns its keep before text-based
                        // state (`Notes · 24w`, `Transcript · LIVE`). Before the
                        // streaming dot it's redundant punctuation around what's
                        // already a visual symbol — `Ask ●` reads cleaner.
                        if isStreaming {
                            AskStreamingDot(isActive: isActive)
                        } else if let badge {
                            Text("·")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.6))
                            Text(badge)
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundStyle(isActive
                                    ? DesignSystem.Colors.accent
                                    : DesignSystem.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .fixedSize()

                Text(title)
                    .font(.system(size: 12, weight: weight))
                    .foregroundStyle(foreground)
            }
        } else {
            Text(title)
                .font(.system(size: 12, weight: weight))
                .foregroundStyle(foreground)
        }
    }

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                if viewModel.showsAudioLevels {
                    LiveAudioOrb(viewModel: viewModel)
                } else {
                    statusDot
                }

                Text(viewModel.statusTitle)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if viewModel.showsElapsedTime {
                    Text(viewModel.formattedElapsed)
                        .font(DesignSystem.Typography.timestamp.monospacedDigit())
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }

                Spacer(minLength: 0)

                if viewModel.wordCount > 0 {
                    Text("\(viewModel.wordCount) words")
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.8))
                }

                if viewModel.canToggleMicrophoneMute {
                    MeetingMicrophoneMuteButton(isMuted: viewModel.isMicrophoneMuted) {
                        viewModel.onMicrophoneMuteToggle?()
                    }
                }

                if viewModel.canTogglePause {
                    PauseResumeButton(isPaused: viewModel.isPaused) {
                        viewModel.onPauseToggle?()
                    }
                }

                if viewModel.canStop {
                    StopRecordingButton {
                        viewModel.onStop?()
                    }
                }
            }

            if viewModel.showsLaggingIndicator {
                Label("Transcript preview is catching up", systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        let hasContent = !viewModel.previewLines.isEmpty

        ZStack {
            // Flower of life — always present, fades to watermark when text appears
            VStack(spacing: DesignSystem.Spacing.md) {
                if viewModel.canStop {
                    BreathingSeedOfLifeView(freeze: viewModel.isPaused)
                        .opacity(hasContent ? 0.15 : 1.0)
                        .animation(.easeInOut(duration: 0.8), value: hasContent)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
                }

                if !hasContent {
                    VStack(spacing: 5) {
                        Text(viewModel.transcriptEmptyStateTitle)
                            .font(.system(size: 13, weight: .light, design: .default))
                            .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.65))

                        if let detail = viewModel.transcriptEmptyStateDetail {
                            Text(detail)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // Native NSTextView — full drag selection, performant
            if hasContent {
                TranscriptTextView(
                    lines: viewModel.previewLines,
                    autoScroll: autoScroll
                )
            }
        }
        .background(DesignSystem.Colors.background)
    }

    /// Only rendered when `selectedTab == .transcript` (parent body guards), so
    /// no inner conditional needed here. Stop now lives in the header so every
    /// tab can reach it; this footer is just Copy (left) and auto-scroll (right).
    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            FooterButton(
                label: viewModel.showCopiedConfirmation ? "Copied" : "Copy",
                icon: viewModel.showCopiedConfirmation ? "checkmark" : "doc.on.doc",
                activeColor: viewModel.showCopiedConfirmation
                    ? DesignSystem.Colors.successGreen
                    : nil,
                disabled: !viewModel.canCopy
            ) {
                copyTranscript()
            }

            Spacer()

            FooterIconButton(
                icon: autoScroll ? "chevron.down.circle.fill" : "chevron.down.circle",
                activeColor: autoScroll ? DesignSystem.Colors.accent : nil,
                tooltip: "Auto-scroll"
            ) {
                autoScroll.toggle()
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.transcriptText, forType: .string)
        Telemetry.send(.copyToClipboard(source: .meeting))
        viewModel.showCopiedFeedback()
    }

    @ViewBuilder
    private var statusDot: some View {
        switch viewModel.state {
        case .hidden, .recording:
            // Recording: vivid success green. Paused: shifts to warning
            // amber — the same color language used by the pause button on
            // hover, the pill's hover-badge pause glyph, and universal
            // "paused / hold" signals (broadcast indicators, traffic
            // lights). 0.85 opacity keeps it slightly quieter than the
            // recording dot — paused is a held-breath, not a shout.
            Circle()
                .fill(viewModel.isPaused
                    ? DesignSystem.Colors.warningAmber.opacity(0.85)
                    : DesignSystem.Colors.successGreen
                )
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isPaused)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
    }
}

/// Isolates the fast-changing `micLevel` / `systemLevel` reads into a leaf so
/// the live audio orb can breathe in near-real-time without re-evaluating the
/// whole panel `body` (header + tab bar + transcript `ForEach`). Same pattern
/// as `MeetingsLiveStatusChip`: the coordinator's ~30 fps glow loop writes these
/// levels, and with the read scoped here only this 20pt view re-renders — the
/// transcript list stays put. The orb's own `.easeOut(0.12)` smooths each step.
private struct LiveAudioOrb: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel

    var body: some View {
        DualAudioOrbView(
            micLevel: viewModel.micLevel,
            systemLevel: viewModel.systemLevel
        )
    }
}

/// Quiet breathing dot rendered next to "Ask" while the LLM is mid-response.
/// Strictly bound to streaming — vanishes the instant streaming ends so it
/// can't decay into a stale notification badge. Matches the brand-orange
/// emphasis of the Ask tab when active; falls back to tertiary text color
/// when the user is on a different tab so it reads as ambient, not loud.
private struct AskStreamingDot: View {
    let isActive: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(isActive ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
            .frame(width: 5, height: 5)
            .opacity(animate ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
            .accessibilityLabel("Ask is responding")
    }
}

/// A slowly rotating seed-of-life (1 center + 6 outer circles) for the empty
/// listening / loading states. Matches the flower head from the recording pill,
/// without the stem. Reused as the summary-generation loading indicator and as
/// the live-notes / transcript watermark behind meeting text.
///
/// **Core Animation backed — not SwiftUI.** This rosette is resident on screen
/// for the entire duration of a meeting recording. A SwiftUI
/// `TimelineView(.animation)` or `repeatForever` here re-evaluates `body` and
/// re-commits an `NSHostingView` display list on *every* display refresh, and
/// that per-frame, main-thread render churn was the dominant cost in the
/// v0.6.14 meeting-recording CPU regression — `sample` pointed straight at
/// `NSHostingView.layout` / `DisplayList.ViewUpdater` through this view.
/// `CABasicAnimation` on `CALayer`s is interpolated by the render server, so
/// the rotation and breathing pulse cost ~0 app-side CPU per frame. This mirrors
/// the floating pill's `MerkabaPillIconView`. See
/// `plans/active/2026-05-meeting-recording-cpu-debug.md`.
///
/// `freeze`: when `true`, the animations halt at their current frame via the
/// canonical Core Animation pause (`layer.speed = 0` + `timeOffset`) and resume
/// seamlessly from the same frame — the clean, externally-cancellable pause the
/// old `TimelineView(paused:)` was reaching for. `reduceMotion` renders a still
/// rosette (same shape and color, no rotation or pulse).
struct BreathingSeedOfLifeView: NSViewRepresentable {
    var freeze: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BreathingSeedOfLifeNSView {
        let view = BreathingSeedOfLifeNSView()
        view.update(animating: !reduceMotion, frozen: freeze)
        return view
    }

    func updateNSView(_ nsView: BreathingSeedOfLifeNSView, context: Context) {
        nsView.update(animating: !reduceMotion, frozen: freeze)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: BreathingSeedOfLifeNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: BreathingSeedOfLifeNSView.designSize, height: BreathingSeedOfLifeNSView.designSize)
    }
}

/// CALayer-backed seed-of-life. Centers a 140pt rosette in its bounds so it
/// renders correctly both at intrinsic size (summary skeleton) and stretched to
/// fill (`.frame(maxWidth: .infinity, maxHeight: .infinity)` watermarks).
final class BreathingSeedOfLifeNSView: NSView {
    static let designSize: CGFloat = 140

    private let circleRadius: CGFloat = 28
    private let rotationPeriod: TimeInterval = 18
    /// Each half of the breathing pulse (up, then down) takes this long. Matches
    /// the original `easeInOut(duration: 3).repeatForever(autoreverses: true)`.
    private let breathingHalfPeriod: TimeInterval = 3

    // Rest / trough values, taken from the original SwiftUI `breathFactor == 0`
    // frame so the still rosette (reduce-motion, or settled after stop) looks
    // identical to an animated one paused at the start of its cycle.
    private let restGlowOpacity: Float = 0.2
    private let restGlowScale: CGFloat = 0.9
    private let restShadowOpacity: Float = 0.15
    private let peakGlowOpacity: Float = 0.5
    private let peakGlowScale: CGFloat = 1.2
    private let peakShadowOpacity: Float = 0.4

    private let glowLayer = CAShapeLayer()
    private let flowerLayer = CALayer()
    private var ringLayers: [CAShapeLayer] = []

    private var didBuild = false
    private var isAnimating = false
    private var isFrozen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.designSize, height: Self.designSize)
    }

    override func layout() {
        super.layout()
        buildIfNeeded()
        layoutLayers()
    }

    func update(animating: Bool, frozen: Bool) {
        buildIfNeeded()

        if animating != isAnimating {
            isAnimating = animating
            if animating {
                startAnimations()
            } else {
                stopAnimations()
            }
        }

        isFrozen = frozen
        // Freezing is only meaningful while animations are attached.
        setPaused(animating && frozen, flowerLayer)
        setPaused(animating && frozen, glowLayer)
    }

    // MARK: - Layer construction

    private func buildIfNeeded() {
        guard !didBuild, let root = layer else { return }
        didBuild = true
        root.masksToBounds = false

        glowLayer.opacity = restGlowOpacity
        glowLayer.shadowRadius = 12
        glowLayer.shadowOffset = .zero
        glowLayer.shadowOpacity = restShadowOpacity
        glowLayer.transform = CATransform3DMakeScale(restGlowScale, restGlowScale, 1)
        root.addSublayer(glowLayer)

        root.addSublayer(flowerLayer)

        // Center ring (alpha 0.7) + 6 petals (alpha 0.5).
        for _ in 0..<7 {
            let ring = CAShapeLayer()
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 1.2
            flowerLayer.addSublayer(ring)
            ringLayers.append(ring)
        }

        applyColors()
    }

    /// Accent-tinted glow + rosette strokes. Resolved against the view's current
    /// appearance and re-applied from `viewDidChangeEffectiveAppearance`, since
    /// `CGColor` snapshots a dynamic `Color` at assignment time (a Light↔Dark
    /// switch while the rosette is on screen would otherwise leave it stale).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let accent = NSColor(DesignSystem.Colors.accent)
            glowLayer.fillColor = accent.cgColor
            glowLayer.shadowColor = accent.cgColor
            let ringAlphas: [CGFloat] = [0.7] + Array(repeating: 0.5, count: 6)
            for (ring, alpha) in zip(ringLayers, ringAlphas) {
                ring.strokeColor = accent.withAlphaComponent(alpha).cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard didBuild else { return }
        applyColors()
    }

    private func layoutLayers() {
        guard didBuild else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let diameter = circleRadius * 2
        let circleRect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let circlePath = CGPath(ellipseIn: circleRect, transform: nil)

        // Glow — centered; symmetric, so it never needs to rotate.
        glowLayer.bounds = circleRect
        glowLayer.position = center
        glowLayer.path = circlePath
        glowLayer.shadowPath = circlePath

        // Flower — centered; rotates about its own center (default anchor 0.5).
        flowerLayer.bounds = CGRect(x: 0, y: 0, width: Self.designSize, height: Self.designSize)
        flowerLayer.position = center
        let flowerCenter = CGPoint(x: Self.designSize / 2, y: Self.designSize / 2)

        for (index, ring) in ringLayers.enumerated() {
            ring.bounds = circleRect
            ring.path = circlePath
            if index == 0 {
                ring.position = flowerCenter
            } else {
                let angle = CGFloat(index - 1) * .pi / 3
                ring.position = CGPoint(
                    x: flowerCenter.x + circleRadius * cos(angle),
                    y: flowerCenter.y + circleRadius * sin(angle)
                )
            }
        }
    }

    // MARK: - Animation

    private func startAnimations() {
        if flowerLayer.animation(forKey: "rotation") == nil {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = rotationPeriod
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            flowerLayer.add(rotation, forKey: "rotation")
        }

        addBreathing(keyPath: "opacity", from: restGlowOpacity, to: peakGlowOpacity, key: "breathOpacity")
        addBreathing(keyPath: "shadowOpacity", from: restShadowOpacity, to: peakShadowOpacity, key: "breathShadow")
        addBreathing(
            keyPath: "transform.scale",
            from: Float(restGlowScale),
            to: Float(peakGlowScale),
            key: "breathScale"
        )
    }

    private func addBreathing(keyPath: String, from: Float, to: Float, key: String) {
        guard glowLayer.animation(forKey: key) == nil else { return }
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = breathingHalfPeriod
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(anim, forKey: key)
    }

    private func stopAnimations() {
        flowerLayer.removeAnimation(forKey: "rotation")
        glowLayer.removeAnimation(forKey: "breathOpacity")
        glowLayer.removeAnimation(forKey: "breathShadow")
        glowLayer.removeAnimation(forKey: "breathScale")
        // Settle to the rest pose so a still rosette matches the trough frame.
        glowLayer.opacity = restGlowOpacity
        glowLayer.shadowOpacity = restShadowOpacity
        glowLayer.transform = CATransform3DMakeScale(restGlowScale, restGlowScale, 1)
    }

    /// Canonical Core Animation pause/resume: stopping the layer clock freezes
    /// every attached animation at its current frame; resuming rebases
    /// `beginTime` so it continues from exactly where it stopped.
    private func setPaused(_ paused: Bool, _ layer: CALayer) {
        if paused {
            guard layer.speed != 0 else { return }
            // A view built already-frozen (panel opened while paused) is not in a
            // window yet, so `convertTime` returns a large absolute time and would
            // freeze at a random frame. Pin to 0 (the rest pose) until windowed.
            let pausedTime = window == nil ? 0 : layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        } else {
            guard layer.speed == 0 else { return }
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = timeSincePause
        }
    }
}

/// Polished footer button with hover background and press feedback.
private struct FooterButton: View {
    let label: String
    let icon: String
    var activeColor: Color?
    var disabled: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    private var foregroundColor: Color {
        if let activeColor {
            return activeColor
        }
        return isHovered
            ? DesignSystem.Colors.textSecondary
            : DesignSystem.Colors.textTertiary
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(foregroundColor)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isHovered
                            ? DesignSystem.Colors.surfaceElevated
                            : .clear
                        )
                )
                .scaleEffect(isHovered ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            guard !disabled else { return }
            isHovered = hovering
        }
    }
}

/// Icon-only footer button with hover effect and instant custom tooltip.
private struct FooterIconButton: View {
    let icon: String
    var activeColor: Color?
    var tooltip: String
    var action: () -> Void

    @State private var isHovered = false

    private var foregroundColor: Color {
        if let activeColor {
            return activeColor
        }
        return isHovered
            ? DesignSystem.Colors.textSecondary
            : DesignSystem.Colors.textTertiary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(foregroundColor)
                    // `.replace.byLayer` fades each SF Symbol layer separately
                    // — for fill ↔ outline pairs (like chevron.down.circle vs
                    // chevron.down.circle.fill) this reads softer than the
                    // default `.replace`, which fades the whole glyph at once.
                    .contentTransition(.symbolEffect(.replace.byLayer))

                if isHovered {
                    Text(tooltip)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(foregroundColor)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, isHovered ? 8 : 0)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovered
                        ? DesignSystem.Colors.surfaceElevated
                        : .clear
                    )
            )
            // Hover expand/contract is the only layout change this button
            // makes. Click only swaps the icon + foreground color in place —
            // no width change, no horizontal movement, no layout jank. Callers
            // must keep `tooltip` stable across state for this to hold; let
            // the icon fill + activeColor carry the state instead.
            .animation(.easeInOut(duration: 0.45), value: isHovered)
            // Animate the foreground color in lockstep with the icon swap.
            // `icon` is a String that changes only on toggle, so it's a clean
            // animation key — without this the color hard-snaps while
            // `.symbolEffect(.replace.byLayer)` runs its own fade, and the
            // mismatch reads as jagged.
            .animation(.easeInOut(duration: 0.3), value: icon)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
