import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

// MARK: - Animated Checkmark (Apple Pay style)

/// Ring draws, then check strokes in. Used for meeting completion confirmation.
private struct MeetingCompletionCheckmarkView: View {
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.5
    private let color = DesignSystem.Colors.successGreen

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(7)
        }
        .frame(width: 26, height: 26)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.25)) {
                checkTrim = 1
            }
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

// MARK: - Pill View

struct MeetingRecordingPillView: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel
    var onTap: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var stemCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .recording, .paused:
            // Paused shares the recording pill structure (rosette + capsule
            // + hover badge) but renders the rosette dimmed with a pause
            // glyph, and the hover badge swaps the red recording dot for a
            // pause symbol. Sharing the structure means the pill doesn't
            // resize between states — pause stays in the same spot, just
            // visually quieter.
            sacredRecordingPill
        case .completing:
            completingPill
        case .transcribing:
            iconPill {
                SpinnerRingView(size: 26)
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
        case .completed:
            iconPill {
                MeetingCompletionCheckmarkView()
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.7)))
        case .error(let message):
            statusPill(
                icon: AnyView(
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                ),
                title: message
            )
        }
    }

    /// Icon-only pill — used for transcribing (merkaba) and completed (checkmark).
    private func iconPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.meetingPillBackground)
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
                    )
            )
            .padding(DesignSystem.Spacing.sm)
    }

    private func statusPill(icon: AnyView, title: String) -> some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .font(DesignSystem.Typography.meetingPillStatus)
                .foregroundStyle(DesignSystem.Colors.meetingPillText)
                .lineLimit(2)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md - DesignSystem.Spacing.xs)
        .background(pillBackground)
    }

    private var completingPill: some View {
        VStack(spacing: 0) {
            FlowerCompletionView(
                stemCollapsed: $stemCollapsed,
                onCollapseFinished: {
                    viewModel.onCompletionAnimationFinished?()
                }
            )
        }
        .padding(10)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
                )
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stemCollapsed)
        .padding(DesignSystem.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording complete")
    }

    private var sacredRecordingPill: some View {
        let isPaused = viewModel.isPaused
        let healthWarning = visibleSourceHealthWarning
        return VStack(spacing: 0) {
            ZStack {
                MerkabaPillIcon(
                    isAnimating: !isPaused && !reduceMotion,
                    audioLevel: isPaused ? 0 : max(viewModel.micLevel, viewModel.systemLevel)
                )
                .opacity(isPaused ? 0.45 : 1.0)
                .animation(.easeInOut(duration: 0.25), value: isPaused)

                if isPaused {
                    // Two parallel bars in the rosette center — the universal
                    // "paused" affordance. Doesn't replace the rosette
                    // (continuity with recording state) but signals "frozen"
                    // on top of the dimmed mark.
                    HStack(spacing: 3) {
                        Capsule()
                            .fill(DesignSystem.Colors.meetingPillText)
                            .frame(width: 3, height: 11)
                        Capsule()
                            .fill(DesignSystem.Colors.meetingPillText)
                            .frame(width: 3, height: 11)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isHovered ? DesignSystem.Colors.meetingPillBackgroundHover : DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    Capsule()
                        .stroke(
                            isHovered ? DesignSystem.Colors.meetingPillStrokeHover : DesignSystem.Colors.meetingPillStroke,
                            lineWidth: 0.5
                        )
                )
                .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        )
        .contentShape(Capsule())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap?()
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        .padding(DesignSystem.Spacing.sm)
        .overlay(alignment: .top) {
            if isHovered && viewModel.elapsedSeconds > 0 {
                HStack(spacing: 5) {
                    if isPaused {
                        // Amber pause glyph — same color the panel status
                        // dot, pause button hover, and tile hover all use,
                        // so paused state reads as one consistent signal
                        // across every meeting surface.
                        Image(systemName: "pause.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.warningAmber)
                            .shadow(color: DesignSystem.Colors.warningAmber.opacity(0.5), radius: 3)
                    } else {
                        Circle()
                            .fill(DesignSystem.Colors.recordingRed)
                            .frame(width: 5, height: 5)
                            .shadow(color: .red.opacity(0.5), radius: 3)
                    }

                    Text(viewModel.formattedElapsed)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .offset(y: -24)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let healthWarning {
                MeetingSourceHealthGlyph(chip: healthWarning)
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPaused
                ? "Meeting recording paused, \(viewModel.formattedElapsed) elapsed\(healthSuffix(healthWarning))"
                : "Recording meeting, \(viewModel.formattedElapsed) elapsed\(healthSuffix(healthWarning))"
        )
        .accessibilityAction {
            onTap?()
        }
        .accessibilityAction(named: Text(isPaused ? "Resume recording" : "Pause recording")) {
            viewModel.onPauseToggle?()
        }
        .accessibilityAction(named: Text("End and transcribe")) {
            viewModel.onStop?()
        }
    }

    var visibleSourceHealthWarning: MeetingSourceHealthChip? {
        AppFeatures.meetingSourceHealthUIEnabled ? viewModel.mirroredSourceHealthWarning : nil
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: 999)
            .fill(DesignSystem.Colors.pillBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
            )
            .cardShadow(DesignSystem.Shadows.meetingPill)
    }

    private func healthSuffix(_ warning: MeetingSourceHealthChip?) -> String {
        warning.map { ", \($0.label)" } ?? ""
    }
}
