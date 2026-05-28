import SwiftUI

struct LoadingCaptionView: View {
    let caption: DictationOverlayViewModel.ProcessingLoadCaption

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(titleColor)

            if let subcopy {
                Text(subcopy)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.pillBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.pillBorder.opacity(0.6), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
    }

    private var title: String {
        switch caption {
        case .preparing, .preparingExtended:
            "Preparing speech engine…"
        case .failed:
            "Couldn't load speech engine."
        }
    }

    private var subcopy: String? {
        switch caption {
        case .preparingExtended:
            "First-time setup — may take a few minutes"
        case .preparing, .failed:
            nil
        }
    }

    private var titleColor: Color {
        switch caption {
        case .preparing, .preparingExtended:
            .white.opacity(0.85)
        case .failed:
            DesignSystem.Colors.recordingRed
        }
    }

    private var accessibilityLabel: String {
        if let subcopy {
            return "\(title) \(subcopy)"
        }
        return title
    }
}

#Preview("Loading Caption") {
    VStack(spacing: 10) {
        LoadingCaptionView(caption: .preparing)
        LoadingCaptionView(caption: .preparingExtended)
        LoadingCaptionView(caption: .failed)
    }
    .padding(24)
    .background(Color.black)
}
