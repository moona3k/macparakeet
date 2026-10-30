import Foundation
import MacParakeetCore
import OSLog

/// Translates the live meeting transcript line by line while recording.
///
/// A line is translated once it has settled: every line except the newest is
/// final, and the newest counts as settled after its text stops changing for
/// `settleDelay`. Translations are in-memory only; the saved meeting can be
/// translated durably from its transcript afterwards.
@MainActor
@Observable
public final class LiveTranslationViewModel {
    public struct Line: Equatable, Sendable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    private struct Entry {
        let source: String
        let text: String
    }

    static let maxLinesPerRequest = 8
    static let maxConsecutiveFailures = 3

    /// Target language; `nil` turns live translation off.
    public var language: TranslationLanguage? {
        didSet {
            guard language != oldValue else { return }
            defaults.set(
                language?.rawValue, forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationLanguageKey)
            restart()
        }
    }

    /// What the live transcript shows while translation is on.
    public enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
        /// The spoken text with its translation underneath.
        case originalAndTranslation
        /// Only the translation; a line shows its original text until its
        /// translation arrives.
        case translationOnly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .originalAndTranslation: return "Original and Translation"
            case .translationOnly: return "Translation Only"
            }
        }
    }

    /// How long the newest line must stop changing before it is translated.
    /// Shorter waits show translations sooner but send more AI requests,
    /// because a line that keeps growing is translated again.
    public enum Speed: String, CaseIterable, Identifiable, Sendable {
        case balanced
        case fast

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .balanced: return "Balanced"
            case .fast: return "Faster (more AI requests)"
            }
        }

        var settleDelay: Duration {
            switch self {
            case .balanced: return .milliseconds(1500)
            case .fast: return .milliseconds(400)
            }
        }
    }

    public var displayMode: DisplayMode {
        didSet {
            defaults.set(
                displayMode.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationDisplayModeKey)
        }
    }

    public var speed: Speed {
        didSet {
            guard speed != oldValue else { return }
            defaults.set(speed.rawValue, forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationSpeedKey)
            // A waiting worker sleeps on the old delay; start one on the new.
            if isWaitingForSettle { cancelWorker() }
            startWorkerIfNeeded()
        }
    }

    public private(set) var errorMessage: String?
    public private(set) var isTranslating = false

    private var entries: [String: Entry] = [:]
    private var lines: [Line] = []
    private var lastLineChangedAt: ContinuousClock.Instant
    private var consecutiveFailures = 0
    private var worker: Task<Void, Never>?
    private var workerGeneration = 0
    private var isWaitingForSettle = false
    private var translator: TranscriptTranslating?
    private var translationRoute: LLMModelSelectionRoute?
    private var hasTranslationRoute = false
    private let defaults: UserDefaults
    /// Test override for the settle wait; `nil` uses `speed`.
    private let settleDelayOverride: Duration?
    private var settleDelay: Duration { settleDelayOverride ?? speed.settleDelay }
    private let retryDelay: Duration
    private let now: () -> ContinuousClock.Instant
    private let sleepForSettle: @MainActor (Duration) async throws -> Void
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "LiveTranslationViewModel")

    public init(
        defaults: UserDefaults = .standard,
        settleDelay: Duration? = nil,
        retryDelay: Duration = .seconds(5),
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleepForSettle: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.defaults = defaults
        self.settleDelayOverride = settleDelay
        self.displayMode =
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationDisplayModeKey)
            .flatMap(DisplayMode.init(rawValue:)) ?? .originalAndTranslation
        self.speed =
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationSpeedKey)
            .flatMap(Speed.init(rawValue:)) ?? .balanced
        self.retryDelay = retryDelay
        self.now = now
        self.sleepForSettle = sleepForSettle
        self.lastLineChangedAt = now()
        self.language = TranslationLanguage.resolve(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.liveMeetingTranslationLanguageKey)
        )
    }

    public var isAvailable: Bool {
        translator != nil
    }

    public var isActive: Bool {
        language != nil && translator != nil
    }

    public func updateTranslator(_ translator: TranscriptTranslating?) {
        hasTranslationRoute = false
        self.translator = translator
        restart()
    }

    /// Repeated window presentation with the same route keeps settled lines
    /// and in-flight work. Route metadata deliberately excludes credentials.
    public func updateTranslator(_ translator: TranscriptTranslating?, route: LLMModelSelectionRoute?) {
        guard !hasTranslationRoute || translationRoute != route || (self.translator == nil) != (translator == nil)
        else { return }
        hasTranslationRoute = true
        translationRoute = route
        self.translator = translator
        restart()
    }

    /// Feed the current live transcript. Cheap to call on every update.
    public func update(lines newLines: [Line]) {
        if newLines.last != lines.last {
            lastLineChangedAt = now()
        }
        lines = newLines
        if newLines.isEmpty {
            entries = [:]
        }
        startWorkerIfNeeded()
    }

    /// Latest translation for a line. While a growing line is waiting to be
    /// re-translated, its previous translation is returned so text does not
    /// flicker away.
    public func translation(forLineID id: String) -> String? {
        guard language != nil else { return nil }
        return entries[id]?.text
    }

    /// Try again after repeated provider failures paused translation.
    public func retry() {
        restart()
    }

    /// Clears per-meeting state. The chosen language is kept.
    public func reset() {
        cancelWorker()
        lines = []
        entries = [:]
        errorMessage = nil
        consecutiveFailures = 0
    }

    // MARK: - Worker

    private func restart() {
        cancelWorker()
        entries = [:]
        errorMessage = nil
        consecutiveFailures = 0
        startWorkerIfNeeded()
    }

    private func cancelWorker() {
        workerGeneration &+= 1
        worker?.cancel()
        worker = nil
        isWaitingForSettle = false
        isTranslating = false
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, isActive, consecutiveFailures < Self.maxConsecutiveFailures else { return }
        guard !pendingLines().isEmpty || lastLineNeedsTranslation else { return }
        workerGeneration &+= 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            await self?.runWorker(generation: generation)
        }
    }

    private func runWorker(generation: Int) async {
        defer {
            if workerGeneration == generation {
                isTranslating = false
                isWaitingForSettle = false
                worker = nil
            }
        }

        while !Task.isCancelled, workerGeneration == generation, let language, let translator {
            let batch = pendingLines()
            if batch.isEmpty {
                // Only the newest, still-changing line is left: wait for it to
                // settle rather than translating every partial update.
                guard lastLineNeedsTranslation else { return }
                isWaitingForSettle = true
                do {
                    try await sleepForSettle(remainingSettleTime())
                } catch { return }
                guard workerGeneration == generation else { return }
                isWaitingForSettle = false
                continue
            }

            isTranslating = true
            do {
                let translated = try await translator.translate(
                    batch.map { TranslationSourceSegment(text: $0.text) },
                    to: language
                )
                guard !Task.isCancelled, workerGeneration == generation, self.language == language else { return }
                for (line, result) in zip(batch, translated) {
                    entries[line.id] = Entry(source: line.text, text: result.text)
                }
                errorMessage = nil
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, workerGeneration == generation else { return }
                consecutiveFailures += 1
                errorMessage = error.localizedDescription
                // LLM errors can echo transcript content, so only the type is logged.
                logger.error("live_translation_failed error=\(String(describing: type(of: error)), privacy: .public)")
                guard consecutiveFailures < Self.maxConsecutiveFailures else { return }
                try? await Task.sleep(for: retryDelay)
            }
            guard workerGeneration == generation else { return }
            isTranslating = false
        }
    }

    /// Settled lines that are untranslated or whose text changed since they
    /// were translated. The most recent ones go first so the live edge stays
    /// current; older history fills in afterwards.
    private func pendingLines() -> [Line] {
        let lastIsSettled = isLastLineSettled
        let pending = lines.enumerated().filter { index, line in
            guard index < lines.count - 1 || lastIsSettled else { return false }
            return needsTranslation(line)
        }.map(\.element)
        return Array(pending.suffix(Self.maxLinesPerRequest))
    }

    private func needsTranslation(_ line: Line) -> Bool {
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return entries[line.id]?.source != line.text
    }

    private var lastLineNeedsTranslation: Bool {
        lines.last.map(needsTranslation) ?? false
    }

    private var isLastLineSettled: Bool {
        now() - lastLineChangedAt >= settleDelay
    }

    private func remainingSettleTime() -> Duration {
        let remaining = settleDelay - (now() - lastLineChangedAt)
        return max(remaining, .milliseconds(50))
    }
}
