import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

// MARK: - Card

/// The white rounded card every onboarding step is built from.
struct OnboardingCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
                    .cardShadow(DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        highlighted
                            ? DesignSystem.Colors.accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.5),
                        lineWidth: highlighted ? 1 : 0.5
                    )
            )
    }
}

// MARK: - Accent button

struct OnboardingAccentButton: View {
    let title: String
    var icon: String? = nil
    var large = false
    var disabled = false
    var isDefault = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.onAccent)
            .padding(.horizontal, large ? 20 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                    .fill(disabled ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.accent)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}

// MARK: - Numbered beat badge

struct OnboardingBeatBadge: View {
    let number: Int
    var done = false

    var body: some View {
        ZStack {
            Circle()
                .fill(done ? DesignSystem.Colors.successGreen.opacity(0.15) : DesignSystem.Colors.accent.opacity(0.12))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            } else {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Key caps

/// A physical-looking key drawn in the Try It card. It lights while the real
/// key is active, so the confirmation lives in the card, not in an overlay.
struct OnboardingKeyCap: View {
    let trigger: HotkeyTrigger
    let caption: String
    let isLit: Bool
    var size: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripple = false

    private var isFnKey: Bool {
        trigger.kind == .modifier && trigger.modifierName == "fn"
    }

    private var capWidth: CGFloat {
        // Wide keys (chords, named keys) get room for their label.
        isFnKey ? size : max(size, CGFloat(trigger.shortSymbol.count) * 11 + 30)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if isLit && !reduceMotion {
                    RoundedRectangle(cornerRadius: size * 0.2)
                        .stroke(DesignSystem.Colors.accent.opacity(ripple ? 0 : 0.5), lineWidth: 2)
                        .frame(width: capWidth, height: size * 0.92)
                        .scaleEffect(ripple ? 1.35 : 1)
                        .onAppear {
                            ripple = false
                            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                ripple = true
                            }
                        }
                        .onDisappear { ripple = false }
                }

                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(
                        LinearGradient(
                            colors: isLit
                                ? [DesignSystem.Colors.accent.opacity(0.30), DesignSystem.Colors.accent.opacity(0.18)]
                                : [DesignSystem.Colors.cardBackground, DesignSystem.Colors.surfaceElevated],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.2)
                            .strokeBorder(
                                isLit ? DesignSystem.Colors.accent : DesignSystem.Colors.border,
                                lineWidth: isLit ? 1.5 : 1
                            )
                    )
                    // The resting key sits on a darker lip; pressed, the lip
                    // disappears and the key glows.
                    .shadow(
                        color: isLit ? DesignSystem.Colors.accent.opacity(0.45) : .black.opacity(0.12),
                        radius: isLit ? 10 : 0,
                        x: 0,
                        y: isLit ? 0 : 2
                    )
                    .frame(width: capWidth, height: size * 0.92)
                    .overlay { legend }
                    .offset(y: isLit ? 1.5 : 0)
            }
            .frame(width: capWidth + 16, height: size + 8)

            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLit ? DesignSystem.Colors.accent : .secondary)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isLit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trigger.displayName), \(caption)")
        .accessibilityValue(isLit ? "Lit" : "At rest")
    }

    @ViewBuilder
    private var legend: some View {
        let color: Color = isLit ? DesignSystem.Colors.accentDark : .primary
        if isFnKey {
            // The Mac fn key: "fn" top right, globe bottom left.
            ZStack {
                Text("fn")
                    .font(.system(size: size * 0.2, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                Image(systemName: "globe")
                    .font(.system(size: size * 0.19, weight: .regular))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .foregroundStyle(color)
            .padding(size * 0.14)
        } else {
            Text(trigger.shortSymbol)
                .font(.system(size: size * 0.24, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
        }
    }
}

/// A small inline key for instruction copy ("Hold [fn] and ...").
struct InlineKeyCap: View {
    let label: String
    var isLit = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(isLit ? DesignSystem.Colors.accentDark : .primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isLit ? DesignSystem.Colors.accent.opacity(0.22) : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isLit ? DesignSystem.Colors.accent : DesignSystem.Colors.border, lineWidth: isLit ? 1 : 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: isLit)
    }
}

// MARK: - Seed of life backdrop

/// A faint seed-of-life figure behind the key caps. Decorative only; it lifts
/// the rehearsal area off the card without adding a separate illustration.
struct SeedOfLifeBackdrop: View {
    var tint: Color = DesignSystem.Colors.accent
    var glow: Bool = false

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.36
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3
                let c = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            context.stroke(path, with: .color(tint.opacity(glow ? 0.16 : 0.07)), lineWidth: 0.8)
        }
        .animation(.easeInOut(duration: 0.3), value: glow)
        .accessibilityHidden(true)
    }
}

// MARK: - Listening wave

/// A small animated wave that says "listening" inside the practice box. The
/// real overlay pill still shows the live level meter.
struct ListeningWave: View {
    var tint: Color = DesignSystem.Colors.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = sin(t * 7 + Double(i) * 0.9)
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: reduceMotion ? 8 : 5 + 7 * CGFloat((phase + 1) / 2))
                }
            }
            .frame(height: 14)
        }
        .accessibilityHidden(true)
    }
}
