import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// The **Transforms** tab — top-level sidebar destination (ADR-022).
///
/// Layout: hero strip → My Transforms grid (3-up cards + Create-your-own
/// tile) → footer with reseed-missing affordance. Calmer no-provider
/// banner replaces the hero when no LLM is configured.
///
/// Visual continuity: rounded display type (no serif — we use
/// `.rounded` system font, not a literal serif copy of the reference
/// screenshots), warm coral accent only on the keycap badges + primary
/// CTAs, generous whitespace, hover lift on cards via the existing
/// `cardRest`/`cardHover` shadow tokens.
struct TransformsView: View {
    @Bindable var viewModel: TransformsViewModel
    let reservedHotkeys: [TransformShortcutReservedHotkey]
    let llmConfiguredAction: () -> Void
    let onEdit: (Prompt) -> Void
    let onCreate: () -> Void
    let onBindingsChanged: () -> Void

    @State private var historySearchText = ""
    @State private var expandedHistoryEntryIDs: Set<UUID> = []

    private var historySearchQuery: String {
        historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHistoryFiltering: Bool {
        !historySearchQuery.isEmpty
    }

    private var filteredHistory: [TransformHistoryEntry] {
        guard isHistoryFiltering else { return viewModel.history }
        return viewModel.history.filter { $0.matchesSearch(historySearchQuery) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                heroHeader

                if viewModel.hasLLMProvider {
                    heroExplainer
                } else {
                    noProviderBanner
                }

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                myTransformsHeader
                transformGrid

                historySection

                footerActions
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.vertical, DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignSystem.Colors.background)
        .onAppear {
            Task { await viewModel.loadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transformHistoryChanged)) { _ in
            Task { await viewModel.loadHistory() }
        }
        .alert(
            "Delete this Transform?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteTransform != nil },
                set: { if !$0 { viewModel.pendingDeleteTransform = nil } }
            ),
            presenting: viewModel.pendingDeleteTransform
        ) { transform in
            Button("Delete", role: .destructive) {
                Task {
                    viewModel.pendingDeleteTransform = nil
                    if await viewModel.delete(transform) {
                        onBindingsChanged()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteTransform = nil
            }
        } message: { transform in
            Text("“\(transform.name)” will be removed. You can re-create it later.")
        }
        .alert(
            "Delete history item?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteHistoryEntry != nil },
                set: { if !$0 { viewModel.pendingDeleteHistoryEntry = nil } }
            ),
            presenting: viewModel.pendingDeleteHistoryEntry
        ) { entry in
            // Use the closure-captured `entry`, not `pendingDeleteHistoryEntry`
            // via a wrapper method. SwiftUI clears the binding (and the
            // pending field) before this Task runs, so reading the pending
            // field would silently no-op the deletion.
            Button("Delete", role: .destructive) {
                Task {
                    viewModel.pendingDeleteHistoryEntry = nil
                    await viewModel.deleteHistoryEntry(entry)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteHistoryEntry = nil
            }
        } message: { entry in
            Text("The saved “\(entry.transformName)” input and output will be removed from local history.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Transforms")
                .font(DesignSystem.Typography.heroTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Press a hotkey on any selected text to rewrite it through your LLM provider — in Slack, Notes, Gmail, your editor, anywhere on Mac.")
                .font(DesignSystem.Typography.bodyLarge)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.top, DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private var heroExplainer: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Label("Highlight any text on your Mac.", systemImage: "1.circle.fill")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Label(viewModel.heroShortcutInstruction, systemImage: "2.circle.fill")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Label("The selection is rewritten in place. ⌘Z to undo.", systemImage: "3.circle.fill")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .padding(.vertical, DesignSystem.Spacing.lg)
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignSystem.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private var noProviderBanner: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add an LLM provider to apply Transforms")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Transforms call your LLM provider on each run. Use Claude, GPT, Ollama, LM Studio — your key, your terms.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Button("Open Settings", action: llmConfiguredAction)
                .parakeetAction(.primary)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.accentLight)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.accent.opacity(0.25), lineWidth: 0.5)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(message)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignSystem.Spacing.md)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.warningAmber.opacity(0.35), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var myTransformsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("My Transforms")
                .font(DesignSystem.Typography.pageTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer()
        }
    }

    @ViewBuilder
    private var transformGrid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 260, maximum: 360), spacing: DesignSystem.Spacing.md, alignment: .top)
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Spacing.md) {
            ForEach(viewModel.transforms) { transform in
                TransformCard(
                    transform: transform,
                    onEdit: { onEdit(transform) },
                    onDelete: {
                        viewModel.pendingDeleteTransform = transform
                    },
                    onReset: {
                        Task {
                            if await viewModel.resetBuiltIn(transform, reservedHotkeys: reservedHotkeys) {
                                onBindingsChanged()
                            }
                        }
                    }
                )
            }

            CreateYourOwnTile(action: onCreate)
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        if viewModel.hasMissingBuiltInTransforms {
            HStack(spacing: DesignSystem.Spacing.md) {
                Button(action: {
                    Task {
                        if await viewModel.reseedMissingBuiltIns(reservedHotkeys: reservedHotkeys) {
                            onBindingsChanged()
                        }
                    }
                }) {
                    Label("Restore missing defaults", systemImage: "arrow.counterclockwise")
                }
                .parakeetAction(.subtle)
                Spacer()
            }
            .padding(.top, DesignSystem.Spacing.md)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let visibleHistory = filteredHistory

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if !viewModel.history.isEmpty {
                    Text("\(viewModel.totalHistoryCount)")
                        .font(DesignSystem.Typography.duration)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                }
                Spacer()
            }

            if !viewModel.history.isEmpty {
                TransformHistorySearchField(text: $historySearchText)
            }

            if let historyError = viewModel.historyErrorMessage {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Text(historyError)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            }

            if viewModel.history.isEmpty {
                TransformHistoryEmptyState()
            } else if visibleHistory.isEmpty {
                TransformHistoryNoResultsState(query: historySearchQuery) {
                    historySearchText = ""
                }
            } else {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(visibleHistory) { entry in
                        TransformHistoryRow(
                            entry: entry,
                            copiedTarget: viewModel.copiedHistoryEntryID == entry.id ? viewModel.copiedHistoryTarget : nil,
                            isExpanded: expandedHistoryEntryIDs.contains(entry.id),
                            onToggleExpanded: {
                                withAnimation(DesignSystem.Animation.contentSwap) {
                                    if expandedHistoryEntryIDs.contains(entry.id) {
                                        expandedHistoryEntryIDs.remove(entry.id)
                                    } else {
                                        expandedHistoryEntryIDs.insert(entry.id)
                                    }
                                }
                            },
                            onCopyOutput: {
                                Task {
                                    await viewModel.copyOutputToClipboard(entry)
                                }
                            },
                            onCopyInput: {
                                Task {
                                    await viewModel.copyInputToClipboard(entry)
                                }
                            },
                            onDelete: { viewModel.pendingDeleteHistoryEntry = entry }
                        )
                    }
                }

                if !isHistoryFiltering && viewModel.totalHistoryCount > viewModel.history.count {
                    Text("Showing the most recent \(viewModel.history.count) of \(viewModel.totalHistoryCount) saved runs.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.top, DesignSystem.Spacing.xs)
                }
            }
        }
        .padding(.top, DesignSystem.Spacing.lg)
    }
}

// MARK: - Transform history

private struct TransformHistoryEmptyState: View {
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignSystem.Colors.surfaceElevated))

            VStack(alignment: .leading, spacing: 3) {
                Text("No saved Transform runs yet")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Completed edits will appear here.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        }
    }
}

private struct TransformHistoryNoResultsState: View {
    let query: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignSystem.Colors.surfaceElevated))

            VStack(alignment: .leading, spacing: 3) {
                Text("No history matches \"\(query)\"")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Search checks Transform names, source apps, original text, and transformed text.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Button("Clear Search", action: onClear)
                .parakeetAction(.subtle)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        }
    }
}

private struct TransformHistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            TextField("Search Transform history", text: $text)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .parakeetAction(.subtle)
                .help("Clear search")
                .accessibilityLabel("Clear history search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct TransformHistoryRow: View {
    private static let todayTimeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let dateTimeFormat = Date.FormatStyle(date: .numeric, time: .shortened)

    let entry: TransformHistoryEntry
    let copiedTarget: TransformHistoryCopyTarget?
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onCopyOutput: () -> Void
    let onCopyInput: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            headerRow
            content
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(isHovered ? DesignSystem.Colors.surfaceElevated.opacity(0.7) : DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(isHovered ? DesignSystem.Colors.accent.opacity(0.25) : DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Copy Transformed", action: onCopyOutput)
            Button("Copy Original", action: onCopyInput)
            Button(isExpanded ? "Hide Details" : "Show Details", action: onToggleExpanded)
        }
        .animation(DesignSystem.Animation.hoverTransition, value: copiedTarget)
        .animation(DesignSystem.Animation.contentSwap, value: isExpanded)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            TransformSigilView(
                data: .from(
                    inputText: entry.inputText,
                    outputText: entry.outputText,
                    transformName: entry.transformName
                ),
                size: 32
            )

            Text(entry.transformName)
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text("·")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            Text(entry.sourceAppDisplayName)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("·")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            Text(formatTime(entry.createdAt))
                .font(DesignSystem.Typography.timestamp)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: DesignSystem.Spacing.sm)

            TransformHistoryCopyButton(
                title: "Copy",
                copiedTitle: "Copied",
                systemImage: "doc.on.doc",
                copiedSystemImage: "checkmark",
                isCopied: copiedTarget == .output,
                prominence: .primary,
                help: "Copy transformed result",
                action: onCopyOutput
            )

            TransformHistoryIconButton(
                systemImage: isExpanded ? "chevron.up" : "chevron.down",
                color: DesignSystem.Colors.textSecondary,
                help: isExpanded ? "Hide details" : "Show details",
                action: onToggleExpanded
            )

            TransformHistoryIconButton(
                systemImage: "trash",
                color: DesignSystem.Colors.textSecondary,
                help: "Delete history item",
                action: onDelete
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                if isExpanded {
                    TransformHistorySectionLabel("Transformed")
                }

                Text(entry.outputText)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(isExpanded ? nil : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isExpanded {
                Divider()
                    .overlay(DesignSystem.Colors.border.opacity(0.5))
                    .padding(.vertical, DesignSystem.Spacing.xs)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                        TransformHistorySectionLabel("Original")

                        Spacer(minLength: DesignSystem.Spacing.sm)

                        TransformHistoryCopyButton(
                            title: "Copy original",
                            copiedTitle: "Copied",
                            systemImage: "doc.text",
                            copiedSystemImage: "checkmark",
                            isCopied: copiedTarget == .input,
                            prominence: .inline,
                            help: "Copy original text",
                            action: onCopyInput
                        )
                    }

                    originalText(lineLimit: nil)
                }

                TransformHistoryMetaStrip(
                    llmDuration: formatMilliseconds(entry.llmElapsedMs),
                    totalDuration: formatMilliseconds(entry.totalElapsedMs)
                )
                .padding(.top, DesignSystem.Spacing.xs)
            } else {
                originalText(lineLimit: 2)
            }
        }
    }

    private func originalText(lineLimit: Int?) -> some View {
        Text(entry.inputText)
            .font(DesignSystem.Typography.bodySmall)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DesignSystem.Spacing.md)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DesignSystem.Colors.border)
                    .frame(width: 2)
            }
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(Calendar.current.isDateInToday(date) ? Self.todayTimeFormat : Self.dateTimeFormat)
    }

    private func formatMilliseconds(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)ms" }
        return String(format: "%.1fs", Double(value) / 1_000)
    }

}

private struct TransformHistorySectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(DesignSystem.Typography.micro)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
    }
}

private struct TransformHistoryMetaStrip: View {
    let llmDuration: String
    let totalDuration: String

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            TransformHistoryMetaChip(systemImage: "sparkles", text: "LLM \(llmDuration)")
            TransformHistoryMetaChip(systemImage: "timer", text: "Total \(totalDuration)")
        }
    }
}

private struct TransformHistoryMetaChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(DesignSystem.Typography.micro)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.72)))
            .overlay {
                Capsule()
                    .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
            }
    }
}

private struct TransformHistoryCopyButton: View {
    enum Prominence {
        case primary
        case inline
    }

    let title: String
    let copiedTitle: String
    let systemImage: String
    let copiedSystemImage: String
    let isCopied: Bool
    let prominence: Prominence
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isCopied ? copiedSystemImage : systemImage)
                    .font(.system(size: imageSize, weight: .semibold))
                    .frame(width: 14)

                Text(isCopied ? copiedTitle : title)
                    .font(labelFont)
                    .lineLimit(1)
            }
            .frame(minWidth: minWidth, minHeight: height)
            .padding(.horizontal, horizontalPadding)
            .foregroundStyle(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(isCopied ? copiedTitle : help)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .animation(DesignSystem.Animation.contentSwap, value: isCopied)
    }

    private var labelFont: Font {
        switch prominence {
        case .primary:
            return DesignSystem.Typography.caption.weight(.semibold)
        case .inline:
            return DesignSystem.Typography.micro.weight(.medium)
        }
    }

    private var imageSize: CGFloat {
        switch prominence {
        case .primary:
            return 13
        case .inline:
            return 11
        }
    }

    private var minWidth: CGFloat {
        switch prominence {
        case .primary:
            return 88
        case .inline:
            return 104
        }
    }

    private var height: CGFloat {
        switch prominence {
        case .primary:
            return 30
        case .inline:
            return 24
        }
    }

    private var horizontalPadding: CGFloat {
        switch prominence {
        case .primary:
            return 10
        case .inline:
            return 8
        }
    }

    private var cornerRadius: CGFloat {
        switch prominence {
        case .primary:
            return 8
        case .inline:
            return 7
        }
    }

    private var foregroundColor: Color {
        if isCopied { return DesignSystem.Colors.successGreen }
        return isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
    }

    private var backgroundColor: Color {
        if isCopied {
            return DesignSystem.Colors.successGreen.opacity(isHovered ? 0.18 : 0.12)
        }
        return DesignSystem.Colors.surfaceElevated.opacity(isHovered ? 0.92 : 0.62)
    }

    private var borderColor: Color {
        if isCopied {
            return DesignSystem.Colors.successGreen.opacity(isHovered ? 0.48 : 0.34)
        }
        return DesignSystem.Colors.border.opacity(isHovered ? 0.72 : 0.48)
    }
}

private struct TransformHistoryIconButton: View {
    let systemImage: String
    let color: Color
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .parakeetAction(.subtle)
        .foregroundStyle(isHovered ? DesignSystem.Colors.textPrimary : color)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

private extension TransformHistoryEntry {
    func matchesSearch(_ query: String) -> Bool {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !terms.isEmpty else { return true }

        let searchableText = [
            transformName,
            sourceAppDisplayName,
            sourceAppBundleID ?? "",
            inputText,
            outputText
        ].joined(separator: "\n")

        return terms.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - Transform card

private struct TransformCard: View {
    let transform: Prompt
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onEdit) {
                cardBody
            }
            .buttonStyle(.plain)
            .contextMenu {
                cardActionMenu
            }
            .accessibilityAction(named: transform.isBuiltIn ? "Reset Transform" : "Delete Transform") {
                if transform.isBuiltIn {
                    onReset()
                } else {
                    onDelete()
                }
            }

            cardActions
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.trailing, DesignSystem.Spacing.md)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .zIndex(1)
        }
        .onHover { isHovered = $0 }
        .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                if let shortcut = transform.shortcut {
                    KeycapBadge(shortcut: shortcut)
                } else {
                    UnboundShortcutChip()
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(transform.name)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text(firstSentence(of: transform.content))
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(isHovered ? DesignSystem.Colors.accent.opacity(0.35) : DesignSystem.Colors.border, lineWidth: 0.5)
        }
        .shadow(
            color: (isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest).color,
            radius: (isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest).radius,
            y: (isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest).y
        )
    }

    @ViewBuilder
    private var cardActions: some View {
        HStack(spacing: 4) {
            if transform.isBuiltIn {
                Button("Reset", action: onReset)
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                    .accessibilityLabel("Reset Transform")
            } else {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .parakeetAction(.subtle)
                .controlSize(.small)
                .help("Delete this Transform")
                .accessibilityLabel("Delete Transform")
            }
        }
    }

    @ViewBuilder
    private var cardActionMenu: some View {
        if transform.isBuiltIn {
            Button("Reset Transform", action: onReset)
        } else {
            Button("Delete Transform", role: .destructive, action: onDelete)
        }
    }

    private func firstSentence(of body: String) -> String {
        let trimmed = body
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let maxLength = 160

        for index in trimmed.indices where ".!?".contains(trimmed[index]) {
            let prefix = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard prefix.count >= 12 else { continue }
            return String(trimmed[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard trimmed.count > maxLength else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - Create-your-own tile

private struct CreateYourOwnTile: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isHovered ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
                Text("Create your own")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                Text("Open editor to create a prompt")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .center)
            .background(isHovered ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isHovered ? DesignSystem.Colors.accent.opacity(0.6) : DesignSystem.Colors.border,
                        style: StrokeStyle(lineWidth: 1.0, dash: [4, 4])
                    )
            }
            .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Keycap badge

struct KeycapBadge: View {
    let shortcut: TransformShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(orderedModifierGlyphs, id: \.self) { glyph in
                Text(glyph)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 6)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    }
            }
            Text(shortcut.displayKeyLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 6)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcutAccessibilityLabel)
    }

    private var orderedModifierGlyphs: [String] {
        // Canonical macOS order: ⌃ ⌥ ⇧ ⌘.
        let ordered: [TransformShortcut.ModifierFlag] = [.control, .option, .shift, .command]
        return ordered
            .filter { (shortcut.modifiers & $0.rawValue) != 0 }
            .map(\.displayGlyph)
    }

    private var shortcutAccessibilityLabel: String {
        let ordered: [TransformShortcut.ModifierFlag] = [.control, .option, .shift, .command]
        let modifierNames = ordered
            .filter { (shortcut.modifiers & $0.rawValue) != 0 }
            .map(\.displayName)
        return (modifierNames + [shortcut.displayKeyLabel]).joined(separator: " ")
    }
}

private struct UnboundShortcutChip: View {
    var body: some View {
        Text("No shortcut bound")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.5))
            .clipShape(Capsule())
    }
}
