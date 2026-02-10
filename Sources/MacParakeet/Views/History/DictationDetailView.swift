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
            HStack {
                Text(formatDate(dictation.createdAt))
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Text(dictation.durationMs.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignSystem.Spacing.lg)

            Divider()

            // Audio playback (if audio exists)
            if dictation.audioPath != nil {
                HStack {
                    Button {
                        onTogglePlayback?()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * playbackProgress)
                        }
                    }
                    .frame(height: 4)

                    Text(playbackTimeString ?? dictation.durationMs.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.lg)

                Divider()
            }

            // Transcript
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("Transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                        .font(DesignSystem.Typography.body)
                        .textSelection(.enabled)
                }
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
                    Label("Delete Dictation", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
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

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
