import Foundation

public enum RTTMParser {
    /// Evaluation fixtures support up to about 24.8 days. This also bounds
    /// downstream millisecond arithmetic for malformed external annotations.
    public static let maximumTimestampMs = Int(Int32.max)

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidSpeakerLine(lineNumber: Int)
        case invalidTime(lineNumber: Int)
        case multipleRecordings

        public var errorDescription: String? {
            switch self {
            case .invalidSpeakerLine(let lineNumber):
                return "Invalid RTTM SPEAKER line at line \(lineNumber)."
            case .invalidTime(let lineNumber):
                return "Invalid RTTM timing at line \(lineNumber)."
            case .multipleRecordings:
                return "Each fixture RTTM must describe only one recording."
            }
        }
    }

    public static func parse(_ contents: String) throws -> [LabeledSegment] {
        var segments: [LabeledSegment] = []

        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = strippedComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard fields.first == "SPEAKER" else { continue }
            guard fields.count >= 8 else {
                throw ParseError.invalidSpeakerLine(lineNumber: lineNumber)
            }

            guard let startSeconds = Double(fields[3]),
                let durationSeconds = Double(fields[4]),
                startSeconds.isFinite,
                durationSeconds.isFinite,
                startSeconds >= 0,
                durationSeconds > 0
            else {
                throw ParseError.invalidTime(lineNumber: lineNumber)
            }

            guard let startMs = Int(exactly: (startSeconds * 1000).rounded()),
                let endMs = Int(exactly: ((startSeconds + durationSeconds) * 1000).rounded()),
                endMs <= maximumTimestampMs,
                endMs > startMs
            else {
                throw ParseError.invalidTime(lineNumber: lineNumber)
            }

            if let recordingID = segments.first?.recordingId, recordingID != fields[1] {
                throw ParseError.multipleRecordings
            }

            segments.append(
                LabeledSegment(
                    recordingId: fields[1],
                    speakerId: fields[7],
                    startMs: startMs,
                    endMs: endMs
                ))
        }

        return segments.sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return $0.speakerId < $1.speakerId
        }
    }

    private static func strippedComment(_ line: String) -> String {
        guard let commentStart = line.firstIndex(of: "#") else { return line }
        return String(line[..<commentStart])
    }
}
