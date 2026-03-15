import SwiftUI

// MARK: - Pattern Enum

enum SacredGeometryPattern: String, CaseIterable {
    case flowerOfLife
    case metatronsCube
    case seedOfLife
    case sriYantra
    case vesicaPiscis
    case merkaba
    case goldenSpiral
    case torus
    case cymaticRing
}

// MARK: - Pattern View

struct SacredGeometryView: View {
    let pattern: SacredGeometryPattern
    let size: CGFloat
    let color: Color
    let lineWidth: CGFloat

    init(pattern: SacredGeometryPattern, size: CGFloat = 100, color: Color, lineWidth: CGFloat = 0.6) {
        self.pattern = pattern
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    var body: some View {
        shapeView
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var shapeView: some View {
        switch pattern {
        case .flowerOfLife:
            FlowerOfLifeShape()
                .stroke(color, lineWidth: lineWidth)
        case .metatronsCube:
            MetatronsCubeShape()
                .stroke(color, lineWidth: lineWidth)
        case .seedOfLife:
            SeedOfLifeShape()
                .stroke(color, lineWidth: lineWidth)
        case .sriYantra:
            SriYantraShape()
                .stroke(color, lineWidth: lineWidth)
        case .vesicaPiscis:
            VesicaPiscisShape()
                .stroke(color, lineWidth: lineWidth)
        case .merkaba:
            MerkabaShape()
                .stroke(color, lineWidth: lineWidth)
        case .goldenSpiral:
            GoldenSpiralShape()
                .stroke(color, lineWidth: lineWidth)
        case .torus:
            TorusShape()
                .stroke(color, lineWidth: lineWidth)
        case .cymaticRing:
            CymaticRingShape()
                .stroke(color, lineWidth: lineWidth)
        }
    }
}

// MARK: - Trig helpers (CGFloat-native to avoid ambiguity)

private func ccos(_ a: CGFloat) -> CGFloat { CoreGraphics.cos(a) }
private func ssin(_ a: CGFloat) -> CGFloat { CoreGraphics.sin(a) }
private func ssqrt(_ v: CGFloat) -> CGFloat { CoreGraphics.sqrt(v) }

private func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

// MARK: - Flower of Life
// 19 circles: 1 center + 6 inner ring + 12 outer ring (two full layers)

struct FlowerOfLifeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 6.0

        // Center circle
        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: r))

        // First ring: 6 circles at distance r
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0
            path.addEllipse(in: circleRect(center: CGPoint(x: cx + r * ccos(a), y: cy + r * ssin(a)), radius: r))
        }

        // Second ring: 6 circles at distance 2r (aligned)
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0
            path.addEllipse(in: circleRect(center: CGPoint(x: cx + 2 * r * ccos(a), y: cy + 2 * r * ssin(a)), radius: r))
        }

        // Second ring: 6 circles at distance sqrt(3)*r (offset 30 degrees)
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0 + .pi / 6.0
            let d = r * ssqrt(3.0)
            path.addEllipse(in: circleRect(center: CGPoint(x: cx + d * ccos(a), y: cy + d * ssin(a)), radius: r))
        }

        // Outer bounding circle
        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: 3 * r))

        return path
    }
}

// MARK: - Metatron's Cube
// 13 circles connected by lines — contains all 5 Platonic solids

struct MetatronsCubeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let outerR = min(rect.width, rect.height) * 0.45
        let innerR = outerR / 2.0
        let nodeR = outerR * 0.06

        var nodes: [CGPoint] = [CGPoint(x: cx, y: cy)]

        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0 - .pi / 2.0
            nodes.append(CGPoint(x: cx + innerR * ccos(a), y: cy + innerR * ssin(a)))
        }
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0 - .pi / 2.0
            nodes.append(CGPoint(x: cx + outerR * ccos(a), y: cy + outerR * ssin(a)))
        }

        // Connect every node to every other
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                path.move(to: nodes[i])
                path.addLine(to: nodes[j])
            }
        }

        // Node circles
        for node in nodes {
            path.addEllipse(in: circleRect(center: node, radius: nodeR))
        }

        return path
    }
}

// MARK: - Seed of Life
// 7 overlapping circles of equal radius — the genesis pattern

struct SeedOfLifeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 4.0

        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: r))

        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0
            path.addEllipse(in: circleRect(center: CGPoint(x: cx + r * ccos(a), y: cy + r * ssin(a)), radius: r))
        }

        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: 2 * r))

        return path
    }
}

// MARK: - Sri Yantra (Simplified)
// 9 interlocking triangles — 4 upward (Shiva) + 5 downward (Shakti)

struct SriYantraShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let s = min(rect.width, rect.height) * 0.45

        let upScales: [CGFloat] = [1.0, 0.72, 0.48, 0.28]
        let upOffsets: [CGFloat] = [0.08, 0.04, 0.0, -0.04]
        for (scale, offset) in zip(upScales, upOffsets) {
            let h = s * scale
            let oy = cy + h * offset
            path.move(to: CGPoint(x: cx, y: oy - h * 0.85))
            path.addLine(to: CGPoint(x: cx - h, y: oy + h * 0.5))
            path.addLine(to: CGPoint(x: cx + h, y: oy + h * 0.5))
            path.closeSubpath()
        }

        let downScales: [CGFloat] = [0.92, 0.68, 0.5, 0.34, 0.18]
        let downOffsets: [CGFloat] = [-0.06, -0.02, 0.02, 0.04, 0.06]
        for (scale, offset) in zip(downScales, downOffsets) {
            let h = s * scale
            let oy = cy + h * offset
            path.move(to: CGPoint(x: cx, y: oy + h * 0.85))
            path.addLine(to: CGPoint(x: cx - h, y: oy - h * 0.5))
            path.addLine(to: CGPoint(x: cx + h, y: oy - h * 0.5))
            path.closeSubpath()
        }

        // Bindu (central point)
        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: s * 0.02))

        // Outer circle
        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: s))

        return path
    }
}

// MARK: - Vesica Piscis
// Two overlapping circles — the womb of creation

struct VesicaPiscisShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.35
        let off = r / 2.0

        path.addEllipse(in: circleRect(center: CGPoint(x: cx - off, y: cy), radius: r))
        path.addEllipse(in: circleRect(center: CGPoint(x: cx + off, y: cy), radius: r))

        // Vesica intersection line
        let h = ssqrt(3.0) / 2.0 * r
        path.move(to: CGPoint(x: cx, y: cy - h))
        path.addLine(to: CGPoint(x: cx, y: cy + h))

        return path
    }
}

// MARK: - Merkaba
// Star tetrahedron — two interlocking equilateral triangles (2D projection)

struct MerkabaShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.42

        // Upward triangle
        for i in 0..<3 {
            let a = CGFloat(i) * 2.0 * .pi / 3.0 - .pi / 2.0
            let pt = CGPoint(x: cx + r * ccos(a), y: cy + r * ssin(a))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        // Downward triangle
        for i in 0..<3 {
            let a = CGFloat(i) * 2.0 * .pi / 3.0 + .pi / 2.0
            let pt = CGPoint(x: cx + r * ccos(a), y: cy + r * ssin(a))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        // Inner hexagon
        let ir = r * 0.5
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3.0
            let pt = CGPoint(x: cx + ir * ccos(a), y: cy + ir * ssin(a))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        // Outer circle
        path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: r))

        return path
    }
}

// MARK: - Golden Spiral
// Fibonacci spiral — logarithmic growth from center outward

struct GoldenSpiralShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let maxR = min(rect.width, rect.height) * 0.44

        // Logarithmic spiral: r = a * e^(b*theta) where b = ln(phi) / (pi/2)
        let phi: CGFloat = (1.0 + ssqrt(5.0)) / 2.0
        let b = CoreGraphics.log(phi) / (.pi / 2.0)
        let a = maxR / CoreGraphics.exp(b * 4.0 * .pi) // Scale to fit

        let steps = 200
        let maxTheta: CGFloat = 4.0 * .pi
        for i in 0...steps {
            let theta = maxTheta * CGFloat(i) / CGFloat(steps)
            let r = a * CoreGraphics.exp(b * theta)
            let x = cx + r * ccos(theta)
            let y = cy + r * ssin(theta)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        // A few guide circles at Fibonacci radii
        let fibRadii: [CGFloat] = [0.15, 0.25, 0.4, 0.65]
        for fr in fibRadii {
            let r = maxR * fr
            path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: r))
        }

        return path
    }
}

// MARK: - Torus
// Energy field — concentric ellipses rotated to form a donut cross-section

struct TorusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let outerR = min(rect.width, rect.height) * 0.44
        let innerR = outerR * 0.3

        let lineCount = 8
        for i in 0..<lineCount {
            let angle = CGFloat(i) * .pi / CGFloat(lineCount)
            let cosA = ccos(angle)
            let sinA = ssin(angle)

            let steps = 64
            for j in 0...steps {
                let t = CGFloat(j) / CGFloat(steps) * 2.0 * .pi
                let r = innerR + (outerR - innerR) * 0.5 * (1.0 + ccos(t))
                let x = r * ccos(t)
                let y = (outerR * 0.6) * ssin(t)

                let rx = x * cosA - y * sinA
                let ry = x * sinA + y * cosA

                let pt = CGPoint(x: cx + rx, y: cy + ry)
                if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }

        // Central axis
        path.move(to: CGPoint(x: cx, y: cy - outerR * 0.85))
        path.addLine(to: CGPoint(x: cx, y: cy + outerR * 0.85))

        return path
    }
}

// MARK: - Cymatic Ring
// Concentric rings with nodal points — standing wave patterns

struct CymaticRingShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let maxR = min(rect.width, rect.height) * 0.44

        // Concentric rings
        for i in 1...5 {
            let r = maxR * CGFloat(i) / 5.0
            path.addEllipse(in: circleRect(center: CGPoint(x: cx, y: cy), radius: r))
        }

        // Nodal radial lines with sine-wave modulation (Chladni plate pattern)
        for i in 0..<12 {
            let angle = CGFloat(i) * .pi / 6.0
            let steps = 48
            for j in 0...steps {
                let t = CGFloat(j) / CGFloat(steps)
                let r = maxR * t
                let wobble = ssin(t * .pi * 6.0) * maxR * 0.03
                let x = cx + (r + wobble) * ccos(angle)
                let y = cy + (r + wobble) * ssin(angle)
                if j == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }

        return path
    }
}

// MARK: - Icon → Pattern Mapping

func sacredGeometryPattern(forIcon icon: String) -> SacredGeometryPattern {
    switch icon {
    case "atom", "engine.combustion":       .flowerOfLife
    case "antenna.radiowaves.left.and.right", "globe": .torus
    case "drop":                            .vesicaPiscis
    case "waveform.path", "waveform":       .cymaticRing
    case "lock.doc", "building.columns":    .metatronsCube
    case "battery.0percent", "car":         .sriYantra
    case "bolt.heart", "thermometer.medium": .seedOfLife
    case "flame":                           .merkaba
    case "leaf":                            .goldenSpiral
    case "circle.hexagongrid":              .metatronsCube
    case "sun.max":                         .flowerOfLife
    case "sparkles":                        .seedOfLife
    default:                                .flowerOfLife
    }
}
