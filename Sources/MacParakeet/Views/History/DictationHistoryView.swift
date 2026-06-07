import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel
    @State private var deleteAlertCount = 0

    var body: some View {
        VStack(spacing: 0) {
            subTabPicker

            Group {
                switch viewModel.selectedSubTab {
                case .history:
                    historyTabContent
                case .stats:
                    DictationStatsView(viewModel: viewModel)
                }
            }
            .frame(maxHeight: .infinity)

            // Playback chrome only applies on the History tab.
            if viewModel.selectedSubTab == .history {
                if let error = viewModel.playbackError {
                    playbackErrorBanner(error)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let playing = viewModel.playingDictation {
                    bottomBarPlayer(playing)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search dictations...")
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.playingDictationId)
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.playbackError != nil)
        .animation(DesignSystem.Animation.contentSwap, value: viewModel.selectedSubTab)
        .onChange(of: viewModel.pendingDeleteCount) { _, count in
            if count > 0 {
                deleteAlertCount = count
            }
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { viewModel.pendingDeleteCount > 0 },
                set: { if !$0 { viewModel.cancelPendingDelete() } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingDelete()
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmPendingDelete()
            }
        } message: {
            Text(deleteAlertMessage)
        }
    }

    // MARK: - Sub-tab Picker

    private var subTabPicker: some View {
        HStack {
            DictationSubTabPicker(selection: $viewModel.selectedSubTab)
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    // MARK: - History Tab Content

    @ViewBuilder
    private var historyTabContent: some View {
        if viewModel.groupedDictations.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if viewModel.hasSelectedDictations {
                    selectedActionsBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                dictationList
            }
            .animation(DesignSystem.Animation.contentSwap, value: viewModel.hasSelectedDictations)
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
                     : "No matching records")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text(viewModel.searchText.isEmpty
                     ? (HotkeyTrigger.current.isDisabled
                        ? "Click the dictation pill or set a hotkey in Settings to start dictating."
                        : "Tap \(HotkeyTrigger.current.displayName) to start dictating from any app.")
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
                            .font(DesignSystem.Typography.bodySmall.weight(.semibold))
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
                            isSelected: viewModel.isDictationSelected(dictation),
                            onToggleSelection: { viewModel.toggleSelection(for: dictation) },
                            onTogglePlayback: { viewModel.togglePlayback(for: dictation) },
                            onCopy: {
                                viewModel.copyToClipboard(dictation)
                            },
                            onDelete: {
                                viewModel.pendingDeleteDictation = dictation
                            },
                            onDownloadAudio: { viewModel.downloadAudio(for: dictation) },
                            onToggleAIEdit: { viewModel.toggleDisplayRawTranscript(for: dictation) }
                        )
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.sm)
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.md)
        }
    }

    private var selectedActionsBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)

            Text("\(viewModel.selectedDictationCount) selected")
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
                .foregroundStyle(.primary)

            Spacer(minLength: DesignSystem.Spacing.md)

            Button {
                viewModel.selectAllVisibleDictations()
            } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            .disabled(viewModel.areAllVisibleDictationsSelected)
            .parakeetAction(.secondary)

            Button {
                viewModel.clearSelection()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .parakeetAction(.secondary)

            Button(role: .destructive) {
                viewModel.requestDeleteSelectedDictations()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .parakeetAction(.destructive)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated)
        .overlay(alignment: .bottom) { Divider() }
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

            Text(dictation.displayText)
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

    private var deleteAlertTitle: String {
        let count = displayedDeleteAlertCount
        return count > 1 ? "Delete \(count) Dictations?" : "Delete Dictation?"
    }

    private var deleteAlertMessage: String {
        let count = displayedDeleteAlertCount
        if count > 1 {
            return "These dictations and their audio files will be permanently deleted."
        }
        return "This dictation and its audio file will be permanently deleted."
    }

    private var displayedDeleteAlertCount: Int {
        deleteAlertCount > 0 ? deleteAlertCount : viewModel.pendingDeleteCount
    }
}

// MARK: - Card Row View

struct DictationCardRow: View {
    let dictation: Dictation
    var searchText: String = ""
    var isPlayingThis: Bool = false
    var isCopied: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onDownloadAudio: (() -> Void)?
    var onToggleAIEdit: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                SelectionToggleButton(isSelected: isSelected) {
                    onToggleSelection?()
                }

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
                    } else if dictation.displayRawTranscript && dictation.hasAIEdit {
                        // Subtle "raw" affordance so users can see at a glance
                        // which rows are showing the un-AI-edited transcript.
                        // Muted styling (not coral/green) to keep the row calm
                        // — this is a state indicator, not a CTA.
                        Text("Raw")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .accessibilityLabel("Showing raw transcript")
                            .transition(
                                .scale(scale: 0.6, anchor: .leading)
                                    .combined(with: .opacity)
                            )
                    }
                }
                .animation(DesignSystem.Animation.portalLift, value: dictation.displayRawTranscript)

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
                        hasAIEdit: dictation.hasAIEdit && onToggleAIEdit != nil,
                        isShowingRaw: dictation.displayRawTranscript,
                        onDownloadAudio: { onDownloadAudio?() },
                        onDelete: { onDelete() },
                        onToggleAIEdit: onToggleAIEdit
                    )
                }
            }

            Text(highlightedTranscript)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: dictation.displayRawTranscript)
        }
        .padding(DesignSystem.Spacing.md)
        .scaleEffect(isPlayingThis ? 1.005 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(cardFill)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    cardStroke,
                    lineWidth: isSelected ? 1 : 0.5
                )
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isPlayingThis)
        .animation(DesignSystem.Animation.selectionChange, value: isSelected)
    }

    private var cardFill: Color {
        if isSelected {
            return DesignSystem.Colors.accent.opacity(0.10)
        }
        if isPlayingThis {
            return DesignSystem.Colors.accent.opacity(0.06)
        }
        return DesignSystem.Colors.cardBackground
    }

    private var cardStroke: Color {
        if isSelected {
            return DesignSystem.Colors.accent.opacity(0.45)
        }
        if isPlayingThis {
            return DesignSystem.Colors.accent.opacity(0.24)
        }
        return DesignSystem.Colors.border.opacity(0.5)
    }

    // MARK: - Highlighted Transcript

    private var highlightedTranscript: AttributedString {
        let text = dictation.displayText
        let attributed = NSMutableAttributedString(string: text)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AttributedString(attributed) }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        // Apply the alpha inside a dynamic provider so the highlight re-resolves
        // on light/dark flip. Resolves `accent` under the supplied appearance,
        // then attaches alpha — keeps `DesignSystem.Colors.accent` as the single
        // source of truth without snapping to whatever appearance was current
        // when the attributed string was built.
        let highlightColor = NSColor(name: nil) { appearance in
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(DesignSystem.Colors.accent)
            }
            return resolved.withAlphaComponent(0.2)
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

// MARK: - Selection Toggle

private struct SelectionToggleButton: View {
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(iconColor)
        .help(isSelected ? "Deselect" : "Select")
        .accessibilityLabel(isSelected ? "Deselect dictation" : "Select dictation")
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        if isSelected {
            return DesignSystem.Colors.accent
        }
        return isHovered ? Color.primary : Color.secondary
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
    let hasAIEdit: Bool
    let isShowingRaw: Bool
    let onDownloadAudio: () -> Void
    let onDelete: () -> Void
    let onToggleAIEdit: (() -> Void)?

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
        }

        // Undo AI edit: only present rows whose cleaned text actually differs
        // from the raw STT output. Label flips so the menu item describes the
        // next action, not the current state.
        if hasAIEdit, let onToggleAIEdit {
            let title = isShowingRaw ? "Re-apply AI edit" : "Undo AI edit"
            let icon = isShowingRaw ? "wand.and.stars" : "arrow.uturn.backward"
            menu.addItem(CallbackMenuItem(title: title, icon: icon, action: onToggleAIEdit))
        }

        if !menu.items.isEmpty {
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
