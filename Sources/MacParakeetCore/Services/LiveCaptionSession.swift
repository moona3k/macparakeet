@preconcurrency import AVFoundation
import Foundation

/// One line in the Live Captions window.
public struct LiveCaptionLine: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: AudioSource
    public let text: String
    /// False while the phrase is still being spoken.
    public let isFinal: Bool

    public init(id: String, source: AudioSource, text: String, isFinal: Bool) {
        self.id = id
        self.source = source
        self.text = text
        self.isFinal = isFinal
    }
}

public enum LiveCaptionSessionError: Error, LocalizedError, Equatable {
    case realtimeModelMissing

    public var errorDescription: String? {
        switch self {
        case .realtimeModelMissing:
            return
                "Live captions need the online speech service with a realtime model. Set them in Settings → Speech → Online Speech Service."
        }
    }
}

/// Live captions without recording a meeting: captures the microphone and/or
/// computer audio and streams each to a realtime transcription session.
/// Nothing is saved. Audio is uploaded to the online speech service, so this
/// is available only when that service and a realtime model are configured.
public actor LiveCaptionSession {
    public typealias Update = @Sendable ([LiveCaptionLine]) -> Void
    public typealias Failure = @Sendable (String) -> Void

    private let capture: any MeetingAudioCapturing
    private let configStore: CloudSTTConfigStore
    private let connect: RealtimeSTTConnect
    private let makeConverter: @Sendable (AVAudioFormat) -> (any LiveCaptionAudioConverting)?
    private let uploadBufferSampleLimit: Int
    private var generation = 0
    private var historyGeneration = 0
    private var engines: [AudioSource: RealtimeTranscribeEngine] = [:]
    private var converters: [AudioSource: any LiveCaptionAudioConverting] = [:]
    private var linesBySource: [AudioSource: [RealtimeCaptionLine]] = [:]
    private var lineRevisions: [AudioSource: Int] = [:]
    private var seenLineIDs: Set<String> = []
    /// Preserve the arrival slots of each source while its own phrases are
    /// reordered by the provider's committed-item chain.
    private var sourceSlots: [AudioSource] = []
    private var eventTask: Task<Void, Never>?
    private var uploadTasks: [AudioSource: Task<Void, Never>] = [:]
    private var uploadReadySources: Set<AudioSource> = []
    private var queuedAudio: [AudioSource: [[Float]]] = [:]
    /// Includes the chunk currently waiting on the network.
    private var bufferedSamples: [AudioSource: Int] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var onUpdate: Update?
    private var onFailure: Failure?
    private var captureRequested = false

    public init(
        capture: any MeetingAudioCapturing,
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        uploadBufferSampleLimit: Int = 48_000,
        connect: @escaping RealtimeSTTConnect = { url, apiKey in
            URLSessionRealtimeSTTSocket(url: url, apiKey: apiKey)
        }
    ) {
        self.init(
            capture: capture, configStore: configStore, uploadBufferSampleLimit: uploadBufferSampleLimit,
            makeConverter: { LiveCaptionResampler(inputFormat: $0) }, connect: connect)
    }

    init(
        capture: any MeetingAudioCapturing,
        configStore: CloudSTTConfigStore,
        uploadBufferSampleLimit: Int = 48_000,
        makeConverter: @escaping @Sendable (AVAudioFormat) -> (any LiveCaptionAudioConverting)?,
        connect: @escaping RealtimeSTTConnect
    ) {
        self.capture = capture
        self.configStore = configStore
        self.uploadBufferSampleLimit = max(1, uploadBufferSampleLimit)
        self.connect = connect
        self.makeConverter = makeConverter
    }

    public func start(
        sourceMode: MeetingAudioSourceMode,
        onUpdate: @escaping Update,
        onFailure: @escaping Failure
    ) async throws {
        generation += 1
        let current = generation
        await retireSession().value
        try requireCurrent(current)
        guard configStore.isConfigured, configStore.loadMetadata().hasRealtimeModel else {
            throw LiveCaptionSessionError.realtimeModelMissing
        }
        self.onUpdate = onUpdate
        self.onFailure = onFailure

        var sources: [AudioSource] = []
        if sourceMode.capturesMicrophone { sources.append(.microphone) }
        if sourceMode != .microphoneOnly { sources.append(.system) }

        do {
            for source in sources {
                let engine = RealtimeTranscribeEngine(configStore: configStore, connect: connect)
                // Stop must see an engine even while its connection is pending.
                engines[source] = engine
                try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
                try requireCurrent(current)
                await installLineObserver(engine, source: source, generation: current, history: historyGeneration)
                try requireCurrent(current)
                try await engine.setFailureObserver { [weak self] message in
                    Task { await self?.fail(message, generation: current) }
                }
                try requireCurrent(current)
                uploadReadySources.insert(source)
            }

            let events = await capture.events
            try requireCurrent(current)
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.handle(event, generation: current)
                }
            }
            // The capture service can be stopped while its start is suspended.
            captureRequested = true
            _ = try await capture.start(sourceMode: sourceMode)
            try requireCurrent(current)
        } catch {
            if generation == current {
                generation += 1
                await retireSession().value
            }
            throw error
        }
    }

    public func stop() async {
        generation += 1
        await retireSession().value
    }

    /// Revocation is synchronous; cleanup is serialized before another start.
    private func retireSession() -> Task<Void, Never> {
        eventTask?.cancel()
        eventTask = nil
        for task in uploadTasks.values { task.cancel() }
        uploadTasks = [:]
        uploadReadySources = []
        queuedAudio = [:]
        bufferedSamples = [:]
        let retiringEngines = Array(engines.values)
        engines = [:]
        let stopCapture = captureRequested
        captureRequested = false
        converters = [:]
        linesBySource = [:]
        lineRevisions = [:]
        seenLineIDs = []
        sourceSlots = []
        historyGeneration += 1
        onUpdate = nil
        onFailure = nil
        let previousShutdown = shutdownTask
        let capture = capture
        let cleanup = Task {
            await previousShutdown?.value
            for engine in retiringEngines { await engine.cancelLiveDictation() }
            if stopCapture { await capture.stop() }
        }
        shutdownTask = cleanup
        return cleanup
    }

    /// Clear linearizes at this actor's audio admission boundary. Previously
    /// admitted audio and converter carry are discarded; capture continues and
    /// newly admitted buffers wait within the normal bound during reconnection.
    public func clearHistory() async -> [LiveCaptionLine] {
        guard captureRequested else { return [] }
        let current = generation
        historyGeneration += 1
        let history = historyGeneration
        for task in uploadTasks.values { task.cancel() }
        uploadTasks = [:]
        uploadReadySources = []
        queuedAudio = [:]
        bufferedSamples = [:]
        converters = [:]
        linesBySource = [:]
        lineRevisions = [:]
        seenLineIDs = []
        sourceSlots = []
        onUpdate?([])
        let activeEngines = engines
        do {
            for source in [AudioSource.microphone, .system] {
                guard let engine = activeEngines[source] else { continue }
                try await engine.clearCaptionHistory()
                guard current == generation, history == historyGeneration else { return [] }
                await installLineObserver(engine, source: source, generation: current, history: history)
                guard current == generation, history == historyGeneration else { return [] }
                uploadReadySources.insert(source)
                startUploadsIfReady(source: source, engine: engine, generation: current, history: history)
            }
        } catch {
            guard current == generation, history == historyGeneration else { return [] }
            await fail("The speech service could not restart after Clear. Live captions stopped.", generation: current)
            return []
        }
        return currentLines()
    }

    private func installLineObserver(
        _ engine: RealtimeTranscribeEngine, source: AudioSource, generation: Int, history: Int
    ) async {
        await engine.setLineObserver { [weak self] lines, revision in
            Task {
                await self?.receive(lines, from: source, revision: revision, generation: generation, history: history)
            }
        }
    }

    private func requireCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func fail(_ message: String, generation expected: Int) async {
        guard generation == expected else { return }
        let notify = onFailure
        generation += 1
        let cleanup = retireSession()
        notify?(message)
        await cleanup.value
    }

    private func handle(_ event: MeetingAudioCaptureEvent, generation: Int) async {
        guard self.generation == generation, captureRequested else { return }
        switch event {
        case .microphoneBuffer(let buffer, _):
            await enqueue(buffer, source: .microphone, generation: generation)
        case .systemBuffer(let buffer, _):
            await enqueue(buffer, source: .system, generation: generation)
        case .error:
            await fail("Audio capture failed. Live captions stopped.", generation: generation)
        case .sourceInterrupted(let source, _):
            await fail(
                "\(source == .microphone ? "Microphone" : "Computer audio") stopped. Live captions stopped.",
                generation: generation)
        default: break
        }
    }

    /// Capture-event consumption never waits on an upload. At most two seconds
    /// of 24 kHz samples per source are retained by default, including in-flight
    /// audio. Overflow stops visibly rather than silently losing caption audio.
    private func enqueue(_ buffer: AVAudioPCMBuffer, source: AudioSource, generation: Int) async {
        guard let engine = engines[source] else { return }
        let converter: any LiveCaptionAudioConverting
        if let existing = converters[source], existing.matches(buffer.format) {
            converter = existing
        } else if let created = makeConverter(buffer.format) {
            converters[source] = created
            converter = created
        } else {
            await fail("Audio conversion failed. Live captions stopped.", generation: generation)
            return
        }
        let samples: [Float]
        do {
            samples = try converter.convert(buffer)
        } catch {
            await fail("Audio conversion failed. Live captions stopped.", generation: generation)
            return
        }
        guard !samples.isEmpty else { return }
        let buffered = bufferedSamples[source, default: 0]
        guard samples.count <= uploadBufferSampleLimit - buffered else {
            await fail(
                "The speech service is too slow to keep up. Live captions stopped; try starting again.",
                generation: generation)
            return
        }
        bufferedSamples[source] = buffered + samples.count
        queuedAudio[source, default: []].append(samples)
        startUploadsIfReady(source: source, engine: engine, generation: generation, history: historyGeneration)
    }

    private func startUploadsIfReady(
        source: AudioSource, engine: RealtimeTranscribeEngine, generation: Int, history: Int
    ) {
        guard uploadReadySources.contains(source), uploadTasks[source] == nil,
            queuedAudio[source]?.isEmpty == false
        else { return }
        uploadTasks[source] = Task { [weak self] in
            await self?.drainUploads(source: source, engine: engine, generation: generation, history: history)
        }
    }

    private func drainUploads(
        source: AudioSource, engine: RealtimeTranscribeEngine, generation: Int, history: Int
    ) async {
        while self.generation == generation, historyGeneration == history, !Task.isCancelled {
            guard var queue = queuedAudio[source], !queue.isEmpty else {
                uploadTasks[source] = nil
                return
            }
            let samples = queue.removeFirst()
            queuedAudio[source] = queue
            do {
                try await engine.processSamples24k(samples)
                guard self.generation == generation, historyGeneration == history, !Task.isCancelled else { return }
                bufferedSamples[source, default: 0] -= samples.count
            } catch {
                guard self.generation == generation, historyGeneration == history, !Task.isCancelled else { return }
                await fail(
                    "The connection to the speech service was lost. Live captions stopped.", generation: generation)
                return
            }
        }
    }

    private func receive(
        _ lines: [RealtimeCaptionLine], from source: AudioSource, revision: Int, generation: Int, history: Int
    ) {
        guard self.generation == generation, historyGeneration == history, engines[source] != nil,
            revision > lineRevisions[source, default: -1]
        else { return }
        lineRevisions[source] = revision
        linesBySource[source] = lines
        for line in lines {
            let id = Self.lineID(source: source, itemID: line.id)
            if seenLineIDs.insert(id).inserted { sourceSlots.append(source) }
        }
        onUpdate?(currentLines())
    }

    private func currentLines() -> [LiveCaptionLine] {
        var positions: [AudioSource: Int] = [:]
        return sourceSlots.compactMap { source in
            let index = positions[source, default: 0]
            guard let lines = linesBySource[source], index < lines.count else { return nil }
            positions[source] = index + 1
            let line = lines[index]
            return LiveCaptionLine(
                id: Self.lineID(source: source, itemID: line.id), source: source, text: line.text, isFinal: line.isFinal
            )
        }
    }

    static func lineID(source: AudioSource, itemID: String) -> String {
        "\(source == .microphone ? "mic" : "sys"):\(itemID)"
    }
}

/// Converts capture buffers (any rate, any channel count) to 24 kHz mono
/// Float32, the format realtime transcription sessions take.
protocol LiveCaptionAudioConverting {
    func matches(_ format: AVAudioFormat) -> Bool
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float]
}

final class LiveCaptionResampler: LiveCaptionAudioConverting {
    enum ConversionError: Error { case invalidFormat, allocationFailed, conversionFailed }
    /// The converter invokes this input block synchronously on the session's
    /// actor. Keep its one-call state behind the SDK's @Sendable boundary.
    private final class Input: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func supply(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard
            inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(RealtimeTranscribeEngine.outputSampleRate),
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func matches(_ format: AVAudioFormat) -> Bool {
        format == inputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard matches(buffer.format) else { throw ConversionError.invalidFormat }
        guard buffer.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let size = (Double(buffer.frameLength) * ratio).rounded(.up) + 64
        guard let capacity = AVAudioFrameCount(exactly: size), capacity > 0 else { throw ConversionError.invalidFormat }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.allocationFailed
        }

        let input = Input(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            input.supply(inputStatus)
        }
        guard status != .error, conversionError == nil else { throw ConversionError.conversionFailed }
        guard output.frameLength > 0 else { return [] }
        guard let channel = output.floatChannelData?[0] else { throw ConversionError.conversionFailed }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
