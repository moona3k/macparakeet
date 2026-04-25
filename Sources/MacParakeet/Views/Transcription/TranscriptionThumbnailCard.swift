import SwiftUI
import MacParakeetCore

private let sharedThumbnailCache = ThumbnailCacheService.shared

/// Thumbnail card for displaying a transcription in a grid layout.
struct TranscriptionThumbnailCard<MenuContent: View>: View {
    let transcription: Transcription
    var searchText: String = ""
    var onTap: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent

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
        .overlay(alignment: .topTrailing) {
            moreButton
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
        }
        .onHover { hovered = $0 }
        .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        .onAppear {
            // If not locally cached, trigger background download so it's cached for next render
            if sharedThumbnailCache.cachedThumbnail(for: transcription.id) == nil,
               let urlString = transcription.thumbnailURL {
                let id = transcription.id
                Task.detached(priority: .utility) {
                    _ = try? await ThumbnailCacheService.shared.downloadThumbnail(from: urlString, for: id)
                }
            }
        }
    }

    @State private var moreHovered = false

    private var moreButton: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(.black.opacity(moreHovered ? 0.85 : 0.5))
                        .scaleEffect(moreHovered ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: moreHovered)
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(6)
        .background(
            // Invisible tracking area — Menu swallows .onHover,
            // so we use a background rectangle to detect hover instead
            Color.clear
                .contentShape(Rectangle())
                .onHover { moreHovered = $0 }
        )
    }

    // MARK: - Thumbnail

    private var thumbnailArea: some View {
        // Color.clear establishes a consistent 16:9 frame regardless of content
        Color.clear
            .aspectRatio(DesignSystem.Layout.thumbnailAspectRatio, contentMode: .fit)
            .overlay {
                thumbnailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
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
            }
            .clipShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let cached = sharedThumbnailCache.cachedThumbnail(for: transcription.id),
           let nsImage = NSImage(contentsOf: cached) {
            // Locally cached thumbnail (YouTube download or local video frame)
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = resolvedThumbnailURL {
            // Remote URL — load and cache in background
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    placeholderView
                }
            }
        } else {
            placeholderView
        }
    }

    /// Resolves a thumbnail URL: explicit thumbnailURL, or derived from YouTube sourceURL.
    private var resolvedThumbnailURL: URL? {
        if let urlString = transcription.thumbnailURL, let url = URL(string: urlString) {
            return url
        }
        // Derive from YouTube video ID
        if let sourceURL = transcription.sourceURL,
           let videoID = YouTubeURLValidator.extractVideoID(sourceURL) {
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }
        return nil
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
        let videoExts: Set = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]
        return videoExts.contains(ext) ? "film" : "waveform"
    }

    // MARK: - Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            highlightedText(transcription.fileName)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)

            if let channelName = transcription.channelName {
                highlightedText(channelName)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)

                Text(transcription.createdAt.relativeFormatted)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            } else {
                Text(transcription.createdAt.relativeFormatted)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }

            if transcription.recoveredFromCrash {
                Label("Recovered", systemImage: "wrench.and.screwdriver")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .lineLimit(1)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 80, alignment: .top)
    }

    // MARK: - Search Highlighting

    @MainActor
    private func highlightedText(_ text: String) -> Text {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(text) }

        var result = Text("")
        var remainder = text[...]

        while let range = remainder.range(of: query, options: .caseInsensitive) {
            let prefix = String(remainder[..<range.lowerBound])
            if !prefix.isEmpty {
                result = result + Text(prefix)
            }

            let match = String(remainder[range])
            result = result + Text(match)
                .bold()

            remainder = remainder[range.upperBound...]
        }

        if !remainder.isEmpty {
            result = result + Text(String(remainder))
        }

        return result
    }
}

// MARK: - Helpers

extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
