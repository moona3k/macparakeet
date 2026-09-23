import MacParakeetCore
import SwiftUI

/// The transcript the user is already reading, opened for changes.
struct TranscriptReadingEditor: View {
    @Binding var drafts: [TranscriptReadingDraft]
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ForEach($drafts) { $draft in
                passage($draft)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
    }

    @ViewBuilder
    private func passage(_ draft: Binding<TranscriptReadingDraft>) -> some View {
        if draft.wrappedValue.removed {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Passage removed")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Button("Restore") {
                    draft.wrappedValue.removed = false
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                TextField("Passage", text: draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .accessibilityLabel("Transcript passage")

                Button {
                    draft.wrappedValue.removed = true
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove passage")
                .accessibilityLabel("Remove passage")
            }
        }
    }
}
