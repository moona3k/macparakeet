import SwiftUI
import MacParakeetCore

struct DictationDetailView: View {
    let dictation: Dictation
    var isPlaying: Bool = false
    var playbackProgress: Double = 0
    var playbackTimeString: String?
    var onTogglePlayback: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    @State private var showDeleteAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(relativeDate(dictation.createdAt))
                    .font(DesignSystem.Typography.headline)
                    .lineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Text(dictation.durationMs.formattedDuration)
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.05))
                    )
                    .fixedSize()
            }
            .padding(DesignSystem.Spacing.lg)

            // Playback card
            if dictation.audioPath != nil {
                playbackCard
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            SacredGeometryDivider()
                .padding(.horizontal, DesignSystem.Spacing.lg)

            // Transcript
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("Transcript")
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(.secondary)

                    Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                        .font(DesignSystem.Typography.body)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.lg)
            }

            Divider()

            // Actions
            HStack {
                Button(action: { onCopy?() }) {
                    Label("Copy", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive, action: { showDeleteAlert = true }) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .alert("Delete Dictation?", isPresented: $showDeleteAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        onDelete?()
                    }
                } message: {
                    Text("This dictation and its audio file will be permanently deleted.")
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    // MARK: - Playback Card

    private var playbackCard: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Play/pause button — accent-filled circle
            Button {
                onTogglePlayback?()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 32, height: 32)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.playbackTrack)
                    Capsule()
                        .fill(DesignSystem.Colors.playbackFill)
                        .frame(width: max(0, geo.size.width * playbackProgress))
                }
            }
            .frame(height: DesignSystem.Layout.playbackBarHeight)

            // Time display
            Text(playbackTimeString ?? dictation.durationMs.formattedDuration)
                .font(DesignSystem.Typography.timestamp)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                        .strokeBorder(DesignSystem.Colors.subtleBorder, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return "Today at \(formatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            formatter.timeStyle = .short
            return "Yesterday at \(formatter.string(from: date))"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}
