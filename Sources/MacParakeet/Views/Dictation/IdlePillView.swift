import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Persistent floating pill shown when idle — always visible at bottom of screen.
/// Expands on hover to show "Click or hold <trigger key> to start dictating" tooltip.
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
                .fill(viewModel.isHovered ? Color.black.opacity(0.85) : Color(white: 0.25, opacity: 0.9))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(viewModel.isHovered ? 0.1 : 0.06), lineWidth: 0.5)
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
        HStack(spacing: 0) {
            Text("Click or hold ")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text(HotkeyTrigger.current.shortSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: NSColor(red: 0.85, green: 0.55, blue: 0.75, alpha: 1.0)))
            Text(" to start dictating")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.9))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
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
