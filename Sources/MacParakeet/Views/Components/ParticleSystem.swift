import SwiftUI

/// Lightweight particle effect for hero contexts — merkaba shimmer, portal hover, celebrations.
/// 6-12 particles max, slow drift, respects reduced motion accessibility.
struct ParticleField: View {
    var particleCount: Int = 8
    var tintColor: Color = DesignSystem.Colors.accent
    var opacity: Double = 0.3
    var driftDirection: DriftDirection = .up

    enum DriftDirection {
        case up
        case orbital
        case converge
    }

    @State private var particles: [Particle] = []
    @State private var isAnimating = false
    @State private var animationTimer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            for particle in particles {
                let x = particle.position.x * size.width
                let y = particle.position.y * size.height
                let dotSize = particle.size
                let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2,
                                  width: dotSize, height: dotSize)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(tintColor.opacity(particle.opacity * opacity))
                )
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            initParticles()
            isAnimating = true
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
    }

    private func initParticles() {
        particles = (0..<particleCount).map { _ in
            Particle(
                position: CGPoint(x: .random(in: 0.1...0.9), y: .random(in: 0.1...0.9)),
                velocity: randomVelocity(),
                size: .random(in: 2...3),
                opacity: .random(in: 0.3...0.8),
                phase: .random(in: 0...(2.0 * Double.pi))
            )
        }
    }

    private func randomVelocity() -> CGPoint {
        switch driftDirection {
        case .up:
            return CGPoint(x: .random(in: -0.001...0.001), y: .random(in: (-0.003)...(-0.001)))
        case .orbital:
            return CGPoint(x: .random(in: -0.002...0.002), y: .random(in: -0.002...0.002))
        case .converge:
            return .zero // Handled in animation
        }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard isAnimating else { return }
            updateParticles()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updateParticles() {
        for i in particles.indices {
            var p = particles[i]

            switch driftDirection {
            case .up:
                p.position.x += p.velocity.x + CGFloat(Foundation.sin(p.phase)) * 0.0005
                p.position.y += p.velocity.y
                p.phase += 0.05

                // Wrap around when going off screen
                if p.position.y < -0.05 {
                    p.position.y = 1.05
                    p.position.x = .random(in: 0.1...0.9)
                    p.opacity = .random(in: 0.3...0.8)
                }

            case .orbital:
                let cx: CGFloat = 0.5, cy: CGFloat = 0.5
                let dx = p.position.x - cx
                let dy = p.position.y - cy
                let angle = Foundation.atan2(Double(dy), Double(dx)) + 0.008
                let dist = Foundation.sqrt(Double(dx * dx + dy * dy))
                let wobble = dist + Foundation.sin(p.phase) * 0.01
                p.position.x = cx + CGFloat(Foundation.cos(angle) * wobble)
                p.position.y = cy + CGFloat(Foundation.sin(angle) * wobble)
                p.phase += 0.03

            case .converge:
                let cx: CGFloat = 0.5, cy: CGFloat = 0.5
                p.position.x += (cx - p.position.x) * 0.01
                p.position.y += (cy - p.position.y) * 0.01
                p.phase += 0.05
                p.opacity = max(0, p.opacity - 0.003)

                // Reset when too close to center
                if abs(p.position.x - cx) < 0.02 && abs(p.position.y - cy) < 0.02 {
                    p.position = CGPoint(x: .random(in: 0.05...0.95), y: .random(in: 0.05...0.95))
                    p.opacity = .random(in: 0.3...0.8)
                }
            }

            particles[i] = p
        }
    }
}

// MARK: - Particle

private struct Particle {
    var position: CGPoint
    var velocity: CGPoint
    var size: CGFloat
    var opacity: Double
    var phase: Double
}
