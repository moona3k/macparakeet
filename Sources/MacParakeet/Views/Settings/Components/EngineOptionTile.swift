import MacParakeetViewModels
import SwiftUI

/// Large selectable tile representing one speech recognition engine.
///
/// The tile is a plain-styled `Button` so it picks up macOS keyboard focus,
/// the system focus ring, and Button accessibility traits for free. It only
/// renders display state (status pill + label) — actionable affordances like
/// Download / Retry live outside the tile (see `EngineDownloadBanner`) so we
/// never nest one Button inside another, which is unreliable on macOS SwiftUI.
struct EngineOptionTile: View {
    let icon: String
    let name: String
    let tagline: String
    let strengths: [String]
    let helpText: String
    let modelStatus: SettingsViewModel.LocalModelStatus
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: handleTileTap) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                header
                Text(tagline)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(strengths.enumerated()), id: \.offset) { _, strength in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(DesignSystem.Colors.accent.opacity(0.55))
                                .frame(width: 4, height: 4)
                                .offset(y: -2)
                            Text(strength)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
                statusFooter
            }
            .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
            .padding(DesignSystem.Spacing.md)
            .background(background)
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(helpText)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(name) engine. \(tagline).")
        .accessibilityHint(helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func handleTileTap() {
        guard !isSelected else { return }
        onSelect()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? DesignSystem.Colors.accent.opacity(0.16)
                              : DesignSystem.Colors.surfaceElevated)
                )

            Text(name)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer(minLength: DesignSystem.Spacing.xs)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
    }

    private var statusFooter: some View {
        let info = StatusInfo.from(modelStatus)
        return HStack(alignment: .center, spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(info.color)
                .frame(width: 6, height: 6)
            Text(info.label)
                .font(DesignSystem.Typography.micro.weight(.medium))
                .foregroundStyle(info.color)
            Text(info.detail)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignSystem.Spacing.xs)
        }
        .padding(.top, DesignSystem.Spacing.xs)
        .padding(.horizontal, 2)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
            .fill(isSelected
                  ? DesignSystem.Colors.accent.opacity(0.13)
                  : DesignSystem.Colors.surfaceElevated.opacity(isHovered ? 0.7 : 0.4))
    }

    private var border: some View {
        let strokeColor: Color = if isSelected {
            DesignSystem.Colors.accent.opacity(0.8)
        } else if isHovered {
            DesignSystem.Colors.accent.opacity(0.3)
        } else {
            DesignSystem.Colors.border.opacity(0.7)
        }
        let lineWidth: CGFloat = isSelected ? 2.0 : 0.5
        return RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
            .strokeBorder(strokeColor, lineWidth: lineWidth)
    }

    private struct StatusInfo {
        let color: Color
        let label: String
        let detail: String

        static func from(_ status: SettingsViewModel.LocalModelStatus) -> StatusInfo {
            switch status {
            case .ready:
                return StatusInfo(
                    color: DesignSystem.Colors.successGreen,
                    label: "Ready",
                    detail: "Loaded in memory"
                )
            case .notLoaded:
                return StatusInfo(
                    color: DesignSystem.Colors.successGreen,
                    label: "Downloaded",
                    detail: "Loads on first use"
                )
            case .notDownloaded:
                return StatusInfo(
                    color: DesignSystem.Colors.warningAmber,
                    label: "Not downloaded",
                    detail: "Needed before first use"
                )
            case .repairing:
                return StatusInfo(
                    color: DesignSystem.Colors.warningAmber,
                    label: "Working",
                    detail: "Updating model…"
                )
            case .checking:
                return StatusInfo(
                    color: DesignSystem.Colors.textSecondary,
                    label: "Checking",
                    detail: "Inspecting model state"
                )
            case .failed:
                return StatusInfo(
                    color: DesignSystem.Colors.errorRed,
                    label: "Failed",
                    detail: "Open Local Models to retry"
                )
            case .unknown:
                return StatusInfo(
                    color: DesignSystem.Colors.textSecondary,
                    label: "Unknown",
                    detail: "Status not yet checked"
                )
            }
        }
    }
}

/// Inline call-to-action that appears below the engine tiles when the
/// selected-but-unavailable engine needs a download, is downloading, or
/// failed. Lives outside the tiles so the tile root can stay a clean
/// `Button` (no nested-button hit testing). Compact full-width row: model
/// description on the left, mode-specific affordance on the right.
struct EngineDownloadBanner: View {
    enum Mode: Equatable {
        case download           // first-run / not downloaded
        case downloading        // download in flight (progress)
        case retry              // last attempt failed
    }

    let title: String
    let subtitle: String
    let mode: Mode
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: leadingIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            trailingControl
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch mode {
        case .download:
            Button("Download", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(DesignSystem.Colors.accent)
                .accessibilityLabel("Download \(title)")
        case .downloading:
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Downloading \(title)")
        case .retry:
            Button("Retry Download", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(DesignSystem.Colors.errorRed)
                .accessibilityLabel("Retry downloading \(title)")
        }
    }

    private var leadingIcon: String {
        switch mode {
        case .download: return "arrow.down.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .retry: return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch mode {
        case .download, .downloading: return DesignSystem.Colors.accent
        case .retry: return DesignSystem.Colors.errorRed
        }
    }
}

#Preview("Engine tiles + banner", traits: .fixedLayout(width: 760, height: 380)) {
    VStack(spacing: DesignSystem.Spacing.md) {
        HStack(spacing: DesignSystem.Spacing.md) {
            EngineOptionTile(
                icon: "bolt.fill",
                name: "Parakeet",
                tagline: "Fastest local engine",
                strengths: [
                    "English + 24 European languages",
                    "155× realtime on Apple Silicon",
                    "Runs on the Neural Engine"
                ],
                helpText: "Best for English and other European languages including Spanish, French, German, and Italian. Runs on the Neural Engine for the lowest latency on Apple Silicon.",
                modelStatus: .ready,
                isSelected: true,
                isBusy: false,
                onSelect: {}
            )

            EngineOptionTile(
                icon: "globe",
                name: "Whisper",
                tagline: "Multilingual coverage",
                strengths: [
                    "Korean, Japanese, Chinese, Thai +95 more",
                    "Auto language detection",
                    "Whisper Large v3 Turbo (632 MB)"
                ],
                helpText: "Best for languages outside Parakeet's coverage. Adds Korean, Japanese, Chinese, Thai, Hindi, Arabic, Vietnamese, and 80+ more — any language Whisper supports.",
                modelStatus: .notDownloaded,
                isSelected: false,
                isBusy: false,
                onSelect: {}
            )
        }

        EngineDownloadBanner(
            title: "Whisper Large v3 Turbo",
            subtitle: "632 MB · downloads once, runs locally afterwards",
            mode: .download,
            action: {}
        )
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
