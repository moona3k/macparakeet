import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Modal preview shown after the user picks a JSON file. Shows counts, conflicts,
/// and lets the user pick a policy before committing.
struct VocabularyImportPreviewSheet: View {
    @Bindable var viewModel: VocabularyBackupViewModel
    let preview: VocabularyImportExportService.ImportPreview

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            summaryCard
            importModeCard
            if viewModel.conflictPolicy == .replaceAll {
                replaceAllWarning
            } else if preview.hasConflicts {
                conflictListsCard
            }
            if let failureMessage {
                failureRow(failureMessage)
            }
            actionRow
        }
        .padding(DesignSystem.Spacing.lg)
        .background(.thickMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Import Vocabulary")
                    .font(DesignSystem.Typography.pageTitle)
                Text("Review what's in this backup before importing.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                summaryChip(
                    title: "Custom words",
                    value: "\(preview.wordsTotal)",
                    icon: "character.book.closed"
                )
                summaryChip(
                    title: "Text snippets",
                    value: "\(preview.snippetsTotal)",
                    icon: "text.insert"
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                metaRow(
                    label: "Exported",
                    value: relativeDate(preview.bundle.exportedAt)
                )
                if let appVersion = preview.bundle.appVersion {
                    metaRow(label: "From version", value: appVersion)
                }
                metaRow(label: "Format", value: "v\(preview.bundle.version)")
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func summaryChip(title: String, value: String, icon: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(DesignSystem.Typography.pageTitle.weight(.semibold))
                Text(title)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.micro.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: - Import mode

    private var importModeCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Import mode")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            policyOption(
                .skip,
                title: "Add new entries",
                detail: "Keep existing words and snippets. Skip anything that already exists."
            )
            policyOption(
                .replace,
                title: "Replace duplicates",
                detail: "Overwrite matching entries. Leave everything else as-is."
            )
            Text("Advanced")
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            policyOption(
                .replaceAll,
                title: "Replace entire vocabulary",
                detail:
                    "Remove words and snippets that aren't in this file, then import. Words MacParakeet learned automatically from dictation stay unless this file also lists them.",
                destructive: true
            )
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var replaceAllWarning: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Text(replaceAllHeadline)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            }

            if !preview.wordsRemoved.isEmpty {
                conflictList(title: "Words that will be removed", items: preview.wordsRemoved)
            }
            if !preview.snippetsRemoved.isEmpty {
                conflictList(title: "Snippets that will be removed", items: preview.snippetsRemoved)
            }
            if !preview.wordConflicts.isEmpty {
                conflictList(title: "Words that will be replaced", items: preview.wordConflicts)
            }
            if !preview.snippetConflicts.isEmpty {
                conflictList(title: "Snippets that will be replaced", items: preview.snippetConflicts)
            }
            if !preview.duplicateWords.isEmpty {
                conflictList(title: "Duplicate words in backup", items: preview.duplicateWords)
            }
            if !preview.duplicateSnippets.isEmpty {
                conflictList(title: "Duplicate triggers in backup", items: preview.duplicateSnippets)
            }
            if !preview.duplicateWords.isEmpty || !preview.duplicateSnippets.isEmpty {
                Text("For repeated entries, the last one in the file wins.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if preview.learnedWordsPreserved > 0 {
                Text(
                    preview.learnedWordsPreserved == 1
                        ? "1 word MacParakeet learned automatically from dictation stays on this Mac."
                        : "\(preview.learnedWordsPreserved) words MacParakeet learned automatically from dictation stay on this Mac."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            }
            if isEmptyReplaceAll {
                Text("This file is empty, so replace-all would only delete. Import a dictionary file instead.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.errorRed.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var conflictListsCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text(conflictHeadline)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            }

            if !preview.wordConflicts.isEmpty {
                conflictList(title: "Conflicting words", items: preview.wordConflicts)
            }
            if !preview.snippetConflicts.isEmpty {
                conflictList(title: "Conflicting triggers", items: preview.snippetConflicts)
            }
            if !preview.duplicateWords.isEmpty {
                conflictList(title: "Duplicate words in backup", items: preview.duplicateWords)
            }
            if !preview.duplicateSnippets.isEmpty {
                conflictList(title: "Duplicate triggers in backup", items: preview.duplicateSnippets)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.warningAmber.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var replaceAllHeadline: String {
        if isEmptyReplaceAll {
            return "This file has no words or snippets."
        }
        if !preview.hasRemovals {
            if preview.hasConflicts {
                return "Matching or repeated entries will be replaced. Nothing extra will be removed."
            }
            return "Your vocabulary will match this file. Nothing extra will be removed."
        }
        var parts: [String] = []
        if !preview.wordsRemoved.isEmpty {
            let count = preview.wordsRemoved.count
            parts.append("\(count) word\(count == 1 ? "" : "s")")
        }
        if !preview.snippetsRemoved.isEmpty {
            let count = preview.snippetsRemoved.count
            parts.append("\(count) snippet\(count == 1 ? "" : "s")")
        }
        return "This removes \(parts.joined(separator: " and ")) that aren't in the file."
    }

    private var conflictHeadline: String {
        let w = preview.wordConflicts.count
        let s = preview.snippetConflicts.count
        let duplicateCount = preview.duplicateWords.count + preview.duplicateSnippets.count
        switch (w, s, duplicateCount) {
        case (0, 0, 0):
            return "No conflicts."
        case (0, 0, let d):
            return "\(d) duplicate entr\(d == 1 ? "y" : "ies") found in this backup."
        case (let w, 0, 0):
            return "\(w) word\(w == 1 ? "" : "s") already exist\(w == 1 ? "s" : "")."
        case (0, let s, 0):
            return "\(s) snippet\(s == 1 ? "" : "s") already exist\(s == 1 ? "s" : "")."
        default:
            let existingCount = w + s
            var parts: [String] = []
            if existingCount > 0 {
                parts.append("\(existingCount) existing entr\(existingCount == 1 ? "y" : "ies")")
            }
            if duplicateCount > 0 {
                parts.append("\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") in the backup")
            }
            return parts.joined(separator: " and ") + "."
        }
    }

    private func conflictList(title: String, items: [String]) -> some View {
        let preview = items.prefix(5)
        let extra = items.count - preview.count
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(preview.map { "\"\($0)\"" }.joined(separator: ", ") + (extra > 0 ? ", and \(extra) more" : ""))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private func policyOption(
        _ value: VocabularyImportExportService.ConflictPolicy,
        title: String,
        detail: String,
        destructive: Bool = false
    ) -> some View {
        let isSelected = viewModel.conflictPolicy == value
        let accent = destructive ? DesignSystem.Colors.errorRed : DesignSystem.Colors.accent
        let selectedFill =
            destructive
            ? DesignSystem.Colors.errorRed.opacity(0.10)
            : DesignSystem.Colors.accentLight
        return Button {
            viewModel.conflictPolicy = value
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(destructive ? accent : (isSelected ? accent : .secondary))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                            .foregroundStyle(destructive ? accent : .primary)
                        if destructive {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                    }
                    Text(detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isSelected ? selectedFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        destructive
                            ? accent.opacity(isSelected ? 0.45 : 0.28)
                            : (isSelected ? accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.6)),
                        lineWidth: isSelected || destructive ? 1.0 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                viewModel.cancelImport()
                dismiss()
            }
            .parakeetAction(.secondary)
            .keyboardShortcut(.cancelAction)

            importConfirmButton
        }
    }

    @ViewBuilder
    private var importConfirmButton: some View {
        let button = Button(
            importButtonTitle,
            role: viewModel.conflictPolicy == .replaceAll ? .destructive : nil
        ) {
            Task {
                if await viewModel.applyImport() {
                    dismiss()
                }
            }
        }
        .parakeetAction(
            viewModel.conflictPolicy == .replaceAll ? .destructiveProminent : .primaryProminent
        )
        .disabled(isImportDisabled)

        if viewModel.conflictPolicy == .replaceAll {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }

    private var importButtonTitle: String {
        switch viewModel.conflictPolicy {
        case .skip:
            return "Import"
        case .replace:
            return preview.hasConflicts ? "Import & Replace" : "Import"
        case .replaceAll:
            if !preview.hasRemovals && !preview.hasConflicts {
                return "Import"
            }
            return "Replace Vocabulary"
        }
    }

    private var isEmptyReplaceAll: Bool {
        viewModel.conflictPolicy == .replaceAll
            && preview.wordsTotal == 0
            && preview.snippetsTotal == 0
    }

    private var isImportDisabled: Bool {
        preview.wordsTotal == 0 && preview.snippetsTotal == 0
    }

    // MARK: - Helpers

    private var failureMessage: String? {
        guard case let .failed(message) = viewModel.status else { return nil }
        return message
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .padding(.top, 1)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let absolute = DateFormatter.localizedString(
            from: date,
            dateStyle: .medium,
            timeStyle: .short
        )
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "\(absolute) (\(relative))"
    }
}
