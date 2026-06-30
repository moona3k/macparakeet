import AppKit
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
    @State private var pendingDeleteAudio: Transcription?
    @State private var audioSaveErrorMessage: String?
    @State private var showingBulkExportOptions = false
    @AppStorage("com.macparakeet.libraryBulkExportFormat")
    private var selectedBulkExportFormatRawValue = TranscriptExportFormat.txt.rawValue
    @AppStorage("com.macparakeet.libraryBulkExportIncludeTimestamps")
    private var bulkExportIncludeTimestamps = true
    @AppStorage("com.macparakeet.libraryBulkExportIncludeSpeakerLabels")
    private var bulkExportIncludeSpeakerLabels = true
    @AppStorage("com.macparakeet.libraryBulkExportIncludeMetadata")
    private var bulkExportIncludeMetadata = true
    @State private var bulkExportInProgress = false
    @State private var bulkExportResult: BulkTranscriptExportResult?
    @State private var bulkExportErrorMessage: String?
    @State private var bulkExportCoordinatorTask: Task<Void, Never>?
    @State private var bulkExportWorkerTask: Task<BulkTranscriptExportResult, Error>?
    @State private var bulkExportRunID = UUID()
    @FocusState private var selectionKeyboardFocused: Bool

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

                if showsSelectManyButton {
                    LibrarySelectManyButton {
                        viewModel.beginBulkSelection()
                    }
                }

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

            if viewModel.isBulkSelectionModeEnabled {
                selectionActionsBar
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .focusable(viewModel.isBulkSelectionModeEnabled)
        .focused($selectionKeyboardFocused)
        // Keep keyboard focus (for ⌘A / Delete) but suppress the system focus
        // ring. The ring is drawn in the system accent (blue), reads as a
        // full-width line across the content's top edge on entering selection
        // mode, and its first-responder draw is the hitch felt as "jank".
        .focusEffectDisabled(viewModel.isBulkSelectionModeEnabled)
        .onChange(of: viewModel.isBulkSelectionModeEnabled) { _, enabled in
            if enabled {
                selectionKeyboardFocused = true
            }
        }
        .animation(.easeInOut(duration: 0.16), value: viewModel.isBulkSelectionModeEnabled)
        .onKeyPress(keys: ["a", "A", .delete, .deleteForward]) { press in
            handleSelectionKeyPress(press)
        }
        .onAppear {
            viewModel.loadTranscriptions()
        }
        .alert(
            pendingDelete.map(singleDeleteTitle) ?? "Delete Transcription?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
            Button(pendingDelete.map(singleDeleteConfirmTitle) ?? "Delete", role: .destructive) {
                if let transcription = pendingDelete {
                    viewModel.deleteTranscription(transcription)
                    pendingDelete = nil
                }
            }
        } message: {
            if let pending = pendingDelete {
                Text(singleDeleteMessage(for: pending))
            }
        }
        .alert(
            MeetingDeletionCopy.audioOnlyAlertTitle,
            isPresented: Binding(
                get: { pendingDeleteAudio != nil },
                set: { if !$0 { pendingDeleteAudio = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeleteAudio = nil
            }
            Button(MeetingDeletionCopy.audioOnlyConfirmTitle, role: .destructive) {
                if let transcription = pendingDeleteAudio {
                    viewModel.deleteMeetingAudio(transcription)
                    pendingDeleteAudio = nil
                }
            }
        } message: {
            Text(MeetingDeletionCopy.singleAudioOnlyMessage(surface: .library))
        }
        .alert(
            bulkOperationTitle,
            isPresented: Binding(
                get: { viewModel.pendingBulkOperation != nil },
                set: { if !$0 { viewModel.cancelPendingBulkOperation() } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingBulkOperation()
            }
            Button(bulkOperationConfirmTitle, role: .destructive) {
                // Capture the operation synchronously. Tapping this button also
                // dismisses the alert, whose isPresented setter runs
                // cancelPendingBulkOperation() and nils pendingBulkOperation —
                // and that dismissal fires before the deferred Task body. Reading
                // the VM state inside the Task would therefore see nil and
                // silently no-op (the "delete does nothing" bug). Snapshot here.
                guard let operation = viewModel.pendingBulkOperation else { return }
                Task {
                    await viewModel.confirmBulkOperation(operation)
                }
            }
        } message: {
            if let operation = viewModel.pendingBulkOperation {
                Text(bulkOperationMessage(for: operation))
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
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { bulkExportErrorMessage != nil },
                set: { if !$0 { bulkExportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                bulkExportErrorMessage = nil
            }
        } message: {
            Text(bulkExportErrorMessage ?? "Unable to export selected transcripts.")
        }
        .popover(item: $bulkExportResult, arrowEdge: .top) { result in
            bulkExportConfirmationPopover(result)
        }
        .onDisappear {
            cancelBulkExport()
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
                        TranscriptionThumbnailCard(
                            transcription: transcription,
                            searchText: viewModel.searchText,
                            isSelected: viewModel.isTranscriptionSelected(transcription),
                            showsSelectionControls: viewModel.isBulkSelectionModeEnabled
                        ) {
                            if viewModel.isBulkOperationInProgress || bulkExportInProgress {
                                return
                            }
                            if viewModel.isBulkSelectionModeEnabled {
                                viewModel.toggleSelection(for: transcription)
                            } else {
                                onSelect(transcription)
                            }
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
            .padding(.top, DesignSystem.Spacing.md)
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
                            isSelected: viewModel.isTranscriptionSelected(transcription),
                            showsSelectionControls: viewModel.isBulkSelectionModeEnabled,
                            onTap: {
                                if viewModel.isBulkOperationInProgress || bulkExportInProgress {
                                    return
                                }
                                if viewModel.isBulkSelectionModeEnabled {
                                    viewModel.toggleSelection(for: transcription)
                                } else {
                                    onSelect(transcription)
                                }
                            },
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

        if !viewModel.isBulkSelectionModeEnabled {
            Button {
                viewModel.beginBulkSelection(startingWith: transcription)
            } label: {
                Label("Select Many...", systemImage: "checklist")
            }
        }

        if transcription.sourceType == .meeting {
            let audioState = MeetingAudioFile.state(for: transcription)
            let audioAvailable = audioState == .saved
            let artifactAvailable = MeetingArtifactActions.folderURL(for: transcription) != nil

            Divider()

            Button {
                MeetingArtifactActions.openFolder(for: transcription)
            } label: {
                Label("Open Meeting Folder", systemImage: "folder")
            }
            .disabled(!artifactAvailable)
            .help(artifactAvailable
                  ? "Open the meeting artifact folder in Finder"
                  : "Meeting artifact folder is not available")

            Button {
                MeetingArtifactActions.copyFolderPath(for: transcription)
            } label: {
                Label("Copy Artifact Folder Path", systemImage: "doc.on.doc")
            }
            .disabled(!artifactAvailable)
            .help(artifactAvailable
                  ? "Copy the meeting artifact folder path"
                  : "Meeting artifact folder is not available")

            Divider()

            Button {
                MeetingAudioActions.revealInFinder(transcription)
            } label: {
                Label("Show Audio in Finder", systemImage: "waveform")
            }
            .disabled(!audioAvailable)
            .help(audioAvailable
                  ? "Reveal the meeting audio file in Finder"
                  : MeetingDeletionCopy.audioUnavailableHelp(for: audioState))

            Button {
                saveMeetingAudio(transcription)
            } label: {
                Label("Save Audio As…", systemImage: "square.and.arrow.down")
            }
            .disabled(!audioAvailable)
            .help(audioAvailable
                  ? "Save a copy of the meeting audio to a chosen location"
                  : MeetingDeletionCopy.audioUnavailableHelp(for: audioState))

            Button(role: .destructive) {
                pendingDeleteAudio = transcription
            } label: {
                Label(MeetingDeletionCopy.audioOnlyMenuTitle, systemImage: "waveform.slash")
            }
            .disabled(!audioAvailable)
            .help(audioAvailable
                  ? "Remove the saved meeting audio while keeping the meeting"
                  : MeetingDeletionCopy.audioUnavailableHelp(for: audioState))
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
            Label(transcription.sourceType == .meeting ? MeetingDeletionCopy.fullDeleteMenuTitle : "Delete", systemImage: "trash")
        }
    }

    private var selectionActionsBar: some View {
        BulkTranscriptionSelectionBar(
            selectedCount: viewModel.selectedTranscriptionCount,
            selectedMeetingAudioCount: viewModel.selectedMeetingAudioCount,
            isMeetingContext: isMeetingListMode,
            areAllVisibleSelected: viewModel.areAllLoadedVisibleTranscriptionsSelected,
            isPerformingOperation: viewModel.isBulkOperationInProgress || bulkExportInProgress,
            operationLabel: bulkExportInProgress ? "Exporting..." : "Deleting...",
            onSelectVisible: { viewModel.selectLoadedVisibleTranscriptions() },
            onClear: { viewModel.clearSelection() },
            onCancel: { viewModel.exitBulkSelection() },
            onExport: { showingBulkExportOptions = true },
            onDeleteAudioOnly: { viewModel.requestDeleteSelectedMeetingAudio() },
            onDeleteItems: { viewModel.requestDeleteSelectedItems() }
        )
        .popover(isPresented: $showingBulkExportOptions, arrowEdge: .top) {
            bulkExportOptionsPopover
        }
    }

    private var showsSelectManyButton: Bool {
        !viewModel.isBulkSelectionModeEnabled && !viewModel.filteredTranscriptions.isEmpty
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

    // Static so the completeness check runs once at first use rather than
    // allocating two Sets on every body re-render (the popover re-renders on
    // each format selection).
    private static let bulkExportFormatOrder: [TranscriptExportFormat] = {
        let preferredOrder: [TranscriptExportFormat] = [.txt, .md, .srt, .vtt, .json, .pdf, .docx]
        precondition(
            preferredOrder.count == TranscriptExportFormat.allCases.count &&
                Set(preferredOrder) == Set(TranscriptExportFormat.allCases),
            "Bulk export format order must include every TranscriptExportFormat case"
        )
        return preferredOrder
    }()

    private var selectedBulkExportFormat: TranscriptExportFormat {
        get {
            TranscriptExportFormat(rawValue: selectedBulkExportFormatRawValue) ?? .txt
        }
        nonmutating set {
            selectedBulkExportFormatRawValue = newValue.rawValue
        }
    }

    private var bulkExportOptions: TranscriptExportOptions {
        TranscriptExportOptions(
            includeTimestamps: bulkExportIncludeTimestamps,
            includeSpeakerLabels: bulkExportIncludeSpeakerLabels,
            includeMetadata: bulkExportIncludeMetadata
        )
    }

    private var isBulkExportActionDisabled: Bool {
        viewModel.selectedTranscriptionCount == 0 ||
            bulkExportInProgress ||
            viewModel.isBulkOperationInProgress
    }

    private var bulkExportOptionsPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Export Selected", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.body.bold())

                Spacer()

                Button {
                    showingBulkExportOptions = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export options")
            }

            Text(
                "\(viewModel.selectedTranscriptionCount) \(viewModel.selectedTranscriptionCount == 1 ? "item" : "items")"
            )
            .font(DesignSystem.Typography.caption.weight(.medium))
            .foregroundStyle(DesignSystem.Colors.textSecondary)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Format")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Self.bulkExportFormatOrder) { format in
                        Button {
                            selectedBulkExportFormat = format
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: format.iconName)
                                    .frame(width: 16)
                                Text(format.shortName)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .font(DesignSystem.Typography.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        selectedBulkExportFormat == format
                                            ? DesignSystem.Colors.accent.opacity(0.14)
                                            : DesignSystem.Colors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        selectedBulkExportFormat == format
                                            ? DesignSystem.Colors.accent.opacity(0.7)
                                            : DesignSystem.Colors.border.opacity(0.7),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(format.displayName)
                        .accessibilityValue(selectedBulkExportFormat == format ? "Selected" : "")
                    }
                }
            }

            if selectedBulkExportFormat.supportsTranscriptOptions {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Options")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    Toggle("Include timestamps when available", isOn: $bulkExportIncludeTimestamps)
                    Toggle("Include speaker labels when available", isOn: $bulkExportIncludeSpeakerLabels)
                    Toggle("Include metadata", isOn: $bulkExportIncludeMetadata)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    showingBulkExportOptions = false
                    runBulkExport()
                } label: {
                    Label("Choose Folder...", systemImage: "folder")
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBulkExportActionDisabled)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 390)
    }

    @ViewBuilder
    private func bulkExportConfirmationPopover(_ result: BulkTranscriptExportResult) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.isCompleteSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(
                        result.isCompleteSuccess ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bulkExportResultTitle(result))
                        .font(DesignSystem.Typography.body.bold())
                    Text(result.directory.lastPathComponent)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if result.failedCount > 0 {
                        Text("\(result.failedCount) \(result.failedCount == 1 ? "file" : "files") failed.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.warningAmber)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    bulkExportResult = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export confirmation")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(result.exportedURLs)
                bulkExportResult = nil
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(DesignSystem.Typography.caption)
            }
            .parakeetAction(.secondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(minWidth: 240)
    }

    private func bulkExportResultTitle(_ result: BulkTranscriptExportResult) -> String {
        if result.isCompleteSuccess {
            return
                "Exported \(result.exportedCount) \(result.format.shortName) \(result.exportedCount == 1 ? "file" : "files")"
        }
        if result.exportedCount > 0 {
            return "Exported \(result.exportedCount) of \(result.requestedCount)"
        }
        preconditionFailure("Bulk export result popover should only be shown after at least one file exports")
    }

    private func runBulkExport() {
        let targets = viewModel.selectedLoadedTranscriptionsForExport
        guard !targets.isEmpty else { return }
        guard !isBulkExportActionDisabled else { return }

        cancelBulkExport()
        let outcome = runBulkExportFolderPanel()
        guard case .selected(let directory) = outcome else { return }

        let runID = UUID()
        let format = selectedBulkExportFormat
        let options = bulkExportOptions

        bulkExportRunID = runID
        bulkExportInProgress = true
        bulkExportErrorMessage = nil
        bulkExportResult = nil

        bulkExportCoordinatorTask = Task { @MainActor in
            defer {
                finishBulkExportRun(runID)
            }

            do {
                await Task.yield()
                guard bulkExportRunID == runID, !Task.isCancelled else { return }

                let exportTask = Task.detached(priority: .userInitiated) {
                    try await TranscriptResultActions.exportTranscriptsToDirectory(
                        transcriptions: targets,
                        format: format,
                        options: options,
                        directory: directory
                    )
                }
                bulkExportWorkerTask = exportTask
                let result = try await withTaskCancellationHandler {
                    try await exportTask.value
                } onCancel: {
                    exportTask.cancel()
                }
                guard bulkExportRunID == runID else { return }
                bulkExportWorkerTask = nil

                guard result.exportedCount > 0 else {
                    bulkExportErrorMessage = result.firstErrorDescription ?? "No files were exported."
                    SoundManager.shared.play(.errorSoft)
                    return
                }

                SoundManager.shared.play(result.isCompleteSuccess ? .transcriptionComplete : .errorSoft)
                bulkExportResult = result
            } catch is CancellationError {
                guard bulkExportRunID == runID else { return }
            } catch {
                guard bulkExportRunID == runID else { return }
                bulkExportErrorMessage = error.localizedDescription
                SoundManager.shared.play(.errorSoft)
            }
        }
    }

    @MainActor
    private func finishBulkExportRun(_ runID: UUID) {
        guard bulkExportRunID == runID else { return }
        bulkExportInProgress = false
        bulkExportCoordinatorTask = nil
        bulkExportWorkerTask = nil
    }

    @MainActor
    private func cancelBulkExport() {
        bulkExportCoordinatorTask?.cancel()
        bulkExportCoordinatorTask = nil
        bulkExportWorkerTask?.cancel()
        bulkExportWorkerTask = nil
        bulkExportInProgress = false
        bulkExportResult = nil
        bulkExportErrorMessage = nil
        bulkExportRunID = UUID()
    }

    private enum BulkExportFolderOutcome: Sendable {
        case selected(URL)
        case cancelled
    }

    // Synchronous app-modal panel, matching MeetingAudioActions.runSaveAudioPanel
    // and DictationHistoryViewModel. It runs before the async export coordinator
    // starts, so no Task is suspended inside the modal interaction.
    @MainActor
    private func runBulkExportFolderPanel() -> BulkExportFolderOutcome {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Export"
        panel.message = "Choose a folder for the selected transcript files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }

        guard panel.runModal() == .OK, let directory = panel.url else { return .cancelled }
        return .selected(directory)
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

    private var bulkOperationTitle: String {
        guard let operation = viewModel.pendingBulkOperation else { return "Delete Items?" }
        if operation.isDeleteAudioOnly {
            return MeetingDeletionCopy.audioOnlyAlertTitle
        }
        if operation.meetingCount == operation.targetCount, operation.targetCount == 1 {
            return MeetingDeletionCopy.fullDeleteAlertTitle
        }
        if operation.meetingCount == operation.targetCount {
            return "Delete Meetings?"
        }
        return "Delete Items?"
    }

    private var bulkOperationConfirmTitle: String {
        guard let operation = viewModel.pendingBulkOperation else { return "Delete" }
        if operation.isDeleteAudioOnly {
            return MeetingDeletionCopy.audioOnlyConfirmTitle
        }
        if operation.meetingCount == operation.targetCount {
            return operation.targetCount == 1 ? MeetingDeletionCopy.fullDeleteConfirmTitle : "Delete Meetings"
        }
        return "Delete Items"
    }

    private func bulkOperationMessage(for operation: BulkTranscriptionOperation) -> String {
        if operation.isDeleteAudioOnly {
            return MeetingDeletionCopy.bulkAudioOnlyMessage(
                count: operation.targetCount,
                skippedCount: operation.skippedCount,
                surface: .library
            )
        }

        if operation.meetingCount > 0 {
            if operation.meetingCount == operation.targetCount {
                return MeetingDeletionCopy.bulkFullDeleteMessage(count: operation.targetCount)
            }
            return MeetingDeletionCopy.mixedBulkFullDeleteMessage(
                totalCount: operation.targetCount,
                meetingCount: operation.meetingCount
            )
        }

        return "Delete \(operation.targetCount) \(operation.targetCount == 1 ? "item" : "items")? This permanently deletes the Library rows and app-owned files. Original local source files are not removed."
    }

    private func singleDeleteTitle(for transcription: Transcription) -> String {
        transcription.sourceType == .meeting ? "Delete Meeting?" : "Delete Transcription?"
    }

    private func singleDeleteConfirmTitle(for transcription: Transcription) -> String {
        transcription.sourceType == .meeting ? "Delete Meeting" : "Delete"
    }

    private func singleDeleteMessage(for transcription: Transcription) -> String {
        if transcription.sourceType == .meeting {
            return MeetingDeletionCopy.singleFullDeleteMessage(title: transcription.fileName)
        }
        return "\"\(transcription.fileName)\" will be permanently deleted. Original local source files are not removed."
    }

    private func handleSelectionKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard
            viewModel.isBulkSelectionModeEnabled,
            !viewModel.isBulkOperationInProgress,
            !bulkExportInProgress
        else { return .ignored }
        if press.key == .delete || press.key == .deleteForward {
            guard viewModel.hasSelectedTranscriptions else { return .ignored }
            viewModel.requestDeleteSelectedItems()
            return .handled
        }
        if (press.key == "a" || press.key == "A"), press.modifiers.contains(.command) {
            viewModel.selectLoadedVisibleTranscriptions()
            return .handled
        }
        return .ignored
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
    @State private var didPushCursor = false

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
            updateCursor(isHovering: hovering)
        }
        .onDisappear {
            releaseCursorIfNeeded()
        }
        .accessibilityLabel(title)
        .accessibilityHint("Starts a new transcription")
    }

    private func updateCursor(isHovering: Bool) {
        if isHovering, !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
            return
        }
        if !isHovering {
            releaseCursorIfNeeded()
        }
    }

    private func releaseCursorIfNeeded() {
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}

private struct LibrarySelectManyButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Select Many", systemImage: "checklist")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
        }
        .parakeetAction(.secondary)
        .help("Select multiple visible Library items")
        .accessibilityHint("Shows selection controls for bulk cleanup")
    }
}
