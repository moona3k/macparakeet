import Foundation

/// The fixed v1, UUID-only recipe for a missing-recording cover.
///
/// The recipe deliberately holds normalized geometry and palette decisions rather
/// than a raster. SwiftUI owns drawing it in the app target; callers can reuse
/// this small value without reading audio, transcript, database, or cache state.
public struct BranchingRecordingCoverRecipe: Sendable, Equatable {
    static let version = 1
    static let maximumLimbCount = 96
    /// A bounded amount of off-canvas growth keeps the clipped composition
    /// organic without making a Canvas redraw unbounded.
    static let maximumNormalizedCoordinateMagnitude = 2.0

    public let palette: BranchingRecordingCoverPalette
    public let focalPoint: BranchingRecordingCoverPoint
    public let limbs: [BranchingRecordingCoverLimb]

    public init(recordingID: UUID) {
        var paletteFamilyRandom = SplitMix64(
            seed: Self.stableSeed(for: recordingID, domain: "palette-family")
        )
        var paletteVariantRandom = SplitMix64(
            seed: Self.stableSeed(for: recordingID, domain: "palette-variant")
        )
        palette = BranchingRecordingCoverPalette(
            family: BranchingRecordingCoverPalette.Family.allCases[
                paletteFamilyRandom.nextInt(upperBound: BranchingRecordingCoverPalette.Family.allCases.count)
            ],
            variant: paletteVariantRandom.nextInt(upperBound: BranchingRecordingCoverPalette.variantCount)
        )

        var geometryRandom = SplitMix64(
            seed: Self.stableSeed(for: recordingID, domain: "geometry")
        )
        focalPoint = BranchingRecordingCoverPoint(
            x: 0.43 + geometryRandom.nextUnit() * 0.14,
            y: 0.42 + geometryRandom.nextUnit() * 0.16
        )

        var generatedLimbs: [BranchingRecordingCoverLimb] = []
        // Six roots remain safely below the 96-limb cap even when every
        // descendant splits at each of the three bounded depths (6 × 15 = 90).
        let primaryCount = 5 + geometryRandom.nextInt(upperBound: 2)
        let phase = geometryRandom.nextUnit() * Double.pi * 2

        for index in 0..<primaryCount {
            let angle =
                phase
                + (Double(index) / Double(primaryCount)) * Double.pi * 2
                + (geometryRandom.nextUnit() - 0.5) * 0.30
            Self.appendLimb(
                from: focalPoint,
                angle: angle,
                // Keep the first generation compact enough that its smaller
                // descendants remain legible inside a thumbnail.
                length: 0.14 + geometryRandom.nextUnit() * 0.065,
                width: 0.060 + geometryRandom.nextUnit() * 0.025,
                depth: 0,
                random: &geometryRandom,
                limbs: &generatedLimbs
            )
        }

        // Canvas receives this back-to-front order directly; do not sort in its
        // drawing closure while a library grid is scrolling.
        limbs = generatedLimbs.sorted { $0.depth > $1.depth }
    }

    /// FNV-1a over the recipe domain followed by the UUID's RFC 4122 bytes,
    /// ordered exactly as the canonical UUID string's hex pairs. Do not replace
    /// this with `hashValue`, whose seed changes between process launches.
    static func stableSeed(for recordingID: UUID, domain: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        let input = Array("MacParakeet.recording-cover.v\(version).\(domain)".utf8) + uuidBytes(recordingID)
        for byte in input {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
        return value
    }

    /// RFC 4122 network byte order, exposed internally so tests can pin this
    /// contract without depending on the platform representation of `uuid_t`.
    static func uuidBytes(_ recordingID: UUID) -> [UInt8] {
        let value = recordingID.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ]
    }

    private static func appendLimb(
        from start: BranchingRecordingCoverPoint,
        angle: Double,
        length: Double,
        width: Double,
        depth: Int,
        random: inout SplitMix64,
        limbs: inout [BranchingRecordingCoverLimb]
    ) {
        guard limbs.count < maximumLimbCount, depth <= 3, length >= 0.035 else { return }

        let bend = (random.nextUnit() - 0.5) * (0.36 + Double(depth) * 0.08)
        let endAngle = angle + bend
        let endpoint = start.translated(
            x: cos(endAngle) * length,
            y: sin(endAngle) * length * (16.0 / 9.0)
        )
        let controlAngle = angle + bend * 0.35
        let control = start.translated(
            x: cos(controlAngle) * length * 0.53,
            y: sin(controlAngle) * length * 0.53 * (16.0 / 9.0)
        )
        let pigment: BranchingRecordingCoverPigment
        switch (depth + random.nextInt(upperBound: 3)) % 3 {
        case 0: pigment = .field
        case 1: pigment = .branch
        default: pigment = .accent
        }

        limbs.append(
            BranchingRecordingCoverLimb(
                start: start,
                control: control,
                end: endpoint,
                startWidth: width,
                endWidth: width * (0.30 + random.nextUnit() * 0.16),
                depth: depth,
                pigment: pigment,
                opacity: 0.84 - Double(depth) * 0.14
            )
        )

        guard depth < 3 else { return }
        let childCount: Int
        if depth == 0 {
            childCount = 2
        } else {
            childCount = random.nextUnit() < 0.68 ? 2 : 1
        }

        for childIndex in 0..<childCount where limbs.count < maximumLimbCount {
            let side = childCount == 1 ? (random.nextUnit() - 0.5) : (childIndex == 0 ? -1.0 : 1.0)
            let spread = 0.32 + random.nextUnit() * 0.28
            appendLimb(
                from: endpoint,
                angle: endAngle + side * spread,
                length: length * (0.53 + random.nextUnit() * 0.10),
                width: width * (0.56 + random.nextUnit() * 0.07),
                depth: depth + 1,
                random: &random,
                limbs: &limbs
            )
        }
    }
}

public struct BranchingRecordingCoverPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func translated(x: Double, y: Double) -> Self {
        Self(x: self.x + x, y: self.y + y)
    }
}

public struct BranchingRecordingCoverLimb: Sendable, Equatable {
    public let start: BranchingRecordingCoverPoint
    public let control: BranchingRecordingCoverPoint
    public let end: BranchingRecordingCoverPoint
    public let startWidth: Double
    public let endWidth: Double
    public let depth: Int
    public let pigment: BranchingRecordingCoverPigment
    public let opacity: Double
}

public enum BranchingRecordingCoverPigment: Sendable, Equatable {
    case field
    case branch
    case accent
}

public struct BranchingRecordingCoverColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct BranchingRecordingCoverPalette: Sendable, Equatable {
    enum Family: String, CaseIterable, Sendable {
        case tidalStone
        case lichenDusk
        case plumMineral
    }

    static let variantCount = 3

    let family: Family
    let variant: Int
    public let colors: BranchingRecordingCoverPaletteColors

    init(family: Family, variant: Int) {
        self.family = family
        self.variant = min(max(variant, 0), Self.variantCount - 1)
        colors = Self.resolvedColors(family: family, variant: self.variant)
    }

    private static func resolvedColors(
        family: Family,
        variant: Int
    ) -> BranchingRecordingCoverPaletteColors {
        let variants: [BranchingRecordingCoverPaletteColors]
        switch family {
        case .tidalStone:
            variants = [
                .init(
                    background: .init(red: 0.063, green: 0.125, blue: 0.145),
                    field: .init(red: 0.094, green: 0.318, blue: 0.345),
                    branch: .init(red: 0.263, green: 0.651, blue: 0.647),
                    accent: .init(red: 0.894, green: 0.643, blue: 0.376),
                    line: .init(red: 0.718, green: 0.847, blue: 0.804)),
                .init(
                    background: .init(red: 0.078, green: 0.125, blue: 0.153),
                    field: .init(red: 0.192, green: 0.322, blue: 0.376),
                    branch: .init(red: 0.373, green: 0.624, blue: 0.714),
                    accent: .init(red: 0.843, green: 0.604, blue: 0.408),
                    line: .init(red: 0.761, green: 0.808, blue: 0.816)),
                .init(
                    background: .init(red: 0.075, green: 0.129, blue: 0.129),
                    field: .init(red: 0.176, green: 0.333, blue: 0.314),
                    branch: .init(red: 0.400, green: 0.678, blue: 0.596),
                    accent: .init(red: 0.851, green: 0.651, blue: 0.396),
                    line: .init(red: 0.769, green: 0.824, blue: 0.714)),
            ]
        case .lichenDusk:
            variants = [
                .init(
                    background: .init(red: 0.082, green: 0.133, blue: 0.114),
                    field: .init(red: 0.192, green: 0.365, blue: 0.282),
                    branch: .init(red: 0.475, green: 0.706, blue: 0.553),
                    accent: .init(red: 0.859, green: 0.647, blue: 0.392),
                    line: .init(red: 0.765, green: 0.835, blue: 0.635)),
                .init(
                    background: .init(red: 0.106, green: 0.129, blue: 0.106),
                    field: .init(red: 0.290, green: 0.353, blue: 0.212),
                    branch: .init(red: 0.612, green: 0.698, blue: 0.459),
                    accent: .init(red: 0.788, green: 0.604, blue: 0.400),
                    line: .init(red: 0.835, green: 0.812, blue: 0.631)),
                .init(
                    background: .init(red: 0.090, green: 0.129, blue: 0.118),
                    field: .init(red: 0.192, green: 0.337, blue: 0.314),
                    branch: .init(red: 0.416, green: 0.667, blue: 0.616),
                    accent: .init(red: 0.867, green: 0.631, blue: 0.408),
                    line: .init(red: 0.722, green: 0.816, blue: 0.694)),
            ]
        case .plumMineral:
            variants = [
                .init(
                    background: .init(red: 0.129, green: 0.098, blue: 0.145),
                    field: .init(red: 0.388, green: 0.243, blue: 0.376),
                    branch: .init(red: 0.678, green: 0.459, blue: 0.635),
                    accent: .init(red: 0.886, green: 0.631, blue: 0.443),
                    line: .init(red: 0.839, green: 0.706, blue: 0.792)),
                .init(
                    background: .init(red: 0.129, green: 0.106, blue: 0.145),
                    field: .init(red: 0.318, green: 0.235, blue: 0.408),
                    branch: .init(red: 0.549, green: 0.467, blue: 0.714),
                    accent: .init(red: 0.851, green: 0.616, blue: 0.459),
                    line: .init(red: 0.780, green: 0.725, blue: 0.855)),
                .init(
                    background: .init(red: 0.145, green: 0.106, blue: 0.125),
                    field: .init(red: 0.412, green: 0.275, blue: 0.314),
                    branch: .init(red: 0.725, green: 0.478, blue: 0.518),
                    accent: .init(red: 0.886, green: 0.627, blue: 0.427),
                    line: .init(red: 0.851, green: 0.722, blue: 0.733)),
            ]
        }
        return variants[variant]
    }
}

public struct BranchingRecordingCoverPaletteColors: Sendable, Equatable {
    public let background: BranchingRecordingCoverColor
    public let field: BranchingRecordingCoverColor
    public let branch: BranchingRecordingCoverColor
    public let accent: BranchingRecordingCoverColor
    public let line: BranchingRecordingCoverColor
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
