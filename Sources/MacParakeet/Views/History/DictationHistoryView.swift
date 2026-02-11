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

            // Playback error bar
            if let error = viewModel.playbackError {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surfaceElevated)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom bar player
            if let playing = viewModel.playingDictation {
                bottomBarPlayer(playing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search dictations...")
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.playingDictationId)
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.playbackError != nil)
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
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            MeditativeMerkabaView(size: 72, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                .opacity(0.4)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text(viewModel.searchText.isEmpty
                     ? "Your voice, captured."
                     : "Nothing matched.")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text(viewModel.searchText.isEmpty
                     ? "Press Fn to start dictating."
                     : "Try different words?")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Card-Based List

    private var dictationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.groupedDictations, id: \.0) { dateHeader, dictations in
                    // Date section header — accent colored
                    Text(dateHeader.uppercased())
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.top, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.sm)

                    ForEach(dictations) { dictation in
                        DictationCardRow(
                            dictation: dictation,
                            searchText: viewModel.searchText,
                            isPlayingThis: viewModel.playingDictationId == dictation.id && viewModel.isPlaying,
                            isCopied: viewModel.copiedDictationId == dictation.id,
                            onTogglePlayback: { viewModel.togglePlayback(for: dictation) },
                            onCopy: {
                                viewModel.copyToClipboard(dictation)
                                SoundManager.shared.play(.copyClick)
                            },
                            onDelete: {
                                viewModel.pendingDeleteDictation = dictation
                            },
                            onDownloadAudio: { viewModel.downloadAudio(for: dictation) }
                        )
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.sm)
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.md)
        }
        .textSelection(.enabled)
    }

    // MARK: - Bottom Bar Player

    private func bottomBarPlayer(_ dictation: Dictation) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Play/pause button
            Button {
                viewModel.togglePlayback(for: dictation)
            } label: {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.accent)
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
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.playbackTrack)
                    Capsule()
                        .fill(DesignSystem.Colors.accent)
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
                .fill(DesignSystem.Colors.surfaceElevated)
                .overlay(alignment: .top) {
                    Divider()
                }
        )
    }
}

// MARK: - Card Row View

struct DictationCardRow: View {
    let dictation: Dictation
    var searchText: String = ""
    var isPlayingThis: Bool = false
    var isCopied: Bool = false
    var onTogglePlayback: (() -> Void)?
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onDownloadAudio: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Top row: mandala + transcript text
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                // Sonic mandala thumbnail
                SonicMandalaView(
                    data: .from(text: dictation.rawTranscript, durationMs: dictation.durationMs),
                    size: 32,
                    style: .monochrome
                )

                // Transcript text — the star
                Text(highlightedTranscript)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Bottom row: metadata + actions
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(formatTime(dictation.createdAt))
                    .font(DesignSystem.Typography.timestamp)
                    .foregroundStyle(.secondary)

                Text(dictation.durationMs.formattedDuration)
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.tertiary)

                Spacer()

                // Always-visible actions
                HStack(spacing: 4) {
                    if dictation.audioPath != nil {
                        actionButton(
                            icon: isPlayingThis ? "pause.fill" : "play.fill",
                            color: DesignSystem.Colors.accent
                        ) {
                            onTogglePlayback?()
                        }
                    }

                    actionButton(
                        icon: isCopied ? "checkmark" : "doc.on.clipboard",
                        color: isCopied ? DesignSystem.Colors.successGreen : .secondary
                    ) {
                        onCopy()
                    }
                    .animation(DesignSystem.Animation.hoverTransition, value: isCopied)

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
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(isPlayingThis
                      ? DesignSystem.Colors.accent.opacity(0.06)
                      : DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isPlayingThis ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.5),
                    lineWidth: 0.5
                )
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

    // MARK: - Action Button

    private func actionButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
    }

    // MARK: - Highlighted Transcript

    private var highlightedTranscript: AttributedString {
        let text = dictation.cleanTranscript ?? dictation.rawTranscript
        var attributed = AttributedString(text)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return attributed }

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex {
            guard let range = attributed[searchStart...].range(
                of: query,
                options: .caseInsensitive
            ) else { break }

            attributed[range].backgroundColor = DesignSystem.Colors.accent.opacity(0.2)
            searchStart = range.upperBound
        }

        return attributed
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
