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
        state = .starting

        let mode = sourceMode
        Task { [weak self] in
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
                guard let self, self.generation == current else {
                    await session.stop()
                    return
                }
                self.state = .running
            } catch {
                guard let self, self.generation == current else { return }
                self.session = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        generation += 1
        let stopping = session
        session = nil
        state = .idle
        Task { await stopping?.stop() }
    }

    public func clear() {
        lines = []
        liveTranslation.reset()
    }

    /// Transcript as plain text; with translations when translation is on.
    public var transcriptText: String {
        lines.map { line in
            guard let translation = liveTranslation.translation(forLineID: line.id) else { return line.text }
            return "\(line.text)\n\(translation)"
        }.joined(separator: "\n\n")
    }

    private func apply(_ newLines: [LiveCaptionLine], generation: Int) {
        guard generation == self.generation else { return }
        lines = newLines
        liveTranslation.update(lines: newLines.map { .init(id: $0.id, text: $0.text) })
    }

    private func note(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        notice = message
    }
}
