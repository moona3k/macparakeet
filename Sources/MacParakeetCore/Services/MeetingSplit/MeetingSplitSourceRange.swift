import Foundation

/// A contiguous slice of the source recording's original millisecond
/// timeline, `[startMs, endMs)`. This is a plain audio-range value: it carries
/// no transcript, speaker or word-timing meaning, and nothing here partitions
/// text or copies speaker baselines. See `spec/contracts/meeting-splitting.md`.
public struct MeetingSplitSourceRange: Codable, Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { endMs - startMs }
}

public enum MeetingSplitCutValidationError: Error, Sendable, Equatable {
    /// The source duration itself is not usable (zero or negative).
    case invalidDuration(durationMs: Int)
    /// No cuts were supplied; splitting requires at least one.
    case noCuts
    /// A cut falls at or outside the source's own bounds: `0` or `durationMs`
    /// would produce an empty leading/trailing part, not a valid interior cut.
    case cutOutOfRange(ms: Int, durationMs: Int)
    /// Cuts must be strictly ascending; this also catches exact duplicates.
    case unorderedOrDuplicateCuts(ms: [Int])
}

/// Turns user-approved cut points into contiguous, gapless
/// `MeetingSplitSourceRange`s covering the entire validated source duration.
/// Cuts may fall inside a word or anywhere else in the audio: this validator
/// never inspects transcript content, timing or speaker data, and it never
/// moves a boundary the user chose.
public enum MeetingSplitGeometry {
    /// - Parameters:
    ///   - durationMs: The source's actual validated audio duration.
    ///   - cutPointsMs: Strictly ascending interior cut points, each strictly
    ///     between `0` and `durationMs`.
    /// - Returns: `cutPointsMs.count + 1` contiguous ranges, in source order,
    ///   whose bounds exactly partition `[0, durationMs)` with no gap or overlap.
    public static func ranges(durationMs: Int, cutPointsMs: [Int]) throws -> [MeetingSplitSourceRange] {
        guard durationMs > 0 else {
            throw MeetingSplitCutValidationError.invalidDuration(durationMs: durationMs)
        }
        guard !cutPointsMs.isEmpty else {
            throw MeetingSplitCutValidationError.noCuts
        }

        var previous = 0
        for cut in cutPointsMs {
            guard cut > 0, cut < durationMs else {
                throw MeetingSplitCutValidationError.cutOutOfRange(ms: cut, durationMs: durationMs)
            }
            guard cut > previous else {
                throw MeetingSplitCutValidationError.unorderedOrDuplicateCuts(ms: cutPointsMs)
            }
            previous = cut
        }

        let boundaries = [0] + cutPointsMs + [durationMs]
        return zip(boundaries, boundaries.dropFirst()).map {
            MeetingSplitSourceRange(startMs: $0, endMs: $1)
        }
    }
}
