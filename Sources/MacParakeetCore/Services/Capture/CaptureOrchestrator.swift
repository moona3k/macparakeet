import Foundation

struct CaptureOrchestratorChunk: Sendable {
    let source: AudioSource
    let chunk: AudioChunker.AudioChunk
}

struct CaptureOrchestratorPairMetadata: Sendable {
    let microphoneHostTime: UInt64?
    let systemHostTime: UInt64?
    let processedMicrophoneRms: Float?
}

struct CaptureOrchestratorOutput: Sendable {
    var chunks: [CaptureOrchestratorChunk] = []
    var diagnostics: [MeetingAudioJoinerDiagnostic] = []
    var pairMetadata: [CaptureOrchestratorPairMetadata] = []
}

actor CaptureOrchestrator {
    private var pairJoiner = MeetingAudioPairJoiner()
    private var microphoneChunker = AudioChunker()
    private var systemChunker = AudioChunker()

    func reset() async {
        pairJoiner.reset()
        await microphoneChunker.reset()
        await systemChunker.reset()
    }

    func ingest(
        samples: [Float],
        source: AudioSource,
        hostTime: UInt64?,
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        pairJoiner.push(samples: samples, hostTime: hostTime, source: source)
        let pairs = pairJoiner.drainPairs()
        var output = await processPairs(pairs, micConditioner: micConditioner)
        output.diagnostics = pairJoiner.drainDiagnostics()
        return output
    }

    func flushPendingPairs(
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        let pairs = pairJoiner.flushRemainingPairs()
        return await processPairs(pairs, micConditioner: micConditioner)
    }

    func flushChunkers() async -> [CaptureOrchestratorChunk] {
        var chunks: [CaptureOrchestratorChunk] = []
        if let microphone = await microphoneChunker.flush() {
            chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: microphone))
        }
        if let system = await systemChunker.flush() {
            chunks.append(CaptureOrchestratorChunk(source: .system, chunk: system))
        }
        return chunks
    }

    private func processPairs(
        _ pairs: [MeetingAudioPair],
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        var output = CaptureOrchestratorOutput()
        for pair in pairs {
            // Feed both chunkers on every pair so their sample-position
            // counters stay aligned with wallclock. The pair joiner already
            // pads the absent source with silence on solo drains; without
            // pushing those zeros through to the absent chunker, its
            // `totalSamplesProcessed` freezes while the active source's
            // tracks wallclock — producing future-dated chunks (e.g.
            // "Me 17:24" inside a 9:20 recording).
            var processedMicrophoneRms: Float?
            let micSamples: [Float]
            if pair.hasMicrophoneSignal {
                let processedMic = micConditioner.condition(
                    microphone: pair.microphoneSamples,
                    speaker: pair.systemSamples
                )
                processedMicrophoneRms = chunkRms(for: processedMic)
                micSamples = processedMic
            } else {
                micSamples = pair.microphoneSamples
            }

            if let micChunk = await microphoneChunker.addSamples(micSamples) {
                output.chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: micChunk))
            }

            if let systemChunk = await systemChunker.addSamples(pair.systemSamples) {
                output.chunks.append(CaptureOrchestratorChunk(source: .system, chunk: systemChunk))
            }

            output.pairMetadata.append(
                CaptureOrchestratorPairMetadata(
                    microphoneHostTime: pair.microphoneHostTime,
                    systemHostTime: pair.systemHostTime,
                    processedMicrophoneRms: processedMicrophoneRms
                )
            )
        }
        return output
    }

    private func chunkRms(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }
}
