import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct FeedbackView: View {
    @Bindable var viewModel: FeedbackViewModel

    @State private var hoveredCategory: FeedbackCategory?
    @State private var isDraggingScreenshot = false
    @State private var isCommunityHovered = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                pageHeader
                categoryPicker
                formCard
                communityCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .onAppear {
            viewModel.configure(feedbackService: FeedbackService())
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Brand glyph lock-up — the same coral-circle + Breath Wave mark
            // that anchors the Dictation Stats hero, so this reads as one of
            // the app's brand surfaces rather than a generic form.
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.accent.opacity(0.12))
                    .frame(width: 34, height: 34)
                BreathWaveLogo(size: 22, tint: DesignSystem.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback")
                    .font(DesignSystem.Typography.pageTitle)
                Text("Found a bug, have an idea, or just want to say hi?")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    // MARK: - Category Picker

    /// The three category tiles sit directly on the page — the choice *is* the
    /// content, so it leads instead of hiding inside an icon-chip card. Selection
    /// reads coral (check + border + tinted fill), matching the Vocabulary mode
    /// picker rather than the old green check that fought the coral border.
    private var categoryPicker: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.md), count: 3),
            spacing: DesignSystem.Spacing.md
        ) {
            ForEach(FeedbackCategory.allCases, id: \.rawValue) { category in
                categoryTile(category)
            }
        }
    }

    private func categoryTile(_ category: FeedbackCategory) -> some View {
        let isSelected = viewModel.category == category
        let isHovered = hoveredCategory == category
        return Button {
            viewModel.category = category
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: categoryIcon(for: category))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }

                Text(category.displayName)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(.primary)

                Text(categorySubtitle(for: category))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredCategory = hovering ? category : nil
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Form

    /// One calm container for the whole form — no repeated icon-chip header.
    /// The first thing inside is the Message label, so the eye lands on the
    /// only required field.
    private var formCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if viewModel.submissionState == .success {
                successBanner
            } else {
                formContent
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var successBanner: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
            Text("Sent! Thanks for helping make MacParakeet better.")
                .font(DesignSystem.Typography.body)
        }
        .foregroundStyle(DesignSystem.Colors.successGreen)
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.successGreen.opacity(0.08))
        )
    }

    private var formContent: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            // Message — the hero, and the only required field. Coral focus ring
            // and the same input material as every other field in the app.
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Message")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.medium)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.message)
                        .font(DesignSystem.Typography.body)
                        .scrollContentBackground(.hidden)
                        .tint(DesignSystem.Colors.accent)
                        .focused($messageFocused)
                        .padding(DesignSystem.Spacing.sm)
                        .frame(minHeight: 120)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .strokeBorder(
                                    messageFocused
                                        ? DesignSystem.Colors.accent.opacity(0.7)
                                        : DesignSystem.Colors.border.opacity(0.7),
                                    lineWidth: messageFocused ? 1.5 : 0.5
                                )
                        )
                        .animation(DesignSystem.Animation.hoverTransition, value: messageFocused)

                    if viewModel.message.isEmpty {
                        Text(placeholderText)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(.tertiary)
                            .padding(DesignSystem.Spacing.sm + 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Email + Screenshot — both optional, visually secondary, sharing
            // the same input material so they read as a pair.
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Email (optional)")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                    ParakeetTextField(placeholder: "you@example.com", text: $viewModel.email)
                    Text("Provide your email if you need a direct response.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Screenshot (optional)")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)

                    if let filename = viewModel.screenshotFilename {
                        screenshotAttachedPill(filename)
                    } else {
                        screenshotAttachButton
                    }

                    Text(viewModel.screenshotFilename != nil
                         ? "PNG, JPEG, TIFF, or HEIC"
                         : "or drop an image here")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .onDrop(of: [.image], isTargeted: $isDraggingScreenshot) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadFileRepresentation(for: .image) { url, _, error in
                        guard let url, error == nil else { return }
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: tmp)
                        try? FileManager.default.copyItem(at: url, to: tmp)
                        Task { @MainActor in
                            viewModel.handleScreenshotDrop(url: tmp)
                        }
                    }
                    return true
                }
            }

            // System info disclosure
            DisclosureGroup("System Info", isExpanded: $viewModel.showSystemInfo) {
                Text(viewModel.systemInfo.displaySummary)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.contentBackground.opacity(0.5))
                    )
            }
            .font(DesignSystem.Typography.body)
            .tint(DesignSystem.Colors.accent)

            // Error banner
            if case .error(let errorMessage) = viewModel.submissionState {
                errorBanner(errorMessage)
            }

            // Action buttons — one coral CTA on the surface.
            HStack {
                Spacer()
                Button("Clear") {
                    viewModel.resetForm()
                }
                .parakeetAction(.secondary)
                .keyboardShortcut(.cancelAction)

                Button(viewModel.submissionState == .submitting ? "Sending…" : "Send Feedback") {
                    viewModel.submit()
                }
                .parakeetAction(.primaryProminent)
                .disabled(!viewModel.canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DesignSystem.Spacing.xs)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(error)
                .font(DesignSystem.Typography.caption)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
    }

    // MARK: - Screenshot Components

    private var screenshotAttachButton: some View {
        Button {
            viewModel.attachScreenshot()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: isDraggingScreenshot ? "arrow.down.doc.fill" : "photo.on.rectangle.angled")
                    .font(.system(size: 13))
                    .foregroundStyle(isDraggingScreenshot ? DesignSystem.Colors.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text("Attach…")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isDraggingScreenshot ? DesignSystem.Colors.accent.opacity(0.06) : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isDraggingScreenshot ? DesignSystem.Colors.accent : DesignSystem.Colors.border.opacity(0.7),
                        lineWidth: isDraggingScreenshot ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func screenshotAttachedPill(_ filename: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(filename)
                .font(DesignSystem.Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                viewModel.removeScreenshot()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
    }

    // MARK: - Community

    /// A community invitation, not fine print. The whole card is one clickable
    /// destination, dressed in the same craft signature as the Dictation Stats
    /// hero — diagonal-gradient material, a whisper-thin coral top-edge
    /// highlight, shadow lift on hover — plus an external-arrow nudge for delight.
    private var communityCard: some View {
        Button {
            if let url = URL(string: "https://github.com/moona3k/macparakeet/issues") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Join the conversation on GitHub")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("See what's already reported and upvote the ideas you want next.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCommunityHovered ? DesignSystem.Colors.accent : .secondary)
                    .offset(x: isCommunityHovered ? 2 : 0, y: isCommunityHovered ? -2 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.cardBackground,
                                DesignSystem.Colors.surfaceElevated.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cardShadow(isCommunityHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.accent.opacity(isCommunityHovered ? 0.35 : 0.18),
                                Color.primary.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isCommunityHovered = hovering
            }
        }
        .accessibilityLabel("Join the conversation on GitHub")
        .accessibilityHint("Opens the MacParakeet issues page on GitHub in your browser")
    }

    // MARK: - Category metadata

    private func categoryIcon(for category: FeedbackCategory) -> String {
        switch category {
        case .bug: return "ladybug"
        case .featureRequest: return "lightbulb"
        case .other: return "ellipsis.bubble"
        }
    }

    private func categorySubtitle(for category: FeedbackCategory) -> String {
        switch category {
        case .bug: return "Something isn't working right."
        case .featureRequest: return "An idea for improvement."
        case .other: return "General thoughts or questions."
        }
    }

    /// Placeholder responds to the chosen category so the message box feels
    /// like it's listening rather than showing one generic prompt.
    private var placeholderText: String {
        switch viewModel.category {
        case .bug: return "What happened, and what did you expect instead?"
        case .featureRequest: return "What would make MacParakeet better for you?"
        case .other: return "What's on your mind?"
        }
    }
}
