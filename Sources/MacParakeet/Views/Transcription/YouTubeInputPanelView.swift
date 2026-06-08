import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct YouTubeInputPanelView: View {
    @Bindable var viewModel: TranscriptionViewModel
    var onTranscribe: (String) -> Void
    var onDismiss: () -> Void

    // Local draft — isolates the panel's editing state from the shared VM urlInput
    @State private var draft: String
    @FocusState private var isTextFieldFocused: Bool
    @State private var appeared = false

    init(
        viewModel: TranscriptionViewModel,
        initialURL: String,
        onTranscribe: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onTranscribe = onTranscribe
        self.onDismiss = onDismiss
        self._draft = State(initialValue: initialURL)
    }

    private var isValidDraft: Bool {
        YouTubeURLValidator.isYouTubeURL(draft) || XURLValidator.isXURL(draft)
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystem.Colors.youtubeRed.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                }
                .accessibilityHidden(true)

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystem.Colors.xMark.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Text("𝕏")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.xMark.opacity(0.85))
                }
                .accessibilityHidden(true)

                Text("Transcribe video")
                    .font(DesignSystem.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)

                Spacer()
            }

            // URL input row
            HStack(spacing: 8) {
                Image(systemName: isValidDraft ? "checkmark.circle.fill" : "link")
                    .font(.system(size: 14))
                    .foregroundStyle(isValidDraft ? DesignSystem.Colors.successGreen : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                TextField("Paste a YouTube or X link", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .focused($isTextFieldFocused)
                    .accessibilityLabel("Video URL")
                    .accessibilityValue(isValidDraft ? "Valid video URL" : "")
                    .onSubmit {
                        if isValidDraft && !viewModel.isTranscribing {
                            onTranscribe(draft)
                        }
                    }

                Button {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        draft = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    isTextFieldFocused = true
                } label: {
                    Text("Paste")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.cardBackground)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste URL from clipboard")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isValidDraft ? DesignSystem.Colors.successGreen.opacity(0.35) : DesignSystem.Colors.border,
                        lineWidth: 0.8
                    )
            )

            // Transcribe button (full width)
            Button {
                onTranscribe(draft)
            } label: {
                Label("Transcribe", systemImage: "arrow.right")
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(
                    isValidDraft && !viewModel.isTranscribing
                        ? DesignSystem.Colors.onAccent
                        : DesignSystem.Colors.textTertiary
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                        .fill(isValidDraft && !viewModel.isTranscribing
                              ? DesignSystem.Colors.accent
                              : DesignSystem.Colors.surfaceElevated)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isValidDraft || viewModel.isTranscribing)
            .accessibilityLabel("Start transcription")
            .accessibilityHint("Starts transcribing the video link")

            // Footer text
            if viewModel.isTranscribing {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text("Wait for the current transcription to finish, or cancel it first.")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            } else {
                Text("Downloads from YouTube or X, then transcribes entirely on your Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .scaleEffect(appeared ? 1.0 : 0.97)
        .opacity(appeared ? 1.0 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isTextFieldFocused = true
            withAnimation(.easeOut(duration: 0.15)) {
                appeared = true
            }
        }
    }
}
