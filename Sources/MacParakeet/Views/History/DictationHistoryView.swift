import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel
    @State private var isHistoryHeaderHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.groupedDictations.isEmpty {
                historyHeader
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.sm)
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

    // MARK: - Stats Header

    private var historyHeader: some View {
        let stats = viewModel.stats

        return VStack(alignment: .leading, spacing: 0) {
            // Title row
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Voice Stats")
                        .font(DesignSystem.Typography.sectionTitle)
                    if stats.isEmpty {
                        Text("Start dictating to see your stats")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Stat cards
            if !stats.isEmpty {
                expandedStatsPanel(stats)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isHistoryHeaderHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHistoryHeaderHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHistoryHeaderHovered = hovering
            }
        }
    }

    // MARK: - Stats Panel

    private func expandedStatsPanel(_ stats: DictationStats) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // 2x2 grid of stat cards
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
                ],
                spacing: DesignSystem.Spacing.sm
            ) {
                statCard(
                    label: "TOTAL WORDS",
                    value: stats.totalWords.compactFormatted,
                    subtitle: wordsComparison(stats),
                    icon: "text.word.spacing"
                )
                statCard(
                    label: "TIME SPEAKING",
                    value: stats.totalDurationMs.friendlyDuration,
                    subtitle: "\(stats.totalCount) dictation\(stats.totalCount == 1 ? "" : "s")",
                    icon: "clock"
                )
                statCard(
                    label: "VOICE SPEED",
                    value: stats.averageWPM.formattedWPM,
                    subtitle: wpmComparison(stats.averageWPM),
                    icon: "gauge.with.dots.needle.33percent"
                )
                statCard(
                    label: "TIME SAVED",
                    value: stats.timeSavedMs.friendlyDuration,
                    subtitle: "vs typing at 40 WPM",
                    icon: "bolt"
                )
            }

            // Streak / this week row
            if stats.weeklyStreak > 0 || stats.dictationsThisWeek > 0 {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if stats.weeklyStreak > 1 {
                        Label("\(stats.weeklyStreak)-week streak", systemImage: "flame.fill")
                            .font(DesignSystem.Typography.caption.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                    if stats.dictationsThisWeek > 0 {
                        Text("\(stats.dictationsThisWeek) this week")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // Fun comparison banner
            if let banner = funComparisonBanner(stats) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(banner)
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.accent)
                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accent.opacity(0.08))
                )
            }
        }
    }

    private func statCard(label: String, value: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(subtitle)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    // MARK: - Fun Comparisons

    private func wordsComparison(_ stats: DictationStats) -> String {
        if stats.totalWords >= 80_000 {
            let books = stats.booksEquivalent
            return String(format: "%.1f novel\(books >= 1.5 ? "s" : "") worth", books)
        } else if stats.totalWords >= 200 {
            let emails = Int(stats.emailsEquivalent)
            return "\(emails) email\(emails == 1 ? "" : "s") worth"
        }
        return "\(stats.totalWords) word\(stats.totalWords == 1 ? "" : "s") total"
    }

    private func wpmComparison(_ wpm: Double) -> String {
        switch wpm {
        case ..<80: return "Thoughtful pace"
        case 80..<120: return "Conversational pace"
        case 120..<160: return "Brisk speaker"
        case 160..<200: return "Fast talker"
        default: return "Lightning speed"
        }
    }

    private func funComparisonBanner(_ stats: DictationStats) -> String? {
        if stats.booksEquivalent >= 1.0 {
            return String(format: "You've dictated %.1f novel\(stats.booksEquivalent >= 1.5 ? "s" : "")!", stats.booksEquivalent)
        } else if stats.emailsEquivalent >= 50 {
            return "That's \(Int(stats.emailsEquivalent)) emails worth of voice!"
        } else if stats.totalWords >= 1000 {
            return "Over \(stats.totalWords.compactFormatted) words and counting!"
        }
        return nil
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
                     ? (HotkeyTrigger.current.isDisabled
                        ? "Click the dictation pill or set a hotkey in Settings to start dictating."
                        : "Double-tap \(HotkeyTrigger.current.displayName) to start dictating from any app.")
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
            historyHeader
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

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
                        .animation(.linear(duration: 0.12), value: viewModel.playbackProgress)
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
                    HStack(spacing: 0) {
                        Text(formatTime(dictation.createdAt))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)

                        Text("\u{2009}\u{00B7}\u{2009}")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.quaternary)

                        Text(dictation.durationMs.formattedDuration)
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.tertiary)

                        if dictation.audioPath != nil {
                            Text("\u{2009}\u{00B7}\u{2009}")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.quaternary)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if isCopied {
                        Text("Copied")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.12)))
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
        .scaleEffect(isPlayingThis ? 1.005 : 1.0)
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
        .animation(.easeInOut(duration: 0.15), value: isPlayingThis)
    }

    // MARK: - Highlighted Transcript

    private var highlightedTranscript: AttributedString {
        let text = dictation.cleanTranscript ?? dictation.rawTranscript
        let attributed = NSMutableAttributedString(string: text)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AttributedString(attributed) }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        let highlightColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 1.0, green: 0.54, blue: 0.36, alpha: 0.2)
                : NSColor(red: 0.91, green: 0.42, blue: 0.23, alpha: 0.2)
        }

        while searchRange.length > 0 {
            let found = nsText.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }

            attributed.addAttribute(.backgroundColor, value: highlightColor, range: found)

            let nextLocation = found.location + max(found.length, 1)
            guard nextLocation < nsText.length else { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return AttributedString(attributed)
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
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
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
            menu.addItem(CallbackMenuItem(title: "Export Audio", icon: "square.and.arrow.up", action: downloadAction))
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
