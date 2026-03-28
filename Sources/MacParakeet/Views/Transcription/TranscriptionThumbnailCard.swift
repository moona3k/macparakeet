import SwiftUI
import MacParakeetCore

/// Thumbnail card for displaying a transcription in a grid layout.
struct TranscriptionThumbnailCard: View {
    let transcription: Transcription
    var onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailArea
                infoArea
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
                    .cardShadow(hovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .scaleEffect(hovered ? 1.02 : 1.0)
            .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    // MARK: - Thumbnail

    private var thumbnailArea: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailContent
                .frame(maxWidth: .infinity)
                .aspectRatio(DesignSystem.Layout.thumbnailAspectRatio, contentMode: .fill)
                .clipped()

            // Duration badge
            if let durationMs = transcription.durationMs {
                Text(durationMs.formattedDuration)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.7))
                    )
                    .padding(8)
            }

            // Summary badge
            if transcription.summary != nil {
                VStack {
                    HStack {
                        Text("SUMMARY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.accent)
                            )
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
    }

    private static let thumbnailCache = ThumbnailCacheService()

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnailURL = transcription.thumbnailURL,
           let cached = Self.thumbnailCache.cachedThumbnail(for: transcription.id) {
            // Cached thumbnail
            AsyncImage(url: cached) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderView
            }
        } else if let urlString = transcription.thumbnailURL, let url = URL(string: urlString) {
            // Has URL but not cached yet — load from remote
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderView
            }
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            DesignSystem.Colors.surfaceElevated

            Image(systemName: sourceIcon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }

    private var sourceIcon: String {
        if transcription.sourceURL != nil {
            return "play.rectangle.fill"
        }
        let ext = transcription.filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let videoExts: Set = ["mp4", "mov", "mkv", "avi", "webm", "m4v"]
        return videoExts.contains(ext) ? "film" : "waveform"
    }

    // MARK: - Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transcription.fileName)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)

            if let channel = transcription.channelName {
                Text(channel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }

            Text(transcription.createdAt.relativeFormatted)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Helpers

extension Date {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var relativeFormatted: String {
        Self.relativeDateFormatter.localizedString(for: self, relativeTo: Date())
    }
}
