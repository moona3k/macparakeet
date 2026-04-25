import AVFAudio
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
    /// First valid hostTime (in ms) seen from any source, kept as the shared
    /// recording-relative origin so per-source offsets stay in the recording
    /// duration's range instead of leaking absolute mach uptime.
    private var sharedOriginMs: Int?
    private var sourceTimelineOffsetsMs: [AudioSource: Int] = [:]

    func reset() async {
        pairJoiner.reset()
        await microphoneChunker.reset()
        await systemChunker.reset()
        sharedOriginMs = nil
        sourceTimelineOffsetsMs = [:]
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
        if let microphone = offsetChunk(
            await microphoneChunker.flush(),
            source: .microphone,
            hostTime: nil
        ) {
            chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: microphone))
        }
        if let system = offsetChunk(
            await systemChunker.flush(),
            source: .system,
            hostTime: nil
        ) {
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
            var processedMicrophoneRms: Float?

            if pair.hasMicrophoneSignal {
                let processedMic = micConditioner.condition(
                    microphone: pair.microphoneSamples,
                    speaker: pair.systemSamples
                )
                processedMicrophoneRms = chunkRms(for: processedMic)
                if let micChunk = offsetChunk(
                    await microphoneChunker.addSamples(processedMic),
                    source: .microphone,
                    hostTime: pair.microphoneHostTime
                ) {
                    output.chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: micChunk))
                }
            }

            if pair.hasSystemSignal,
               let systemChunk = offsetChunk(
                   await systemChunker.addSamples(pair.systemSamples),
                   source: .system,
                   hostTime: pair.systemHostTime
               ) {
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

    private func offsetChunk(
        _ chunk: AudioChunker.AudioChunk?,
        source: AudioSource,
        hostTime: UInt64?
    ) -> AudioChunker.AudioChunk? {
        guard let chunk else { return nil }
        let offsetMs = timelineOffsetMs(for: source, hostTime: hostTime)
        guard offsetMs != 0 else { return chunk }
        return AudioChunker.AudioChunk(
            samples: chunk.samples,
            startMs: chunk.startMs + offsetMs,
            endMs: chunk.endMs + offsetMs
        )
    }

    private func timelineOffsetMs(for source: AudioSource, hostTime: UInt64?) -> Int {
        if let existing = sourceTimelineOffsetsMs[source] {
            return existing
        }
        guard let hostTime else {
            // Don't cache: a later buffer from this source may carry a valid
            // hostTime, and we want that one to define the cross-stream delta.
            return 0
        }

        let absoluteMs = Int((AVAudioTime.seconds(forHostTime: hostTime) * 1000).rounded())
        let origin = sharedOriginMs ?? absoluteMs
        sharedOriginMs = origin
        let offsetMs = absoluteMs - origin
        sourceTimelineOffsetsMs[source] = offsetMs
        return offsetMs
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
