import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingRecordingPanelView: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel
    @State private var autoScroll = true
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptContent
            Divider()
            footer
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 460)
        .background(DesignSystem.Colors.surface)
    }

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                statusDot

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

                if viewModel.showsAudioLevels {
                    DualAudioOrbView(
                        micLevel: viewModel.micLevel,
                        systemLevel: viewModel.systemLevel
                    )
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
        if viewModel.previewLines.isEmpty {
            VStack(spacing: DesignSystem.Spacing.md) {
                if viewModel.canStop {
                    BreathingEnsoView()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
                }

                Text(viewModel.canStop ? "Listening…" : "Transcription in progress…")
                    .font(.system(size: 13, weight: .light, design: .default))
                    .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignSystem.Spacing.lg)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(buildAttributedTranscript())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .id("transcript-bottom")
                }
                .background(DesignSystem.Colors.background)
                .onAppear {
                    guard autoScroll else { return }
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: viewModel.previewLines.count) { _, _ in
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button {
                copyTranscript()
            } label: {
                Label(
                    viewModel.showCopiedConfirmation ? "Copied" : "Copy",
                    systemImage: viewModel.showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(
                    viewModel.showCopiedConfirmation
                        ? DesignSystem.Colors.successGreen
                        : DesignSystem.Colors.textTertiary
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canCopy)
            .help("Copy transcript to clipboard")

            Spacer()

            Button {
                autoScroll.toggle()
            } label: {
                Label(autoScroll ? "Auto-scroll" : "Paused", systemImage: autoScroll ? "chevron.down.circle.fill" : "chevron.down.circle")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(autoScroll ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            Button(action: { viewModel.onStop?() }) {
                Text(viewModel.canStop ? "Stop Recording" : "Recording Stopped")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(viewModel.canStop ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canStop)
            .help(viewModel.canStop ? "Stop meeting recording" : "Meeting recording is no longer active")
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func buildAttributedTranscript() -> AttributedString {
        var result = AttributedString()
        var previousSource: AudioSource? = nil

        for line in viewModel.previewLines {
            let speakerChanged = line.source != previousSource

            if speakerChanged {
                if !result.characters.isEmpty {
                    result.append(AttributedString("\n"))
                }
                let color = sourceColor(for: line.source)
                var dot = AttributedString("● ")
                dot.font = .system(size: 10, weight: .medium)
                dot.foregroundColor = NSColor(color)
                result.append(dot)

                var speaker = AttributedString("\(line.speakerLabel)  ")
                speaker.font = .system(size: 11, weight: .medium)
                speaker.foregroundColor = NSColor(color.opacity(0.85))
                result.append(speaker)

                var timestamp = AttributedString("\(line.timestamp)\n")
                timestamp.font = .system(size: 10, weight: .regular).monospacedDigit()
                timestamp.foregroundColor = NSColor(DesignSystem.Colors.textTertiary.opacity(0.5))
                result.append(timestamp)
            }

            var text = AttributedString("\(line.text)\n")
            text.font = .system(size: 13, weight: .regular)
            text.foregroundColor = NSColor(DesignSystem.Colors.textPrimary.opacity(0.9))
            result.append(text)

            previousSource = line.source
        }

        return result
    }

    private func sourceColor(for source: AudioSource?) -> Color {
        switch source {
        case .microphone:
            return DesignSystem.Colors.accent
        case .system:
            return DesignSystem.Colors.speakerColor(for: 0)
        case .none:
            return DesignSystem.Colors.textSecondary
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.transcriptText, forType: .string)
        viewModel.showCopiedConfirmation = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            viewModel.showCopiedConfirmation = false
        }
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

/// A gently breathing ensō circle for the empty listening state.
private struct BreathingEnsoView: View {
    @State private var breathing = false

    private let size: CGFloat = 36

    var body: some View {
        ZStack {
            // Outer ensō ring
            Circle()
                .stroke(
                    DesignSystem.Colors.accent.opacity(breathing ? 0.35 : 0.12),
                    lineWidth: 1.5
                )
                .frame(width: size, height: size)
                .scaleEffect(breathing ? 1.08 : 0.95)

            // Inner glow dot
            Circle()
                .fill(DesignSystem.Colors.accent.opacity(breathing ? 0.25 : 0.08))
                .frame(width: size * 0.3, height: size * 0.3)
                .scaleEffect(breathing ? 1.15 : 0.85)
        }
        .animation(
            .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
            value: breathing
        )
        .onAppear { breathing = true }
    }
}
