import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingRecordingPanelView: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            paneContent
            // Ask owns its own bottom area (composer + follow-up pills). The Stop control
            // lives on the floating recording pill, so the panel stays focused on chat.
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
        case .transcript:
            transcriptContent
        case .ask:
            LiveAskPaneView(viewModel: viewModel.chatViewModel)
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
        let shortcut: KeyEquivalent = tab == .transcript ? "1" : "2"
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                Text(tab.title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textTertiary)
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

/// Stop button with inline "End?" confirmation.
/// First click shows "End?" label. Second click within 3s confirms.
/// Auto-reverts to icon if not confirmed.
private struct StopRecordingButton: View {
    var onStop: () -> Void

    @State private var isHovered = false
    @State private var confirming = false
    @State private var countdownProgress: CGFloat = 1.0
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        Group {
            if confirming {
                // Confirmation state — "End?" text button
                Button {
                    revertTask?.cancel()
                    confirming = false
                    onStop()
                } label: {
                    Text("Click to end")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated)
                                .overlay(
                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(DesignSystem.Colors.errorRed.opacity(0.2))
                                            .frame(width: geo.size.width * countdownProgress)
                                    }
                                    .clipShape(Capsule())
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(DesignSystem.Colors.errorRed.opacity(0.3), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                // Default state — stop square icon
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary.opacity(0.6))
                    .frame(width: 13, height: 13)
                    .padding(9)
                    .background(
                        Circle()
                            .fill(isHovered
                                ? DesignSystem.Colors.errorRed.opacity(0.15)
                                : DesignSystem.Colors.surfaceElevated
                            )
                            .overlay(
                                Circle()
                                    .stroke(isHovered ? DesignSystem.Colors.errorRed.opacity(0.3) : .clear, lineWidth: 0.5)
                            )
                    )
                    .shadow(color: isHovered ? DesignSystem.Colors.errorRed.opacity(0.25) : .clear, radius: 6)
                    .scaleEffect(isHovered ? 1.08 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
                    .onHover { hovering in
                        isHovered = hovering
                    }
                    .onTapGesture {
                        countdownProgress = 1.0
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            confirming = true
                        }
                        withAnimation(.linear(duration: 3)) {
                            countdownProgress = 0
                        }
                        revertTask?.cancel()
                        revertTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                confirming = false
                            }
                        }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .help(confirming ? "Click to confirm" : "End recording")
        .onDisappear { revertTask?.cancel() }
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

