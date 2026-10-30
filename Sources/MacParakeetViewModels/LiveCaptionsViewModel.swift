import Foundation
import MacParakeetCore

/// Drives the Live Captions window: start/stop a realtime caption session,
/// hold its lines, and translate them as they settle.
@MainActor
@Observable
public final class LiveCaptionsViewModel {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case failed(String)
    }

    public typealias SessionFactory = @MainActor () -> LiveCaptionSession?

    public private(set) var state: State = .idle
    public private(set) var lines: [LiveCaptionLine] = []
    /// A problem that arose while running (for example a lost connection).
    public private(set) var notice: String?
    public let liveTranslation: LiveTranslationViewModel

    public var sourceMode: MeetingAudioSourceMode {
        didSet {
            defaults.set(sourceMode.rawValue, forKey: UserDefaultsAppRuntimePreferences.liveCaptionsSourceModeKey)
        }
    }

    private let sessionFactory: SessionFactory
    private let defaults: UserDefaults
    private var session: LiveCaptionSession?
    /// Guards against a late callback from a session that was already stopped.
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var acceptingUpdates = true
    private var clearGeneration = 0

    public init(
        sessionFactory: @escaping SessionFactory,
        liveTranslation: LiveTranslationViewModel? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sessionFactory = sessionFactory
        self.liveTranslation = liveTranslation ?? LiveTranslationViewModel()
        self.defaults = defaults
        self.sourceMode =
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.liveCaptionsSourceModeKey)
            .flatMap(MeetingAudioSourceMode.init(rawValue:)) ?? .systemOnly
    }

    public var isRunning: Bool { state == .running }
    public var isBusy: Bool { state == .starting }

    public func toggle() {
        if state == .running || state == .starting {
            stop()
        } else {
            start()
        }
    }

    public func start() {
        guard state != .running, state != .starting else { return }
        guard let session = sessionFactory() else {
            state = .failed("Live captions are not available right now.")
            return
        }
        generation += 1
        let current = generation
        self.session = session
        lines = []
        notice = nil
        liveTranslation.reset()
        acceptingUpdates = true
        state = .starting

        let mode = sourceMode
        let pendingStop = stopTask
        startTask = Task { [weak self] in
            await pendingStop?.value
            guard !Task.isCancelled, self?.generation == current else { return }
            do {
                try await session.start(
                    sourceMode: mode,
                    onUpdate: { lines in
                        Task { @MainActor in self?.apply(lines, generation: current) }
                    },
                    onFailure: { message in
                        Task { @MainActor in self?.note(message, generation: current) }
                    }
                )
                guard let self, self.generation == current else { return }
                self.state = .running
                self.startTask = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.session = nil
                self.startTask = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        let stopping = session
        session = nil
        state = .idle
        acceptingUpdates = true
        let pendingStop = stopTask
        stopTask = Task {
            await pendingStop?.value
            await stopping?.stop()
        }
    }

    public func clear() {
        lines = []
        liveTranslation.reset()
        guard let session else { return }
        acceptingUpdates = false
        clearGeneration += 1
        let clearing = clearGeneration
        let current = generation
        Task { [weak self] in
            let remaining = await session.clearHistory()
            guard let self, self.generation == current, self.clearGeneration == clearing else { return }
            self.acceptingUpdates = true
            self.apply(remaining, generation: current)
        }
    }

    /// Transcript as plain text; with translations when translation is on.
    public var transcriptText: String {
        lines.map { line in
            let source = line.source == .microphone ? "Microphone" : "Computer audio"
            let original = "\(source): \(line.text)"
            guard let translation = liveTranslation.translation(forLineID: line.id) else { return original }
            return "\(original)\n\(translation)"
        }.joined(separator: "\n\n")
    }

    private func apply(_ newLines: [LiveCaptionLine], generation: Int) {
        guard generation == self.generation, acceptingUpdates else { return }
        lines = newLines
        liveTranslation.update(lines: newLines.map { .init(id: $0.id, text: $0.text) })
    }

    private func note(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        stop()
        notice = message
        state = .failed(message)
    }
}
