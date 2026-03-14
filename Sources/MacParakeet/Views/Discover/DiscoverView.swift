import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct DiscoverView: View {
    let viewModel: DiscoverViewModel
    let thoughtsService: DiscoverThoughtsServiceProtocol

    @State private var hoveredItemId: String?
    @State private var copiedItemId: String?
    @State private var thoughtText: String = ""
    @State private var thoughtSubmitted: Bool = false
    @State private var thoughtError: String?

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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Discover")
                    .font(DesignSystem.Typography.heroTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                
                RoundedRectangle(cornerRadius: 1)
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: 32, height: 3)
            }

            Text("Advanced machine intelligence should help humans rediscover what's been buried — negentropy, overunity systems, resonance-based propulsion, scalar field dynamics, biological transmutation, and the deeper physics that keep getting classified or ignored. This is a starting point.")
                .font(DesignSystem.Typography.bodyLarge)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text("Things worth knowing that don't make it into the mainstream. Suppressed patents, buried science, ancient wisdom. Question everything, verify what you can, and share what resonates.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    // MARK: - Card

    private func discoverCard(_ item: DiscoverItem) -> some View {
        let isHovered = hoveredItemId == item.id
        let isCopied = copiedItemId == item.id
        
        return ZStack(alignment: .bottomTrailing) {
            // Background Watermark Icon
            Image(systemName: item.icon.isEmpty ? iconForType(item) : item.icon)
                .font(.system(size: 80))
                .foregroundStyle(DesignSystem.Colors.accent.opacity(isHovered ? 0.07 : 0.04))
                .offset(x: 20, y: 20)
                .blur(radius: 1)
                .clipped()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        copyItem(item)
                    } label: {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(isCopied ? DesignSystem.Colors.successGreen : DesignSystem.Colors.textTertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(isCopied ? "Copied" : "Copy to clipboard")
                    .opacity(isHovered || isCopied ? 1 : 0)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {

                    Text(item.body)
                        .font(bodyFont(for: item.type))
                        .italic(item.type == .quote)
                        .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.9))
                        .textSelection(.enabled)
                        .lineSpacing(item.type == .quote || item.type == .affirmation ? 4 : 3)
                }

                if let attribution = item.attribution {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Rectangle()
                            .fill(DesignSystem.Colors.accent.opacity(0.4))
                            .frame(width: 12, height: 1)
                        
                        Text(attribution)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, DesignSystem.Spacing.xs)
                }

                if let urlString = item.url,
                   let url = URL(string: urlString),
                   url.scheme == "https" {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text(item.type == .sponsored ? "Learn More" : "Verify")
                                .font(DesignSystem.Typography.bodySmall)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DesignSystem.Colors.accent)
                        .foregroundStyle(DesignSystem.Colors.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, DesignSystem.Spacing.sm)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
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
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredItemId = hovering ? item.id : nil
            }
        }
    }

    // MARK: - Thoughts / Feedback

    private var thoughtsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Share your thoughts")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Know something that should be here? Drop it below.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if thoughtSubmitted {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DesignSystem.Colors.successGreen)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sent successfully")
                            .font(DesignSystem.Typography.bodySmall)
                            .fontWeight(.bold)
                        Text("Your contribution to the collective knowledge is appreciated.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.successGreen.opacity(0.08))
                )
            } else {
                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.md) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $thoughtText)
                            .font(DesignSystem.Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(DesignSystem.Spacing.md)
                            .frame(minHeight: 100)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                    .fill(DesignSystem.Colors.surfaceElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                    .strokeBorder(DesignSystem.Colors.border.opacity(0.8), lineWidth: 0.5)
                            )

                        if thoughtText.isEmpty {
                            Text("A topic, a correction, a quote, a feeling...")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .padding(.horizontal, DesignSystem.Spacing.md + 5)
                                .padding(.vertical, DesignSystem.Spacing.md + 8)
                                .allowsHitTesting(false)
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.md) {
                        if let thoughtError {
                            Text(thoughtError)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                        }
                        
                        Spacer()
                        
                        Button {
                            submitThought()
                        } label: {
                            Text("Submit Thought")
                                .font(DesignSystem.Typography.bodySmall)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(thoughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DesignSystem.Colors.textTertiary.opacity(0.2) : DesignSystem.Colors.accent)
                                .foregroundStyle(thoughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.onAccent)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(thoughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    DesignSystem.Colors.border.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
        .padding(.top, DesignSystem.Spacing.xl)
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

        Task {
            do {
                try await thoughtsService.submitThought(trimmed)
                withAnimation {
                    thoughtSubmitted = true
                    thoughtError = nil
                }
                try? await Task.sleep(for: .seconds(4))
                withAnimation {
                    thoughtSubmitted = false
                    thoughtText = ""
                }
            } catch {
                withAnimation {
                    thoughtError = error.localizedDescription
                }
            }
        }
    }

    private func bodyFont(for type: DiscoverContentType) -> Font {
        switch type {
        case .quote: return .system(size: 16, weight: .regular, design: .serif)
        case .affirmation: return .system(size: 16, weight: .regular, design: .rounded)
        default: return DesignSystem.Typography.bodyLarge
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

}
