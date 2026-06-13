import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Persistent floating pill shown when idle — always visible at bottom of screen.
/// Expands on hover to show the available dictation entry points.
struct IdlePillView: View {
    @Bindable var viewModel: IdlePillViewModel

    var body: some View {
        VStack(spacing: 6) {
            // Tooltip — appears above pill on hover
            tooltip
                .opacity(viewModel.isHovered ? 1 : 0)
                .scaleEffect(viewModel.isHovered ? 1 : 0.9)
                .animation(.easeOut(duration: 0.2), value: viewModel.isHovered)

            // Pill
            pill
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isHovered)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Pill

    private var pill: some View {
        ZStack {
            // Dark capsule background
            Capsule()
                .fill(viewModel.isHovered ? DesignSystem.Colors.pillBackground : Color(white: 0.25, opacity: 0.9))
                .overlay(
                    Capsule()
                        .strokeBorder(DesignSystem.Colors.pillBorder.opacity(viewModel.isHovered ? 0.67 : 0.4), lineWidth: 0.5)
                )
        }
        .frame(
            width: viewModel.isHovered ? 148 : 48,
            height: viewModel.isHovered ? 30 : 10
        )
        .shadow(color: .black.opacity(0.3), radius: viewModel.isHovered ? 8 : 4, y: 4)
        .overlay {
            // Dots shown on hover inside the pill
            if viewModel.isHovered {
                dotsRow
                    .transition(.opacity)
            }
        }
    }

    private var dotsRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 3, height: 3)
            }
        }
    }

    // MARK: - Tooltip

    private var tooltip: some View {
        Group {
            let handsFreeTrigger = HotkeyTrigger.current
            let pushToTalkTrigger = HotkeyTrigger.current(
                defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
                fallback: .defaultPushToTalk
            )
            if handsFreeTrigger.isDisabled, pushToTalkTrigger.isDisabled {
                Text("Click to start dictating")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                HStack(spacing: 0) {
                    Text("Click")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    if !handsFreeTrigger.isDisabled {
                        Text(", tap ")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        shortcutText(handsFreeTrigger.shortSymbol)
                    }
                    if !pushToTalkTrigger.isDisabled {
                        Text(" or hold ")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        shortcutText(pushToTalkTrigger.shortSymbol)
                    }
                    Text(" to dictate")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.pillBackground)
                .overlay(
                    Capsule()
                        .strokeBorder(DesignSystem.Colors.pillBorder.opacity(0.67), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
    }

    private func shortcutText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: NSColor(red: 0.85, green: 0.55, blue: 0.75, alpha: 1.0)))
    }
}

#Preview {
    VStack(spacing: 40) {
        IdlePillView(viewModel: {
            let vm = IdlePillViewModel()
            return vm
        }())

        IdlePillView(viewModel: {
            let vm = IdlePillViewModel()
            vm.isHovered = true
            return vm
        }())
    }
    .padding(30)
    .frame(width: 400, height: 200)
    .background(Color.gray.opacity(0.3))
}
