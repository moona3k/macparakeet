import Foundation
import OSLog

// MARK: - Progress

/// Progress events for the Transforms pipeline. The UI overlay listens for
/// these to drive its label / spinner state and to dismiss itself once a
/// terminal event arrives.
public enum TransformProgress: Sendable, Equatable {
    case capturing
    case llmStarted
    /// Streamed token accumulation so the UI can show partial progress if it
    /// wants. Phase-1 spike doesn't render this (paste happens only after
    /// `llmCompleted`), but it's threaded through so a future iteration can.
    case llmStreaming(String)
    case llmCompleted(String)
    case pasting
    case done(SelectionReplacementPath)
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .done, .failed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Result

public struct TransformExecutionResult: Sendable {
    public let inputText: String
    public let outputText: String
    public let path: SelectionReplacementPath
    public let totalElapsedMs: Int
    public let llmElapsedMs: Int
    public let captureTag: String
    public let target: SelectionCaptureTarget?

    public init(
        inputText: String,
        outputText: String,
        path: SelectionReplacementPath,
        totalElapsedMs: Int,
        llmElapsedMs: Int,
        captureTag: String,
        target: SelectionCaptureTarget?
    ) {
        self.inputText = inputText
        self.outputText = outputText
        self.path = path
        self.totalElapsedMs = totalElapsedMs
        self.llmElapsedMs = llmElapsedMs
        self.captureTag = captureTag
        self.target = target
    }
}

// MARK: - Errors

public enum TransformExecutorError: Error, LocalizedError, Sendable {
    case emptySelection
    case captureFailed(SelectionCaptureError)
    case llmNotConfigured
    case llmFailed(String)
    case replacementFailed(SelectionReplacementError)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No selection — select text first, then trigger the transform."
        case .captureFailed(let underlying):
            return underlying.errorDescription
        case .llmNotConfigured:
            return "Transforms need an LLM provider — configure one in Settings."
        case .llmFailed(let detail):
            return "Transform failed: \(detail)"
        case .replacementFailed(let underlying):
            return underlying.errorDescription
        case .cancelled:
            return "Transform cancelled."
        }
    }
}

// MARK: - Executor

/// One-shot transforms pipeline: capture → LLM → replace.
///
/// The spike intentionally exposes a single `run(prompt:onProgress:)` entry
/// point — no Prompt model, no rule toggles, no diff preview. Cancellation is
/// cooperative: the caller cancels the Task wrapping `run(...)` (e.g., when
/// the user presses Esc or triggers another transform).
///
/// See `docs/research/transforms-design-2026-05.md` §3 for the productized
/// shape this spike will graduate to in Phase 2.
public actor TransformExecutor {
    private let captureService: SelectionCaptureService
    private let replacementService: SelectionReplacementService
    private let llmService: LLMServiceProtocol
    private let logger: Logger

    public init(
        captureService: SelectionCaptureService = SelectionCaptureService(),
        replacementService: SelectionReplacementService = SelectionReplacementService(),
        llmService: LLMServiceProtocol
    ) {
        self.captureService = captureService
        self.replacementService = replacementService
        self.llmService = llmService
        self.logger = Logger(subsystem: "com.macparakeet.core", category: "TransformExecutor")
    }

    /// Run the pipeline. The progress callback fires on the caller's context
    /// — wrap it with `@MainActor` semantics at the call site if the UI
    /// needs main-thread delivery.
    public func run(
        prompt: String,
        replacementMode: SelectionReplacementMode = .replaceSelection,
        onProgress: @escaping @Sendable (TransformProgress) -> Void
    ) async throws -> TransformExecutionResult {
        let start = ContinuousClock.now

        // 1. Capture.
        onProgress(.capturing)
        let captured = await captureService.captureSelection()
        do {
            try Task.checkCancellation()
        } catch {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.cancelled.localizedDescription))
            throw TransformExecutorError.cancelled
        }

        switch captured {
        case .empty:
            onProgress(.failed(TransformExecutorError.emptySelection.localizedDescription))
            throw TransformExecutorError.emptySelection
        case .failed(let error):
            onProgress(.failed(error.localizedDescription))
            throw TransformExecutorError.captureFailed(error)
        default:
            break
        }

        guard let inputText = captured.capturedText, !inputText.isEmpty else {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.emptySelection.localizedDescription))
            throw TransformExecutorError.emptySelection
        }

        // 2. LLM transform stream.
        onProgress(.llmStarted)
        let llmStart = ContinuousClock.now
        var accumulated = ""
        do {
            let stream = llmService.transformStream(text: inputText, prompt: prompt)
            for try await chunk in stream {
                try Task.checkCancellation()
                accumulated += chunk
                onProgress(.llmStreaming(accumulated))
            }
        } catch is CancellationError {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.cancelled.localizedDescription))
            throw TransformExecutorError.cancelled
        } catch let error as LLMError {
            if case .notConfigured = error {
                await restoreIfAbandoning(captured)
                onProgress(.failed(TransformExecutorError.llmNotConfigured.localizedDescription))
                throw TransformExecutorError.llmNotConfigured
            }
            let detail = error.localizedDescription
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.llmFailed(detail).localizedDescription))
            throw TransformExecutorError.llmFailed(detail)
        } catch {
            let detail = error.localizedDescription
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.llmFailed(detail).localizedDescription))
            throw TransformExecutorError.llmFailed(detail)
        }
        let llmElapsedMs = Self.elapsedMs(from: llmStart)
        do {
            try Task.checkCancellation()
        } catch {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.cancelled.localizedDescription))
            throw TransformExecutorError.cancelled
        }

        guard !accumulated.isEmpty else {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.llmFailed("LLM returned empty output.").localizedDescription))
            throw TransformExecutorError.llmFailed("LLM returned empty output.")
        }
        onProgress(.llmCompleted(accumulated))

        // 3. Replace.
        //
        // Final cancellation gate. Past this point the replace+restore path
        // is *not* honored mid-flight: aborting once we've written the new
        // text to the clipboard and posted Cmd+V leaves the host app in a
        // partial state (paste happened, restore didn't), so we run replace
        // to completion and only honor cancel before it begins.
        do {
            try Task.checkCancellation()
        } catch {
            await restoreIfAbandoning(captured)
            onProgress(.failed(TransformExecutorError.cancelled.localizedDescription))
            throw TransformExecutorError.cancelled
        }
        onProgress(.pasting)
        let path: SelectionReplacementPath
        do {
            path = try await replacementService.replace(
                with: accumulated,
                in: captured,
                mode: replacementMode
            )
        } catch let error as SelectionReplacementError {
            onProgress(.failed(error.localizedDescription))
            throw TransformExecutorError.replacementFailed(error)
        } catch {
            let mapped = SelectionReplacementError.allPathsFailed
            onProgress(.failed(mapped.localizedDescription))
            throw TransformExecutorError.replacementFailed(mapped)
        }

        let totalMs = Self.elapsedMs(from: start)
        let result = TransformExecutionResult(
            inputText: inputText,
            outputText: accumulated,
            path: path,
            totalElapsedMs: totalMs,
            llmElapsedMs: llmElapsedMs,
            captureTag: captured.pathTag,
            target: captured.target
        )
        onProgress(.done(path))

        logger.notice(
            "transforms-spike: capture=\(captured.pathTag, privacy: .public) text_len=\(inputText.count, privacy: .public) llm_ms=\(llmElapsedMs, privacy: .public) replace=\(path.rawValue, privacy: .public) total_ms=\(totalMs, privacy: .public)"
        )

        return result
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let components = elapsed.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private func restoreIfAbandoning(_ captured: SelectionCaptureResult) async {
        await captureService.restoreClipboardCaptureIfCurrent(captured)
    }
}
