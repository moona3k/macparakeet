import SwiftUI

/// The hero interaction — a warm card with merkaba that responds to file dragging.
/// "Portal" effect: lifts, glows, particles drift on hover; contracts on file drop.
struct PortalDropZone: View {
    @Binding var isDragging: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    let onBrowse: () -> Void

    @State private var browseHovered = false

    var body: some View {
        ZStack {
            // Card background
            RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
                .fill(isDragging ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
                        .strokeBorder(
                            isDragging ? DesignSystem.Colors.accent.opacity(0.4) : Color.clear,
                            lineWidth: 1
                        )
                )
                .cardShadow(isDragging ? DesignSystem.Shadows.portalLift : DesignSystem.Shadows.cardRest)

            // Content
            VStack(spacing: DesignSystem.Spacing.md) {
                // Merkaba — state-reactive
                ZStack {
                    if isDragging {
                        ParticleField(
                            particleCount: 6,
                            tintColor: DesignSystem.Colors.accent,
                            opacity: 0.25,
                            driftDirection: .up
                        )
                        .frame(width: 120, height: 120)
                    }

                    MeditativeMerkabaView(
                        size: 80,
                        revolutionDuration: isDragging ? 3.0 : 6.0,
                        tintColor: DesignSystem.Colors.accent,
                        animate: isDragging
                    )
                    .opacity(isDragging ? 0.9 : 0.7)
                    .animation(.easeInOut(duration: 0.3), value: isDragging)
                }

                // Call to action
                Text("Drop a file to transcribe")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(isDragging ? DesignSystem.Colors.accent : .primary)

                // Browse button
                Button(action: onBrowse) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                        Text("Browse Files")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(browseHovered ? DesignSystem.Colors.onAccent : DesignSystem.Colors.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                            .fill(browseHovered ? DesignSystem.Colors.accent : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                            .strokeBorder(DesignSystem.Colors.accent.opacity(browseHovered ? 0 : 0.5), lineWidth: 1.5)
                    )
                    .animation(DesignSystem.Animation.hoverTransition, value: browseHovered)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse files")
                .accessibilityHint("Opens a file picker to choose audio or video files")
                .onHover { hovering in
                    browseHovered = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                // Supported formats
                Text("MP3, WAV, M4A, MP4, MOV, FLAC, and more")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, DesignSystem.Spacing.xl)
        }
        .frame(minHeight: 220)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            onDrop(providers)
        }
        .animation(DesignSystem.Animation.portalLift, value: isDragging)
        .accessibilityLabel("File drop zone")
        .accessibilityHint("Drop an audio or video file to start transcription")
    }
}
