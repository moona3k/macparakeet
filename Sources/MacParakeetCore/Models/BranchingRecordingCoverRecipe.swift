import Foundation

/// The frozen v2, UUID-only recipe for a missing-recording cover.
///
/// Version 2 draws a Seed of Life: seven equal circles on a locked night
/// field. The UUID may rotate the figure, light one or two rings, drift the
/// center slightly, and shift sage ink by at most 12°. It does not choose a
/// second palette family, a gold nucleus, or branches.
///
/// The recipe holds normalized geometry and ink rather than a raster.
/// SwiftUI owns drawing it in the app target; callers can reuse this small
/// value without reading audio, transcript, database, or cache state.
public struct BranchingRecordingCoverRecipe: Sendable, Equatable {
    public static let version = 2
    public static let ringCount = 7
    public static let presentScale = 0.76
    public static let maximumHueShiftDegrees = 12.0
    public static let nightBackground = BranchingRecordingCoverColor(
        red: 20.0 / 255.0,
        green: 25.0 / 255.0,
        blue: 27.0 / 255.0
    )
    private static let sageInk = BranchingRecordingCoverColor(
        red: 126.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 154.0 / 255.0
    )
    private static let paleInk = BranchingRecordingCoverColor(
        red: 186.0 / 255.0,
        green: 214.0 / 255.0,
        blue: 204.0 / 255.0
    )

    public let center: BranchingRecordingCoverPoint
    /// Fraction of `min(width, height)` at draw time.
    public let radius: Double
    public let rotation: Double
    /// Sorted unique indexes into the seven Seed of Life circles.
    public let litRingIndexes: [Int]
    public let hueShiftDegrees: Double
    public let ink: BranchingRecordingCoverColor
    public let pale: BranchingRecordingCoverColor

    public init(recordingID: UUID) {
        var geometryRandom = SplitMix64(
            seed: Self.stableSeed(for: recordingID, domain: "geometry")
        )
        var inkRandom = SplitMix64(
            seed: Self.stableSeed(for: recordingID, domain: "ink")
        )

        center = BranchingRecordingCoverPoint(
            x: 0.50 + (geometryRandom.nextUnit() - 0.5) * 0.02,
            y: 0.40 + (geometryRandom.nextUnit() - 0.5) * 0.02
        )
        radius = (0.168 + geometryRandom.nextUnit() * 0.012) * Self.presentScale
        rotation = geometryRandom.nextUnit() * (Double.pi / 3)
        let firstLit = geometryRandom.nextInt(upperBound: Self.ringCount)
        let secondLit = geometryRandom.nextInt(upperBound: Self.ringCount)
        litRingIndexes = Array(Set([firstLit, secondLit])).sorted()

        hueShiftDegrees = (inkRandom.nextUnit() - 0.5) * (Self.maximumHueShiftDegrees * 2)
        ink = Self.hueShifted(Self.sageInk, degrees: hueShiftDegrees)
        pale = Self.hueShifted(Self.paleInk, degrees: hueShiftDegrees)
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

    private static func hueShifted(
        _ color: BranchingRecordingCoverColor,
        degrees: Double
    ) -> BranchingRecordingCoverColor {
        let hsl = rgbToHSL(color)
        var hue = hsl.hue + degrees / 360.0
        hue = hue.truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return hslToRGB(hue: hue, saturation: hsl.saturation, lightness: hsl.lightness)
    }

    private static func rgbToHSL(
        _ color: BranchingRecordingCoverColor
    ) -> (hue: Double, saturation: Double, lightness: Double) {
        let maxChannel = max(color.red, color.green, color.blue)
        let minChannel = min(color.red, color.green, color.blue)
        let lightness = (maxChannel + minChannel) / 2
        let delta = maxChannel - minChannel
        guard delta > 0 else {
            return (0, 0, lightness)
        }

        let saturation =
            lightness > 0.5
            ? delta / (2 - maxChannel - minChannel)
            : delta / (maxChannel + minChannel)
        let hue: Double
        if maxChannel == color.red {
            hue = (color.green - color.blue) / delta + (color.green < color.blue ? 6 : 0)
        } else if maxChannel == color.green {
            hue = (color.blue - color.red) / delta + 2
        } else {
            hue = (color.red - color.green) / delta + 4
        }
        return (hue / 6, saturation, lightness)
    }

    private static func hslToRGB(
        hue: Double,
        saturation: Double,
        lightness: Double
    ) -> BranchingRecordingCoverColor {
        guard saturation > 0 else {
            return BranchingRecordingCoverColor(red: lightness, green: lightness, blue: lightness)
        }

        let q =
            lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        return BranchingRecordingCoverColor(
            red: hueChannel(p: p, q: q, t: hue + 1.0 / 3.0),
            green: hueChannel(p: p, q: q, t: hue),
            blue: hueChannel(p: p, q: q, t: hue - 1.0 / 3.0)
        )
    }

    private static func hueChannel(p: Double, q: Double, t: Double) -> Double {
        var wrapped = t
        if wrapped < 0 { wrapped += 1 }
        if wrapped > 1 { wrapped -= 1 }
        if wrapped < 1.0 / 6.0 { return p + (q - p) * 6 * wrapped }
        if wrapped < 1.0 / 2.0 { return q }
        if wrapped < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - wrapped) * 6 }
        return p
    }
}

public struct BranchingRecordingCoverPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BranchingRecordingCoverColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
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
