import AppKit
import Foundation
import MacParakeetCore
import OSLog

/// Wires the productized Transforms feature to the app surface (ADR-022):
///
/// - reads `.transform` prompts from `PromptRepository`
/// - installs them with the process-wide `TransformsHotkeyRegistry`
/// - on hotkey trigger, drives `TransformExecutor` with that Transform's
///   prompt body and surfaces progress in the brand-finished floating
///   pill (`TransformSpikeProgressPanelController`, retained from the
///   spike)
/// - pastes the result into the currently focused target instead of forcing
///   replacement back into the captured source surface, so read-only
///   selections (browser text, terminal scrollback, PDFs) can still feed a
///   paste-ready result into the user's active input
/// - manages cancel-then-restart on re-trigger, run-ID stale-event
///   guarding, and per-Transform telemetry
///
/// Replaces `TransformsSpikeCoordinator` (which bound a single hardcoded
/// Opt+Ctrl+1 to a baked-in Polish prompt). The coordinator is gated by
/// `AppFeatures.transformsEnabled`, which is enabled on `main` after the
/// website telemetry allowlist deploy landed.
@MainActor
final class TransformsCoordinator {
    private let llmServiceProvider: () -> LLMServiceProtocol?
    private let promptRepository: PromptRepositoryProtocol
    private let historyRepository: TransformHistoryRepositoryProtocol?
    private let reservedHotkeysProvider: () -> [TransformShortcutReservedHotkey]
    private let onLLMProviderRequired: () -> Void
    private let logger = Logger(subsystem: "com.macparakeet", category: "TransformsCoordinator")

    private var registry: TransformsHotkeyRegistry?
    private var panelController: TransformSpikeProgressPanelController?
    private var executor: TransformExecutor?
    private var inFlightTask: Task<Void, Never>?
    private var bindingsChangedObserver: NSObjectProtocol?

    /// Per-run identity for stale-event guarding. See the same pattern in
    /// the spike coordinator: if the user re-triggers a hotkey mid-flight,
    /// the previous task may emit a terminal event after cancellation
    /// lands. We gate every UI/state mutation in the task body on
    /// `activeRunID == myRunID`.
    private var activeRunID: UUID?

    /// Cached snapshot of bound `.transform` prompts, keyed by ID. Used to
    /// resolve a `KeyboardShortcut`-triggered ID back to its prompt body
    /// without re-hitting the DB on every keystroke.
    private var promptIndex: [UUID: Prompt] = [:]
    private var activeBindingIDs: Set<UUID> = []

    init(
        llmServiceProvider: @escaping () -> LLMServiceProtocol?,
        promptRepository: PromptRepositoryProtocol,
        historyRepository: TransformHistoryRepositoryProtocol? = nil,
        reservedHotkeysProvider: @escaping () -> [TransformShortcutReservedHotkey] = { [] },
        onLLMProviderRequired: @escaping () -> Void = {}
    ) {
        self.llmServiceProvider = llmServiceProvider
        self.promptRepository = promptRepository
        self.historyRepository = historyRepository
        self.reservedHotkeysProvider = reservedHotkeysProvider
        self.onLLMProviderRequired = onLLMProviderRequired
    }

    // MARK: - Lifecycle

    /// Install the event tap and load the initial set of bindings from the
    /// repository. Idempotent. No-op when the feature flag is off.
    func start() {
        guard AppFeatures.transformsEnabled else { return }
        guard registry == nil else { return }

        panelController = TransformSpikeProgressPanelController()
        let registry = TransformsHotkeyRegistry()
        registry.onTrigger = { [weak self] promptID in
            // The event tap callback runs on the runloop thread. Hop to main
            // for everything that touches state / UI.
            Task { @MainActor in
                self?.handleTrigger(promptID: promptID)
            }
        }
        if registry.start() {
            self.registry = registry
            reloadBindings()
            // Save/delete/reset on the Transforms tab posts this notification.
            bindingsChangedObserver = NotificationCenter.default.addObserver(
                forName: .transformsBindingsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reloadBindings()
                }
            }
            logger.notice("transforms: registry started with \(self.activeBindingIDs.count, privacy: .public) bindings")
        } else {
            logger.error("transforms: failed to install registry event tap")
        }
    }

    /// Tear down event tap + in-flight work. Called from `applicationWillTerminate`.
    func stop() {
        inFlightTask?.cancel()
        inFlightTask = nil
        registry?.stop()
        registry = nil
        panelController?.close()
        panelController = nil
        if let observer = bindingsChangedObserver {
            NotificationCenter.default.removeObserver(observer)
            bindingsChangedObserver = nil
        }
    }

    func suspendHotkeys() {
        registry?.stop()
    }

    func resumeHotkeys() {
        guard AppFeatures.transformsEnabled else { return }
        if let registry {
            if registry.start() {
                reloadBindings()
            }
        } else {
            start()
        }
    }

    /// Re-read `.transform` prompts from the repository and rebuild the
    /// registry's dispatch table. Call after any save/delete/import.
    func reloadBindings() {
        guard let registry else { return }
        let prompts: [Prompt]
        do {
            prompts = try promptRepository.fetchVisible(category: .transform)
        } catch {
            logger.error("transforms: fetchVisible failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        promptIndex = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })

        let reservedHotkeys = reservedHotkeysProvider().filter { !$0.trigger.isDisabled }
        var bindings: [UUID: KeyboardShortcut] = [:]
        for prompt in prompts {
            if let shortcut = prompt.shortcut {
                if let conflict = reservedHotkeys.first(where: { shortcut.hotkeyTrigger.overlaps(with: $0.trigger) }) {
                    logger.notice(
                        "transforms: skipping binding for \(prompt.name, privacy: .public); conflicts with \(conflict.name, privacy: .public) \(conflict.trigger.formattedLabel, privacy: .public)"
                    )
                    continue
                }
                bindings[prompt.id] = shortcut
            }
        }
        activeBindingIDs = Set(bindings.keys)
        registry.replaceBindings(bindings)
    }

    /// True when at least one Transform has a hotkey bound. Used by the
    /// Transforms tab to surface a calmer "no bindings yet" hint state.
    var hasActiveBindings: Bool {
        !activeBindingIDs.isEmpty
    }

    // MARK: - Trigger handling

    private func handleTrigger(promptID: UUID) {
        guard AppFeatures.transformsEnabled else { return }
        guard let prompt = promptIndex[promptID] else {
            logger.notice("transforms: trigger for unknown promptID, reloading bindings")
            reloadBindings()
            return
        }

        let telemetryName = TelemetryTransformName(
            builtInName: prompt.name,
            isBuiltIn: prompt.isBuiltIn
        )
        let operationContext = ObservabilityOperationContext()

        guard let llmService = llmServiceProvider() else {
            handleMissingLLMProvider(
                prompt: prompt,
                telemetryName: telemetryName,
                operationContext: operationContext
            )
            return
        }

        // Cancel any in-flight Transform if the user re-triggers a hotkey
        // before the previous one finishes. ADR-022 §4 / spike pattern.
        if let inFlightTask {
            inFlightTask.cancel()
            self.inFlightTask = nil
        }

        let executor = TransformExecutor(llmService: llmService)
        self.executor = executor

        let runID = UUID()
        activeRunID = runID

        panelController?.show()

        let promptBody = prompt.content
        let runningTransformName = prompt.name

        inFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeRunID == runID {
                    self.inFlightTask = nil
                }
            }
            do {
                let result = try await Observability.withOperationContext(operationContext) {
                    try await executor.run(
                        prompt: promptBody,
                        replacementMode: .pasteIntoCurrentFocus,
                        onProgress: { [weak self] progress in
                            if case .failed = progress {
                                Task { @MainActor [weak self, runID] in
                                    guard self?.activeRunID == runID else { return }
                                    if case .failed(let message) = progress {
                                        self?.panelController?.fail(message: message)
                                    }
                                }
                            }
                        }
                    )
                }
                guard self.activeRunID == runID else { return }
                self.panelController?.done(message: "Done")
                let capturePath: TelemetryTransformCapturePath = result.captureTag == "ax" ? .ax : .clipboard
                let replacePath: TelemetryTransformReplacePath = result.path == .ax ? .ax : .clipboardPaste
                Telemetry.send(.transformExecuted(
                    transformName: telemetryName,
                    capturePath: capturePath,
                    replacePath: replacePath,
                    llmMs: result.llmElapsedMs,
                    totalMs: result.totalElapsedMs
                ))
                self.sendTransformOperation(
                    operationContext: operationContext,
                    outcome: .success,
                    transformName: telemetryName,
                    stage: .complete,
                    capturePath: capturePath,
                    replacePath: replacePath,
                    llmMs: result.llmElapsedMs,
                    totalMs: result.totalElapsedMs,
                    errorType: nil
                )
                self.saveHistoryEntry(prompt: prompt, result: result)
                self.logger.notice("transforms: \(runningTransformName, privacy: .public) completed")
            } catch let error as TransformExecutorError {
                guard self.activeRunID == runID else { return }
                switch error {
                case .cancelled:
                    self.panelController?.close()
                    Telemetry.send(.transformFailed(transformName: telemetryName, reason: .cancelled))
                    self.sendTransformOperation(
                        operationContext: operationContext,
                        outcome: .cancelled,
                        transformName: telemetryName,
                        stage: nil,
                        errorType: .cancelled
                    )
                case .emptySelection:
                    self.panelController?.fail(message: error.localizedDescription)
                    Telemetry.send(.transformFailed(transformName: telemetryName, reason: .emptySelection))
                    self.sendTransformOperation(
                        operationContext: operationContext,
                        outcome: .empty,
                        transformName: telemetryName,
                        stage: .capture,
                        errorType: .emptySelection
                    )
                case .llmNotConfigured:
                    self.handleMissingLLMProvider(
                        prompt: prompt,
                        telemetryName: telemetryName,
                        operationContext: operationContext
                    )
                case .captureFailed:
                    self.panelController?.fail(message: error.localizedDescription)
                    Telemetry.send(.transformFailed(transformName: telemetryName, reason: .captureFailed))
                    self.sendTransformOperation(
                        operationContext: operationContext,
                        outcome: .failure,
                        transformName: telemetryName,
                        stage: .capture,
                        errorType: .captureFailed
                    )
                case .llmFailed:
                    self.panelController?.fail(message: error.localizedDescription)
                    Telemetry.send(.transformFailed(transformName: telemetryName, reason: .llmFailed))
                    self.sendTransformOperation(
                        operationContext: operationContext,
                        outcome: .failure,
                        transformName: telemetryName,
                        stage: .llm,
                        errorType: .llmFailed
                    )
                case .replacementFailed:
                    self.panelController?.fail(message: error.localizedDescription)
                    Telemetry.send(.transformFailed(transformName: telemetryName, reason: .replacementFailed))
                    self.sendTransformOperation(
                        operationContext: operationContext,
                        outcome: .failure,
                        transformName: telemetryName,
                        stage: .replacement,
                        errorType: .replacementFailed
                    )
                }
                self.logger.notice("transforms: \(runningTransformName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            } catch {
                guard self.activeRunID == runID else { return }
                self.panelController?.fail(message: error.localizedDescription)
                Telemetry.send(.transformFailed(transformName: telemetryName, reason: .llmFailed))
                self.sendTransformOperation(
                    operationContext: operationContext,
                    outcome: .failure,
                    transformName: telemetryName,
                    stage: nil,
                    errorType: .llmFailed
                )
            }
        }
    }

    private func handleMissingLLMProvider(
        prompt: Prompt,
        telemetryName: TelemetryTransformName,
        operationContext: ObservabilityOperationContext
    ) {
        panelController?.show()
        panelController?.fail(message: "Opening AI settings...")
        onLLMProviderRequired()
        Telemetry.send(.transformFailed(transformName: telemetryName, reason: .noProvider))
        sendTransformOperation(
            operationContext: operationContext,
            outcome: .unavailable,
            transformName: telemetryName,
            stage: .llm,
            errorType: .noProvider
        )
        logger.notice("transforms: no LLM provider configured for \(prompt.name, privacy: .public)")
    }

    private func sendTransformOperation(
        operationContext: ObservabilityOperationContext,
        outcome: ObservabilityOutcome,
        transformName: TelemetryTransformName,
        stage: TelemetryTransformOperationStage?,
        capturePath: TelemetryTransformCapturePath? = nil,
        replacePath: TelemetryTransformReplacePath? = nil,
        llmMs: Int? = nil,
        totalMs: Int? = nil,
        errorType: TelemetryTransformFailureReason? = nil
    ) {
        Telemetry.send(.transformOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            outcome: outcome,
            transformName: transformName,
            stage: stage,
            capturePath: capturePath,
            replacePath: replacePath,
            durationSeconds: totalMs.map { Double($0) / 1000.0 }
                ?? Observability.durationSeconds(since: operationContext.startedAt),
            llmMs: llmMs,
            totalMs: totalMs,
            errorType: errorType
        ))
    }

    private func saveHistoryEntry(prompt: Prompt, result: TransformExecutionResult) {
        guard let historyRepository else { return }
        let entry = TransformHistoryEntry(
            transformId: prompt.id,
            transformName: prompt.name,
            inputText: result.inputText,
            outputText: result.outputText,
            sourceAppBundleID: result.target?.bundleIdentifier,
            sourceAppName: result.target?.localizedName,
            capturePath: result.captureTag,
            replacementPath: result.path.rawValue,
            llmElapsedMs: result.llmElapsedMs,
            totalElapsedMs: result.totalElapsedMs
        )
        // Intentional silent-on-failure: the rewrite already succeeded
        // (text was pasted into the host app), so a failed history write
        // is a secondary concern. We log to os.log for support workflows
        // but don't surface to the user — they already got their result.
        Task.detached { [historyRepository, logger] in
            do {
                try historyRepository.save(entry)
                await MainActor.run {
                    NotificationCenter.default.post(name: .transformHistoryChanged, object: nil)
                }
            } catch {
                logger.error("transforms: failed to save history entry: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
