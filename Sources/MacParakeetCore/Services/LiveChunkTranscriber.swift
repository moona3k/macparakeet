import AVFAudio
import Foundation
import OSLog

actor LiveChunkTranscriber {
    struct SessionContext: Sendable {
        let id: UUID
        let chunkFolderURL: URL
    }

    struct OrderedResult: Sendable {
        let source: AudioSource
        let chunk: AudioChunker.AudioChunk
        let result: STTResult
    }

    enum Event: Sendable {
        case orderedResults([OrderedResult])
        case backpressureDrop
        case transcriptionFailed(String)
    }

    typealias EventHandler = @Sendable (Event) async -> Void

    private struct PendingChunkTask: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "LiveChunkTranscriber")
    private let sttTranscriber: STTTranscribing
    private let fileManager: FileManager

    private var sessionContext: SessionContext?
    private var eventHandler: EventHandler?
    private var pendingChunkTasks: [PendingChunkTask] = []
    private var nextChunkSequence: [AudioSource: Int] = [:]
    private var chunkResultBuffer = MeetingChunkResultBuffer()

    init(sttTranscriber: STTTranscribing, fileManager: FileManager = .default) {
        self.sttTranscriber = sttTranscriber
        self.fileManager = fileManager
    }

    func startSession(
        _ context: SessionContext,
        onEvent: @escaping EventHandler
    ) async {
        await cancelPendingTasks(waitForCancellation: true)
        self.sessionContext = context
        self.eventHandler = onEvent
        self.pendingChunkTasks = []
        self.nextChunkSequence = [:]
        self.chunkResultBuffer.reset()
    }

    func finishSession() async {
        await cancelPendingTasks(waitForCancellation: false)
        self.sessionContext = nil
        self.eventHandler = nil
        self.pendingChunkTasks = []
        self.nextChunkSequence = [:]
        self.chunkResultBuffer.reset()
    }

    func enqueue(chunk: AudioChunker.AudioChunk, source: AudioSource) {
        guard let context = sessionContext else { return }
        let sequence = nextChunkSequence[source] ?? 0
        nextChunkSequence[source] = sequence + 1

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.transcribeChunk(
                    chunk,
                    source: source,
                    context: context
                )
                await self.handleSuccess(
                    result,
                    chunk: chunk,
                    source: source,
                    sequence: sequence,
                    sessionID: context.id
                )
            } catch is CancellationError {
                // Expected during stop/cancel.
            } catch {
                await self.handleFailure(
                    error,
                    source: source,
                    sequence: sequence,
                    sessionID: context.id
                )
            }

            await self.removePendingChunkTask(id: taskID)
        }

        pendingChunkTasks.append(PendingChunkTask(id: taskID, task: task))
    }

    func waitForPendingTasksToDrain(timeout: Duration) async -> Bool {
        let startedAt = ContinuousClock.now
        while !pendingChunkTasks.isEmpty {
            if startedAt.duration(to: .now) > timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func cancelPendingTasks(waitForCancellation: Bool) async {
        let tasks = pendingChunkTasks.map(\.task)
        pendingChunkTasks = []

        for task in tasks {
            task.cancel()
        }

        guard waitForCancellation else { return }
        for task in tasks {
            await task.value
        }
    }

    private func transcribeChunk(
        _ chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        context: SessionContext
    ) async throws -> STTResult {
        let chunkURL = context.chunkFolderURL
            .appendingPathComponent("\(source.rawValue)-\(chunk.startMs)-\(chunk.endMs).wav")
        try writeChunkAudio(samples: chunk.samples, to: chunkURL)
        defer { try? fileManager.removeItem(at: chunkURL) }
        return try await sttTranscriber.transcribe(
            audioPath: chunkURL.path,
            job: .meetingLiveChunk,
            onProgress: nil
        )
    }

    private func writeChunkAudio(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingAudioError.storageFailed("invalid chunk format")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw MeetingAudioError.storageFailed("failed to allocate chunk buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { pointer in
                channelData[0].update(from: pointer.baseAddress!, count: samples.count)
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func handleSuccess(
        _ result: STTResult,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        sequence: Int,
        sessionID: UUID
    ) async {
        guard sessionContext?.id == sessionID else { return }
        logger.info(
            "meeting_live_chunk_transcribed source=\(source.rawValue, privacy: .public) seq=\(sequence) words=\(result.words.count) range=\(chunk.startMs)-\(chunk.endMs)"
        )

        let readyResults = chunkResultBuffer.receiveSuccess(
            sequence: sequence,
            source: source,
            chunk: chunk,
            result: result
        )
        guard !readyResults.isEmpty else { return }

        let ordered = readyResults.map {
            OrderedResult(source: source, chunk: $0.chunk, result: $0.result)
        }
        await emit(.orderedResults(ordered))
    }

    private func handleFailure(
        _ error: Error,
        source: AudioSource,
        sequence: Int,
        sessionID: UUID
    ) async {
        guard sessionContext?.id == sessionID else { return }

        let droppedByBackpressure =
            if case STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk) = error {
                true
            } else {
                false
            }

        if droppedByBackpressure {
            logger.notice(
                "meeting_live_chunk_backpressure_drop source=\(source.rawValue, privacy: .public) seq=\(sequence)"
            )
            await emit(.backpressureDrop)
        } else {
            logger.error(
                "meeting_live_chunk_failed source=\(source.rawValue, privacy: .public) seq=\(sequence) error=\(error.localizedDescription, privacy: .public)"
            )
            await emit(.transcriptionFailed(error.localizedDescription))
        }

        let readyResults = chunkResultBuffer.receiveFailure(sequence: sequence, source: source)
        guard !readyResults.isEmpty else { return }
        let ordered = readyResults.map {
            OrderedResult(source: source, chunk: $0.chunk, result: $0.result)
        }
        await emit(.orderedResults(ordered))
    }

    private func emit(_ event: Event) async {
        guard let eventHandler else { return }
        await eventHandler(event)
    }

    private func removePendingChunkTask(id: UUID) {
        pendingChunkTasks.removeAll { $0.id == id }
    }
}
