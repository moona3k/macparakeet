import MacParakeetViewModels
import SwiftUI

/// The transcript the user is already reading, opened for changes.
struct TranscriptReadingEditor: View {
    let session: TranscriptReadingEditSession
    let font: Font

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ForEach(session.passages) { passage in
                TranscriptReadingPassageRow(passage: passage, font: font)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
    }
}

private struct TranscriptReadingPassageRow: View {
    @Bindable var passage: TranscriptReadingPassage
    let font: Font

    var body: some View {
        if passage.removed {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Passage removed")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Button("Restore") {
                    passage.removed = false
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                TextField("Passage", text: $passage.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .accessibilityLabel("Transcript passage")

                Button {
                    passage.removed = true
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
