import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct TranscriptionLibraryView: View {
    @Bindable var viewModel: TranscriptionLibraryViewModel
    var title: String = "Library"
    var showsFilterBar: Bool = true
    var primaryActionTitle: String? = nil
    var onPrimaryAction: (() -> Void)? = nil
    var emptyTitle: String = "No transcriptions yet"
    var emptyMessage: String = "Transcribe a file or video link to get started."
    var onSelect: (Transcription) -> Void

    @State private var pendingDelete: Transcription?
    @State private var audioSaveErrorMessage: String?

    private var visibleLibraryFilters: [LibraryFilter] {
        LibraryFilter.allCases.filter { filter in
            AppFeatures.meetingRecordingEnabled || filter != .meeting
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer()

                if let primaryActionTitle, let onPrimaryAction {
                    LibraryPrimaryActionButton(title: primaryActionTitle, action: onPrimaryAction)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.lg)
            .padding(.bottom, DesignSystem.Spacing.sm)

            // Filter bar
            if showsFilterBar {
                HStack(spacing: 0) {
                    ForEach(visibleLibraryFilters, id: \.self) { filter in
                        LibraryFilterChip(
                            filter: filter,
                            isSelected: viewModel.filter == filter,
                            onTap: { viewModel.filter = filter }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.sm)
            }

            // Content — date-grouped list for meetings, thumbnail grid otherwise.
            // Reason: meetings have no thumbnail-worthy visual asset, so a list with
            // preview text + speaker count is denser and more useful than a wall of
            // waveform placeholders.
            if viewModel.isLoading && viewModel.filteredTranscriptions.isEmpty {
                loadingState
            } else if viewModel.filteredTranscriptions.isEmpty {
                emptyState
            } else if isMeetingListMode {
                meetingsList
            } else {
                thumbnailGrid
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search transcriptions")
        .onAppear {
            viewModel.loadTranscriptions()
        }
        .alert(
            "Delete Transcription?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let transcription = pendingDelete {
                    viewModel.deleteTranscription(transcription)
                    pendingDelete = nil
                }
            }
        } message: {
            if let pending = pendingDelete {
                Text("\"\(pending.fileName)\" will be permanently deleted.")
            }
        }
        .alert(
            "Save Failed",
            isPresented: Binding(
                get: { audioSaveErrorMessage != nil },
                set: { if !$0 { audioSaveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                audioSaveErrorMessage = nil
            }
        } message: {
            Text(audioSaveErrorMessage ?? "Unable to save meeting audio.")
        }
    }

    private var thumbnailGrid: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.md) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: DesignSystem.Layout.thumbnailCardMinWidth), spacing: DesignSystem.Spacing.md)],
                    spacing: DesignSystem.Spacing.md
                ) {
                    ForEach(viewModel.filteredTranscriptions) { transcription in
                        TranscriptionThumbnailCard(transcription: transcription, searchText: viewModel.searchText) {
                            onSelect(transcription)
                        } menuContent: {
                            libraryMenuItems(for: transcription)
                        }
                        .contextMenu {
                            libraryMenuItems(for: transcription)
                        }
                    }
                }
                loadMoreFooter
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private var meetingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.groupedTranscriptions, id: \.group) { section in
                    MeetingDateGroupHeader(group: section.group)
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, transcription in
                        MeetingRowCard(
                            transcription: transcription,
                            searchText: viewModel.searchText,
                            onTap: { onSelect(transcription) },
                            menuContent: { libraryMenuItems(for: transcription) }
                        )
                        if idx < section.items.count - 1 {
                            MeetingRowHairline()
                        }
                    }
                }
                loadMoreFooter
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.md)
            }
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    @ViewBuilder
    private func libraryMenuItems(for transcription: Transcription) -> some View {
        Button {
            onSelect(transcription)
        } label: {
            Label("Open", systemImage: "doc.text")
        }

        if transcription.sourceType == .meeting {
            let audioAvailable = MeetingAudioFile.isAvailable(for: transcription)

            Divider()

            Button {
                MeetingAudioActions.revealInFinder(transcription)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(!audioAvailable)
            .help(audioAvailable
                  ? "Reveal the meeting audio file in Finder"
                  : "Audio file is not available yet")

            Button {
                saveMeetingAudio(transcription)
            } label: {
                Label("Save Audio As…", systemImage: "square.and.arrow.down")
            }
            .disabled(!audioAvailable)
            .help(audioAvailable
                  ? "Save a copy of the meeting audio to a chosen location"
                  : "Audio file is not available yet")
        }

        Divider()

        Button {
            viewModel.toggleFavorite(transcription)
        } label: {
            Label(
                transcription.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: transcription.isFavorite ? "star.slash" : "star"
            )
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = transcription
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func saveMeetingAudio(_ transcription: Transcription) {
        Task { @MainActor in
            do {
                let outcome = try await MeetingAudioActions.runSaveAudioPanel(for: transcription)
                switch outcome {
                case .saved:
                    // The Save panel itself is the user-visible
                    // confirmation (it dismisses on success); a sound
                    // adds a non-blocking "your copy landed" signal
                    // without an extra popover in the Library.
                    SoundManager.shared.play(.transcriptionComplete)
                case .cancelled:
                    break
                case .sourceUnavailable:
                    audioSaveErrorMessage = "The meeting audio file is no longer available."
                }
            } catch {
                audioSaveErrorMessage = error.localizedDescription
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(viewModel.searchText.isEmpty
                 ? emptyStateTitle
                 : "No matching transcriptions")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(viewModel.searchText.isEmpty
                 ? emptyStateMessage
                 : "Try different words or clear your search.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if viewModel.hasMore {
            HStack {
                Spacer()
                Button {
                    viewModel.loadMoreTranscriptions()
                } label: {
                    Text(viewModel.isLoading ? "Loading..." : "Load More")
                }
                .parakeetAction(.secondary)
                .disabled(viewModel.isLoading)
                Spacer()
            }
        } else if viewModel.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    private var isMeetingListMode: Bool {
        viewModel.scope == .meetings || viewModel.filter == .meeting
    }

    private var emptyStateIcon: String {
        if !viewModel.searchText.isEmpty { return "magnifyingglass" }
        return isMeetingListMode ? "waveform.badge.mic" : "square.grid.2x2"
    }

    private var emptyStateTitle: String {
        isMeetingListMode ? "No meetings recorded yet" : emptyTitle
    }

    private var emptyStateMessage: String {
        isMeetingListMode
            ? "Press Record Meeting on the Transcribe tab to capture system audio and transcribe locally."
            : emptyMessage
    }
}

// MARK: - Library filter chip

/// One pill in the Library filter bar (All / Video / Local / Meetings /
/// Favorites). Three-tier visual hierarchy keeps "hovered" clearly subordinate
/// to "selected": idle is plain text, hover adds a faint *neutral* wash and
/// brightens the label toward primary, and only the selected chip wears the
/// coral pill + coral text. Hover deliberately avoids the accent so it never
/// masquerades as the active filter. Owns its own `isHovered` so each chip in
/// the `ForEach` tracks the cursor independently — matching the hover idiom used
/// by the Browse Files and Start buttons.
private struct LibraryFilterChip: View {
    let filter: LibraryFilter
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        if isSelected { return DesignSystem.Colors.accent }
        return isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
    }

    private var fill: Color {
        if isSelected { return DesignSystem.Colors.accent.opacity(0.12) }
        return isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : .clear
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(filter.rawValue)
                    .font(DesignSystem.Typography.bodySmall.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 8)
            .background(Capsule().fill(fill))
            .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
            .animation(DesignSystem.Animation.hoverTransition, value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// The Library header's primary "New Transcription" CTA — a filled coral capsule
/// with a create glyph and a soft coral shadow that lifts on hover. Filled (not
/// outline) because it's the single highest-priority action on the surface, and
/// it carries the same hover idiom (scale + pointing-hand cursor) as the other
/// polished buttons so the header reads as one system.
private struct LibraryPrimaryActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            }
            .foregroundStyle(DesignSystem.Colors.onAccent)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 9)
            .background(Capsule().fill(DesignSystem.Colors.accent))
            .shadow(
                color: DesignSystem.Colors.accent.opacity(isHovered ? 0.45 : 0.26),
                radius: isHovered ? 12 : 6,
                x: 0,
                y: isHovered ? 5 : 3
            )
            .scaleEffect(isHovered ? 1.035 : 1.0)
            .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(title)
        .accessibilityHint("Starts a new transcription")
    }
}
