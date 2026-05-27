import AppKit
import Foundation
import MacParakeetCore
import OSLog

/// Wires the Opt+Ctrl+1 hotkey to the `TransformExecutor` pipeline and the
/// floating spike progress panel.
///
/// Spike scope only — see `AppFeatures.transformsSpikeEnabled` and
/// `docs/research/transforms-design-2026-05.md`. The coordinator is created
/// even when the feature flag is off, but `start()` is a no-op in that case
/// so the binary surface stays unchanged.
@MainActor
final class TransformsSpikeCoordinator {
    /// Hardcoded chord for the spike: Opt+Ctrl+1. Ctrl is intentional during
    /// development to avoid colliding with the long-tail of "Opt+1 produces an
    /// alt-character" combinations during smoke-testing. Phase 2 binds via
    /// the per-Transform recorder UI.
    private static let spikeHotkey: HotkeyTrigger = .chord(
        modifiers: ["control", "option"],
        keyCode: 18  // ANSI '1' (kVK_ANSI_1)
    )

    private let llmServiceProvider: () -> LLMServiceProtocol?
    private let logger = Logger(subsystem: "com.macparakeet", category: "TransformsSpikeCoordinator")
    private var shortcutManager: GlobalShortcutManager?
    private var panelController: TransformSpikeProgressPanelController?
    private var executor: TransformExecutor?
    private var inFlightTask: Task<Void, Never>?
    /// Per-run identity for the cancellation guard. When the user re-triggers
    /// the hotkey mid-flight we cancel the old `inFlightTask` and start a
    /// new one — but the old task's terminal `do/catch` may still run after
    /// cancellation lands, and without this guard it would close the *new*
    /// run's panel and nil out the new `inFlightTask`. Every UI / state
    /// mutation in the task body is gated on `activeRunID == myRunID`.
    private var activeRunID: UUID?

    init(llmServiceProvider: @escaping () -> LLMServiceProtocol?) {
        self.llmServiceProvider = llmServiceProvider
    }

    /// Register the spike hotkey if the feature flag is enabled. Idempotent.
    func start() {
        guard AppFeatures.transformsSpikeEnabled else { return }
        guard shortcutManager == nil else { return }

        panelController = TransformSpikeProgressPanelController()
        let manager = GlobalShortcutManager(trigger: Self.spikeHotkey)
        manager.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.handleHotkey()
            }
        }
        if manager.start() {
            shortcutManager = manager
            logger.notice("transforms-spike: registered hotkey Opt+Ctrl+1")
        } else {
            logger.error("transforms-spike: failed to register Opt+Ctrl+1 event tap")
        }
    }

    /// Tear down event tap + in-flight work. Called on app termination.
    func stop() {
        inFlightTask?.cancel()
        inFlightTask = nil
        shortcutManager?.stop()
        shortcutManager = nil
        panelController?.close()
        panelController = nil
    }

    // MARK: - Hotkey handler

    private func handleHotkey() {
        guard AppFeatures.transformsSpikeEnabled else { return }

        guard let llmService = llmServiceProvider() else {
            panelController?.fail(
                message: "Turn on AI in Settings"
            )
            logger.notice("transforms-spike: no LLM provider configured, aborting")
            return
        }

        // Cancel any in-flight transform if the user re-triggers the hotkey
        // before the previous one finishes. Phase 2's design doc calls for
        // cancel-then-restart on re-trigger.
        if let inFlightTask {
            inFlightTask.cancel()
            self.inFlightTask = nil
        }

        let executor = TransformExecutor(llmService: llmService)
        self.executor = executor

        let runID = UUID()
        activeRunID = runID

        // Pill starts as an icon-only rose; if the run lasts past the panel
        // controller's patience threshold the default "Still polishing…"
        // label fades in.
        panelController?.show()

        inFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only clear `inFlightTask` if this run is still the active
                // one. Otherwise the new run's task pointer (set by the
                // outer code that started it) would be nil'd out by our
                // late completion.
                if self.activeRunID == runID {
                    self.inFlightTask = nil
                }
            }
            do {
                _ = try await executor.run(
                    prompt: TransformSpikePrompts.polish,
                    onProgress: { [weak self] progress in
                        // Progress callback fires on the executor's actor
                        // context. Hop to main only when the UI cares —
                        // the spike's UI only reacts to terminal `.failed`
                        // events. Spawning a Task per LLM-streaming token
                        // would be wasteful (and the bot reviewers flagged
                        // it).
                        if case .failed = progress {
                            Task { @MainActor [weak self, runID] in
                                guard self?.activeRunID == runID else { return }
                                self?.handleProgress(progress)
                            }
                        }
                    }
                )
                guard self.activeRunID == runID else { return }
                self.panelController?.done(message: "Done")
            } catch let error as TransformExecutorError {
                guard self.activeRunID == runID else { return }
                switch error {
                case .cancelled:
                    self.panelController?.close()
                default:
                    self.panelController?.fail(message: error.localizedDescription)
                }
            } catch {
                guard self.activeRunID == runID else { return }
                self.panelController?.fail(message: error.localizedDescription)
            }
        }
    }

    private func handleProgress(_ progress: TransformProgress) {
        // The spike UI is intentionally minimal — we surface the same
        // "Polishing…" label across capturing/llm/pasting and let the final
        // .done / .failed states swap the visual.
        switch progress {
        case .failed(let message):
            panelController?.fail(message: message)
        default:
            break
        }
    }
}
