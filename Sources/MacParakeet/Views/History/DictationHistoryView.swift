import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        HStack(spacing: 0) {
            // List pane
            listPane
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Divider()

            // Detail pane
            detailPane
                .frame(minWidth: 300, maxWidth: .infinity)
                .animation(DesignSystem.Animation.contentSwap, value: viewModel.selectedDictation?.id)
        }
    }

    private var listPane: some View {
        NavigationStack {
            if viewModel.groupedDictations.isEmpty {
                emptyState
            } else {
                dictationList
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search dictations...")
    }

    private var detailPane: some View {
        Group {
            if let selected = viewModel.selectedDictation {
                DictationDetailView(
                    dictation: selected,
                    isPlaying: viewModel.playingDictationId == selected.id && viewModel.isPlaying,
                    playbackProgress: viewModel.playingDictationId == selected.id ? viewModel.playbackProgress : 0,
                    playbackTimeString: viewModel.playingDictationId == selected.id ? viewModel.playbackTimeString : nil,
                    onTogglePlayback: { viewModel.togglePlayback(for: selected) },
                    onDelete: {
                        withAnimation(DesignSystem.Animation.contentSwap) {
                            viewModel.deleteDictation(selected)
                        }
                    },
                    onCopy: {
                        viewModel.copyToClipboard(selected)
                    }
                )
            } else {
                detailEmptyState
            }
        }
    }

    private var detailEmptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            MeditativeMerkabaView(size: 48, revolutionDuration: 8.0)
            Text("Select a dictation to view details")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            MeditativeMerkabaView(size: 56, revolutionDuration: 8.0)
            Text(viewModel.searchText.isEmpty ? "No dictations yet" : "No results found")
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty ? "Press Fn to start dictating" : "Try a different search term")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var dictationList: some View {
        List(selection: Binding(
            get: { viewModel.selectedDictation?.id },
            set: { newId in
                withAnimation(DesignSystem.Animation.selectionChange) {
                    viewModel.selectedDictation = viewModel.groupedDictations
                        .flatMap(\.1)
                        .first { $0.id == newId }
                }
            }
        )) {
            ForEach(viewModel.groupedDictations, id: \.0) { dateHeader, dictations in
                Section(dateHeader) {
                    ForEach(dictations) { dictation in
                        DictationRowView(
                            dictation: dictation,
                            isSelected: viewModel.selectedDictation?.id == dictation.id,
                            isPlayingThis: viewModel.playingDictationId == dictation.id && viewModel.isPlaying,
                            onTogglePlayback: { viewModel.togglePlayback(for: dictation) },
                            onCopy: { viewModel.copyToClipboard(dictation) },
                            onDelete: {
                                withAnimation(DesignSystem.Animation.contentSwap) {
                                    viewModel.deleteDictation(dictation)
                                }
                            }
                        )
                        .tag(dictation.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.groupedDictations.map(\.0))
    }
}

// MARK: - Row View

struct DictationRowView: View {
    let dictation: Dictation
    var isSelected: Bool = false
    var isPlayingThis: Bool = false
    var onTogglePlayback: (() -> Void)?
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Leading accent bar on selection
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
                .opacity(isSelected ? 1 : 0)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(alignment: .center) {
                    Text(formatTime(dictation.createdAt))
                        .font(DesignSystem.Typography.timestamp)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Duration pill
                    Text(dictation.durationMs.formattedDuration)
                        .font(DesignSystem.Typography.duration)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.05))
                        )
                }

                if !dictation.rawTranscript.isEmpty {
                    Text(dictation.rawTranscript)
                        .lineLimit(2)
                        .font(.body)
                        .foregroundStyle(.primary)
                }

                // Hover-reveal action buttons
                if isHovered {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if dictation.audioPath != nil {
                            Button {
                                onTogglePlayback?()
                            } label: {
                                Label(
                                    isPlayingThis ? "Pause" : "Play",
                                    systemImage: isPlayingThis ? "pause.fill" : "play.fill"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }

                        Spacer()

                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.clipboard")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, DesignSystem.Spacing.sm)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isHovered && !isSelected ? DesignSystem.Colors.rowHoverBackground : .clear)
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Copy") { onCopy() }
                .keyboardShortcut("c", modifiers: .command)
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
