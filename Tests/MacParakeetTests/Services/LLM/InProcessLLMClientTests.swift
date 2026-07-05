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
        let firstGenerationGate = AsyncGate()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [
                [.wait(firstGenerationGate), .text("first")],
                [.text("second")],
            ]
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
        await runtime.waitForRequestCount(1)
        async let second = client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Second")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-test")),
            options: .default
        )
        await Task.yield()
        await firstGenerationGate.open()

        let firstResponse = try await first
        let secondResponse = try await second
        XCTAssertEqual([firstResponse.content, secondResponse.content], ["first", "second"])

        try await withTimeout {
            await runtime.waitForUnloadCount(1)
        }
        let requestContents = await runtime.requestContents()
        let unloadCount = await runtime.unloadCallCount()
        XCTAssertEqual(requestContents, ["First", "Second"])
        XCTAssertEqual(unloadCount, 1)
    }

    func testQueuedGenerationCancellationReturnsBeforeActiveGenerationFinishes() async throws {
        let modelDirectory = temporaryModelDirectory()
        let firstGenerationGate = AsyncGate()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [
                [.wait(firstGenerationGate), .text("first")],
                [.text("second")],
            ]
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

        await runtime.waitForRequestCount(1)
        let queuedTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Second")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "queued-cancel-test")),
                options: .default
            )
        }

        await Task.yield()
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

        await firstGenerationGate.open()
        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.content, "first")

        let requestContents = await runtime.requestContents()
        XCTAssertEqual(requestContents, ["First"])
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

        try await withTimeout {
            await runtime.waitForUnloadCount(1)
        }
        let unloadCount = await runtime.unloadCallCount()
        XCTAssertEqual(unloadCount, 1)
    }

    func testGenerationWaitsForInProgressImmediateUnloadToDrain() async throws {
        let modelDirectory = temporaryModelDirectory()
        let unloadGate = AsyncGate()
        let runtime = FakeLocalLLMRuntime(
            eventPlans: [
                [.text("first")],
                [.text("second")],
            ],
            unloadGate: unloadGate
        )
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 0
        )

        let firstResponse = try await client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "First")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "unload-drain-test")),
            options: .default
        )
        XCTAssertEqual(firstResponse.content, "first")
        try await withTimeout {
            await runtime.waitForUnloadCount(1)
        }

        let secondTask = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Second")],
                context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "unload-drain-test")),
                options: .default
            )
        }
        await Task.yield()
        let requestCountWhileUnloadHeld = await runtime.requestCallCount()
        XCTAssertEqual(requestCountWhileUnloadHeld, 1)

        await unloadGate.open()
        let secondResponse = try await secondTask.value
        XCTAssertEqual(secondResponse.content, "second")
        let requestContents = await runtime.requestContents()
        XCTAssertEqual(requestContents, ["First", "Second"])
    }

    func testConnectionReleasesLeaseAndSchedulesImmediateUnload() async throws {
        let modelDirectory = temporaryModelDirectory()
        let runtime = FakeLocalLLMRuntime(eventPlans: [])
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 60
        )

        try await client.testConnection(
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "probe-test"))
        )

        try await withTimeout {
            await runtime.waitForUnloadCount(1)
        }
        let loadedModels = await runtime.loadedModels()
        let unloadCount = await runtime.unloadCallCount()
        XCTAssertEqual(loadedModels, [LocalLLMModelReference(modelName: "probe-test", directory: modelDirectory)])
        XCTAssertEqual(unloadCount, 1)
    }

    private func temporaryModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor FakeLocalLLMRuntime: LocalLLMRuntime {
    private var eventPlans: [[FakeRuntimeEvent]]
    private let delayNanoseconds: UInt64
    private let unloadGate: AsyncGate?
    private var loadCalls: [LocalLLMModelReference] = []
    private var unloadCalls = 0
    private var requests: [[ChatMessage]] = []
    private var latestMetricsValue: LLMGenerationMetrics?
    private var requestCountWaiters: [CountWaiter] = []
    private var unloadCountWaiters: [CountWaiter] = []

    init(
        eventPlans: [[FakeRuntimeEvent]],
        delayNanoseconds: UInt64 = 0,
        unloadGate: AsyncGate? = nil
    ) {
        self.eventPlans = eventPlans
        self.delayNanoseconds = delayNanoseconds
        self.unloadGate = unloadGate
    }

    func load(model: LocalLLMModelReference) async throws {
        loadCalls.append(model)
    }

    func unload() async {
        unloadCalls += 1
        resumeSatisfiedWaiters(&unloadCountWaiters, currentCount: unloadCalls)
        if let unloadGate {
            await unloadGate.wait()
        }
    }

    func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error> {
        requests.append(messages)
        resumeSatisfiedWaiters(&requestCountWaiters, currentCount: requests.count)
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
                        case .wait(let gate):
                            await gate.wait()
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

    func requestCallCount() -> Int {
        requests.count
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append(CountWaiter(count: count, continuation: continuation))
        }
    }

    func waitForUnloadCount(_ count: Int) async {
        guard unloadCalls < count else { return }
        await withCheckedContinuation { continuation in
            unloadCountWaiters.append(CountWaiter(count: count, continuation: continuation))
        }
    }

    func requestContents() -> [String] {
        requests.map { request in
            request.map(\.content).joined(separator: "\n\n")
        }
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [CountWaiter],
        currentCount: Int
    ) {
        let ready = waiters.filter { currentCount >= $0.count }
        waiters.removeAll { currentCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private enum FakeRuntimeEvent: Sendable {
    case text(String)
    case metrics(LLMGenerationMetrics)
    case failure(any Error & Sendable)
    case wait(AsyncGate)
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

private struct CountWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    nanoseconds: UInt64 = 1_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TestTimeoutError.timedOut
        }

        guard let result = try await group.next() else {
            throw TestTimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}
