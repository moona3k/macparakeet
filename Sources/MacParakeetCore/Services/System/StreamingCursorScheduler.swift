import Foundation

/// Caps and streamability rules for optional dictation caret streaming (#449).
public enum StreamingCursorPolicy: Sendable {
    /// `CGEventKeyboardSetUnicodeString` truncates around this many UTF-16 units.
    public static let maxUTF16PerEvent = 20
    public static let minMotionDuration: Duration = .milliseconds(180)
    public static let maxMotionDuration: Duration = .milliseconds(420)
    public static let settleDuration: Duration = .milliseconds(80)
    public static let minGraphemesForMotion = 4
    public static let millisecondsPerGrapheme = 12.0
    public static let targetHz = 120.0
    public static let maxAnimationBatches = 48

    public static func isStreamable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            return false
        }
        for grapheme in text {
            if String(grapheme).utf16.count > maxUTF16PerEvent {
                return false
            }
        }
        return true
    }

    /// Non-ASCII-capable IMEs may ignore Unicode HID payloads and treat keycode 0 as `a`.
    /// Unknown capability fails closed to paste.
    public static func inputSourceAllowsStreaming(asciiCapable: Bool?) -> Bool {
        asciiCapable ?? false
    }
}

public struct StreamingCursorBatch: Equatable, Sendable {
    public let text: String
    public let delayBefore: Duration

    public init(text: String, delayBefore: Duration) {
        self.text = text
        self.delayBefore = delayBefore
    }
}

public struct StreamingCursorSchedule: Equatable, Sendable {
    public let batches: [StreamingCursorBatch]

    public var isInstant: Bool {
        batches.count <= 1 || batches.allSatisfy { $0.delayBefore == .zero }
    }

    public func remainingText(from index: Int) -> String {
        guard index >= 0, index < batches.count else { return "" }
        return batches[index...].map(\.text).joined()
    }
}

public enum StreamingCursorScheduler: Sendable {
    public static func schedule(_ text: String) -> StreamingCursorSchedule {
        let graphemes = text.map(String.init)
        guard !graphemes.isEmpty else {
            return StreamingCursorSchedule(batches: [])
        }
        if graphemes.contains(where: { $0.utf16.count > StreamingCursorPolicy.maxUTF16PerEvent }) {
            return StreamingCursorSchedule(batches: [])
        }

        let graphemeCount = graphemes.count
        if graphemeCount < StreamingCursorPolicy.minGraphemesForMotion {
            return StreamingCursorSchedule(
                batches: utf16LimitedChunks(graphemes).map {
                    StreamingCursorBatch(text: $0, delayBefore: .zero)
                }
            )
        }

        let rawMs = StreamingCursorPolicy.millisecondsPerGrapheme * Double(graphemeCount)
        let durationMs = min(
            max(rawMs, milliseconds(StreamingCursorPolicy.minMotionDuration)),
            milliseconds(StreamingCursorPolicy.maxMotionDuration)
        )
        let hzBatches = Int(ceil(durationMs * StreamingCursorPolicy.targetHz / 1_000))
        let animationCount = min(
            graphemeCount,
            StreamingCursorPolicy.maxAnimationBatches,
            max(2, hzBatches)
        )
        let groups = splitEvenly(graphemes, into: animationCount)
        let duration = Duration.milliseconds(durationMs)
        let last = groups.count - 1
        var previous: Duration = .zero
        var batches: [StreamingCursorBatch] = []

        for (index, group) in groups.enumerated() {
            let time: Duration
            if last == 0 {
                time = .zero
            } else {
                let progress = Double(index) / Double(last)
                time = scaled(duration, by: inverseEaseOutCubic(progress))
            }
            let delay = index == 0 ? .zero : time - previous
            previous = time
            let chunks = utf16LimitedChunks(group)
            for (chunkIndex, chunk) in chunks.enumerated() {
                batches.append(
                    StreamingCursorBatch(
                        text: chunk,
                        delayBefore: chunkIndex == 0 ? delay : .zero
                    )
                )
            }
        }

        return StreamingCursorSchedule(batches: batches)
    }

    static func utf16LimitedChunks(_ graphemes: [String]) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUTF16 = 0
        for piece in graphemes {
            let n = piece.utf16.count
            if n > StreamingCursorPolicy.maxUTF16PerEvent {
                return []
            }
            if !current.isEmpty, currentUTF16 + n > StreamingCursorPolicy.maxUTF16PerEvent {
                chunks.append(current)
                current = piece
                currentUTF16 = n
            } else {
                current += piece
                currentUTF16 += n
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func splitEvenly(_ graphemes: [String], into count: Int) -> [[String]] {
        let groupCount = min(max(count, 1), graphemes.count)
        var groups: [[String]] = []
        groups.reserveCapacity(groupCount)
        var index = 0
        for groupIndex in 0..<groupCount {
            let remainingGroups = groupCount - groupIndex
            let remainingItems = graphemes.count - index
            let size = (remainingItems + remainingGroups - 1) / remainingGroups
            groups.append(Array(graphemes[index..<(index + size)]))
            index += size
        }
        return groups
    }

    /// Inverse of easeOutCubic so text races early and lingers at the end.
    private static func inverseEaseOutCubic(_ p: Double) -> Double {
        let clamped = min(max(p, 0), 1)
        return 1 - pow(1 - clamped, 1.0 / 3.0)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func scaled(_ duration: Duration, by scale: Double) -> Duration {
        Duration.milliseconds(milliseconds(duration) * scale)
    }
}
