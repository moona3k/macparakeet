import Foundation
import MacParakeetCore
import OSLog

/// Owns saved translations and in-flight translation jobs for the transcript
/// detail view. Jobs are keyed by transcript so one keeps running (and saves)
/// if the user opens a different transcript before it finishes.
@MainActor
@Observable
public final class TranscriptTranslationViewModel {
    public struct Job: Equatable, Sendable {
        public var segments: [TranslatedSegment] = []
        public var totalSegments: Int
        public var errorMessage: String?

        public var isRunning: Bool { errorMessage == nil }

        public var fractionCompleted: Double {
            guard totalSegments > 0 else { return 0 }
            return min(1, Double(segments.count) / Double(totalSegments))
        }
    }

    private struct JobKey: Hashable {
        let transcriptionId: UUID
        let language: TranslationLanguage
    }

    /// Saved translations for the transcript currently on screen.
    public private(set) var translations: [TranscriptTranslation] = []
    public var onTranslationsChanged: ((UUID, Bool) -> Void)?

    private var jobs: [JobKey: Job] = [:]
    private var tasks: [JobKey: Task<Void, Never>] = [:]
    private var translator: TranscriptTranslating?
    private var repository: TranscriptTranslationRepositoryProtocol?
    private var modelNameProvider: (@MainActor () -> String?)?
    private var currentTranscription: Transcription?
    private var currentSourceHash: String?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptTranslationViewModel")

    public init() {}

    public var canTranslate: Bool {
        translator != nil
    }

    public func configure(
        translator: TranscriptTranslating?,
        repository: TranscriptTranslationRepositoryProtocol?,
        modelNameProvider: (@MainActor () -> String?)? = nil
    ) {
        self.translator = translator
        self.repository = repository
        self.modelNameProvider = modelNameProvider
    }

    public func updateTranslator(_ translator: TranscriptTranslating?) {
        self.translator = translator
    }

    // MARK: - Loading

    public func load(transcription: Transcription) {
        currentTranscription = transcription
        currentSourceHash = TranscriptTranslationSource.hash(
            of: TranscriptTranslationSource.segments(for: transcription)
        )
        reloadTranslations()
    }

    private func reloadTranslations() {
        guard let transcriptionId = currentTranscription?.id else {
            translations = []
            return
        }
        do {
            translations = try repository?.fetchAll(transcriptionId: transcriptionId) ?? []
        } catch {
            translations = []
            logger.error("translation_load_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
        onTranslationsChanged?(transcriptionId, hasTranslationTabs)
    }

    // MARK: - Queries

    /// Languages that have a tab: saved translations first, then jobs.
    public var tabLanguages: [TranslationLanguage] {
        var languages = translations.compactMap(\.language)
        for language in TranslationLanguage.allCases
        where !languages.contains(language) && job(for: language) != nil {
            languages.append(language)
        }
        return languages
    }

    public var hasTranslationTabs: Bool {
        !tabLanguages.isEmpty
    }

    public func translation(for language: TranslationLanguage) -> TranscriptTranslation? {
        translations.first { $0.languageCode == language.rawValue }
    }

    public func job(for language: TranslationLanguage) -> Job? {
        guard let transcriptionId = currentTranscription?.id else { return nil }
        return jobs[JobKey(transcriptionId: transcriptionId, language: language)]
    }

    public func isTranslating(_ language: TranslationLanguage) -> Bool {
        job(for: language)?.isRunning ?? false
    }

    /// The transcript text changed (edit or retranscription) after this
    /// translation was made.
    public func isStale(_ translation: TranscriptTranslation) -> Bool {
        guard let currentSourceHash else { return false }
        return translation.sourceHash != currentSourceHash
    }

    // MARK: - Actions

    public func translate(to language: TranslationLanguage) {
        guard let transcription = currentTranscription, let translator else { return }
        let key = JobKey(transcriptionId: transcription.id, language: language)
        guard tasks[key] == nil else { return }

        let source = TranscriptTranslationSource.segments(for: transcription)
        guard !source.isEmpty else {
            jobs[key] = Job(totalSegments: 0, errorMessage: "There is no transcript text to translate.")
            return
        }
        let sourceHash = TranscriptTranslationSource.hash(of: source)

        jobs[key] = Job(totalSegments: source.count)
        notifyChanged(transcription.id)

        tasks[key] = Task { [weak self] in
            do {
                let segments = try await translator.translate(source, to: language) { [weak self] batch in
                    await self?.appendProgress(batch, for: key)
                }
                self?.finish(key, segments: segments, sourceHash: sourceHash)
            } catch is CancellationError {
                self?.clearJob(key)
            } catch {
                self?.fail(key, error: error)
            }
        }
    }

    /// Stops a running job, or dismisses a failed one.
    public func cancel(_ language: TranslationLanguage) {
        guard let transcriptionId = currentTranscription?.id else { return }
        let key = JobKey(transcriptionId: transcriptionId, language: language)
        tasks[key]?.cancel()
        clearJob(key)
    }

    public func delete(_ language: TranslationLanguage) {
        cancel(language)
        guard let translation = translation(for: language) else { return }
        do {
            _ = try repository?.delete(id: translation.id)
        } catch {
            logger.error("translation_delete_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
        reloadTranslations()
    }

    // MARK: - Job bookkeeping

    private func appendProgress(_ batch: [TranslatedSegment], for key: JobKey) {
        jobs[key]?.segments.append(contentsOf: batch)
    }

    private func finish(_ key: JobKey, segments: [TranslatedSegment], sourceHash: String) {
        let translation = TranscriptTranslation(
            transcriptionId: key.transcriptionId,
            languageCode: key.language.rawValue,
            segments: segments,
            sourceHash: sourceHash,
            modelName: modelNameProvider?()
        )
        do {
            try repository?.save(translation)
            clearJob(key)
        } catch {
            fail(key, error: error)
        }
    }

    private func fail(_ key: JobKey, error: Error) {
        tasks[key] = nil
        jobs[key]?.errorMessage = error.localizedDescription
        // LLM errors can echo transcript content, so only the type is logged.
        logger.error("translation_failed error=\(String(describing: type(of: error)), privacy: .public)")
    }

    private func clearJob(_ key: JobKey) {
        tasks[key] = nil
        jobs[key] = nil
        if key.transcriptionId == currentTranscription?.id {
            reloadTranslations()
        }
    }

    private func notifyChanged(_ transcriptionId: UUID) {
        guard transcriptionId == currentTranscription?.id else { return }
        onTranslationsChanged?(transcriptionId, hasTranslationTabs)
    }
}
