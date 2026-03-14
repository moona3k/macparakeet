import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct DiscoverView: View {
    let viewModel: DiscoverViewModel
    let feedbackViewModel: FeedbackViewModel

    @State private var hoveredItemId: String?
    @State private var copiedItemId: String?
    @State private var thoughtText: String = ""
    @State private var thoughtSubmitted: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerSection

                ForEach(viewModel.allItems) { item in
                    discoverCard(item)
                }

                thoughtsSection
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Discover")
                .font(.system(size: 24, weight: .bold))

            Text("Things worth knowing that don't make it into the mainstream. Suppressed patents, buried science, ancient wisdom. Question everything, verify what you can, and share what resonates.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    // MARK: - Card

    private func discoverCard(_ item: DiscoverItem) -> some View {
        let isHovered = hoveredItemId == item.id
        let isCopied = copiedItemId == item.id
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top) {
                Text(item.title)
                    .font(DesignSystem.Typography.sectionTitle)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    copyItem(item)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(isCopied ? DesignSystem.Colors.successGreen : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(isCopied ? "Copied" : "Copy to clipboard")
                .opacity(isHovered || isCopied ? 1 : 0)
                .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
            }

            Text(item.body)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .lineSpacing(2)

            if let attribution = item.attribution {
                Text("— \(attribution)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .textSelection(.enabled)
            }

            if item.type == .sponsored, let urlString = item.url,
               let url = URL(string: urlString),
               url.scheme == "https" {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Learn More")
                            .font(DesignSystem.Typography.body)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
            }
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
                hoveredItemId = hovering ? item.id : nil
            }
        }
    }

    // MARK: - Thoughts / Feedback

    private var thoughtsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Share your thoughts")
                .font(DesignSystem.Typography.sectionTitle)

            Text("Know something that should be here? Have a correction, a lead, or just want to say what resonated? We read everything.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)

            if thoughtSubmitted {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                    Text("Sent. Thank you.")
                        .font(DesignSystem.Typography.body)
                }
                .foregroundStyle(DesignSystem.Colors.successGreen)
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.successGreen.opacity(0.08))
                )
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $thoughtText)
                        .font(DesignSystem.Typography.body)
                        .scrollContentBackground(.hidden)
                        .padding(DesignSystem.Spacing.sm)
                        .frame(minHeight: 70, maxHeight: 120)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .fill(DesignSystem.Colors.contentBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                        )

                    if thoughtText.isEmpty {
                        Text("A topic, a correction, a quote, a feeling...")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(.tertiary)
                            .padding(DesignSystem.Spacing.sm + 5)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Spacer()
                    Button("Send") {
                        submitThought()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(thoughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - Actions

    private func copyItem(_ item: DiscoverItem) {
        var text = item.title + "\n\n" + item.body
        if let attribution = item.attribution {
            text += "\n\n— " + attribution
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            copiedItemId = item.id
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                if copiedItemId == item.id {
                    copiedItemId = nil
                }
            }
        }
    }

    private func submitThought() {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        feedbackViewModel.configure(feedbackService: FeedbackService())
        feedbackViewModel.category = .other
        feedbackViewModel.message = "[Discover] \(trimmed)"
        feedbackViewModel.submit()

        withAnimation {
            thoughtSubmitted = true
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation {
                thoughtSubmitted = false
                thoughtText = ""
                feedbackViewModel.resetForm()
            }
        }
    }

    // MARK: - Helpers

    private func iconForType(_ item: DiscoverItem) -> String {
        switch item.type {
        case .tip: return "lightbulb.fill"
        case .quote: return "quote.bubble"
        case .affirmation: return "sparkles"
        case .sponsored: return item.icon
        }
    }

    private func typeLabel(_ type: DiscoverContentType) -> String {
        switch type {
        case .tip: return "Tip"
        case .quote: return "Quote"
        case .affirmation: return "Affirmation"
        case .sponsored: return "Sponsored"
        }
    }
}
