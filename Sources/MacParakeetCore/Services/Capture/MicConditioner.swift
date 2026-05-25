import Foundation

struct MeetingEchoSuppressionDiagnostics: Sendable, Equatable {
    var processorName: String
    var loaded: Bool
    var micFrames: Int
    var processedFrames: Int
    var rawFallbackFrames: Int
    var fullReferenceFrames: Int
    var partialReferenceFrames: Int
    var missingReferenceFrames: Int
    var processingFailures: Int

    static func passthrough(
        processorName: String = "passthrough",
        loaded: Bool = true
    ) -> MeetingEchoSuppressionDiagnostics {
        MeetingEchoSuppressionDiagnostics(
            processorName: processorName,
            loaded: loaded,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }
}

protocol MeetingEchoSuppressing: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Int { get }
    var frameSize: Int { get }
    func reset()
    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws
}

protocol MicConditioning: AnyObject, Sendable {
    var diagnostics: MeetingEchoSuppressionDiagnostics { get }
    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float]
    func reset()
}

extension MicConditioning {
    func condition(microphone: [Float], speaker: [Float]) -> [Float] {
        condition(microphone: microphone, speaker: speaker, hasSpeakerReference: !speaker.isEmpty)
    }
}

/// No-op pass-through. This is the call-safe baseline: MacParakeet keeps raw
/// mic capture and only enables model-backed cleanup when a local processor is
/// explicitly configured and loaded.
final class PassthroughMicConditioner: MicConditioning, @unchecked Sendable {
    private let processorName: String
    private let loaded: Bool
    private let lock = NSLock()
    private var diagnosticsStorage: MeetingEchoSuppressionDiagnostics

    var diagnostics: MeetingEchoSuppressionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    init(processorName: String = "passthrough", loaded: Bool = true) {
        self.processorName = processorName
        self.loaded = loaded
        self.diagnosticsStorage = MeetingEchoSuppressionDiagnostics.passthrough(
            processorName: processorName,
            loaded: loaded
        )
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        microphone
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        diagnosticsStorage = MeetingEchoSuppressionDiagnostics.passthrough(
            processorName: processorName,
            loaded: loaded
        )
    }
}

final class StreamingMeetingEchoSuppressor: MicConditioning, @unchecked Sendable {
    private let processor: any MeetingEchoSuppressing
    private let lock = NSLock()
    private var diagnosticsStorage: MeetingEchoSuppressionDiagnostics

    var diagnostics: MeetingEchoSuppressionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    init(processor: any MeetingEchoSuppressing) {
        self.processor = processor
        self.diagnosticsStorage = MeetingEchoSuppressionDiagnostics(
            processorName: processor.name,
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        guard !microphone.isEmpty else { return [] }

        let frameSize = max(processor.frameSize, 1)
        var output: [Float] = []
        output.reserveCapacity(microphone.count)
        var micFrame = [Float](repeating: 0, count: frameSize)
        var referenceFrame = [Float](repeating: 0, count: frameSize)
        var processedFrame = [Float](repeating: 0, count: frameSize)

        lock.lock()
        defer { lock.unlock() }
        var cursor = 0
        while cursor + frameSize <= microphone.count {
            copyFrame(from: microphone, start: cursor, into: &micFrame)
            let referenceQuality = fillReferenceFrame(
                &referenceFrame,
                speaker: speaker,
                start: cursor,
                hasSpeakerReference: hasSpeakerReference
            )

            diagnosticsStorage.micFrames += 1
            switch referenceQuality {
            case .full:
                diagnosticsStorage.fullReferenceFrames += 1
            case .partial:
                diagnosticsStorage.partialReferenceFrames += 1
            case .missing:
                diagnosticsStorage.missingReferenceFrames += 1
            }

            do {
                try processor.processFrame(
                    microphone: micFrame,
                    reference: referenceFrame,
                    output: &processedFrame
                )
                if processedFrame.count == frameSize {
                    output.append(contentsOf: processedFrame)
                    diagnosticsStorage.processedFrames += 1
                } else {
                    output.append(contentsOf: micFrame)
                    diagnosticsStorage.rawFallbackFrames += 1
                    diagnosticsStorage.processingFailures += 1
                }
            } catch {
                output.append(contentsOf: micFrame)
                diagnosticsStorage.rawFallbackFrames += 1
                diagnosticsStorage.processingFailures += 1
            }

            cursor += frameSize
        }

        if cursor < microphone.count {
            output.append(contentsOf: microphone[cursor...])
            diagnosticsStorage.rawFallbackFrames += 1
        }

        return output
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        processor.reset()
        diagnosticsStorage = MeetingEchoSuppressionDiagnostics(
            processorName: processor.name,
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }

    private enum ReferenceQuality {
        case full
        case partial
        case missing
    }

    private func copyFrame(
        from samples: [Float],
        start: Int,
        into frame: inout [Float]
    ) {
        for offset in frame.indices {
            frame[offset] = samples[start + offset]
        }
    }

    private func fillReferenceFrame(
        _ frame: inout [Float],
        speaker: [Float],
        start: Int,
        hasSpeakerReference: Bool
    ) -> ReferenceQuality {
        for index in frame.indices {
            frame[index] = 0
        }

        guard hasSpeakerReference, !speaker.isEmpty, start < speaker.count else {
            return .missing
        }

        if start + frame.count <= speaker.count {
            for offset in frame.indices {
                frame[offset] = speaker[start + offset]
            }
            return .full
        }

        let available = speaker.count - start
        guard available > 0 else {
            return .missing
        }

        for offset in 0..<available {
            frame[offset] = speaker[start + offset]
        }
        return .partial
    }
}
