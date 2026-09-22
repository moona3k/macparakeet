import AVFoundation
import Foundation

public enum VoiceControlSpeechEvent: Sendable {
    case listening(UUID, UUID), speechBegan(UUID, UUID), transcribing(UUID, UUID)
    case level(Float, UUID)
    case partial(String, UUID, UUID)
    case transcript(String, UUID, UUID)
    case stopped(UUID)
    case failed(String, UUID)
}

/// Deterministic, conservative endpointing. No action is based on partial text.
/// This energy-based detector needs real microphone qualification; noise is not
/// speech recognition, and hold-to-talk remains available in noisy environments.
public struct VoiceControlEndpointer: Sendable {
    public enum Signal: Sendable, Equatable { case none, began, ended, tooLong }
    private var speechSamples = 0
    private var silenceSamples = 0
    private var totalSamples = 0
    private var began = false
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func consume(_ samples: [Float]) -> Signal {
        guard !samples.isEmpty else { return .none }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        if rms >= 0.012 {
            speechSamples += samples.count
            silenceSamples = 0
        } else {
            silenceSamples += samples.count
            if !began, silenceSamples > 4800 { speechSamples = 0 }
        }
        if began { totalSamples += samples.count }
        if !began, speechSamples >= 2400 {
            began = true
            totalSamples = speechSamples
            return .began
        }
        if began, totalSamples >= 480_000 { reset(); return .tooLong }
        if began, silenceSamples >= 14_400 { reset(); return .ended }
        return .none
    }
}

/// Raw local command speech over the process-wide microphone and STT scheduler.
/// Hands-free keeps capture alive while finalized segments are transcribed, so
/// incoming speech can revoke execution before another command has been decoded.
public actor VoiceControlSpeechSession {
    public nonisolated let events: AsyncStream<VoiceControlSpeechEvent>
    private let continuation: AsyncStream<VoiceControlSpeechEvent>.Continuation
    private let audio: any AudioProcessorProtocol
    private let stt: any STTTranscribing
    private nonisolated let revocation = VoiceControlSpeechRevocation()
    private var generation = 0
    private var active = false
    private var handsFree = false
    private var sampleTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var sampleContinuation: AsyncStream<[Float]>.Continuation?
    private var endpointer = VoiceControlEndpointer()
    private var utterance: [Float] = []
    private var hasSpeech = false
    private var captureID = UUID()
    private var utteranceID = UUID()
    private var discardUntilSilence = false
    private var discardSilenceSamples = 0
    private var engineLease: SpeechEngineLease?
    private var preview: VoiceControlSpeechPreview?
    private var previewTransition: Task<Void, Never>?
    private var previewDrain: Task<Void, Never>?
    private var isCommitting = false

    public init(audio: any AudioProcessorProtocol, stt: any STTTranscribing) {
        self.audio = audio
        self.stt = stt
        let pair = AsyncStream<VoiceControlSpeechEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    public func begin(handsFree: Bool, captureID: UUID = UUID()) async throws {
        guard !active else { return }
        generation += 1
        let token = generation
        active = true
        self.handsFree = handsFree
        self.captureID = captureID
        utteranceID = UUID()
        revocation.beginCapture(utterance: utteranceID)
        discardUntilSilence = false; discardSilenceSamples = 0
        if let manager = stt as? any SpeechEngineSessionManaging {
            let lease = await manager.beginSpeechEngineSession()
            guard active, generation == token else {
                await manager.endSpeechEngineSession(lease)
                throw CancellationError()
            }
            engineLease = lease
        }
        if !handsFree { startPreview(token: token) }
        endpointer.reset(); utterance = []; hasSpeech = false
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(128))
        sampleContinuation = pair.continuation
        sampleTask = Task { [weak self] in
            for await samples in pair.stream {
                guard !Task.isCancelled else { break }
                await self?.consume(samples, token: token)
            }
        }
        do {
            try await audio.startCapture(
                sampleSink: DictationAudioSampleSink(
                    onSamples: { [weak self] samples in
                        if case .dropped = pair.continuation.yield(samples) {
                            Task { await self?.captureOverflow(token: token) }
                        }
                    }, onFinish: { pair.continuation.finish() },
                    onCancel: { pair.continuation.finish() }
                ))
            guard active, generation == token else {
                if let url = try? await audio.stopCapture() { try? FileManager.default.removeItem(at: url) }
                throw CancellationError()
            }
            continuation.yield(.listening(captureID, utteranceID))
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(handsFree ? 600 : 30))
                guard !Task.isCancelled else { return }
                await self?.expire(token: token)
            }
        } catch {
            if generation == token {
                active = false
                sampleContinuation?.finish(); sampleTask?.cancel()
                await stopPreview()
                await releaseEngineLease()
            }
            throw error
        }
    }

    public func commit() async {
        guard active else { return }
        let token = generation
        let capture = captureID
        let utteranceToken = utteranceID
        isCommitting = true
        limitTask?.cancel()
        let lease = engineLease
        engineLease = nil
        do {
            let url = try await audio.stopCapture()
            sampleContinuation?.finish()
            await sampleTask?.value
            active = false
            isCommitting = false
            if handsFree {
                // The rolling recorder contains previous commands too. Commit
                // only the current segment; never replay the whole session WAV.
                try? FileManager.default.removeItem(at: url)
                if hasSpeech, !utterance.isEmpty {
                    let segmentURL = try Self.writeSegment(utterance)
                    await transcribe(url: segmentURL, token: token, utteranceToken: utteranceToken)
                }
            } else {
                await transcribe(url: url, token: token, utteranceToken: utteranceToken)
            }
        } catch AudioProcessorError.insufficientSamples {
            if generation == token { continuation.yield(.failed("Hold the shortcut while you speak.", capture)) }
        } catch {
            if generation == token { continuation.yield(.failed("Could not finish microphone capture.", capture)) }
        }
        if generation == token {
            active = false; isCommitting = false
            await stopPreview()
        }
        if let lease, let manager = stt as? any SpeechEngineSessionManaging {
            await manager.endSpeechEngineSession(lease)
        }
        if generation == token { continuation.yield(.stopped(capture)) }
    }

    public nonisolated func revokePendingTranscripts() { revocation.revoke() }
    public nonisolated func isCurrentUtterance(_ id: UUID) -> Bool { revocation.accepts(id) }

    public func cancel() async {
        revocation.revoke()
        let capture = captureID
        generation += 1
        utteranceID = UUID()
        active = false
        limitTask?.cancel(); finalTask?.cancel()
        sampleContinuation?.finish(); sampleTask?.cancel()
        if let url = try? await audio.stopCapture() { try? FileManager.default.removeItem(at: url) }
        utterance = []; hasSpeech = false
        await stopPreview()
        await finalTask?.value
        await releaseEngineLease()
        continuation.yield(.stopped(capture))
    }

    /// Discard the current turn without turning off an explicit hands-free mic.
    /// Re-arm only after silence so the remainder of a stopped phrase cannot act.
    public func discardPendingUtterance() async {
        revocation.revoke()
        utteranceID = UUID()
        finalTask?.cancel()
        utterance = []; hasSpeech = false; endpointer.reset()
        discardUntilSilence = true; discardSilenceSamples = 0
        await stopPreview()
    }

    private func consume(_ samples: [Float], token: Int) {
        guard active, token == generation else { return }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        continuation.yield(.level(min(1, rms * 12), captureID))
        if revocation.needsSilenceRearm, !discardUntilSilence {
            discardUntilSilence = true; discardSilenceSamples = 0
            utterance = []; hasSpeech = false; endpointer.reset()
            finalTask?.cancel()
        }
        if discardUntilSilence {
            discardSilenceSamples = rms < 0.012 ? discardSilenceSamples + samples.count : 0
            if discardSilenceSamples >= 14_400 {
                discardUntilSilence = false
                revocation.rearmAfterSilence()
            }
            return
        }
        preview?.append(samples)
        guard handsFree else { return }
        utterance.append(contentsOf: samples)
        if isCommitting { return }
        switch endpointer.consume(samples) {
        case .began:
            hasSpeech = true
            finalTask?.cancel()
            utteranceID = UUID()
            guard revocation.beginUtterance(utteranceID) else { return }
            continuation.yield(.speechBegan(captureID, utteranceID))
            startPreview(token: token)
        case .ended:
            let segment = utterance
            let utteranceToken = utteranceID
            utterance = []; hasSpeech = false
            finalTask?.cancel()
            finalTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try Self.writeSegment(segment)
                    await self.transcribe(url: url, token: token, utteranceToken: utteranceToken)
                } catch { await self.segmentFailed(token: token) }
            }
        case .tooLong:
            utterance = []; hasSpeech = false
            continuation.yield(.failed("That utterance was too long. Try a shorter instruction.", captureID))
        case .none:
            // Retain at most 350 ms before actual speech, and bound active speech.
            if !hasSpeech, utterance.count > 5600 { utterance.removeFirst(utterance.count - 5600) }
        }
    }

    private func transcribe(url: URL, token: Int, utteranceToken: UUID) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard token == generation, utteranceToken == utteranceID, revocation.accepts(utteranceToken), !Task.isCancelled
        else { return }
        await stopPreview()
        guard token == generation, utteranceToken == utteranceID, revocation.accepts(utteranceToken), !Task.isCancelled
        else { return }
        continuation.yield(.transcribing(captureID, utteranceToken))
        do {
            let result = try await stt.transcribe(audioPath: url.path, job: .dictation, onProgress: nil)
            guard token == generation, utteranceToken == utteranceID, revocation.accepts(utteranceToken),
                !Task.isCancelled
            else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { continuation.yield(.transcript(text, captureID, utteranceToken)) }
        } catch is CancellationError { return } catch {
            guard token == generation, utteranceToken == utteranceID, revocation.accepts(utteranceToken),
                !Task.isCancelled
            else { return }
            continuation.yield(.failed("Speech recognition failed. Please try again.", captureID))
        }
    }

    private func segmentFailed(token: Int) {
        if token == generation { continuation.yield(.failed("Could not prepare command audio.", captureID)) }
    }
    private func captureOverflow(token: Int) async {
        guard token == generation else { return }
        await cancel()
        continuation.yield(.failed("Audio could not keep up. Please start listening again.", captureID))
    }
    private func expire(token: Int) async {
        guard active, token == generation else { return }
        if handsFree { await cancel() } else { await commit() }
    }
    private func releaseEngineLease() async {
        let lease = engineLease
        engineLease = nil
        if let lease, let manager = stt as? any SpeechEngineSessionManaging {
            await manager.endSpeechEngineSession(lease)
        }
    }
    private func startPreview(token: Int) {
        let prior = preview
        preview = nil
        let oldDrain = previewDrain
        let drain = Task {
            await oldDrain?.value; await prior?.stop()
        }
        previewDrain = drain
        previewTransition?.cancel()
        let utteranceToken = utteranceID
        let capture = captureID
        let selection = engineLease?.selection ?? SpeechEngineSelection(engine: .parakeet)
        let pendingFinal = finalTask
        previewTransition = Task { [weak self, stt] in
            await drain.value
            await pendingFinal?.value
            guard let self, !Task.isCancelled else { return }
            await self.installPreview(
                stt: stt, selection: selection, token: token, capture: capture, utteranceToken: utteranceToken)
        }
    }
    private func installPreview(
        stt: any STTTranscribing, selection: SpeechEngineSelection,
        token: Int, capture: UUID, utteranceToken: UUID
    ) {
        guard active, token == generation, utteranceToken == utteranceID else { return }
        preview = VoiceControlSpeechPreview(
            stt: stt, selection: selection,
            onPartial: { [weak self] text in
                Task {
                    await self?.receivePartial(text, token: token, capture: capture, utteranceToken: utteranceToken)
                }
            })
        if handsFree { preview?.append(utterance) }
    }
    private func receivePartial(_ text: String, token: Int, capture: UUID, utteranceToken: UUID) {
        guard active, token == generation, utteranceToken == utteranceID, revocation.accepts(utteranceToken),
            !discardUntilSilence
        else { return }
        continuation.yield(.partial(text, capture, utteranceToken))
    }
    private func stopPreview() async {
        let transition = previewTransition
        previewTransition = nil
        transition?.cancel()
        // A transition may be waiting for this finalTask, so do not await it.
        // Its cancellation guard prevents installation after this boundary.
        let current = preview
        preview = nil
        let drain = previewDrain
        previewDrain = nil
        await drain?.value
        await current?.stop()
    }
    private static func writeSegment(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-command-\(UUID()).wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw AudioProcessorError.insufficientSamples }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
