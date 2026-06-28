import AVFoundation
import FluidAudio
import Foundation
import os

protocol STTRuntimeProtocol: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
    func beginLiveDictationTranscription(
        sessionID: UUID,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws
    func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws
    func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult
    func cancelLiveDictationTranscription(sessionID: UUID) async
    func transcribeDictationPreview(
        samples: [Float],
        speechEngine: SpeechEngineSelection
    ) async throws -> STTResult
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func isReady() async -> Bool
    func shutdown() async
    func clearModelCache() async
    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws
    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func currentSpeechEngineSelection() async -> SpeechEngineSelection
}

extension STTRuntimeProtocol {
    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        onProgress?("Preparing \(preference.displayName)...")
        try await setSpeechEngine(preference)
    }
}

/// Sole owner of the shared local speech-engine lifecycle.
///
/// The runtime stays process-wide and singular at the app boundary, but it keeps
/// one `AsrManager` per execution slot so dictation remains isolated from the
/// shared background workload inside app-level scheduling.
public actor STTRuntime: STTRuntimeProtocol {
    private enum LiveDictationSessionState: Equatable {
        case active(UUID)
        case finishing(UUID)
        case cancelling(UUID)
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTRuntime")

    /// Serializes Parakeet TDT Neural Engine inference on macOS 14 (no-op on
    /// 15+); see ``ANEInferenceGate``. Injected so the serialization invariant
    /// is unit-testable on any host, and defaults to the shared process gate so
    /// every STT engine and lane contends on one Neural Engine mutex in
    /// production.
    private let inferenceGate: ANEInferenceGate

    private var interactiveManager: AsrManager?
    private var backgroundManager: AsrManager?
    private var models: AsrModels?
    private var decoderLayerCount: Int?
    private var initializationTask: Task<Void, Error>?
    private var initializationGeneration: UInt64 = 0
    private var warmUpProgressHandler: (@Sendable (String) -> Void)?
    /// The active Parakeet TDT build (`v2`/`v3`). Mutable because the user can
    /// switch variants at runtime (`setParakeetModelVariant`);
    /// `ensureInitialized()` reads it when loading the shared `AsrManager`.
    /// Only meaningful while ``currentParakeetVariant`` is a TDT build — when the
    /// active variant is `.unified` the TDT path never runs, so this holds a
    /// harmless `.v3` placeholder.
    private var modelVersion: AsrModelVersion
    /// The active user-facing Parakeet variant, the source of truth for which
    /// runtime serves Parakeet work. `.v2`/`.v3` route to the shared
    /// `AsrManager` (TDT) path keyed by ``modelVersion``; `.unified` routes to
    /// ``parakeetUnifiedEngine``. Mirrors how ``nemotronModelVariant`` selects
    /// between the two Nemotron engines.
    private var currentParakeetVariant: ParakeetModelVariant
    /// Owns FluidAudio's offline Parakeet Unified runtime. Lazily created the
    /// first time the `.unified` variant is used; sibling of the TDT
    /// `interactiveManager`/`backgroundManager` pair.
    private var parakeetUnifiedEngine: ParakeetUnifiedEngine?
    private var speechEngine: SpeechEnginePreference
    private var nemotronEngine: NemotronEngine?
    private var nemotronEngineLanguage: String?
    private var nemotronEnglishEngine: NemotronEnglishEngine?
    /// The active Nemotron build. Mutable because the user can switch between
    /// the multilingual and English-only variants at runtime
    /// (`setNemotronModelVariant`); the Nemotron paths read it when routing.
    private var nemotronModelVariant: NemotronModelVariant
    private var whisperEngine: WhisperEngine?
    private let whisperModelVariant: String
    /// Owns the Cohere Transcribe runtime (FluidAudio `CoherePipeline`). Lazily
    /// created on first use; sibling of the other speech engines. Batch-only
    /// (no live dictation / preview path).
    private var cohereEngine: CohereTranscribeEngine?
    private let defaults: UserDefaults
    private var activeTranscriptionCount = 0
    private var liveDictationSession: LiveDictationSessionState? {
        didSet {
            guard liveDictationSession == nil, !liveDictationSessionWaiters.isEmpty else { return }
            let waiters = liveDictationSessionWaiters
            liveDictationSessionWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
    private var liveDictationSessionWaiters: [CheckedContinuation<Void, Never>] = []
    /// The native streaming engine driving the active live dictation session.
    /// Captured at `begin` so `append`/`finish`/`cancel` route to the same
    /// loaded engine the session started on, regardless of later preferences.
    private var liveDictationEngine: (any NativeLiveDictating)?

    private var backgroundWarmUpState: STTWarmUpState = .idle
    private var backgroundWarmUpTask: Task<Void, Never>?
    private var warmUpObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation] = [:]
    private var backgroundWarmUpGeneration: UInt64 = 0

    public init(
        parakeetModelVariant: ParakeetModelVariant = .v3,
        speechEngine: SpeechEnginePreference = .parakeet,
        nemotronModelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        whisperModelVariant: String = SpeechEnginePreference.defaultWhisperModelVariant,
        defaults: UserDefaults = .standard,
        inferenceGate: ANEInferenceGate = .shared
    ) {
        self.currentParakeetVariant = parakeetModelVariant
        // `.unified` has no TDT version; the TDT path is never taken for it, so a
        // `.v3` placeholder keeps `modelVersion` non-optional without affecting
        // behavior.
        self.modelVersion = parakeetModelVariant.asrModelVersion ?? .v3
        self.speechEngine = speechEngine
        self.nemotronModelVariant = nemotronModelVariant
        self.whisperModelVariant = WhisperEngine.normalizeModelVariant(whisperModelVariant)
        self.defaults = defaults
        self.inferenceGate = inferenceGate
    }

    #if DEBUG
    /// Test seam: runs `body` under the runtime's injected ``inferenceGate`` so a
    /// test can prove the runtime serializes Neural Engine work on macOS 14
    /// without a CoreML model present. Production inference can't funnel through a
    /// shared helper — its closure captures the actor-owned, non-Sendable
    /// `AsrManager`, which Swift 6 only lets the gate close over inline — so each
    /// `manager.transcribe(...)` site inlines `inferenceGate.withExclusiveAccess`
    /// instead. Every such site MUST be gated; a bare call reopens the concurrent
    /// Neural Engine SIGBUS (FluidAudio #661) for whichever lane runs unguarded.
    func runUnderInferenceGate<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await inferenceGate.withExclusiveAccess(body)
    }
    #endif

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioPath: audioPath,
            job: job,
            speechEngine: SpeechEngineSelection(
                engine: speechEngine,
                language: defaultLanguage(for: speechEngine)
            ),
            onProgress: onProgress
        )
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine selection: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        activeTranscriptionCount += 1
        defer { activeTranscriptionCount -= 1 }

        switch selection.engine {
        case .parakeet:
            return try await transcribeWithParakeet(audioPath: audioPath, job: job, onProgress: onProgress)
        case .nemotron:
            return try await transcribeWithNemotron(
                audioPath: audioPath,
                job: job,
                language: selection.language,
                onProgress: onProgress
            )
        case .whisper:
            return try await transcribeWithWhisper(audioPath: audioPath, language: selection.language, onProgress: onProgress)
        case .cohere:
            return try await transcribeWithCohere(
                audioPath: audioPath,
                job: job,
                language: selection.language,
                onProgress: onProgress
            )
        }
    }

    func transcribeDictationPreview(
        samples: [Float],
        speechEngine selection: SpeechEngineSelection
    ) async throws -> STTResult {
        guard !samples.isEmpty else {
            throw STTError.transcriptionFailed("No dictation preview samples")
        }

        activeTranscriptionCount += 1
        defer { activeTranscriptionCount -= 1 }

        switch selection.engine {
        case .parakeet:
            return try await transcribeParakeetPreview(samples: samples)
        case .whisper:
            return try await transcribeWhisperPreview(samples: samples, language: selection.language)
        case .nemotron:
            throw STTError.transcriptionFailed("Nemotron uses native live dictation partials and does not support display-preview transcription.")
        case .cohere:
            throw STTError.transcriptionFailed("Cohere uses record-then-transcribe dictation and does not support display-preview transcription.")
        }
    }

    func beginLiveDictationTranscription(
        sessionID: UUID,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        guard liveDictationSession == nil else {
            throw STTError.engineBusy
        }
        let engine: any NativeLiveDictating
        let language: String?
        switch speechEngine {
        case .parakeet where currentParakeetVariant.usesUnifiedEngine:
            guard let unifiedEngine = parakeetUnifiedEngine else {
                throw STTLiveDictationTranscriptionError.modelNotReady
            }
            engine = unifiedEngine
            language = nil
        case .parakeet:
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.parakeet)
        case .nemotron:
            // Both Nemotron builds wrap FluidAudio streaming managers that emit
            // partials, so live dictation routes to whichever build is active.
            // The English build ignores the language hint; the multilingual
            // build honors the persisted default.
            if nemotronModelVariant.isEnglishOnly {
                guard let englishEngine = nemotronEnglishEngine else {
                    throw STTLiveDictationTranscriptionError.modelNotReady
                }
                engine = englishEngine
                language = nil
            } else {
                guard let multilingualEngine = nemotronEngine else {
                    throw STTLiveDictationTranscriptionError.modelNotReady
                }
                engine = multilingualEngine
                language = defaultLanguage(for: .nemotron)
            }
        case .whisper:
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.whisper)
        case .cohere:
            // Batch engine — no native live-partial path.
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.cohere)
        }
        guard await engine.isReady() else {
            throw STTLiveDictationTranscriptionError.modelNotReady
        }

        // Intentionally NOT wrapped in `ANEInferenceGate`: `beginLiveDictation`
        // is inference-free session setup — it resets streaming state, configures
        // language, and stores the partial callback. Models are already loaded
        // (the `isReady()` guard above ensures `prepare()` inside is a no-op), and
        // the only Neural Engine work happens inside the native streaming
        // engines' `processLiveDictationSamples` / `finishLiveDictation`
        // implementations, which own their inference-level `ANEInferenceGate`
        // calls. Gating start-of-session here would just add dictation-start
        // latency on macOS 14 with no SIGBUS to prevent.
        activeTranscriptionCount += 1
        do {
            try await engine.beginLiveDictation(
                language: language,
                onPartial: onPartial
            )
            liveDictationEngine = engine
            liveDictationSession = .active(sessionID)
        } catch {
            activeTranscriptionCount -= 1
            throw error
        }
    }

    func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws {
        guard liveDictationSession == .active(sessionID),
              let engine = liveDictationEngine else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        try await engine.processLiveDictationSamples(samples)
    }

    func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult {
        guard liveDictationSession == .active(sessionID),
              let engine = liveDictationEngine else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveDictationSession = .finishing(sessionID)
        defer {
            if liveDictationSession == .finishing(sessionID) {
                liveDictationSession = nil
            }
            liveDictationEngine = nil
            activeTranscriptionCount -= 1
        }
        return try await engine.finishLiveDictation()
    }

    func cancelLiveDictationTranscription(sessionID: UUID) async {
        guard liveDictationSession == .active(sessionID) else { return }
        liveDictationSession = .cancelling(sessionID)
        await liveDictationEngine?.cancelLiveDictation()
        liveDictationEngine = nil
        if liveDictationSession == .cancelling(sessionID) {
            liveDictationSession = nil
        }
        activeTranscriptionCount -= 1
    }

    private func transcribeWithNemotron(
        audioPath: String,
        job: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        // The English-only build has no language hint surface; the selection's
        // language is intentionally ignored (it stays persisted and applies the
        // moment the multilingual build is selected again).
        if nemotronModelVariant.isEnglishOnly {
            let engine = try ensureNemotronEnglishEngine()
            return try await engine.transcribe(
                audioURL: URL(fileURLWithPath: audioPath),
                job: job,
                onProgress: onProgress
            )
        }
        let language = SpeechEnginePreference.normalizeNemotronLanguage(language)
        let engine = try await ensureNemotronEngine(language: language)
        return try await engine.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            job: job,
            language: language,
            onProgress: onProgress
        )
    }

    private func transcribeWithWhisper(
        audioPath: String,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = try ensureWhisperEngine()
        return try await engine.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            language: language,
            onProgress: onProgress
        )
    }

    private func transcribeWithCohere(
        audioPath: String,
        job: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = try ensureCohereEngine()
        return try await engine.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            job: job,
            language: language,
            onProgress: onProgress
        )
    }

    private func transcribeWhisperPreview(samples: [Float], language: String?) async throws -> STTResult {
        let engine = try ensureWhisperEngine()
        return try await engine.transcribe(samples: samples, language: language)
    }

    /// Transcription-path engine access. `warmUp()` and
    /// `performSpeechEngineSwitch()` intentionally construct `WhisperEngine`
    /// inline instead. Warm-up is NOT gated on `activeTranscriptionCount`
    /// (background warm-up fires from launch/meeting/onboarding flows while
    /// jobs may be in flight); it stays safe because its reuse-or-construct
    /// (`whisperEngine ?? WhisperEngine(...)`) is synchronous on this actor,
    /// so it can never double-construct or orphan an engine mid-job. The
    /// switch path runs under `setSpeechEngine`'s
    /// `activeTranscriptionCount == 0` guard and stages into
    /// `preparedWhisper` (prepare-then-commit, with a `language:` argument)
    /// rather than committing to `whisperEngine` up front. Routing either
    /// through this guard would change those semantics for no safety gain.
    private func ensureWhisperEngine() throws -> WhisperEngine {
        if let whisperEngine {
            return whisperEngine
        }
        // Mirrors ensureNemotronEngine: never construct a fresh engine while
        // another transcription may be mid-flight on the existing one. The
        // scheduler's single background slot already serializes Whisper jobs,
        // but the invariant shouldn't depend on the caller (AUDIT-075).
        guard activeTranscriptionCount <= 1 else {
            throw STTError.engineBusy
        }
        let engine = WhisperEngine(model: whisperModelVariant)
        whisperEngine = engine
        return engine
    }

    /// Owns the single Cohere engine instance. The compute policy is read once
    /// at construction; language is supplied per-call, so an existing engine is
    /// always reusable. Cohere job serialization lives in `STTScheduler`, so
    /// construction only needs this actor's normal single-threaded mutation.
    private func ensureCohereEngine() throws -> CohereTranscribeEngine {
        if let cohereEngine {
            return cohereEngine
        }
        let engine = CohereTranscribeEngine(
            computePolicy: CohereTranscribeEngine.ComputePolicy.current(defaults: defaults)
        )
        cohereEngine = engine
        return engine
    }

    private func transcribeWithParakeet(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        // Parakeet Unified is a separate FluidAudio runtime — delegate before
        // touching the shared TDT `AsrManager` path.
        if currentParakeetVariant.usesUnifiedEngine {
            return try await ensureParakeetUnifiedEngine().transcribe(
                audioPath: audioPath,
                job: job,
                onProgress: onProgress
            )
        }

        try await ensureInitialized()

        let slot = route(for: job)
        guard let manager = manager(for: slot) else {
            throw STTError.modelNotLoaded
        }
        guard let decoderLayers = decoderLayerCount else {
            throw STTError.modelNotLoaded
        }

        // Dictation finalizes a short, single-window clip. Pad a little trailing
        // silence onto the samples so the Parakeet TDT decoder has enough
        // context to emit a fast final word that lands right on the end of the
        // recording (issue #562). The decode is bounded to the real (pre-pad)
        // audio length, so FluidAudio's own fixed-size input padding does not
        // extend it: only real trailing samples do. File/meeting jobs and long
        // dictations keep FluidAudio's URL path (which disk-backs long audio for
        // constant memory); Whisper is unaffected (trailing silence there can
        // trigger hallucinated text). An unreadable, empty, or long clip yields
        // no padded samples and falls through to the URL path below;
        // transcription errors themselves propagate from either path.
        if job == .dictation {
            let paddedSamples = Self.paddedDictationSamples(audioPath: audioPath)
            if !paddedSamples.isEmpty {
                do {
                    try Task.checkCancellation()
                    var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                    try Task.checkCancellation()
                    onProgress?(0, 100)
                    // Same Neural Engine serialization as the URL and preview
                    // paths below: this short-clip finalize is the common
                    // dictation case, so leaving it ungated lets it race a
                    // concurrent background transcription and SIGBUS on macOS 14.
                    let result = try await inferenceGate.withExclusiveAccess {
                        try await manager.transcribe(paddedSamples, decoderState: &decoderState)
                    }
                    onProgress?(100, 100)
                    return STTResult(
                        text: result.text,
                        words: STTWordTimingBuilder.words(from: result.tokenTimings),
                        language: "en",
                        engine: .parakeet,
                        engineVariant: ParakeetModelVariant(asrModelVersion: modelVersion).rawValue
                    )
                } catch {
                    throw try Self.mapTranscriptionError(error)
                }
            }
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        let transcriptionProgressTask: Task<Void, Never>? = if let onProgress {
            Task {
                do {
                    let progressStream = await manager.transcriptionProgressStream
                    var lastProgress = -1
                    for try await value in progressStream {
                        let percent = min(99, max(0, Int((value * 100).rounded())))
                        guard percent != lastProgress else { continue }
                        lastProgress = percent
                        onProgress(percent, 100)
                    }
                } catch {
                    // The transcription task completes or fails independently.
                }
            }
        } else {
            nil
        }
        defer {
            transcriptionProgressTask?.cancel()
        }

        onProgress?(0, 100)

        do {
            try Task.checkCancellation()
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            try Task.checkCancellation()
            // Serialize only the CoreML inference call on macOS 14 (no-op on
            // macOS 15+). Model setup and progress plumbing stay outside the
            // hardware mutex so unsupported or preprocessing-only work does not
            // delay interactive inference.
            let result = try await inferenceGate.withExclusiveAccess {
                try await manager.transcribe(audioURL, decoderState: &decoderState)
            }
            let words = STTWordTimingBuilder.words(from: result.tokenTimings)
            onProgress?(100, 100)
            // Telemetry `language` is attributed "en": MacParakeet positions
            // Parakeet as English-first (v2 is English-only; v3 multilingual is
            // not surfaced via a Parakeet language picker), so this reflects the
            // app's configuration rather than per-segment detection. The
            // `engineVariant` carries the active build (v2/v3) so adoption and
            // impact can be measured without exposing transcript content.
            return STTResult(
                text: result.text,
                words: words,
                language: "en",
                engine: .parakeet,
                engineVariant: ParakeetModelVariant(asrModelVersion: modelVersion).rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    // MARK: - Dictation trailing-silence pad (issue #562)

    /// Trailing silence appended to a dictation clip before the final Parakeet
    /// transcription. Enough to give the TDT decoder a few extra encoder frames
    /// so it emits a fast final word (the decode is bounded to the real, pre-pad
    /// length — FluidAudio's fixed-size input padding does not extend it), but
    /// small enough to add no perceptible stop latency.
    static let dictationTrailingSilenceSeconds: Double = 0.5

    /// Decode the recorded dictation WAV and append trailing silence — but only
    /// for short, single-window clips. Returns an empty array (so the caller
    /// keeps the URL path) for an unreadable/empty clip, or one long enough that
    /// FluidAudio would chunk it: long audio stays on the disk-backed URL path,
    /// which holds memory constant, while this helper stays focused on the
    /// reported short-clip failure mode.
    static func paddedDictationSamples(audioPath: String) -> [Float] {
        let padSamples = Int(dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        // Keep the *padded* clip inside FluidAudio's single-window tier
        // (`maxModelSamples`). Bounding the pre-pad length here also means a long
        // file is never read fully into memory just to be discarded.
        guard
            let samples = loadShortDictationSamples16k(
                path: audioPath,
                maxSamples: max(0, ASRConstants.maxModelSamples - padSamples)
            ),
            !samples.isEmpty
        else {
            return []
        }
        return appendingTrailingSilence(
            samples,
            seconds: dictationTrailingSilenceSeconds,
            sampleRate: ASRConstants.sampleRate
        )
    }

    /// Append `seconds` of silence (zero samples) to the end of `samples`.
    /// Pure and allocation-bounded; a no-op for empty input or a non-positive
    /// pad so callers can apply it unconditionally.
    static func appendingTrailingSilence(
        _ samples: [Float],
        seconds: Double,
        sampleRate: Int
    ) -> [Float] {
        guard seconds > 0, sampleRate > 0, !samples.isEmpty else { return samples }
        let padCount = Int(seconds * Double(sampleRate))
        guard padCount > 0 else { return samples }
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: padCount))
        return padded
    }

    /// Decode a recorded dictation WAV to 16 kHz mono Float samples, mirroring
    /// the capture pipeline's downmix + resample (`AudioChunker.extractAndResample`).
    /// Returns nil for an unreadable or empty file, or one whose 16 kHz length
    /// exceeds `maxSamples` — checked before reading, so a long file is not
    /// loaded into memory (the caller keeps FluidAudio's disk-backed URL path).
    /// Dictation clips are short, so a qualifying file is read in one buffer.
    static func loadShortDictationSamples16k(path: String, maxSamples: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let sourceRate = file.processingFormat.sampleRate
        guard
            sourceRate > 0,
            let frameCount = AVAudioFrameCount(exactly: file.length),
            frameCount > 0
        else {
            return nil
        }
        // Dictation WAVs are written at 16 kHz mono; estimate the 16 kHz length
        // so the guard holds even if that capture format ever changes.
        let estimated16kSamples = Int(
            (Double(file.length) * Double(ASRConstants.sampleRate) / sourceRate).rounded(.up)
        )
        guard
            estimated16kSamples <= maxSamples,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
            (try? file.read(into: buffer)) != nil
        else {
            return nil
        }
        return AudioChunker.extractAndResample(from: buffer)
    }

    private func transcribeParakeetPreview(samples: [Float]) async throws -> STTResult {
        // Parakeet Unified drives live dictation through its native streaming
        // manager. This display-preview batch path is for the TDT builds only;
        // return an empty preview if a stale caller reaches it.
        if currentParakeetVariant.usesUnifiedEngine {
            return STTResult(
                text: "",
                words: [],
                language: "en",
                engine: .parakeet,
                engineVariant: ParakeetModelVariant.unified.rawValue
            )
        }

        try await ensureInitialized()

        guard let manager = manager(for: .interactive) else {
            throw STTError.modelNotLoaded
        }
        guard let decoderLayers = decoderLayerCount else {
            throw STTError.modelNotLoaded
        }

        do {
            try Task.checkCancellation()
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            try Task.checkCancellation()
            let result = try await inferenceGate.withExclusiveAccess {
                try await manager.transcribe(samples, decoderState: &decoderState)
            }
            return STTResult(
                text: result.text,
                words: STTWordTimingBuilder.words(from: result.tokenTimings),
                // Mirrors batch Parakeet attribution: the build variant carries v2/v3.
                language: "en",
                engine: .parakeet,
                engineVariant: ParakeetModelVariant(asrModelVersion: modelVersion).rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    /// Warms the runtime and reports progress through `onProgress` only.
    ///
    /// This method does not update `observeWarmUpProgress()` observers. Call
    /// `backgroundWarmUp()` when UI state should flow through the shared
    /// observer stream instead of a one-off callback.
    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpProgressHandler = onProgress
        defer {
            warmUpProgressHandler = nil
        }

        onProgress?("Loading model into memory...")

        let start = ContinuousClock.now
        let operationContext = Observability.childOperationContext()
        let activeSpeechEngine = speechEngine
        let modelKind = telemetryModelKind(for: activeSpeechEngine)
        let engineVariant = telemetryEngineVariant(for: activeSpeechEngine)
        do {
            switch activeSpeechEngine {
            case .parakeet:
                try await ensureInitialized()
            case .nemotron where nemotronModelVariant.isEnglishOnly:
                let engine = try ensureNemotronEnglishEngine()
                try await engine.prepare(onProgress: onProgress)
            case .nemotron:
                let engine = try await ensureNemotronEngine(
                    language: SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
                )
                try await engine.prepare(onProgress: onProgress)
            case .whisper:
                let engine = whisperEngine ?? WhisperEngine(model: whisperModelVariant)
                whisperEngine = engine
                try await engine.prepare(onProgress: onProgress)
            case .cohere:
                let engine = try ensureCohereEngine()
                try await engine.prepare(onProgress: onProgress)
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            Telemetry.send(.modelLoaded(
                loadTimeSeconds: seconds,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant
            ))
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .success,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: seconds,
                errorType: nil
            ))
            onProgress?("Ready")
        } catch is CancellationError {
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .cancelled,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: durationSeconds,
                errorType: "CancellationError"
            ))
            throw CancellationError()
        } catch {
            let mapped = try Self.mapWarmUpError(error)
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .failure,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                errorType: TelemetryErrorClassifier.classify(mapped)
            ))
            throw mapped
        }
    }

    public func backgroundWarmUp() async {
        if case .ready = backgroundWarmUpState { return }
        if backgroundWarmUpTask != nil { return }

        // Order matters: `beginBackgroundWarmUp()` advances the generation
        // counter *before* the task is assigned to `backgroundWarmUpTask`.
        // This is safe because both the generation check and the nil-task
        // guard at the top run synchronously on this actor — no suspension
        // point exists between them and the assignment below, so no
        // concurrent caller can observe the intermediate state.
        let generation = beginBackgroundWarmUp()
        prepareBackgroundWarmUpForRetry()
        setBackgroundWarmUpState(
            .working(message: "Checking setup requirements...", progress: nil),
            generation: generation
        )
        backgroundWarmUpTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.warmUp { [weak self] progressMessage in
                    guard let self else { return }
                    Task { [weak self] in
                        guard let self else { return }
                        let message = "Speech model: \(progressMessage)"
                        let fraction = OnboardingProgressParser.parseProgressFraction(from: message)
                        await self.setBackgroundWarmUpState(
                            .working(message: message, progress: fraction),
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()
                await self.setBackgroundWarmUpState(.ready, generation: generation)
            } catch is CancellationError {
                // Cancelled — don't update state.
            } catch {
                await self.setBackgroundWarmUpState(.failed(message: error.localizedDescription), generation: generation)
            }
            await self.clearBackgroundWarmUpTask(generation: generation)
        }
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let id = UUID()
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(backgroundWarmUpState)
            warmUpObservers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeWarmUpObserver(id: id)
                }
            }
        }
        return (id, stream)
    }

    public func removeWarmUpObserver(id: UUID) async {
        warmUpObservers.removeValue(forKey: id)?.finish()
    }

    public func isReady() async -> Bool {
        if speechEngine == .nemotron {
            if nemotronModelVariant.isEnglishOnly {
                return await nemotronEnglishEngine?.isReady() ?? false
            }
            return await nemotronEngine?.isReady() ?? false
        }
        if speechEngine == .whisper {
            return await whisperEngine?.isReady() ?? false
        }
        if speechEngine == .cohere {
            return await cohereEngine?.isReady() ?? false
        }

        // Parakeet engine: Unified reports through its own engine actor.
        if currentParakeetVariant.usesUnifiedEngine {
            return await parakeetUnifiedEngine?.isReady() ?? false
        }

        guard let interactiveManager, let backgroundManager else { return false }
        let interactiveReady = await interactiveManager.isAvailable
        let backgroundReady = await backgroundManager.isAvailable
        return interactiveReady && backgroundReady
    }

    public func shutdown() async {
        invalidateBackgroundWarmUp()
        await cancelOrWaitForLiveDictationSession()
        await unloadWhisper()
        await unloadNemotron()
        await unloadParakeet()
        await unloadCohere()
        warmUpProgressHandler = nil
        setBackgroundWarmUpState(.idle)
    }

    private func cancelOrWaitForLiveDictationSession() async {
        switch liveDictationSession {
        case .active(let sessionID):
            await cancelLiveDictationTranscription(sessionID: sessionID)
        case .finishing, .cancelling:
            await waitForLiveDictationSessionToEnd()
        case nil:
            return
        }
    }

    private func waitForLiveDictationSessionToEnd() async {
        while liveDictationSession != nil {
            await withCheckedContinuation { continuation in
                liveDictationSessionWaiters.append(continuation)
            }
        }
    }

    public func clearModelCache() async {
        let operationContext = Observability.childOperationContext()
        let activeSpeechEngine = speechEngine
        let engineVariant = telemetryEngineVariant(for: activeSpeechEngine)
        await shutdown()
        DownloadUtils.clearAllModelCaches()
        try? FileManager.default.removeItem(atPath: AppPaths.whisperModelsDir)
        _ = Self.removeNemotronModelFiles(at: NemotronEngine.defaultCacheRoot())
        // The English build caches under its own family root
        // (`Models/nemotron-streaming/<tier>ms`); remove the family root so a
        // full clear can't strand a tier directory.
        _ = Self.removeNemotronModelFiles(
            at: NemotronEnglishEngine.defaultCacheRoot().deletingLastPathComponent()
        )
        // Cohere caches under `…/Models/cohere-transcribe/q8`; remove the family
        // root so a full clear can't strand the precision subdirectory.
        _ = CohereTranscribeEngine.deleteModel(
            cacheRoot: CohereTranscribeEngine.defaultCacheRoot().deletingLastPathComponent()
        )
        setBackgroundWarmUpState(.idle)
        Telemetry.send(.modelOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            action: .clearCache,
            outcome: .success,
            stage: .clearCache,
            modelKind: .localSpeechStack,
            speechEngine: activeSpeechEngine,
            engineVariant: engineVariant,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: nil
        ))
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await setSpeechEngine(preference, onProgress: nil)
    }

    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard preference != speechEngine else {
            preference.save(to: defaults)
            return
        }

        guard initializationTask == nil, activeTranscriptionCount == 0 else {
            throw STTError.engineBusy
        }

        invalidateBackgroundWarmUp()
        setBackgroundWarmUpState(.idle)

        let previous = speechEngine
        let startedAt = Date()
        let targetVariant = telemetryEngineVariant(for: preference) ?? "none"
        logger.notice("speech_engine_switch_start from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) variant=\(targetVariant, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "speech_engine_switch_start from=\(previous.rawValue) to=\(preference.rawValue) variant=\(targetVariant)"
        )

        do {
            try await performSpeechEngineSwitch(
                from: previous,
                to: preference,
                onProgress: onProgress
            )
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("speech_engine_switch_complete from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "speech_engine_switch_complete from=\(previous.rawValue) to=\(preference.rawValue) duration_s=\(Self.formatSeconds(duration))"
            )
        } catch {
            let duration = Observability.durationSeconds(since: startedAt)
            logger.error("speech_engine_switch_failed from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) duration_s=\(duration, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "speech_engine_switch_failed from=\(previous.rawValue) to=\(preference.rawValue) duration_s=\(Self.formatSeconds(duration)) \(AudioCaptureDiagnostics.errorFields(error))"
            )
            throw error
        }
    }

    private func performSpeechEngineSwitch(
        from previous: SpeechEnginePreference,
        to preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        var preparedWhisper: WhisperEngine?
        var preparedNemotron: NemotronEngine?
        var preparedNemotronEnglish: NemotronEnglishEngine?

        switch preference {
        case .parakeet:
            onProgress?("Loading Parakeet with Core ML...")
            try await ensureInitialized()
        case .nemotron where nemotronModelVariant.isEnglishOnly:
            let engine = try ensureNemotronEnglishEngine()
            try await engine.prepare(onProgress: onProgress)
            preparedNemotronEnglish = engine
        case .nemotron:
            let engine = try await ensureNemotronEngine(
                language: SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
            )
            try await engine.prepare(onProgress: onProgress)
            preparedNemotron = engine
        case .whisper:
            let engine = whisperEngine ?? WhisperEngine(
                model: whisperModelVariant,
                language: SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)
            )
            try await engine.prepare(onProgress: onProgress)
            preparedWhisper = engine
        case .cohere:
            let engine = try ensureCohereEngine()
            try await engine.prepare(onProgress: onProgress)
        }

        if let preparedWhisper {
            whisperEngine = preparedWhisper
        }
        if let preparedNemotron {
            nemotronEngine = preparedNemotron
        }
        if let preparedNemotronEnglish {
            nemotronEnglishEngine = preparedNemotronEnglish
        }
        speechEngine = preference
        preference.save(to: defaults)

        switch previous {
        case .parakeet where preference != .parakeet:
            onProgress?("Releasing Parakeet model...")
            await unloadParakeet()
        case .nemotron where preference != .nemotron:
            onProgress?("Releasing Nemotron model...")
            await unloadNemotron()
        case .whisper where preference != .whisper:
            onProgress?("Releasing Whisper model...")
            await unloadWhisper()
        case .cohere where preference != .cohere:
            onProgress?("Releasing Cohere model...")
            await unloadCohere()
        default:
            break
        }
        onProgress?("\(preference.displayName) is ready")
    }

    /// Switches the active Parakeet build between the multilingual `v3` and the
    /// English-only `v2` variant. Symmetric to ``setSpeechEngine(_:onProgress:)``:
    /// it downloads the target first (so the current model keeps serving until
    /// the slow fetch finishes), then swaps the loaded managers in place. When
    /// the target is already cached the download is a cheap no-op, so flipping
    /// between two installed variants is near-instant.
    ///
    /// If Parakeet isn't the active engine there is nothing loaded to swap, so
    /// the new version is simply recorded and takes effect the next time
    /// Parakeet loads.
    public func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        // Compare on the user-facing variant so unified↔v2/v3 switches register
        // even though `.unified` has no `AsrModelVersion`.
        guard variant != currentParakeetVariant else { return }

        guard initializationTask == nil, activeTranscriptionCount == 0 else {
            throw STTError.engineBusy
        }

        let previousVariant = currentParakeetVariant
        let previousVersion = modelVersion
        let startedAt = Date()
        logger.notice("parakeet_variant_switch_start to=\(variant.rawValue, privacy: .public) engine=\(self.speechEngine.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "parakeet_variant_switch_start to=\(variant.rawValue) engine=\(self.speechEngine.rawValue)"
        )

        guard speechEngine == .parakeet else {
            // Inactive engine: record the choice; it loads on the next Parakeet use.
            currentParakeetVariant = variant
            if let targetVersion = variant.asrModelVersion {
                modelVersion = targetVersion
            }
            logger.notice("parakeet_variant_switch_deferred to=\(variant.rawValue, privacy: .public) reason=engine_inactive")
            AudioCaptureDiagnostics.append("parakeet_variant_switch_deferred to=\(variant.rawValue) reason=engine_inactive")
            return
        }

        invalidateBackgroundWarmUp()
        setBackgroundWarmUpState(.idle)

        do {
            onProgress?("Preparing \(variant.modelName)...")
            // Download the target build first so the current model keeps serving
            // until the fetch completes. Unified and TDT live in different repos.
            if variant.usesUnifiedEngine {
                try await ParakeetUnifiedEngine.downloadModel(onProgress: onProgress)
            } else if let targetVersion = variant.asrModelVersion {
                try await downloadParakeetModels(version: targetVersion, onProgress: onProgress)
            }

            onProgress?("Loading \(variant.modelName) with Core ML...")
            await unloadParakeet()
            currentParakeetVariant = variant
            if let targetVersion = variant.asrModelVersion {
                modelVersion = targetVersion
            }
            try await ensureInitialized()

            onProgress?("\(variant.modelName) is ready")
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("parakeet_variant_switch_complete to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "parakeet_variant_switch_complete to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration))"
            )
        } catch {
            let switchError = error
            // Restore the previous variant so the in-memory runtime matches the
            // persisted preference; callers only save the new selection on
            // success.
            currentParakeetVariant = previousVariant
            modelVersion = previousVersion
            do {
                try await ensureInitialized()
            } catch {
                logger.error("parakeet_variant_restore_failed version=\(String(describing: previousVersion), privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                AudioCaptureDiagnostics.append(
                    "parakeet_variant_restore_failed version=\(previousVersion) \(AudioCaptureDiagnostics.errorFields(error))"
                )
            }
            let duration = Observability.durationSeconds(since: startedAt)
            logger.error("parakeet_variant_switch_failed to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(switchError), privacy: .public) error_detail=\(switchError.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "parakeet_variant_switch_failed to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration)) \(AudioCaptureDiagnostics.errorFields(switchError))"
            )
            throw switchError
        }
    }

    /// Switches the active Nemotron build between the multilingual and the
    /// English-only variant. Symmetric to ``setParakeetModelVariant(_:onProgress:)``:
    /// it downloads the target first (so the current model keeps serving until
    /// the slow fetch finishes), then swaps the loaded engine in place. When the
    /// target is already cached the download is a cheap no-op.
    ///
    /// If Nemotron isn't the active engine there is nothing loaded to swap, so
    /// the new variant is simply recorded and takes effect the next time
    /// Nemotron loads.
    public func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard variant != nemotronModelVariant else { return }

        guard initializationTask == nil, activeTranscriptionCount == 0 else {
            throw STTError.engineBusy
        }

        let previousVariant = nemotronModelVariant
        let startedAt = Date()
        logger.notice("nemotron_variant_switch_start to=\(variant.rawValue, privacy: .public) engine=\(self.speechEngine.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "nemotron_variant_switch_start to=\(variant.rawValue) engine=\(self.speechEngine.rawValue)"
        )

        guard speechEngine == .nemotron else {
            // Inactive engine: record the choice; it loads on the next Nemotron use.
            nemotronModelVariant = variant
            logger.notice("nemotron_variant_switch_deferred to=\(variant.rawValue, privacy: .public) reason=engine_inactive")
            AudioCaptureDiagnostics.append("nemotron_variant_switch_deferred to=\(variant.rawValue) reason=engine_inactive")
            return
        }

        invalidateBackgroundWarmUp()
        setBackgroundWarmUpState(.idle)

        do {
            onProgress?("Preparing \(variant.modelName)...")
            try await Self.downloadNemotronModel(
                modelVariant: variant,
                language: SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults),
                emitTelemetry: false,
                onProgress: onProgress
            )

            onProgress?("Loading \(variant.modelName) with Core ML...")
            await unloadNemotron()
            nemotronModelVariant = variant
            try await prepareActiveNemotronEngine(onProgress: onProgress)

            onProgress?("\(variant.modelName) is ready")
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("nemotron_variant_switch_complete to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "nemotron_variant_switch_complete to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration))"
            )
        } catch {
            let switchError = error
            // Restore the previous variant so the in-memory runtime matches the
            // persisted preference; callers only save the new selection on
            // success.
            nemotronModelVariant = previousVariant
            do {
                try await prepareActiveNemotronEngine(onProgress: nil)
            } catch {
                logger.error("nemotron_variant_restore_failed variant=\(previousVariant.rawValue, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                AudioCaptureDiagnostics.append(
                    "nemotron_variant_restore_failed variant=\(previousVariant.rawValue) \(AudioCaptureDiagnostics.errorFields(error))"
                )
            }
            let duration = Observability.durationSeconds(since: startedAt)
            logger.error("nemotron_variant_switch_failed to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(switchError), privacy: .public) error_detail=\(switchError.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "nemotron_variant_switch_failed to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration)) \(AudioCaptureDiagnostics.errorFields(switchError))"
            )
            throw switchError
        }
    }

    /// Loads whichever Nemotron build `nemotronModelVariant` currently selects.
    /// Shared by the variant switch's commit and restore paths.
    private func prepareActiveNemotronEngine(
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        if nemotronModelVariant.isEnglishOnly {
            let engine = try ensureNemotronEnglishEngine()
            try await engine.prepare(onProgress: onProgress)
        } else {
            let engine = try await ensureNemotronEngine(
                language: SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
            )
            try await engine.prepare(onProgress: onProgress)
        }
    }

    /// Pre-fetches a Parakeet build to disk without loading it, reusing the
    /// throttled progress→message bridge. Returns immediately when the model is
    /// already cached (`AsrModels.download` validates and no-ops).
    private func downloadParakeetModels(
        version: AsrModelVersion,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        try await Self.downloadParakeetModel(version: version, onProgress: onProgress)
    }

    /// Downloads a Parakeet build to its version-specific cache without loading
    /// it (no runtime spin-up). Cached builds are a cheap validate-and-return.
    /// Exposed for the CLI's `models download parakeet-v2|v3` path so a build can
    /// be pre-fetched headlessly without selecting it.
    public nonisolated static func downloadParakeetModel(
        version: AsrModelVersion,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let progressHandler = makeDownloadProgressHandler(onProgress)
        _ = try await AsrModels.download(version: version, progressHandler: progressHandler)
    }

    public func currentSpeechEngineSelection() async -> SpeechEngineSelection {
        SpeechEngineSelection(
            engine: speechEngine,
            language: defaultLanguage(for: speechEngine)
        )
    }

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    public nonisolated static func isNemotronModelCached(
        modelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        language: String? = nil
    ) -> Bool {
        if modelVariant.isEnglishOnly {
            return NemotronEnglishEngine.isModelCached()
        }
        return NemotronEngine.isModelCached(modelVariant: modelVariant, language: language)
    }

    /// Deletes a single Parakeet build's files from disk, leaving the sibling
    /// build (and every other model) untouched. Each FluidAudio version caches
    /// into its own leaf directory under `…/FluidAudio/Models`, so removing one
    /// can't strand the other. Returns `true` when files were present and are
    /// now gone; a no-op `false` when the build wasn't cached.
    ///
    /// Pure file work — callers must not delete the build currently loaded by
    /// the active engine (the app and CLI guard this). Mirrors
    /// ``downloadParakeetModel(version:onProgress:)`` so a build can be removed
    /// headlessly without touching the runtime.
    @discardableResult
    public nonisolated static func deleteParakeetModel(version: AsrModelVersion) -> Bool {
        let operationContext = Observability.childOperationContext()
        let removed = removeParakeetModelFiles(at: AsrModels.defaultCacheDirectory(for: version))
        Telemetry.send(.modelOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            action: .deleteModel,
            outcome: removed ? .success : .failure,
            stage: .delete,
            modelKind: .parakeetSTT,
            speechEngine: .parakeet,
            engineVariant: ParakeetModelVariant(asrModelVersion: version).rawValue,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: nil
        ))
        return removed
    }

    /// File-removal core of ``deleteParakeetModel(version:)``, split out so the
    /// directory resolution can be exercised against a temp dir in tests without
    /// emitting telemetry. Returns `true` only when the directory existed and is
    /// gone afterward.
    @discardableResult
    nonisolated static func removeParakeetModelFiles(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            return false
        }
        return !fileManager.fileExists(atPath: directory.path)
    }

    /// File-removal core for the full-stack `models clear` path. Nemotron keeps
    /// language-scoped directories under one repo root, so a full clear removes
    /// the root rather than the currently configured language leaf only.
    @discardableResult
    nonisolated static func removeNemotronModelFiles(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            return false
        }
        return !fileManager.fileExists(atPath: directory.path)
    }

    /// Deletes a downloaded Whisper variant from disk, leaving Parakeet and the
    /// speaker models untouched. Thin telemetry-emitting wrapper over
    /// ``WhisperEngine/deleteModel(model:downloadBase:defaults:)`` so model
    /// deletions report through the same `model_operation` channel as Parakeet.
    /// Pure-file deletion (and its unit tests) lives on `WhisperEngine`.
    @discardableResult
    public nonisolated static func deleteWhisperModel(
        variant: String = SpeechEnginePreference.defaultWhisperModelVariant,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let operationContext = Observability.childOperationContext()
        let removed = WhisperEngine.deleteModel(model: variant, defaults: defaults)
        Telemetry.send(.modelOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            action: .deleteModel,
            outcome: removed ? .success : .failure,
            stage: .delete,
            modelKind: .whisperSTT,
            speechEngine: .whisper,
            engineVariant: SpeechEnginePreference.normalizeModelVariant(variant) ?? variant,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: nil
        ))
        return removed
    }

    public nonisolated static func downloadNemotronModel(
        modelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        language: String? = nil,
        emitTelemetry: Bool = true,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await downloadNemotronModel(
            modelVariant: modelVariant,
            language: language,
            emitTelemetry: emitTelemetry,
            onProgress: onProgress,
            downloader: { modelVariant, language, onProgress in
                if modelVariant.isEnglishOnly {
                    return try await NemotronEnglishEngine.downloadModel(onProgress: onProgress)
                }
                return try await NemotronEngine.downloadModel(
                    modelVariant: modelVariant,
                    language: language,
                    onProgress: onProgress
                )
            }
        )
    }

    nonisolated static func downloadNemotronModel(
        modelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        language: String? = nil,
        emitTelemetry: Bool,
        onProgress: (@Sendable (String) -> Void)? = nil,
        downloader: @escaping @Sendable (
            NemotronModelVariant,
            String?,
            (@Sendable (String) -> Void)?
        ) async throws -> URL
    ) async throws {
        let operationContext = Observability.childOperationContext()
        if emitTelemetry {
            Telemetry.send(.modelDownloadStarted(
                modelKind: .nemotronSTT,
                speechEngine: .nemotron,
                engineVariant: modelVariant.rawValue
            ))
        }

        do {
            _ = try await downloader(modelVariant, language, onProgress)
            guard emitTelemetry else { return }
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            Telemetry.send(.modelDownloadCompleted(
                durationSeconds: durationSeconds,
                modelKind: .nemotronSTT,
                speechEngine: .nemotron,
                engineVariant: modelVariant.rawValue
            ))
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .download,
                outcome: .success,
                stage: .download,
                modelKind: .nemotronSTT,
                speechEngine: .nemotron,
                engineVariant: modelVariant.rawValue,
                durationSeconds: durationSeconds,
                errorType: nil
            ))
        } catch is CancellationError {
            if emitTelemetry {
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .cancelled,
                    stage: .download,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    errorType: "CancellationError"
                ))
            }
            throw CancellationError()
        } catch {
            let errorType = TelemetryErrorClassifier.classify(error)
            if emitTelemetry {
                Telemetry.send(.modelDownloadFailed(
                    errorType: errorType,
                    errorDetail: TelemetryErrorClassifier.errorDetail(error),
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue
                ))
                Telemetry.send(.modelOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    action: .download,
                    outcome: .failure,
                    stage: .download,
                    modelKind: .nemotronSTT,
                    speechEngine: .nemotron,
                    engineVariant: modelVariant.rawValue,
                    durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                    errorType: errorType
                ))
            }
            throw error
        }
    }

    @discardableResult
    public nonisolated static func deleteNemotronModel(
        modelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        language: String? = nil
    ) -> Bool {
        let operationContext = Observability.childOperationContext()
        let removed = modelVariant.isEnglishOnly
            ? NemotronEnglishEngine.deleteModel()
            : NemotronEngine.deleteModel(modelVariant: modelVariant, language: language)
        Telemetry.send(.modelOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            action: .deleteModel,
            outcome: removed ? .success : .failure,
            stage: .delete,
            modelKind: .nemotronSTT,
            speechEngine: .nemotron,
            engineVariant: modelVariant.rawValue,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: nil
        ))
        return removed
    }

    private func unloadParakeet() async {
        let inFlightInitialization = cancelInitialization()
        inFlightInitialization?.cancel()
        _ = try? await inFlightInitialization?.value

        let interactiveManager = self.interactiveManager
        let backgroundManager = self.backgroundManager
        self.interactiveManager = nil
        self.backgroundManager = nil
        self.models = nil
        self.decoderLayerCount = nil
        await Self.cleanupManagers(
            interactiveManager: interactiveManager,
            backgroundManager: backgroundManager
        )

        // The Unified engine is the other half of "Parakeet" — tear it down here
        // too so engine swaps and shutdown release its CoreML models.
        let unifiedEngine = self.parakeetUnifiedEngine
        self.parakeetUnifiedEngine = nil
        await unifiedEngine?.unload()
    }

    private func unloadWhisper() async {
        let engine = whisperEngine
        whisperEngine = nil
        await engine?.unload()
    }

    private func unloadCohere() async {
        let engine = cohereEngine
        cohereEngine = nil
        await engine?.unload()
    }

    private func unloadNemotron() async {
        let engine = nemotronEngine
        let englishEngine = nemotronEnglishEngine
        nemotronEngine = nil
        nemotronEngineLanguage = nil
        nemotronEnglishEngine = nil
        await engine?.unload()
        await englishEngine?.unload()
    }

    private func ensureNemotronEngine(language: String?) async throws -> NemotronEngine {
        let language = SpeechEnginePreference.normalizeNemotronLanguage(language)
        if let nemotronEngine, nemotronEngineLanguage == language {
            return nemotronEngine
        }

        guard activeTranscriptionCount <= 1 else {
            throw STTError.engineBusy
        }

        let previousEngine = nemotronEngine
        let engine = NemotronEngine(modelVariant: nemotronModelVariant, language: language)
        nemotronEngine = engine
        nemotronEngineLanguage = language
        await previousEngine?.unload()
        return engine
    }

    /// Mirrors `ensureNemotronEngine` for the English-only build. There is no
    /// language (or any other) construction key, so an existing engine is
    /// always reusable.
    private func ensureNemotronEnglishEngine() throws -> NemotronEnglishEngine {
        if let nemotronEnglishEngine {
            return nemotronEnglishEngine
        }

        guard activeTranscriptionCount <= 1 else {
            throw STTError.engineBusy
        }

        let engine = NemotronEnglishEngine()
        nemotronEnglishEngine = engine
        return engine
    }

    /// Mirrors `ensureNemotronEnglishEngine` for the Parakeet Unified build.
    /// There is no construction key, so an existing engine is always reusable.
    private func ensureParakeetUnifiedEngine() throws -> ParakeetUnifiedEngine {
        if let parakeetUnifiedEngine {
            return parakeetUnifiedEngine
        }

        guard activeTranscriptionCount <= 1 else {
            throw STTError.engineBusy
        }

        let engine = ParakeetUnifiedEngine()
        parakeetUnifiedEngine = engine
        return engine
    }

    private func beginBackgroundWarmUp() -> UInt64 {
        backgroundWarmUpGeneration &+= 1
        return backgroundWarmUpGeneration
    }

    private func invalidateBackgroundWarmUp() {
        backgroundWarmUpGeneration &+= 1
        backgroundWarmUpTask?.cancel()
        backgroundWarmUpTask = nil
    }

    private func prepareBackgroundWarmUpForRetry() {
        if case .failed = backgroundWarmUpState {
            backgroundWarmUpState = .idle
        }
    }

    private func setBackgroundWarmUpState(_ state: STTWarmUpState, generation: UInt64) {
        guard generation == backgroundWarmUpGeneration else { return }
        setBackgroundWarmUpState(state)
    }

    private func setBackgroundWarmUpState(_ state: STTWarmUpState) {
        if case .working = state {
            switch backgroundWarmUpState {
            case .ready, .failed: return
            default: break
            }
        }
        backgroundWarmUpState = state
        for (_, continuation) in warmUpObservers {
            continuation.yield(state)
        }
    }

    private func clearBackgroundWarmUpTask(generation: UInt64) {
        guard generation == backgroundWarmUpGeneration else { return }
        backgroundWarmUpTask = nil
    }

    private func ensureInitialized() async throws {
        // Parakeet Unified runs on its own engine actor, not the shared TDT
        // `AsrManager` pair — preparing it satisfies "Parakeet is initialized"
        // for warm-up and readiness without ever loading the TDT models.
        if currentParakeetVariant.usesUnifiedEngine {
            try await ensureParakeetUnifiedEngine().prepare(onProgress: warmUpProgressHandler)
            return
        }

        if interactiveManager != nil, backgroundManager != nil {
            return
        }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let generation = nextInitializationGeneration()
        let version = modelVersion
        let warmUpProgressHandler = self.warmUpProgressHandler
        let task = Task {
            var interactiveManager: AsrManager?
            var backgroundManager: AsrManager?
            let progressHandler = Self.makeDownloadProgressHandler(warmUpProgressHandler)

            let downloadedModels = try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: progressHandler
            )
            do {
                // FluidAudio progress is manager-scoped, so each slot keeps its
                // own manager while the read-only model bundle stays shared.
                let loadedInteractiveManager = AsrManager(config: .default)
                let loadedBackgroundManager = AsrManager(config: .default)
                interactiveManager = loadedInteractiveManager
                backgroundManager = loadedBackgroundManager
                try await loadedInteractiveManager.loadModels(downloadedModels)
                try await loadedBackgroundManager.loadModels(downloadedModels)
                let loadedDecoderLayerCount = await loadedInteractiveManager.decoderLayerCount
                try Task.checkCancellation()
                try await self.completeInitialization(
                    generation: generation,
                    models: downloadedModels,
                    decoderLayerCount: loadedDecoderLayerCount,
                    interactiveManager: loadedInteractiveManager,
                    backgroundManager: loadedBackgroundManager
                )
                interactiveManager = nil
                backgroundManager = nil
            } catch {
                await Self.cleanupManagers(
                    interactiveManager: interactiveManager,
                    backgroundManager: backgroundManager
                )
                throw error
            }
        }

        initializationTask = task

        do {
            try await task.value
            if initializationGeneration == generation {
                initializationTask = nil
            }
        } catch {
            if initializationGeneration == generation {
                initializationTask = nil
            }
            throw error
        }
    }

    private func completeInitialization(
        generation: UInt64,
        models: AsrModels,
        decoderLayerCount: Int,
        interactiveManager: AsrManager,
        backgroundManager: AsrManager
    ) async throws {
        guard initializationGeneration == generation else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        self.models = models
        self.decoderLayerCount = decoderLayerCount
        self.interactiveManager = interactiveManager
        self.backgroundManager = backgroundManager
    }

    private func nextInitializationGeneration() -> UInt64 {
        initializationGeneration &+= 1
        return initializationGeneration
    }

    private func cancelInitialization() -> Task<Void, Error>? {
        initializationGeneration &+= 1
        let task = initializationTask
        initializationTask = nil
        return task
    }

    private nonisolated static func cleanupManagers(
        interactiveManager: AsrManager?,
        backgroundManager: AsrManager?
    ) async {
        if let interactiveManager {
            await interactiveManager.cleanup()
        }
        if let backgroundManager {
            await backgroundManager.cleanup()
        }
    }

    private nonisolated static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func manager(for lane: STTRuntimeLane) -> AsrManager? {
        switch lane {
        case .interactive:
            interactiveManager
        case .background:
            backgroundManager
        }
    }

    private func route(for job: STTJobKind) -> STTRuntimeLane {
        switch job {
        case .dictation:
            .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            .background
        }
    }

    private func telemetryModelKind(for engine: SpeechEnginePreference) -> TelemetryModelKind {
        switch engine {
        case .parakeet:
            .parakeetSTT
        case .nemotron:
            .nemotronSTT
        case .whisper:
            .whisperSTT
        case .cohere:
            .cohereSTT
        }
    }

    private func telemetryEngineVariant(for engine: SpeechEnginePreference) -> String? {
        switch engine {
        case .parakeet:
            // Surface the active Parakeet build (v2/v3/unified) so model-load
            // telemetry can measure variant adoption and impact (issues #311,
            // #398, #520). Read the source-of-truth variant directly so unified —
            // which has no `AsrModelVersion` — is attributed correctly rather than
            // collapsing to the `modelVersion` placeholder.
            currentParakeetVariant.rawValue
        case .nemotron:
            nemotronModelVariant.rawValue
        case .whisper:
            whisperModelVariant
        case .cohere:
            // Surface the active compute policy (ane/gpu) so model-load
            // telemetry can compare the two backends' load/latency posture.
            CohereTranscribeEngine.ComputePolicy.current(defaults: defaults).rawValue
        }
    }

    private func defaultLanguage(for engine: SpeechEnginePreference) -> String? {
        switch engine {
        case .parakeet:
            nil
        case .nemotron:
            SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        case .whisper:
            SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)
        case .cohere:
            SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults)
        }
    }

    private nonisolated static func mapWarmUpError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .transcriptionFailed(error.localizedDescription)
    }

    private nonisolated static func mapCommonError(_ error: Error) -> STTError? {
        if error is CancellationError {
            return nil
        }

        if let sttError = error as? STTError {
            return sttError
        }

        if let asrError = error as? ASRError {
            switch asrError {
            case .notInitialized:
                return .modelNotLoaded
            case .invalidAudioData:
                return .transcriptionFailed(asrError.localizedDescription)
            case .modelLoadFailed, .modelCompilationFailed:
                return .engineStartFailed(asrError.localizedDescription)
            case .processingFailed(let message):
                return .transcriptionFailed(message)
            case .unsupportedPlatform(let message):
                return .engineStartFailed(message)
            case .streamingConversionFailed, .fileAccessFailed:
                return .transcriptionFailed(asrError.localizedDescription)
            }
        }

        if let modelError = error as? AsrModelsError {
            return .engineStartFailed(modelError.localizedDescription)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .modelDownloadFailed
            default:
                return .engineStartFailed(urlError.localizedDescription)
            }
        }

        return nil
    }

    /// Builds a download progress handler that throttles to ≤1 update / 250 ms
    /// and suppresses repeated identical messages, translating raw
    /// `DownloadProgress` into a user-facing string. Shared by initial warm-up
    /// loading and the Parakeet variant pre-download so both report identically.
    private nonisolated static func makeDownloadProgressHandler(
        _ onProgress: (@Sendable (String) -> Void)?
    ) -> DownloadUtils.ProgressHandler? {
        guard let onProgress else { return nil }
        let clock = ContinuousClock()
        let lastProgressUpdate = OSAllocatedUnfairLock(initialState: clock.now - .seconds(1))
        let lastProgressMessage = OSAllocatedUnfairLock(initialState: "")
        return { progress in
            guard let message = Self.warmUpProgressMessage(from: progress) else { return }
            let now = clock.now
            let shouldEmit = lastProgressUpdate.withLock { lastUpdate in
                guard lastUpdate.duration(to: now) >= .milliseconds(250) else { return false }
                lastUpdate = now
                return true
            }
            guard shouldEmit else { return }

            let isNewMessage = lastProgressMessage.withLock { lastMessage in
                guard lastMessage != message else { return false }
                lastMessage = message
                return true
            }
            guard isNewMessage else { return }

            onProgress(message)
        }
    }

    private nonisolated static func warmUpProgressMessage(from progress: DownloadUtils.DownloadProgress) -> String? {
        switch progress.phase {
        case .listing:
            return "Preparing speech model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading speech model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling speech model..."
        }
    }
}

private enum STTRuntimeLane: Sendable {
    case interactive
    case background
}
