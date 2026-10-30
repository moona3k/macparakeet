import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels
import UniformTypeIdentifiers

/// Backup and restore stays accessible independently of processing mode.
/// Surfaces export / import in plain sight — issue #67.
struct VocabularyBackupSection: View {
    @Bindable var viewModel: VocabularyBackupViewModel

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(action: presentExportPanel) {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .parakeetAction(.secondary)
                Button(action: presentImportPanel) {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .parakeetAction(.secondary)
                Spacer(minLength: 0)
            }
            .disabled(!viewModel.canStartOperation)

            statusLine
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(hovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    hovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hovered = hovering
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isPresentingImportSheet },
                set: { if !$0, viewModel.pendingImport != nil { viewModel.cancelImport() } }
            )
        ) {
            if let preview = viewModel.pendingImport {
                VocabularyImportPreviewSheet(
                    viewModel: viewModel,
                    preview: preview
                )
                .frame(minWidth: 460)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "tray.and.arrow.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup & Restore")
                    .font(DesignSystem.Typography.sectionTitle)
                Text("Save your vocabulary to a file. Restore it on this Mac or another.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch viewModel.status {
        case .idle, .exporting, .importing:
            EmptyView()
        case let .exported(words, snippets, filename):
            statusRow(
                icon: "checkmark.circle.fill",
                tint: DesignSystem.Colors.successGreen,
                text:
                    "Exported \(pluralize(words, "word", "words")) and \(pluralize(snippets, "snippet", "snippets")) to \(filename.isEmpty ? "your chosen file" : filename)."
            )
        case let .imported(result):
            statusRow(
                icon: "checkmark.circle.fill",
                tint: DesignSystem.Colors.successGreen,
                text: importedSummary(result)
            )
        case let .failed(message):
            statusRow(
                icon: "exclamationmark.triangle.fill",
                tint: DesignSystem.Colors.errorRed,
                text: message
            )
        }
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.dismissStatus()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func importedSummary(_ r: VocabularyImportExportService.ImportResult) -> String {
        var parts: [String] = []
        let totalAdded = r.wordsAdded + r.snippetsAdded
        let totalReplaced = r.wordsReplaced + r.snippetsReplaced
        let totalSkipped = r.wordsSkipped + r.snippetsSkipped
        if totalAdded > 0 {
            parts.append(
                "Added \(pluralize(r.wordsAdded, "word", "words")) and \(pluralize(r.snippetsAdded, "snippet", "snippets"))"
            )
        }
        if totalReplaced > 0 {
            parts.append("replaced \(totalReplaced)")
        }
        if totalSkipped > 0 {
            parts.append("skipped \(totalSkipped) duplicate\(totalSkipped == 1 ? "" : "s")")
        }
        let totalRemoved = r.wordsRemoved + r.snippetsRemoved
        if totalRemoved > 0 {
            parts.append(
                "removed \(pluralize(r.wordsRemoved, "word", "words")) and \(pluralize(r.snippetsRemoved, "snippet", "snippets"))"
            )
        }
        if parts.isEmpty {
            return "Nothing to import — the file matched your existing vocabulary."
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Actions

    private func presentExportPanel() {
        Task { @MainActor in
            guard let export = await viewModel.makeExportPayload() else { return }
            let panel = NSSavePanel()
            panel.title = "Export Vocabulary"
            panel.message = "Save your custom words and text snippets to a JSON file."
            panel.nameFieldStringValue = viewModel.suggestedFilename()
            if let json = UTType(filenameExtension: "json") {
                panel.allowedContentTypes = [json]
            }
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try export.data.write(to: url, options: .atomic)
                }.value
                viewModel.confirmExportSucceeded(
                    filename: url.lastPathComponent,
                    wordsCount: export.wordsCount,
                    snippetsCount: export.snippetsCount
                )
            } catch {
                // Reuse failed status for write errors.
                viewModel.status = .failed("Couldn't write the file: \(error.localizedDescription)")
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Vocabulary"
        panel.message = "Choose a MacParakeet vocabulary backup (.json)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let json = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [json]
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        Task {
            await viewModel.loadPreview(from: url)
        }
    }

    private func pluralize(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}
