import Foundation

/// One diarized speech segment returned by VibeVoice-ASR.
///
/// VibeVoice's C ABI emits JSON of shape
///   `[{"Start": <sec>, "End": <sec>, "Speaker": <int>, "Content": <string>}]`
/// per audio file. This struct mirrors that shape exactly so the JSON
/// decoder can hydrate it without custom transforms.
///
/// `startSec` / `endSec` are in seconds relative to the input audio.
/// `speakerId` is VibeVoice's internal speaker label (0-indexed). Maps
/// to MacParakeet's existing speaker model in the Phase 2.2 wire-up.
public struct DiarizedSegment: Sendable, Equatable, Codable {
    public let startSec: Double
    public let endSec: Double
    public let speakerId: Int
    public let text: String

    public init(startSec: Double, endSec: Double, speakerId: Int, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.speakerId = speakerId
        self.text = text
    }

    /// Custom keys: vibevoice.cpp returns PascalCase fields per the
    /// Microsoft VibeVoice reference implementation.
    private enum CodingKeys: String, CodingKey {
        case startSec = "Start"
        case endSec = "End"
        case speakerId = "Speaker"
        case text = "Content"
    }
}
