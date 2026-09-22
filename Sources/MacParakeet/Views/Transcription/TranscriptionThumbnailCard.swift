import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

private let sharedThumbnailCache = ThumbnailCacheService.shared

/// Thumbnail card for displaying a transcription in a grid layout.
struct TranscriptionThumbnailCard<MenuContent: View>: View {
    let transcription: Transcription
    var classification: MeetingClassification? = nil
    var searchText: String = ""
    var isSelected: Bool = false
    var showsSelectionControls: Bool = false
    var sourceLabelStyle: LibrarySourceLabelStyle = .visible
    var onTap: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            cardButton

            if showsUnavailableAudioIndicator {
                MeetingAudioStateChip(state: .removed)
                    .padding(8)
            }
        }
        .accessibilityElement(children: .contain)
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

    private var cardButton: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailArea
                infoArea
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.cardBackground)
                    .cardShadow(hovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.72) : DesignSystem.Colors.border.opacity(0.75),
                        lineWidth: isSelected ? 1.25 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .scaleEffect(hovered ? 1.02 : 1.0)
            .animation(DesignSystem.Animation.hoverTransition, value: hovered)
            .animation(DesignSystem.Animation.hoverTransition, value: isSelected)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if showsSelectionControls {
                selectionBadge
                    .padding(8)
                    // Decorative state indicator only — the whole card is the
                    // tap target. Without this, the filled circle intercepts
                    // clicks that land directly on it and swallows the toggle.
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            moreButton
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
        }
        .accessibilityValue(showsSelectionControls ? (isSelected ? "Selected" : "Not selected") : "")
        .accessibilityHint(showsSelectionControls ? "Toggles selection" : "Opens transcription")
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

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.surface.opacity(0.94))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.7),
                            lineWidth: 1.2
                        )
                }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.onAccent)
            }
        }
        .accessibilityHidden(true)
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
                case .empty:
                    remoteLoadingView
                case .failure:
                    placeholderView
                @unknown default:
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
        BranchingRecordingCoverView(recordingID: transcription.id)
            .id(transcription.id)
    }

    private var remoteLoadingView: some View {
        ZStack {
            DesignSystem.Colors.surfaceElevated
            ProgressView()
                .controlSize(.small)
                .tint(DesignSystem.Colors.textTertiary)
        }
    }

    private var displayTitle: String {
        transcription.effectiveDisplayTitle
    }

    private var sourceDisplay: TranscriptionSourceDisplay {
        TranscriptionSourceDisplay.resolve(for: transcription)
    }

    // MARK: - Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                highlightedText(displayTitle)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if transcription.isFavorite {
                    FavoriteStatusMarker()
                        .fixedSize()
                }
            }

            if let channelName = transcription.channelName {
                highlightedText(channelName)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                // Guarded rather than relying on an EmptyView contributing no
                // spacing, so a hidden label cannot shift the date 6pt right.
                if sourceLabelStyle != .hidden {
                    TranscriptionSourceLabel(source: sourceDisplay, style: sourceLabelStyle)
                }

                Text(transcription.createdAt.relativeFormatted)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }
            .font(DesignSystem.Typography.caption)

            transcriptionStatus

            if transcription.sourceType == .meeting,
                MeetingAudioFile.state(for: transcription) == .missing
            {
                MeetingAudioStateChip(state: MeetingAudioFile.state(for: transcription))
            }

            if let partialCapture = MeetingPartialCapturePresentation.make(for: transcription) {
                Text(partialCapture.badgeText)
                    .font(DesignSystem.Typography.micro.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.warningAmber.opacity(0.10))
                    )
                    .fixedSize()
                    .help(partialCapture.message)
                    .accessibilityLabel(partialCapture.badgeText)
                    .accessibilityHint(partialCapture.message)
            }

            if transcription.recoveredFromCrash {
                Label("Recovered", systemImage: "wrench.and.screwdriver")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .lineLimit(1)
            }

            MeetingClassificationBadges(classification: classification)
        }
        .padding(DesignSystem.Spacing.sm)
        .padding(.trailing, showsUnavailableAudioIndicator ? 36 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 100, alignment: .top)
    }

    private var showsUnavailableAudioIndicator: Bool {
        transcription.sourceType == .meeting && MeetingAudioFile.state(for: transcription) == .removed
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch transcription.status {
        case .processing:
            HStack(spacing: 5) {
                ParakeetSpinner(.inline)
                    .scaleEffect(0.85)
                    .frame(width: 12, height: 12)
                Text("Transcribing")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        case .error:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Transcription failed")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .help(transcription.errorMessage ?? "Transcription failed")
            .accessibilityHint(transcription.errorMessage ?? "Transcription failed")
        case .cancelled:
            Text("Transcription stopped")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        case .completed:
            EmptyView()
        }
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
