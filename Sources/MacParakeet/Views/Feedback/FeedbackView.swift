import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct FeedbackView: View {
    @Bindable var viewModel: FeedbackViewModel

    @State private var hoveredCardTitle: String?
    @State private var hoveredCategory: FeedbackCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                categoryCard
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

    // MARK: - Category Selection

    private var categoryCard: some View {
        feedbackCard(
            title: "What would you like to share?",
            subtitle: "Pick the type that best fits.",
            icon: "tray.2"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: DesignSystem.Spacing.md)],
                spacing: DesignSystem.Spacing.md
            ) {
                ForEach(FeedbackCategory.allCases, id: \.rawValue) { category in
                    categorySelectionCard(category)
                }
            }
        }
    }

    private func categorySelectionCard(_ category: FeedbackCategory) -> some View {
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
                            .foregroundStyle(DesignSystem.Colors.successGreen)
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
    }

    // MARK: - Form

    private var formCard: some View {
        feedbackCard(
            title: "Details",
            subtitle: "The more context, the better we can help.",
            icon: "pencil.line"
        ) {
            if viewModel.submissionState == .success {
                successBanner
            } else {
                formContent
            }
        }
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
        VStack(spacing: DesignSystem.Spacing.md) {
            // Message
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Message")
                    .font(DesignSystem.Typography.body)
                TextEditor(text: $viewModel.message)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(minHeight: 100)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                    )
            }

            Divider()

            // Email (optional)
            HStack(alignment: .center) {
                rowText(
                    title: "Email (optional)",
                    detail: "Only if you'd like a reply."
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                TextField("you@example.com", text: $viewModel.email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            Divider()

            // Screenshot
            HStack(alignment: .center) {
                rowText(
                    title: "Screenshot (optional)",
                    detail: "PNG, JPEG, TIFF, or HEIC. Max 5 MB."
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                if let filename = viewModel.screenshotFilename {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(filename)
                            .font(DesignSystem.Typography.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Remove") {
                            viewModel.removeScreenshot()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button("Attach Screenshot") {
                        viewModel.attachScreenshot()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // System info disclosure
            DisclosureGroup("System Info", isExpanded: $viewModel.showSystemInfo) {
                Text(viewModel.systemInfo.displaySummary)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
            .font(DesignSystem.Typography.body)

            // Error banner
            if case .error(let errorMessage) = viewModel.submissionState {
                errorBanner(errorMessage)
            }

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.resetForm()
                }
                .buttonStyle(.bordered)

                Button(viewModel.submissionState == .submitting ? "Sending..." : "Send Feedback") {
                    viewModel.submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(!viewModel.canSubmit)
            }
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

    // MARK: - Community

    private var communityCard: some View {
        feedbackCard(
            title: "Community",
            subtitle: "See what others have reported, vote on ideas, or follow progress.",
            icon: "person.2"
        ) {
            Button {
                if let url = URL(string: "https://github.com/moona3k/macparakeet-community") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                    Text("Open on GitHub")
                        .font(DesignSystem.Typography.body)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Reusable

    private func feedbackCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isHovered = hoveredCardTitle == title
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredCardTitle = hovering ? title : nil
            }
        }
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.body)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

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
}
