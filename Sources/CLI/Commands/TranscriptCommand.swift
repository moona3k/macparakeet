import ArgumentParser
import Foundation
import MacParakeetCore

struct TranscriptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Read a segment slice from a saved meeting or file/URL transcript."
    )

    @Argument(help: "Transcription UUID, UUID prefix, or exact title.")
    var id: String

    @Option(help: "Center timestamp as hh:mm:ss or integer milliseconds.")
    var around: String?

    @Option(help: "Time on either side of --around (for example 30s, 2m, 5000ms, or hh:mm:ss).")
    var window: String = "30s"

    @Option(help: "Center segment sequence number.")
    var aroundSeq: Int?

    @Option(help: "Segments on either side of --around-seq.")
    var context: Int = 2

    @Flag(name: .long, help: "Emit a transcript-slice object as JSON.")
    var json = false

    @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
    var envelope = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func validate() throws {
        guard around == nil || aroundSeq == nil else {
            throw ValidationError("--around and --around-seq are mutually exclusive.")
        }
        guard (aroundSeq ?? 0) >= 0 else { throw ValidationError("--around-seq must be >= 0.") }
        guard context >= 0 else { throw ValidationError("--context must be >= 0.") }
        _ = try around.map(parseTranscriptPosition)
        _ = try parseTranscriptDuration(window)
        try validateJSONEnvelopeFlags(json: json, envelope: envelope)
    }

    func run() async throws {
        try emitJSONOrRethrow(json: json || envelope) {
            let db = try makeDatabaseManager(database: database)
            let transcription = try findTranscription(
                id: id,
                repo: TranscriptionRepository(dbQueue: db.dbQueue)
            )
            let repository = SegmentRepository(dbQueue: db.dbQueue)
            let rows = try repository.fetchSlice(
                transcriptionId: transcription.id,
                aroundMs: try around.map(parseTranscriptPosition),
                windowMs: try parseTranscriptDuration(window),
                aroundSeq: aroundSeq,
                context: context
            )
            let record = TranscriptSliceRecord(transcription: transcription, segments: rows)
            if envelope {
                try printEnvelope(command: "transcript", data: record)
            } else if json {
                try printJSON(record)
            } else if rows.isEmpty {
                print("No indexed transcript segments found. Run `macparakeet-cli search-reindex`.")
            } else {
                for segment in rows {
                    let location = segment.startMs.map(formatSearchTimestamp) ?? "#\(segment.seq)"
                    let speaker = segment.speaker.map { "\($0): " } ?? ""
                    print("[\(location)] \(speaker)\(segment.text)")
                }
            }
        }
    }
}

private struct TranscriptSliceRecord: Encodable {
    let transcriptionId: UUID
    let title: String
    let recordedAt: Date
    let source: SegmentSearchSource
    let segments: [TranscriptSliceSegment]

    init(transcription: Transcription, segments: [Segment]) {
        transcriptionId = transcription.id
        title = transcription.effectiveDisplayTitle
        recordedAt = transcription.createdAt
        source =
            switch transcription.sourceType {
            case .meeting: .meeting
            case .file: .file
            case .youtube, .podcast: .url
            }
        self.segments = segments.map(TranscriptSliceSegment.init)
    }
}

private struct TranscriptSliceSegment: Encodable {
    let seq: Int
    let startMs: Int?
    let endMs: Int?
    let speaker: String?
    let text: String
    let segmenterVersion: Int

    init(_ segment: Segment) {
        seq = segment.seq
        startMs = segment.startMs
        endMs = segment.endMs
        speaker = segment.speaker
        text = segment.text
        segmenterVersion = segment.segmenterVersion
    }

    private enum CodingKeys: String, CodingKey {
        case seq, startMs, endMs, speaker, text, segmenterVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        if let startMs {
            try container.encode(startMs, forKey: .startMs)
        } else {
            try container.encodeNil(forKey: .startMs)
        }
        if let endMs {
            try container.encode(endMs, forKey: .endMs)
        } else {
            try container.encodeNil(forKey: .endMs)
        }
        if let speaker {
            try container.encode(speaker, forKey: .speaker)
        } else {
            try container.encodeNil(forKey: .speaker)
        }
        try container.encode(text, forKey: .text)
        try container.encode(segmenterVersion, forKey: .segmenterVersion)
    }
}

private func parseTranscriptPosition(_ value: String) throws -> Int {
    if value.contains(":") { return try parseClockMilliseconds(value) }
    guard let milliseconds = Int(value), milliseconds >= 0 else {
        throw ValidationError("--around must be hh:mm:ss or non-negative integer milliseconds.")
    }
    return milliseconds
}

private func parseTranscriptDuration(_ value: String) throws -> Int {
    if value.contains(":") { return try parseClockMilliseconds(value) }
    let lowered = value.lowercased()
    let multiplier: Double
    let number: String
    if lowered.hasSuffix("ms") {
        multiplier = 1
        number = String(lowered.dropLast(2))
    } else if lowered.hasSuffix("s") {
        multiplier = 1_000
        number = String(lowered.dropLast())
    } else if lowered.hasSuffix("m") {
        multiplier = 60_000
        number = String(lowered.dropLast())
    } else if lowered.hasSuffix("h") {
        multiplier = 3_600_000
        number = String(lowered.dropLast())
    } else {
        multiplier = 1
        number = lowered
    }
    guard let amount = Double(number), amount.isFinite, amount >= 0 else {
        throw ValidationError("--window must be a non-negative duration such as 30s, 2m, 5000ms, or hh:mm:ss.")
    }
    let milliseconds = (amount * multiplier).rounded()
    guard milliseconds.isFinite, milliseconds < Double(Int.max) else {
        throw ValidationError("--window is too large.")
    }
    return Int(milliseconds)
}

private func parseClockMilliseconds(_ value: String) throws -> Int {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
        let hours = Int(parts[0]), hours >= 0,
        let minutes = Int(parts[1]), (0..<60).contains(minutes),
        let seconds = Double(parts[2]), seconds >= 0, seconds < 60
    else {
        throw ValidationError("Timestamp/duration must use hh:mm:ss with minutes and seconds below 60.")
    }
    let milliseconds =
        (Double(hours) * 3_600_000
        + Double(minutes) * 60_000
        + seconds * 1_000).rounded()
    guard milliseconds.isFinite, milliseconds < Double(Int.max) else {
        throw ValidationError("Timestamp/duration is too large.")
    }
    return Int(milliseconds)
}
