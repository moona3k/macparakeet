import Foundation

struct MeetingChunkResultBuffer {
    typealias ChunkResult = (chunk: AudioChunker.AudioChunk, result: STTResult)

    private var nextExpectedSequence: [AudioSource: Int] = [:]
    private var bufferedResults: [AudioSource: [Int: ChunkResult]] = [:]
    private var failedSequences: [AudioSource: Set<Int>] = [:]

    mutating func reset() {
        nextExpectedSequence = [:]
        bufferedResults = [:]
        failedSequences = [:]
    }

    mutating func receiveSuccess(
        sequence: Int,
        source: AudioSource,
        chunk: AudioChunker.AudioChunk,
        result: STTResult
    ) -> [ChunkResult] {
        bufferedResults[source, default: [:]][sequence] = (chunk, result)
        return drain(source: source)
    }

    mutating func receiveFailure(sequence: Int, source: AudioSource) -> [ChunkResult] {
        failedSequences[source, default: []].insert(sequence)
        return drain(source: source)
    }

    private mutating func drain(source: AudioSource) -> [ChunkResult] {
        var drained: [ChunkResult] = []
        var expected = nextExpectedSequence[source] ?? 0

        while true {
            if failedSequences[source, default: []].contains(expected) {
                failedSequences[source]?.remove(expected)
                expected += 1
                continue
            }

            guard let result = bufferedResults[source]?[expected] else { break }
            bufferedResults[source]?.removeValue(forKey: expected)
            drained.append(result)
            expected += 1
        }

        nextExpectedSequence[source] = expected
        return drained
    }
}
