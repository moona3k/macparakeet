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
            if preview.hasConflicts {
                conflictPolicyCard
            }
            if let failureMessage {
                failureRow(failureMessage)
            }
            actionRow
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.background)
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
                    .font(DesignSystem.Typography.title)
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
                    .font(DesignSystem.Typography.title.weight(.semibold))
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

    // MARK: - Conflict policy

    private var conflictPolicyCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text(conflictHeadline)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            }

            if !preview.wordConflicts.isEmpty {
                conflictList(
                    title: "Conflicting words",
                    items: preview.wordConflicts
                )
            }
            if !preview.snippetConflicts.isEmpty {
                conflictList(
                    title: "Conflicting triggers",
                    items: preview.snippetConflicts
                )
            }
            if !preview.duplicateWords.isEmpty {
                conflictList(
                    title: "Duplicate words in backup",
                    items: preview.duplicateWords
                )
            }
            if !preview.duplicateSnippets.isEmpty {
                conflictList(
                    title: "Duplicate triggers in backup",
                    items: preview.duplicateSnippets
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("When an entry already exists or appears more than once:")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                policyOption(
                    .skip,
                    title: "Skip duplicates",
                    detail: "Keep your existing entries unchanged."
                )
                policyOption(
                    .replace,
                    title: "Replace duplicates",
                    detail: "Overwrite existing entries with the imported ones."
                )
            }
            .padding(.top, 2)
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
        detail: String
    ) -> some View {
        let isSelected = viewModel.conflictPolicy == value
        return Button {
            viewModel.conflictPolicy = value
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                        .foregroundStyle(.primary)
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
                    .fill(isSelected ? DesignSystem.Colors.accentLight : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.6),
                        lineWidth: isSelected ? 1.0 : 0.5
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
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button(importButtonTitle) {
                Task {
                    if await viewModel.applyImport() {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(preview.wordsTotal == 0 && preview.snippetsTotal == 0)
        }
    }

    private var importButtonTitle: String {
        guard preview.hasConflicts else { return "Import" }
        return viewModel.conflictPolicy == .replace ? "Import & Replace" : "Import"
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
