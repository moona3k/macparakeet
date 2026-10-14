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

    private var engines: [AudioSource: RealtimeTranscribeEngine] = [:]
    private var converters: [AudioSource: LiveCaptionResampler] = [:]
    private var linesBySource: [AudioSource: [RealtimeCaptionLine]] = [:]
    /// Phrase ids in the order they were first heard, across both sources.
    private var order: [String] = []
    private var eventTask: Task<Void, Never>?
    private var onUpdate: Update?
    private var onFailure: Failure?
    private var isRunning = false

    public init(
        capture: any MeetingAudioCapturing,
        configStore: CloudSTTConfigStore = CloudSTTConfigStore(),
        connect: @escaping RealtimeSTTConnect = { url, apiKey in
            URLSessionRealtimeSTTSocket(url: url, apiKey: apiKey)
        }
    ) {
        self.capture = capture
        self.configStore = configStore
        self.connect = connect
    }

    public func start(
        sourceMode: MeetingAudioSourceMode,
        onUpdate: @escaping Update,
        onFailure: @escaping Failure
    ) async throws {
        await stop()
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
                try await engine.beginLiveDictation(language: nil, onPartial: { _ in })
                await engine.setLineObserver { [weak self] lines in
                    Task { await self?.receive(lines, from: source) }
                }
                engines[source] = engine
            }

            let events = await capture.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.handle(event)
                }
            }
            _ = try await capture.start(sourceMode: sourceMode)
            isRunning = true
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if isRunning {
            await capture.stop()
        }
        isRunning = false
        for engine in engines.values {
            await engine.cancelLiveDictation()
        }
        engines = [:]
        converters = [:]
        linesBySource = [:]
        order = []
        onUpdate = nil
        onFailure = nil
    }

    // MARK: - Capture events

    private func handle(_ event: MeetingAudioCaptureEvent) async {
        switch event {
        case .microphoneBuffer(let buffer, _):
            await feed(buffer, source: .microphone)
        case .systemBuffer(let buffer, _):
            await feed(buffer, source: .system)
        case .error(let error):
            onFailure?(error.localizedDescription)
        case .sourceInterrupted(let source, let error):
            onFailure?(
                "\(source == .microphone ? "Microphone" : "Computer audio") stopped: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer, source: AudioSource) async {
        guard let engine = engines[source] else { return }
        let converter: LiveCaptionResampler
        if let existing = converters[source], existing.matches(buffer.format) {
            converter = existing
        } else if let created = LiveCaptionResampler(inputFormat: buffer.format) {
            converters[source] = created
            converter = created
        } else {
            return
        }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        do {
            try await engine.processSamples24k(samples)
        } catch {
            onFailure?("The connection to the speech service was lost.")
        }
    }

    private func receive(_ lines: [RealtimeCaptionLine], from source: AudioSource) {
        guard engines[source] != nil else { return }
        linesBySource[source] = lines
        for line in lines {
            let id = Self.lineID(source: source, itemID: line.id)
            if !order.contains(id) { order.append(id) }
        }
        var byID: [String: LiveCaptionLine] = [:]
        for (lineSource, sourceLines) in linesBySource {
            for line in sourceLines {
                let id = Self.lineID(source: lineSource, itemID: line.id)
                byID[id] = LiveCaptionLine(id: id, source: lineSource, text: line.text, isFinal: line.isFinal)
            }
        }
        onUpdate?(order.compactMap { byID[$0] })
    }

    static func lineID(source: AudioSource, itemID: String) -> String {
        "\(source == .microphone ? "mic" : "sys"):\(itemID)"
    }
}

/// Converts capture buffers (any rate, any channel count) to 24 kHz mono
/// Float32, the format realtime transcription sessions take.
final class LiveCaptionResampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard
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

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
