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
        MediaPlatform.isTranscribable(draft)
    }

    /// The platform recognized from the current draft, if any — drives the
    /// live matched-glyph reaction in the header.
    private var draftPlatform: MediaPlatform? {
        MediaPlatform.recognize(draft)
    }

    /// Reactive footer copy: confirms a recognized link, acknowledges any other
    /// link, or invites a paste while idle.
    private var footerCaption: String {
        if let platform = draftPlatform {
            let kind = platform.isAudioFirst ? "audio" : "video"
            return "Ready to transcribe this \(platform.displayName) \(kind), on your Mac."
        }
        if isValidDraft {
            return "Ready to transcribe this link, entirely on your Mac."
        }
        return "Works with YouTube, X, Vimeo, TikTok, Instagram, podcasts, and more — on your Mac."
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Header — a single badge that morphs from a neutral globe to the
            // matched platform's brand glyph as a link is recognized.
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((draftPlatform?.brandTint ?? DesignSystem.Colors.accent).opacity(0.12))
                        .frame(width: 38, height: 38)

                    // No `.id` here: PlatformGlyph re-renders its Canvas when the
                    // platform changes, so the mark updates in place (the tint
                    // springs via the ZStack animation) instead of hard-cutting.
                    PlatformGlyph(
                        platform: draftPlatform,
                        color: draftPlatform?.brandTint ?? DesignSystem.Colors.textSecondary
                    )
                    .frame(width: 21, height: 21)
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: draftPlatform)
                .accessibilityHidden(true)

                Text("Transcribe YouTube & more")
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

                TextField("Paste any video or podcast link", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .focused($isTextFieldFocused)
                    .accessibilityLabel("Media URL")
                    .accessibilityValue(isValidDraft ? "Valid media URL" : "")
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
            .accessibilityHint("Starts transcribing the media link")

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
                Text(footerCaption)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .animation(.easeInOut(duration: 0.2), value: footerCaption)
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
