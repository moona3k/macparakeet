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
/// Supersedes the original AX-coverage spike (a single hardcoded Opt+Ctrl+1
/// bound to a baked-in Polish prompt). The coordinator is gated by
/// `AppFeatures.transformsEnabled`, which is enabled and shipping after the
/// website telemetry allowlist deploy landed.
@MainActor
final class TransformsCoordinator {
    private let llmServiceProvider: () -> LLMServiceProtocol?
    private let promptRepository: PromptRepositoryProtocol
    private let historyRepository: TransformHistoryRepositoryProtocol?
    private let activeModelNameProvider: () -> String?
    private let reservedHotkeysProvider: () -> [TransformShortcutReservedHotkey]
    private let onLLMProviderRequired: () -> Void
    private let logger = Logger(subsystem: "com.macparakeet", category: "TransformsCoordinator")

    private var registry: TransformsHotkeyRegistry?
    private var panelController: TransformSpikeProgressPanelController?
    private let runSerializer = TransformRunSerializer()
    private var bindingsChangedObserver: NSObjectProtocol?

    /// Per-run identity for stale-event guarding: if the user re-triggers a
    /// hotkey mid-flight, the previous task may emit a terminal event after
    /// cancellation lands. We gate every UI/state mutation in the task body
    /// on `activeRunID == myRunID`.
    private var activeRunID: UUID?

    /// Cached snapshot of bound `.transform` prompts, keyed by ID. Used to
    /// resolve a `KeyboardShortcut`-triggered ID back to its prompt body
    /// without re-hitting the DB on every keystroke.
    private var promptIndex: [UUID: Prompt] = [:]
    private var activeBindingIDs: Set<UUID> = []
    private var menuBarCaptureTask: Task<SelectionCaptureResult, Never>?
    private var menuBarCaptureTarget: SelectionCaptureTarget?
    private let menuBarCaptureService = SelectionCaptureService()

    init(
        llmServiceProvider: @escaping () -> LLMServiceProtocol?,
        promptRepository: PromptRepositoryProtocol,
        historyRepository: TransformHistoryRepositoryProtocol? = nil,
        activeModelNameProvider: @escaping () -> String? = { nil },
        reservedHotkeysProvider: @escaping () -> [TransformShortcutReservedHotkey] = { [] },
        onLLMProviderRequired: @escaping () -> Void = {}
    ) {
        self.llmServiceProvider = llmServiceProvider
        self.promptRepository = promptRepository
        self.historyRepository = historyRepository
        self.activeModelNameProvider = activeModelNameProvider
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
        self.registry = registry
        reloadBindings()
        if registry.start() {
            logger.notice("transforms: registry started with \(self.activeBindingIDs.count, privacy: .public) bindings")
        } else {
            logger.error("transforms: failed to install registry event tap")
        }

        // The menu catalog and its updates must work even when the event tap
        // cannot be installed. A later resume can retry the same registry.
        bindingsChangedObserver = NotificationCenter.default.addObserver(
            forName: .transformsBindingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadBindings()
            }
        }
    }

    /// Tear down event tap + in-flight work. Called from `applicationWillTerminate`.
    func stop() {
        runSerializer.cancel()
        registry?.stop()
        registry = nil
        panelController?.close()
        panelController = nil
        if let observer = bindingsChangedObserver {
            NotificationCenter.default.removeObserver(observer)
            bindingsChangedObserver = nil
        }
        discardMenuBarCapture()
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
        let prompts: [Prompt]
        do {
            prompts = try promptRepository.fetchVisible(category: .transform)
        } catch {
            logger.error("transforms: fetchVisible failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        promptIndex = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })

        guard let registry else { return }

        let reservedHotkeys = reservedHotkeysProvider().filter { !$0.trigger.isDisabled }
        var bindings: [UUID: KeyboardShortcut] = [:]
        for prompt in prompts {
            if let shortcut = prompt.shortcut {
                let trigger = shortcut.hotkeyTrigger
                if let conflict = reservedHotkeys.first(where: {
                    trigger.conflicts(with: $0.trigger, otherMode: $0.conflictMode)
                }) {
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

    /// Capture from the app observed at status-button mouse-down, before the
    /// status menu can make MacParakeet frontmost.
    /// AX-only: dismissing the menu must not leave a Cmd+C hijack behind.
    func prepareMenuBarCapture(frontmostApplication: SelectionCaptureTarget?) {
        guard AppFeatures.transformsEnabled else { return }
        let preferred = Self.menuCaptureTarget(
            frontmostApplication: frontmostApplication,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        menuBarCaptureTarget = preferred
        menuBarCaptureTask?.cancel()
        guard let preferred else {
            // A missing mouse-down snapshot or an app-owned menu must never
            // capture a previously focused app's selection.
            menuBarCaptureTask = Task { .empty }
            return
        }
        menuBarCaptureTask = Task { [menuBarCaptureService] in
            await menuBarCaptureService.captureAXSelection(preferring: preferred)
        }
    }

    func discardMenuBarCapture() {
        menuBarCaptureTask?.cancel()
        menuBarCaptureTask = nil
        menuBarCaptureTarget = nil
    }

    func runFromMenuBar(promptID: UUID) {
        let captureTask = menuBarCaptureTask ?? Task<SelectionCaptureResult, Never> { .empty }
        let captureTarget = menuBarCaptureTarget
        menuBarCaptureTask = nil
        menuBarCaptureTarget = nil
        handleTrigger(promptID: promptID, menuBarCapture: captureTask, menuBarCaptureTarget: captureTarget)
    }

    func menuBarListings() -> [MenuBarTransformListing] {
        MenuBarTransformCatalog.listings(
            from: Array(promptIndex.values),
            hiddenIDs: UserDefaultsAppRuntimePreferences.hiddenMenuBarTransformIDs(
                defaults: AppPaths.appDefaults()
            )
        )
    }

    static func menuCaptureBelongsToTarget(
        _ capture: SelectionCaptureResult,
        target: SelectionCaptureTarget?
    ) -> Bool {
        guard let target, let capturedTarget = capture.target else { return false }
        return capturedTarget.processIdentifier == target.processIdentifier
            && capturedTarget.bundleIdentifier == target.bundleIdentifier
    }

    static func menuCaptureTarget(
        frontmostApplication: SelectionCaptureTarget?,
        ownBundleIdentifier: String?
    ) -> SelectionCaptureTarget? {
        guard let frontmostApplication,
            let ownBundleIdentifier,
            frontmostApplication.bundleIdentifier != ownBundleIdentifier
        else { return nil }
        return frontmostApplication
    }

    static func waitForMenuCaptureTarget(
        _ target: SelectionCaptureTarget,
        timeout: Duration = .milliseconds(500),
        pollInterval: Duration = .milliseconds(10),
        frontmostApplication: @MainActor () -> SelectionCaptureTarget?
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            if let frontmost = frontmostApplication(),
                frontmost.processIdentifier == target.processIdentifier,
                frontmost.bundleIdentifier == target.bundleIdentifier
            {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    private static func frontmostCaptureTarget() -> SelectionCaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = app.bundleIdentifier
        else { return nil }
        return SelectionCaptureTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    private func handleTrigger(
        promptID: UUID,
        menuBarCapture: Task<SelectionCaptureResult, Never>? = nil,
        menuBarCaptureTarget: SelectionCaptureTarget? = nil
    ) {
        guard AppFeatures.transformsEnabled else { return }
        if let owner = GUIMutationArbiter.shared.current?.owner, owner != .transform {
            panelController?.show()
            panelController?.fail(message: "Finish the current voice task before running a Transform.")
            return
        }
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

        let executor = TransformExecutor(llmService: llmService)

        let runID = UUID()
        activeRunID = runID

        panelController?.show()

        let promptBody = prompt.content
        let runningTransformName = prompt.name
        // Capture the concrete model before entering the serialized queue. A
        // queued Transform must not observe a later Settings model change.
        let modelSnapshot = Self.resolveModelSnapshot(
            promptOverride: prompt.modelOverride,
            activeModelName: activeModelNameProvider()
        )

        // Cancel any in-flight Transform if the user re-triggers a hotkey
        // before the previous one finishes, and only start this run once the
        // old one has fully wound down. The executor's replace phase ignores
        // cancellation by design (clipboard write → target re-activation →
        // ⌘V → restore must not abort half-pasted), so an immediate restart
        // could capture the old run's payload off the pasteboard or read
        // from the wrong app after a focus yank. ADR-022 §4; AUDIT-072.
        runSerializer.replace { @MainActor [weak self] in
            guard let self else { return }
            guard let lease = GUIMutationArbiter.shared.acquire(.transform) else {
                self.panelController?.fail(message: "Another voice action is active.")
                return
            }
            defer { GUIMutationArbiter.shared.release(lease) }
            do {
                var preCaptured: SelectionCaptureResult?
                if let menuBarCapture {
                    let snapshot = await menuBarCapture.value
                    if snapshot.capturedText != nil {
                        guard Self.menuCaptureBelongsToTarget(snapshot, target: menuBarCaptureTarget)
                        else { throw TransformExecutorError.captureFailed(.targetNotFrontmost) }
                        preCaptured = snapshot
                    } else if case .failed = snapshot {
                        preCaptured = snapshot
                    } else if let target = menuBarCaptureTarget {
                        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
                            app.bundleIdentifier == target.bundleIdentifier
                        else { throw TransformExecutorError.captureFailed(.targetNotFrontmost) }
                        let frontmost = Self.frontmostCaptureTarget()
                        if frontmost?.processIdentifier != target.processIdentifier
                            || frontmost?.bundleIdentifier != target.bundleIdentifier
                        {
                            guard NSApp.isActive else {
                                throw TransformExecutorError.captureFailed(.targetNotFrontmost)
                            }
                            NSApp.yieldActivation(to: app)
                            guard app.activate() else {
                                throw TransformExecutorError.captureFailed(.targetNotFrontmost)
                            }
                        }
                        guard
                            await Self.waitForMenuCaptureTarget(
                                target,
                                frontmostApplication: Self.frontmostCaptureTarget
                            )
                        else { throw TransformExecutorError.captureFailed(.targetNotFrontmost) }
                        preCaptured = await self.menuBarCaptureService.captureSelection(in: target)
                    } else {
                        throw TransformExecutorError.captureFailed(.targetNotFrontmost)
                    }
                }
                let result = try await Observability.withOperationContext(operationContext) {
                    try await executor.run(
                        prompt: promptBody,
                        inferenceSettings: prompt.inferenceSettings,
                        modelOverride: modelSnapshot,
                        replacementMode: menuBarCapture == nil
                            ? .pasteIntoCurrentFocus
                            : .replaceSelection,
                        preCaptured: preCaptured,
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
                // The target captured at trigger time is the app the rewritten
                // text was pasted back into — map it to a coarse category only.
                let appCategory = TelemetryAppCategory(bundleIdentifier: result.target?.bundleIdentifier)
                Telemetry.send(.transformExecuted(
                    transformName: telemetryName,
                    capturePath: capturePath,
                    replacePath: replacePath,
                    llmMs: result.llmElapsedMs,
                    totalMs: result.totalElapsedMs,
                    appCategory: appCategory
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
                    appCategory: appCategory,
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

    static func resolveModelSnapshot(promptOverride: String?, activeModelName: String?) -> String? {
        let override = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        let active = activeModelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return active?.isEmpty == false ? active : nil
    }

    private func handleMissingLLMProvider(
        prompt: Prompt,
        telemetryName: TelemetryTransformName,
        operationContext: ObservabilityOperationContext
    ) {
        panelController?.show()
        // Name the problem + where to fix it. The old "Opening AI settings..."
        // described a side-effect, not what the user needs to do — and when the
        // hotkey is fired from another app the Settings window opens behind
        // focus, so it read as "nothing happened" and users re-fired the hotkey
        // (see the no_provider telemetry cluster). The Settings → AI window
        // still opens automatically alongside this message.
        panelController?.fail(message: "Add an LLM provider in Settings to use Transforms")
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
        appCategory: TelemetryAppCategory? = nil,
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
            appCategory: appCategory,
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
