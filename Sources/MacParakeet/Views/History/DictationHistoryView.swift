import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

            if viewModel.groupedDictations.isEmpty {
                emptyState
            } else {
                dictationList
            }

            if let error = viewModel.playbackError {
                playbackErrorBanner(error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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

    // MARK: - Header

    private var historyHeader: some View {
        let total = viewModel.groupedDictations.reduce(0) { $0 + $1.1.count }
        let isSearching = !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation History")
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(isSearching ? "Filtered voice records" : "All recorded dictations")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: DesignSystem.Spacing.sm)],
                spacing: DesignSystem.Spacing.sm
            ) {
                headerChip(
                    title: "Records",
                    value: "\(total)"
                )
                headerChip(
                    title: "Sections",
                    value: "\(viewModel.groupedDictations.count)"
                )
                if let playing = viewModel.playingDictation {
                    headerChip(
                        title: "Playback",
                        value: playing.durationMs.formattedDuration,
                        icon: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                    )
                } else {
                    headerChip(
                        title: "Playback",
                        value: "Idle",
                        icon: "waveform"
                    )
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
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

    private func headerChip(title: String, value: String, icon: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(DesignSystem.Typography.body.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
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
                     : "No matching records")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text(viewModel.searchText.isEmpty
                     ? "Press \(TriggerKey.current.displayName) to start dictating."
                     : "Try different words or clear your search.")
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
                    HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                        Text(dateHeader.uppercased())
                            .font(DesignSystem.Typography.sectionHeader)
                            .foregroundStyle(DesignSystem.Colors.accent.opacity(0.8))
                        Text("\(dictations.count)")
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                    }
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
    }

    // MARK: - Status Bars

    private func playbackErrorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(error)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated)
        .overlay(alignment: .top) { Divider() }
    }

    private func bottomBarPlayer(_ dictation: Dictation) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button {
                viewModel.togglePlayback(for: dictation)
            } label: {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: 32, height: 32)

                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.onAccent)
                        .offset(x: viewModel.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)

            Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                .lineLimit(1)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.playbackTrack)
                    Capsule()
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: max(0, geo.size.width * viewModel.playbackProgress))
                }
            }
            .frame(width: 140, height: DesignSystem.Layout.playbackBarHeight)

            Text(viewModel.playbackTimeString)
                .font(DesignSystem.Typography.timestamp)
                .foregroundStyle(.secondary)
                .fixedSize()

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
        .frame(height: 56)
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
            HStack(spacing: DesignSystem.Spacing.md) {
                SonicMandalaView(
                    data: .from(text: dictation.rawTranscript, durationMs: dictation.durationMs),
                    size: 32,
                    style: .monochrome
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(formatTime(dictation.createdAt))
                            .font(DesignSystem.Typography.timestamp)
                            .foregroundStyle(.secondary)

                        Text(dictation.durationMs.formattedDuration)
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.tertiary)

                        if dictation.audioPath != nil {
                            Text("Audio")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        }
                    }

                    HStack(spacing: 6) {
                        Text(dictation.processingMode == .clean ? "Clean mode" : "Raw mode")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.secondary)

                        if isCopied {
                            Text("Copied")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(DesignSystem.Colors.successGreen)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.12)))
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    if dictation.audioPath != nil {
                        CardActionButton(
                            icon: isPlayingThis ? "pause.fill" : "play.fill",
                            color: DesignSystem.Colors.accent,
                            action: { onTogglePlayback?() }
                        )
                    }

                    CardActionButton(
                        icon: isCopied ? "checkmark" : "doc.on.clipboard",
                        color: isCopied ? DesignSystem.Colors.successGreen : .secondary,
                        action: { onCopy() }
                    )
                    .animation(DesignSystem.Animation.hoverTransition, value: isCopied)

                    CardMenuButton(
                        hasAudio: dictation.audioPath != nil,
                        onDownloadAudio: { onDownloadAudio?() },
                        onDelete: { onDelete() }
                    )
                }
            }

            Text(highlightedTranscript)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    isPlayingThis ? DesignSystem.Colors.accent.opacity(0.24) : DesignSystem.Colors.border.opacity(0.5),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
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

// MARK: - Hover-Aware Action Button

private struct CardActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : color)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Hover-Aware Menu Button (AppKit NSMenu for reliable clicks)

private struct CardMenuButton: View {
    let hasAudio: Bool
    let onDownloadAudio: () -> Void
    let onDelete: () -> Void

    var body: some View {
        CardActionButton(icon: "ellipsis", color: .secondary) {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        if hasAudio {
            let downloadAction = onDownloadAudio
            menu.addItem(CallbackMenuItem(title: "Download Audio", icon: "arrow.down.circle", action: downloadAction))
            menu.addItem(.separator())
        }

        menu.addItem(CallbackMenuItem(title: "Delete", icon: "trash", isDestructive: true, action: onDelete))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// NSMenuItem subclass that invokes a Swift closure on click.
private final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.callback = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        if isDestructive {
            self.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { callback() }
}
