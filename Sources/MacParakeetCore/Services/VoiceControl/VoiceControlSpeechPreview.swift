import Foundation

/// Display-only preview using the same scheduler as the authoritative final pass.
/// Ordered samples and one consumer avoid concurrent streaming-engine appends.
final class VoiceControlSpeechPreview: Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    private let task: Task<Void, Never>

    init(
        stt: any STTTranscribing, selection: SpeechEngineSelection,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(120))
        continuation = pair.continuation
        task = Task {
            if let live = stt as? any STTLiveDictationTranscribing {
                do {
                    let id = try await live.beginLiveDictationTranscription(onPartial: onPartial)
                    do {
                        for await samples in pair.stream {
                            try Task.checkCancellation()
                            try await live.appendLiveDictationSamples(samples, sessionID: id)
                        }
                    } catch { /* Preview failure never changes the final recording. */  }
                    await live.cancelLiveDictationTranscription(sessionID: id)
                    return
                } catch { /* Non-native engines can use the display-only preview below. */  }
            }
            guard !Task.isCancelled, selection.engine == .parakeet,
                let preview = stt as? any STTDictationPreviewTranscribing
            else { return }
            var window: [Float] = []
            var sincePreview = 0
            for await samples in pair.stream {
                guard !Task.isCancelled else { break }
                window.append(contentsOf: samples)
                sincePreview += samples.count
                if window.count > 64_000 { window.removeFirst(window.count - 64_000) }
                guard sincePreview >= 19_200 else { continue }
                sincePreview = 0
                do {
                    let result = try await preview.transcribeDictationPreview(samples: window, speechEngine: selection)
                    guard !Task.isCancelled else { break }
                    onPartial(result.text)
                } catch { if Task.isCancelled { break } }
            }
            await preview.cancelDictationPreview()
        }
    }
    func append(_ samples: [Float]) { continuation.yield(samples) }
    func stop() async {
        continuation.finish()
        task.cancel()
        await task.value
    }
}
