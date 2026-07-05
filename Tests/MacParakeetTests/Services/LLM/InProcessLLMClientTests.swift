import XCTest
@testable import MacParakeetCore

final class InProcessLLMClientTests: XCTestCase {
    func testChatCompletionLoadsRuntimeAndReturnsMetrics() async throws {
        let modelDirectory = temporaryModelDirectory()
        let metrics = LLMGenerationMetrics(
            tokensPerSecond: 42,
            promptTokensPerSecond: 120,
            timeToFirstTokenMs: 25,
            peakRSSBytes: 1_000
        )
        let runtime = FakeLocalLLMRuntime(eventPlans: [[
            .text("hello"),
            .text(" local"),
            .metrics(metrics),
        ]])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60
        )

        let response = try await client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Summarize.")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "test-model")),
            options: .default
        )

        XCTAssertEqual(response.content, "hello local")
        XCTAssertEqual(response.model, "test-model")
        XCTAssertEqual(response.generationMetrics?.tokensPerSecond, 42)
        XCTAssertGreaterThanOrEqual(response.generationMetrics?.peakRSSBytes ?? 0, 1_000)

        let loadedModels = await runtime.loadedModels()
        XCTAssertEqual(loadedModels, [LocalLLMModelReference(modelName: "test-model", directory: modelDirectory)])
    }

    func testLongInputUsesMapReduceChunksBeforeFinalAnswer() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [
            [.text("map-1")],
            [.text("map-2")],
            [.text("map-3")],
            [.text("final")],
        ])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            chunkCharacterThreshold: 10,
            chunkCharacterLimit: 60,
            idleUnloadDelaySeconds: 60
        )

        let response = try await client.chatCompletion(
            messages: [
                ChatMessage(role: .user, content: String(repeating: "a", count: 100)),
            ],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "chunk-test")),
            options: .default
        )

        XCTAssertEqual(response.content, "final")
        let requestContents = await runtime.requestContents()
        XCTAssertGreaterThan(requestContents.count, 1)
        XCTAssertTrue(requestContents.dropLast().allSatisfy { $0.contains("Process chunk") })
        XCTAssertTrue(requestContents.last?.contains("Combine the chunk results") == true)
    }

    func testChunkingBypassesMapReduceWhenSplitProducesOneChunk() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [
            [.text("single")],
        ])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            chunkCharacterThreshold: 10,
            chunkCharacterLimit: 500,
            idleUnloadDelaySeconds: 60
        )

        let response = try await client.chatCompletion(
            messages: [
                ChatMessage(role: .user, content: String(repeating: "a", count: 450)),
            ],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "single-chunk-test")),
            options: .default
        )

        XCTAssertEqual(response.content, "single")
        let requestContents = await runtime.requestContents()
        XCTAssertEqual(requestContents.count, 1)
        XCTAssertFalse(requestContents[0].contains("Process chunk"))
        XCTAssertFalse(requestContents[0].contains("Combine the chunk results"))
    }

    func testLongInputReducePromptPreservesConversationContext() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [
            [.text("map-1")],
            [.text("map-2")],
            [.text("map-3")],
            [.text("final")],
        ])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            chunkCharacterThreshold: 10,
            chunkCharacterLimit: 900,
            idleUnloadDelaySeconds: 60
        )

        _ = try await client.chatCompletion(
            messages: [
                ChatMessage(role: .system, content: "Be faithful."),
                ChatMessage(role: .user, content: "Earlier user asked for Alpha."),
                ChatMessage(role: .assistant, content: "Earlier assistant answered with Alpha."),
                ChatMessage(
                    role: .user,
                    content: String(repeating: "b", count: 1_400) + " Final user asks for Beta."
                ),
            ],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "chunk-context-test")),
            options: .default
        )

        let requestContents = await runtime.requestContents()
        let mapPrompts = requestContents.dropLast()
        XCTAssertFalse(mapPrompts.isEmpty)
        XCTAssertTrue(mapPrompts.allSatisfy { $0.contains("Original conversation context") })
        XCTAssertTrue(mapPrompts.allSatisfy { $0.contains("Earlier user asked for Alpha.") })
        XCTAssertTrue(mapPrompts.allSatisfy { $0.contains("Earlier assistant answered with Alpha.") })
        XCTAssertTrue(mapPrompts.allSatisfy { $0.contains("Final user asks for Beta.") })

        let reducePrompt = try XCTUnwrap(requestContents.last)
        XCTAssertTrue(reducePrompt.contains("Original conversation context"))
        XCTAssertTrue(reducePrompt.contains("Earlier user asked for Alpha."))
        XCTAssertTrue(reducePrompt.contains("Earlier assistant answered with Alpha."))
        XCTAssertTrue(reducePrompt.contains("Final user asks for Beta."))
    }

    func testChunkedPromptsBoundContextAndPartialResults() async throws {
        let modelDirectory = temporaryModelDirectory()
        let largePartial = String(repeating: "partial ", count: 200)
        let runtime = FakeLocalLLMRuntime(eventPlans: [
            [.text(largePartial)],
            [.text(largePartial)],
            [.text(largePartial)],
            [.text("final")],
        ])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            chunkCharacterThreshold: 10,
            chunkCharacterLimit: 300,
            idleUnloadDelaySeconds: 60
        )

        _ = try await client.chatCompletion(
            messages: [
                ChatMessage(role: .user, content: String(repeating: "a", count: 500)),
            ],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "prompt-budget-test")),
            options: .default
        )

        let requestContents = await runtime.requestContents()
        XCTAssertGreaterThan(requestContents.count, 1)
        XCTAssertTrue(requestContents.dropLast().allSatisfy { $0.count < 800 })

        let reducePrompt = try XCTUnwrap(requestContents.last)
        XCTAssertLessThan(reducePrompt.count, 800)
        XCTAssertTrue(reducePrompt.contains("[...truncated for local model memory...]"))
    }

    func testQueuedGenerationDoesNotUnloadRuntimeBetweenRequests() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [
                [.text("first")],
                [.text("second")],
            ],
            delayNanoseconds: 50_000_000
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 0
        )

        async let first = client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "First")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-test")),
            options: .default
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        async let second = client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Second")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-test")),
            options: .default
        )

        let firstResponse = try await first
        let secondResponse = try await second
        XCTAssertEqual([firstResponse.content, secondResponse.content], ["first", "second"])

        try await Task.sleep(nanoseconds: 50_000_000)
        let requestContents = await runtime.requestContents()
        let unloadCount = await runtime.unloadCallCount()
        XCTAssertEqual(requestContents, ["First", "Second"])
        XCTAssertEqual(unloadCount, 1)
    }

    func testQueuedGenerationCancellationReturnsBeforeActiveGenerationFinishes() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [
                [.text("first")],
                [.text("second")],
            ],
            delayNanoseconds: 700_000_000
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60
        )

        let firstTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "First")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-cancel-test")),
                options: .default
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let queuedTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Second")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-cancel-test")),
                options: .default
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let cancellationStart = Date()
        queuedTask.cancel()

        do {
            _ = try await queuedTask.value
            XCTFail("Expected queued local generation to throw CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.3)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.content, "first")

        let requestContents = await runtime.requestContents()
        XCTAssertEqual(requestContents, ["First"])
    }

    func testQueuedGenerationCancellationBeforeWaitRegistrationReturnsPromptly() async throws {
        let modelDirectory = temporaryModelDirectory()
        let signal = StateSignal<String>()
        let runtime = CoordinatedLocalLLMRuntime(signal: signal)
        let coordinator = LocalLLMLifetimeCoordinator(
            beforeWaitContinuationHook: {
                await signal.emit("before-wait-registration")
                _ = await signal.wait(for: "release-wait-registration")
            }
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60,
            lifetimeCoordinator: coordinator
        )

        let firstTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "First")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-cancel-race-test")),
                options: .default
            )
        }
        let didStartFirstStream = await signal.wait(for: "stream-started-First")
        XCTAssertTrue(didStartFirstStream)

        let queuedTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Second")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-cancel-race-test")),
                options: .default
            )
        }
        let didReachWaitRegistration = await signal.wait(for: "before-wait-registration")
        XCTAssertTrue(didReachWaitRegistration)

        queuedTask.cancel()
        await signal.emit("release-wait-registration")

        do {
            _ = try await queuedTask.value
            XCTFail("Expected queued local generation to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let requestContents = await runtime.requestContents()
        XCTAssertEqual(requestContents, ["First"])
        await signal.emit("finish-First")
        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.content, "response-First")
    }

    func testStreamingYieldsRuntimeChunks() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [[
            .text("stream"),
            .text("-chunk"),
        ]])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60
        )

        let stream = client.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "stream-test")),
            options: .default
        )

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["stream", "-chunk"])
    }

    func testCancellationPropagates() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [[.failure(CancellationError())]]
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60
        )

        do {
            _ = try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Cancel me")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "cancel-test")),
                options: .default
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testIdleUnloadRunsAfterGenerationDelay() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [[.text("done")]])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 0.01
        )

        _ = try await client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "idle-test")),
            options: .default
        )

        try await Task.sleep(nanoseconds: 80_000_000)
        let unloadCount = await runtime.unloadCallCount()
        XCTAssertEqual(unloadCount, 1)
    }

    func testStaleIdleUnloadDoesNotUnloadDuringNextGeneration() async throws {
        let modelDirectory = temporaryModelDirectory()
        let signal = StateSignal<String>()
        let runtime = CoordinatedLocalLLMRuntime(signal: signal)
        let coordinator = LocalLLMLifetimeCoordinator(
            beforeIdleUnloadHook: {
                await signal.emit("idle-unload-ready")
                _ = await signal.wait(for: "release-idle-unload")
            }
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 0,
            lifetimeCoordinator: coordinator
        )

        let firstTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "First")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "idle-unload-race-test")),
                options: .default
            )
        }
        let didStartFirstStream = await signal.wait(for: "stream-started-First")
        XCTAssertTrue(didStartFirstStream)
        await signal.emit("finish-First")
        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.content, "response-First")
        let didReachIdleUnload = await signal.wait(for: "idle-unload-ready")
        XCTAssertTrue(didReachIdleUnload)

        let secondTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Second")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "idle-unload-race-test")),
                options: .default
            )
        }
        let didStartSecondStream = await signal.wait(for: "stream-started-Second")
        XCTAssertTrue(didStartSecondStream)

        await signal.emit("release-idle-unload")
        try await Task.sleep(nanoseconds: 50_000_000)
        let didUnloadDuringActiveStream = await runtime.didUnloadDuringActiveStream()
        XCTAssertFalse(didUnloadDuringActiveStream)

        await signal.emit("finish-Second")
        let secondResponse = try await secondTask.value
        XCTAssertEqual(secondResponse.content, "response-Second")
    }

    private func temporaryModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor FakeLocalLLMRuntime: LocalLLMRuntime {
    private var eventPlans: [[FakeRuntimeEvent]]
    private let delayNanoseconds: UInt64
    private var loadCalls: [LocalLLMModelReference] = []
    private var unloadCalls = 0
    private var requests: [[ChatMessage]] = []
    private var latestMetricsValue: LLMGenerationMetrics?

    init(
        eventPlans: [[FakeRuntimeEvent]],
        delayNanoseconds: UInt64 = 0
    ) {
        self.eventPlans = eventPlans
        self.delayNanoseconds = delayNanoseconds
    }

    func load(model: LocalLLMModelReference) async throws {
        loadCalls.append(model)
    }

    func unload() async {
        unloadCalls += 1
    }

    func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error> {
        requests.append(messages)
        let events = eventPlans.isEmpty ? [.text("fallback")] : eventPlans.removeFirst()
        latestMetricsValue = events.compactMap { event in
            if case .metrics(let metrics) = event {
                return metrics
            }
            return nil
        }.last
        let delayNanoseconds = delayNanoseconds

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for event in events {
                        if delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                        try Task.checkCancellation()
                        switch event {
                        case .text(let text):
                            continuation.yield(.text(text))
                        case .metrics(let metrics):
                            continuation.yield(.metrics(metrics))
                        case .failure(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func instrumentation() async -> LLMGenerationMetrics? {
        latestMetricsValue
    }

    func loadedModels() -> [LocalLLMModelReference] {
        loadCalls
    }

    func unloadCallCount() -> Int {
        unloadCalls
    }

    func requestContents() -> [String] {
        requests.map { request in
            request.map(\.content).joined(separator: "\n\n")
        }
    }
}

private enum FakeRuntimeEvent: Sendable {
    case text(String)
    case metrics(LLMGenerationMetrics)
    case failure(any Error & Sendable)
}

private actor CoordinatedLocalLLMRuntime: LocalLLMRuntime {
    private let signal: StateSignal<String>
    private var loadCalls: [LocalLLMModelReference] = []
    private var unloadCalls = 0
    private var requests: [[ChatMessage]] = []
    private var activeStreamIDs: Set<UUID> = []
    private var unloadedDuringActiveStream = false

    init(signal: StateSignal<String>) {
        self.signal = signal
    }

    func load(model: LocalLLMModelReference) async throws {
        loadCalls.append(model)
    }

    func unload() async {
        unloadCalls += 1
        if !activeStreamIDs.isEmpty {
            unloadedDuringActiveStream = true
        }
    }

    func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error> {
        requests.append(messages)
        let requestLabel = messages.map(\.content).joined(separator: "\n\n")
        let streamID = UUID()
        activeStreamIDs.insert(streamID)
        let signal = signal

        return AsyncThrowingStream { continuation in
            let task = Task {
                await signal.emit("stream-started-\(requestLabel)")
                _ = await signal.wait(for: "finish-\(requestLabel)")
                continuation.yield(.text("response-\(requestLabel)"))
                self.finishStream(id: streamID)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func instrumentation() async -> LLMGenerationMetrics? {
        nil
    }

    func requestContents() -> [String] {
        requests.map { request in
            request.map(\.content).joined(separator: "\n\n")
        }
    }

    func didUnloadDuringActiveStream() -> Bool {
        unloadedDuringActiveStream
    }

    private func finishStream(id: UUID) {
        activeStreamIDs.remove(id)
    }
}
