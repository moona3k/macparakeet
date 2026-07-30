import Foundation

#if MACPARAKEET_HAS_TRANSCRIBE_CPP
import TranscribeCpp

actor TranscribeCppCohereBackend: CohereTranscribeBackend {
    private var model: Model?
    private var session: Session?
    private var activeRun: Task<Transcript, Error>?
    private var activeRunID: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var isLoading = false
    private var isUnloading = false

    func load(
        modelURL: URL,
        computePolicy: CohereTranscribeEngine.ComputePolicy
    ) async throws -> CohereNativeCapabilities {
        guard model == nil, session == nil, !isLoading, !isUnloading else {
            throw CohereNativeBackendError.nativeFailure(
                "The Cohere native context is already loaded or tearing down.")
        }
        isLoading = true
        let loadGeneration = lifecycleGeneration
        defer { isLoading = false }

        let backend: Backend = computePolicy == .metal ? .metal : .cpu
        let loadedModel = try await Task.detached(priority: .userInitiated) {
            try Transcribe.ensureCompatible()
            try Transcribe.initBackends()
            return try Model(
                path: modelURL.path,
                options: ModelOptions(backend: backend)
            )
        }.value

        try Task.checkCancellation()
        guard loadGeneration == lifecycleGeneration, !isUnloading else {
            throw CancellationError()
        }
        let loadedSession = try loadedModel.session(
            SessionOptions(nThreads: 0, kvType: .f16, nCtx: 0)
        )
        let native = loadedModel.capabilities
        let capabilities = CohereNativeCapabilities(
            runtimeVersion: Transcribe.version(),
            runtimeCommit: Transcribe.versionCommit(),
            architecture: loadedModel.arch,
            variant: loadedModel.variant,
            computeBackend: loadedModel.backend,
            nativeSampleRate: Int(native.nativeSampleRate),
            maxAudioMilliseconds: native.maxAudioMs,
            supportedLanguages: native.languages,
            // Cohere's prompt protocol has no native LID head. The model
            // transcribes its supported languages without a caller hint, and
            // the adapter classifies the resulting local text below.
            supportsLanguageDetection: true,
            providesTimestamps: native.maxTimestampKind != .none
        )

        try CohereTranscribeEngine.validateNativeCapabilities(capabilities)
        try Task.checkCancellation()
        guard loadGeneration == lifecycleGeneration, !isUnloading else {
            throw CancellationError()
        }
        model = loadedModel
        session = loadedSession
        return capabilities
    }

    func transcribe(
        samples: [Float],
        language _: String?
    ) async throws -> CohereNativeTranscript {
        guard !isUnloading, let session else {
            throw CohereNativeBackendError.notLoaded
        }
        guard activeRun == nil else {
            throw CohereNativeBackendError.nativeFailure(
                "The Cohere native context already has an active transcription.")
        }

        let runID = UUID()
        let task = Task {
            try await session.run(
                samples,
                options: RunOptions(
                    timestamps: .none,
                    language: nil
                )
            )
        }
        activeRun = task
        activeRunID = runID

        do {
            let transcript = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            finishRun(runID)
            return makeNativeTranscript(transcript, wasTruncated: false)
        } catch let TranscribeError.outputTruncated(_, partial) {
            finishRun(runID)
            guard let partial else {
                return CohereNativeTranscript(
                    text: "",
                    detectedLanguage: nil,
                    wasTruncated: true
                )
            }
            return makeNativeTranscript(partial, wasTruncated: true)
        } catch let TranscribeError.aborted(_, partial) {
            finishRun(runID)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw CohereNativeBackendError.nativeFailure(
                partial?.text.isEmpty == false
                    ? "Cohere transcription was aborted after returning a partial result."
                    : "Cohere transcription was aborted."
            )
        } catch {
            finishRun(runID)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw CohereNativeBackendError.nativeFailure(error.localizedDescription)
        }
    }

    func unload() async {
        isUnloading = true
        lifecycleGeneration &+= 1
        let run = activeRun
        run?.cancel()
        _ = try? await run?.value
        activeRun = nil
        activeRunID = nil

        session?.clearCancellationToken()
        session = nil
        model = nil
        isUnloading = false
    }

    private func finishRun(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRun = nil
        activeRunID = nil
    }

    private nonisolated func makeNativeTranscript(
        _ transcript: Transcript,
        wasTruncated: Bool
    ) -> CohereNativeTranscript {
        CohereNativeTranscript(
            text: transcript.text,
            detectedLanguage: transcript.language
                ?? CohereTranscriptLanguageDetector.detect(
                    transcript.text,
                    supportedLanguages: CohereTranscribeEngine.supportedLanguages.map(\.code)
                ),
            wasTruncated: wasTruncated
        )
    }
}
#endif
