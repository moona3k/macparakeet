import Foundation
import MacParakeetCore

/// Translates the live dictation transcript for the floating overlay.
///
/// One request at a time, started after the text has been quiet briefly, and
/// only the recent tail is sent so each request stays small. The text typed
/// into the target app does not come from here; the dictation service
/// translates the finished transcript separately.
@MainActor
final class DictationLiveTranslator {
    nonisolated static let debounce: Duration = .milliseconds(450)
    /// Characters of the live transcript sent per request.
    nonisolated static let tailCharacters = 320

    var translatorProvider: (() -> TranscriptTranslating?)?
    var onTranslation: ((String, TranslationLanguage) -> Void)?
    var onClearTranslation: (() -> Void)?
    var settingsProvider: () -> DictationTranslationSettings? = { DictationTranslationSettings.current() }

    private var latest = ""
    private var observedLanguage: TranslationLanguage?
    private var lastChangedAt: ContinuousClock.Instant
    private var lastTranslatedSource = ""
    private var lastTranslatedLanguage: TranslationLanguage?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let debounceDelay: Duration
    private let now: () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async throws -> Void

    init(
        debounce: Duration = DictationLiveTranslator.debounce,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        debounceDelay = debounce
        self.now = now
        self.sleep = sleep
        lastChangedAt = now()
    }

    /// Sampled by the recording loop even when the transcript is unchanged,
    /// so enabling, changing, or disabling translation takes effect promptly.
    func update(_ text: String) {
        let language = settingsProvider()?.language
        let textChanged = text != latest
        let languageChanged = language != observedLanguage
        guard textChanged || languageChanged else { return }
        if textChanged {
            latest = text
            lastChangedAt = now()
        }
        if languageChanged {
            observedLanguage = language
            generation += 1
            task?.cancel()
            task = nil
            lastTranslatedSource = ""
            lastTranslatedLanguage = nil
            onClearTranslation?()
        }
        guard task == nil, language != nil else { return }
        let current = generation
        task = Task { [weak self] in
            await self?.run(generation: current)
        }
    }

    /// Call when a dictation starts or ends.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        latest = ""
        observedLanguage = nil
        onClearTranslation?()
        lastTranslatedSource = ""
        lastTranslatedLanguage = nil
    }

    private func run(generation current: Int) async {
        defer { if generation == current { task = nil } }
        while !Task.isCancelled, generation == current {
            while now() - lastChangedAt < debounceDelay {
                do {
                    try await sleep(debounceDelay - (now() - lastChangedAt))
                } catch { return }
                guard !Task.isCancelled, generation == current else { return }
            }
            guard !Task.isCancelled, generation == current,
                let settings = settingsProvider(),
                let translator = translatorProvider?()
            else { return }

            observedLanguage = settings.language
            let source = Self.tail(of: latest)
            guard !source.isEmpty, source != lastTranslatedSource || settings.language != lastTranslatedLanguage
            else { return }
            do {
                let result = try await translator.translate(
                    [TranslationSourceSegment(text: source)], to: settings.language)
                guard !Task.isCancelled, generation == current else { return }
                lastTranslatedSource = source
                lastTranslatedLanguage = settings.language
                if source == Self.tail(of: latest), settingsProvider()?.language == settings.language,
                    let text = result.first?.text
                {
                    onTranslation?(text, settings.language)
                }
            } catch {
                // The live line is best-effort; the final translation is separate.
                return
            }
        }
    }

    /// The recent part of the transcript, cut at a word boundary.
    static func tail(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > tailCharacters else { return trimmed }
        let suffix = trimmed.suffix(tailCharacters)
        guard let space = suffix.firstIndex(where: \.isWhitespace) else { return String(suffix) }
        return String(suffix[suffix.index(after: space)...])
    }
}
