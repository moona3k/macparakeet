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
    var emptyMessage: String = "Transcribe a file or YouTube video to get started."
    var onSelect: (Transcription) -> Void

    @State private var pendingDelete: Transcription?

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
                    Button(primaryActionTitle, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.accent)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.lg)
            .padding(.bottom, DesignSystem.Spacing.sm)

            // Filter bar
            if showsFilterBar {
                HStack(spacing: 0) {
                    ForEach(visibleLibraryFilters, id: \.self) { filter in
                        Button {
                            viewModel.filter = filter
                        } label: {
                            Text(filter.rawValue)
                                .font(DesignSystem.Typography.bodySmall.weight(
                                    viewModel.filter == filter ? .semibold : .regular
                                ))
                                .padding(.horizontal, DesignSystem.Spacing.md)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(viewModel.filter == filter
                                              ? DesignSystem.Colors.accent.opacity(0.12)
                                              : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(viewModel.filter == filter ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
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

            // Grid
            if viewModel.filteredTranscriptions.isEmpty {
                emptyState
            } else {
                ScrollView {
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
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.lg)
                }
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
    }

    @ViewBuilder
    private func libraryMenuItems(for transcription: Transcription) -> some View {
        Button {
            onSelect(transcription)
        } label: {
            Label("Open", systemImage: "doc.text")
        }

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

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()
            Image(systemName: viewModel.searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(viewModel.searchText.isEmpty
                 ? emptyTitle
                 : "No matching transcriptions")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(viewModel.searchText.isEmpty
                 ? emptyMessage
                 : "Try different words or clear your search.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
