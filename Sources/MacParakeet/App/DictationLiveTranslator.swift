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
    static let debounce: Duration = .milliseconds(450)
    /// Characters of the live transcript sent per request.
    static let tailCharacters = 320

    var translatorProvider: (() -> TranscriptTranslating?)?
    var onTranslation: ((String, TranslationLanguage) -> Void)?

    private var latest = ""
    private var lastTranslatedSource = ""
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Call whenever the live transcript changes.
    func update(_ text: String) {
        latest = text
        guard task == nil, DictationTranslationSettings.current() != nil else { return }
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
        lastTranslatedSource = ""
    }

    private func run(generation current: Int) async {
        defer { if generation == current { task = nil } }
        while !Task.isCancelled, generation == current {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, generation == current,
                let settings = DictationTranslationSettings.current(),
                let translator = translatorProvider?()
            else { return }

            let source = Self.tail(of: latest)
            guard !source.isEmpty, source != lastTranslatedSource else { return }
            do {
                let result = try await translator.translate(
                    [TranslationSourceSegment(text: source)], to: settings.language)
                guard !Task.isCancelled, generation == current else { return }
                lastTranslatedSource = source
                if let text = result.first?.text {
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
