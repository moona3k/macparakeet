import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.groupedDictations.isEmpty {
                emptyState
            } else {
                dictationList
            }

            // Bottom bar player
            if let playing = viewModel.playingDictation {
                bottomBarPlayer(playing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search dictations...")
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.playingDictationId)
        .alert(
            "Delete Dictation?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteDictation != nil },
                set: { if !$0 { viewModel.pendingDeleteDictation = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteDictation = nil
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            Text("This dictation and its audio file will be permanently deleted.")
        }
    }

    // MARK: - Empty State

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
        .frame(maxWidth: .infinity)
    }

    // MARK: - Flat List

    private var dictationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.groupedDictations, id: \.0) { dateHeader, dictations in
                    // Date section header
                    Text(dateHeader.uppercased())
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.top, DesignSystem.Spacing.md)
                        .padding(.bottom, DesignSystem.Spacing.xs)

                    ForEach(Array(dictations.enumerated()), id: \.element.id) { index, dictation in
                        DictationRowView(
                            dictation: dictation,
                            isPlayingThis: viewModel.playingDictationId == dictation.id && viewModel.isPlaying,
                            onTogglePlayback: { viewModel.togglePlayback(for: dictation) },
                            onCopy: { viewModel.copyToClipboard(dictation) },
                            onDelete: {
                                viewModel.pendingDeleteDictation = dictation
                            },
                            onDownloadAudio: { viewModel.downloadAudio(for: dictation) }
                        )

                        if index < dictations.count - 1 {
                            Divider()
                                .padding(.leading, 56 + DesignSystem.Spacing.sm + DesignSystem.Spacing.lg)
                                .padding(.trailing, DesignSystem.Spacing.lg)
                        }
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.sm)
        }
    }

    // MARK: - Bottom Bar Player

    private func bottomBarPlayer(_ dictation: Dictation) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Play/pause button — accent-filled circle
            Button {
                viewModel.togglePlayback(for: dictation)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 32, height: 32)

                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: viewModel.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)

            // Transcript snippet
            Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.playbackTrack)
                    Capsule()
                        .fill(DesignSystem.Colors.playbackFill)
                        .frame(width: max(0, geo.size.width * viewModel.playbackProgress))
                }
            }
            .frame(width: 120, height: DesignSystem.Layout.playbackBarHeight)

            // Time display
            Text(viewModel.playbackTimeString)
                .font(DesignSystem.Typography.timestamp)
                .foregroundStyle(.secondary)
                .fixedSize()

            // Close button
            Button {
                viewModel.stopPlayback()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .frame(height: 52)
        .background(
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .top) {
                    Divider()
                }
        )
    }
}

// MARK: - Row View

struct DictationRowView: View {
    let dictation: Dictation
    var isPlayingThis: Bool = false
    var onTogglePlayback: (() -> Void)?
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onDownloadAudio: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            // Timestamp + duration column
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTime(dictation.createdAt))
                    .font(DesignSystem.Typography.timestamp)
                    .foregroundStyle(.secondary)

                Text(dictation.durationMs.formattedDuration)
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 56, alignment: .trailing)

            // Transcript text — full, no line limit
            Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hover actions
            if isHovered {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if dictation.audioPath != nil {
                        Button {
                            onTogglePlayback?()
                        } label: {
                            Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Menu {
                        if dictation.audioPath != nil {
                            Button {
                                onDownloadAudio?()
                            } label: {
                                Label("Download Audio", systemImage: "arrow.down.circle")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isPlayingThis
                    ? Color.accentColor.opacity(0.06)
                    : isHovered
                        ? DesignSystem.Colors.rowHoverBackground
                        : .clear)
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if dictation.audioPath != nil {
                Button {
                    onTogglePlayback?()
                } label: {
                    Label(isPlayingThis ? "Pause" : "Play", systemImage: isPlayingThis ? "pause.fill" : "play.fill")
                }
            }
            Button("Copy") { onCopy() }
                .keyboardShortcut("c", modifiers: .command)
            if dictation.audioPath != nil {
                Button {
                    onDownloadAudio?()
                } label: {
                    Label("Download Audio", systemImage: "arrow.down.circle")
                }
            }
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
