import AppKit
@preconcurrency import ApplicationServices
import os
import XCTest
@testable import MacParakeetCore

final class TransformExecutorTests: XCTestCase {
    func testRunReturnsEmptySelectionWhenCaptureIsEmpty() async {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 0,
            pasteboardAfterCmdC: nil,
            changeCountAfterCmdC: 0  // No change
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(isTrusted: true)
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        let recorder = TransformProgressRecorder()
        do {
            _ = try await executor.run(prompt: "polish", onProgress: { recorder.record($0) })
            XCTFail("Expected emptySelection")
        } catch let error as TransformExecutorError {
            switch error {
            case .emptySelection: break
            default: XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = recorder.snapshot()
        XCTAssertEqual(events.first, .capturing)
        XCTAssertTrue(events.contains(where: { if case .failed = $0 { return true } else { return false } }))
        XCTAssertEqual(llm.callCount, 0, "LLM must not be invoked when capture returns empty")
        XCTAssertEqual(replacementBackend.cmdVPostCount(), 0)
    }

    func testRunSurfacesLLMNotConfigured() async {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello"
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(isTrusted: true)
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamError = LLMError.notConfigured
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        do {
            _ = try await executor.run(prompt: "polish", onProgress: { _ in })
            XCTFail("Expected llmNotConfigured")
        } catch let error as TransformExecutorError {
            switch error {
            case .llmNotConfigured: break
            default: XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunRestoresClipboardCaptureWhenLLMFailsBeforeReplacement() async {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 10,
            pasteboardAfterCmdC: "Hello",
            changeCountAfterCmdC: 11
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(isTrusted: true)
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamError = LLMError.rateLimited
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        do {
            _ = try await executor.run(prompt: "polish", onProgress: { _ in })
            XCTFail("Expected llmFailed")
        } catch let error as TransformExecutorError {
            switch error {
            case .llmFailed: break
            default: XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(captureBackend.restoreCount(), 1)
        XCTAssertEqual(replacementBackend.cmdVPostCount(), 0)
    }

    func testRunRestoresClipboardCaptureWhenLLMReturnsEmptyOutput() async {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 20,
            pasteboardAfterCmdC: "Hello",
            changeCountAfterCmdC: 21
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(isTrusted: true)
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamTokens = []
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        do {
            _ = try await executor.run(prompt: "polish", onProgress: { _ in })
            XCTFail("Expected llmFailed")
        } catch let error as TransformExecutorError {
            switch error {
            case .llmFailed: break
            default: XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(captureBackend.restoreCount(), 1)
        XCTAssertEqual(replacementBackend.cmdVPostCount(), 0)
    }

    func testRunPropagatesCaptureTargetIntoResultExactlyOnce() async throws {
        // Regression guard: PR #283 originally read
        // `NSWorkspace.frontmostApplication` at history-write time, which
        // drifts during long LLM runs (Alt-Tab → wrong source app
        // recorded). The fix threads the typed capture target through
        // `TransformExecutionResult.target`, captured ONCE at the start of
        // `captureSelection()`. This test asserts both invariants:
        //   1. The captured target reaches `result.target`.
        //   2. `frontmostApplicationTarget()` is called exactly once
        //      (not re-queried after the LLM), so the recorded app
        //      can't drift mid-run.
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello"
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: true
        )
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamTokens = ["polished"]
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        let result = try await executor.run(prompt: "polish", onProgress: { _ in })

        XCTAssertEqual(result.inputText, "Hello")
        XCTAssertEqual(result.outputText, "polished")
        let target = try XCTUnwrap(result.target, "Captured target must be propagated to result")
        XCTAssertEqual(target.processIdentifier, 1234)
        XCTAssertEqual(target.bundleIdentifier, "com.example.Source")
        XCTAssertEqual(target.localizedName, "Source")
        XCTAssertEqual(
            captureBackend.frontmostTargetCallCount(), 1,
            "Frontmost app must be queried exactly once — at capture time — to prevent drift during long LLM runs."
        )
    }

    func testRunEmitsProgressInOrderAndCallsReplacementOnSuccess() async throws {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello world"
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: true
        )
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamTokens = ["Hi ", "there!"]
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        let recorder = TransformProgressRecorder()
        let result = try await executor.run(prompt: "polish") { recorder.record($0) }
        XCTAssertEqual(result.outputText, "Hi there!")
        XCTAssertEqual(result.path, .ax)
        XCTAssertEqual(result.captureTag, "ax")

        let events = recorder.snapshot()
        // Required ordering: capturing → llmStarted → at least one
        // llmStreaming → llmCompleted → pasting → done.
        let names = events.map { eventName($0) }
        XCTAssertEqual(names.first, "capturing")
        guard let llmStartedIdx = names.firstIndex(of: "llmStarted"),
              let pastingIdx = names.firstIndex(of: "pasting"),
              let doneIdx = names.firstIndex(of: "done"),
              let completedIdx = names.firstIndex(of: "llmCompleted") else {
            XCTFail("Missing expected progress events: \(names)")
            return
        }
        XCTAssertLessThan(llmStartedIdx, completedIdx)
        XCTAssertLessThan(completedIdx, pastingIdx)
        XCTAssertLessThan(pastingIdx, doneIdx)
        XCTAssertTrue(names.contains("llmStreaming"))

        XCTAssertEqual(replacementBackend.lastAXText(), "Hi there!")
    }

    func testRunCanPasteResultIntoCurrentFocusInsteadOfAXReplacing() async throws {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello world"
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: true
        )
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamTokens = ["Hi there!"]
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        let result = try await executor.run(
            prompt: "polish",
            replacementMode: .pasteIntoCurrentFocus,
            onProgress: { _ in }
        )

        XCTAssertEqual(result.outputText, "Hi there!")
        XCTAssertEqual(result.path, .clipboardPaste)
        XCTAssertNil(replacementBackend.lastAXText())
        XCTAssertEqual(replacementBackend.lastClipboardText(), "Hi there!")
        XCTAssertEqual(replacementBackend.cmdVPostCount(), 1)
    }

    func testRunPropagatesLLMStreamError() async {
        let captureBackend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello"
        )
        let captureService = SelectionCaptureService(
            backend: captureBackend,
            clipboardPollTimeout: .milliseconds(40),
            pollIntervalNanos: 1_000_000
        )
        let replacementBackend = FakeSelectionReplacementBackend(isTrusted: true)
        let replacementService = SelectionReplacementService(
            backend: replacementBackend,
            postPasteDelay: .milliseconds(1)
        )
        let llm = MockTransformLLMService()
        llm.streamError = LLMError.rateLimited
        let executor = TransformExecutor(
            captureService: captureService,
            replacementService: replacementService,
            llmService: llm
        )

        do {
            _ = try await executor.run(prompt: "polish", onProgress: { _ in })
            XCTFail("Expected llmFailed")
        } catch let error as TransformExecutorError {
            switch error {
            case .llmFailed: break
            default: XCTFail("Unexpected: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(replacementBackend.cmdVPostCount(), 0)
    }

    // MARK: - Helpers

    private func eventName(_ progress: TransformProgress) -> String {
        switch progress {
        case .capturing: return "capturing"
        case .llmStarted: return "llmStarted"
        case .llmStreaming: return "llmStreaming"
        case .llmCompleted: return "llmCompleted"
        case .pasting: return "pasting"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

// MARK: - Recorder

final class TransformProgressRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[TransformProgress]>(initialState: [])

    func record(_ progress: TransformProgress) {
        lock.withLock { $0.append(progress) }
    }

    func snapshot() -> [TransformProgress] {
        lock.withLock { $0 }
    }
}

// MARK: - LLM mock

final class MockTransformLLMService: LLMServiceProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    var streamTokens: [String] = ["polished"]
    var streamError: Error?

    var callCount: Int {
        lock.withLock { $0 }
    }

    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func transform(text: String, prompt: String) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0),
            operationID: "mock",
            inputChars: transcript.count,
            outputChars: 0,
            inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 2
        )
    }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { $0 += 1 }
        let tokens = streamTokens
        let error = streamError
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for token in tokens { continuation.yield(token) }
            continuation.finish()
        }
    }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult {
        LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0)
    }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult {
        LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0)
    }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0)
    }
}
