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
            // Notes and Ask own their own bottom UI (Notes shows a soft-cap
            // footer when relevant; Ask owns its composer + follow-up pills).
            // The footer stays transcript-specific (Copy, auto-scroll toggle, Stop).
            // The floating recording pill remains the canonical Stop control.
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
                elapsedSeconds: viewModel.elapsedSeconds
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
            withAnimation(.easeOut(duration: 0.12)) {
                if hovering {
                    hoveredTab = tab
                } else if hoveredTab == tab {
                    hoveredTab = nil
                }
            }
        }
        .help(tabTooltip(title: tab.title, badge: badge, isStreaming: isStreaming, shortcut: shortcutDisplay))
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
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
                    DualAudioOrbView(
                        micLevel: viewModel.micLevel,
                        systemLevel: viewModel.systemLevel
                    )
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
                    BreathingSeedOfLifeView()
                        .opacity(hasContent ? 0.15 : 1.0)
                        .animation(.easeInOut(duration: 0.8), value: hasContent)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
                }

                if !hasContent {
                    Text(viewModel.canStop ? "Listening…" : "Transcription in progress…")
                        .font(.system(size: 13, weight: .light, design: .default))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.6))
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
    /// no inner conditional needed here.
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

            FooterIconButton(
                icon: autoScroll ? "chevron.down.circle.fill" : "chevron.down.circle",
                activeColor: autoScroll ? DesignSystem.Colors.accent : nil,
                tooltip: autoScroll ? "Auto-scroll on" : "Auto-scroll paused"
            ) {
                autoScroll.toggle()
            }

            Spacer()

            if viewModel.canStop {
                StopRecordingButton {
                    viewModel.onStop?()
                }
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
            Circle()
                .fill(DesignSystem.Colors.successGreen)
                .frame(width: 8, height: 8)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
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

/// A slowly rotating seed-of-life (1 center + 6 outer circles) for the
/// empty listening state. Matches the flower head from the recording pill,
/// without the stem. Also reused as the summary-generation loading indicator.
struct BreathingSeedOfLifeView: View {
    @State private var rotation: Double = 0
    @State private var glowBreathing = false

    private let size: CGFloat = 140
    private let circleRadius: CGFloat = 28
    private let strokeColor = DesignSystem.Colors.accent

    var body: some View {
        ZStack {
            // Center glow
            Circle()
                .fill(strokeColor.opacity(glowBreathing ? 0.5 : 0.2))
                .frame(width: circleRadius * 2, height: circleRadius * 2)
                .shadow(color: strokeColor.opacity(glowBreathing ? 0.4 : 0.15), radius: 12)
                .scaleEffect(glowBreathing ? 1.2 : 0.9)

            // Center circle
            Circle()
                .stroke(strokeColor.opacity(0.7), lineWidth: 1.2)
                .frame(width: circleRadius * 2, height: circleRadius * 2)

            // 6 outer circles (seed of life)
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .stroke(strokeColor.opacity(0.5), lineWidth: 1.2)
                    .frame(width: circleRadius * 2, height: circleRadius * 2)
                    .offset(x: circleRadius * CGFloat(cos(Double(i) * .pi / 3)),
                            y: circleRadius * CGFloat(sin(Double(i) * .pi / 3)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glowBreathing = true
            }
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
                    .contentTransition(.symbolEffect(.replace))

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
            .animation(.easeInOut(duration: 0.3), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
