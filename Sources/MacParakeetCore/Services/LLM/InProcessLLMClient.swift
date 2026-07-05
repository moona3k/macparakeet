import Darwin
import Foundation
import MacParakeetObjCShims
import OSLog

public typealias LocalLLMModelDirectoryResolver = @Sendable (LLMProviderConfig) throws -> URL

public final class InProcessLLMClient: LLMClientProtocol, Sendable {
    public static let modelDirectoryEnvironmentVariable = "MACPARAKEET_LOCAL_LLM_MODEL_DIR"
    public static let defaultChunkCharacterThreshold = 24_000
    public static let defaultChunkCharacterLimit = 12_000
    public static let defaultIdleUnloadDelaySeconds: TimeInterval = 300

    private let runtime: any LocalLLMRuntime
    private let modelDirectoryResolver: LocalLLMModelDirectoryResolver
    private let chunkCharacterThreshold: Int
    private let chunkCharacterLimit: Int
    private let idleUnloadDelayNanoseconds: UInt64
    private let lifetimeCoordinator: LocalLLMLifetimeCoordinator
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "InProcessLLMClient")

    public convenience init(
        runtime: any LocalLLMRuntime = UnavailableLocalLLMRuntime(),
        modelDirectoryResolver: @escaping LocalLLMModelDirectoryResolver = {
            try InProcessLLMClient.environmentModelDirectory(for: $0)
        },
        chunkCharacterThreshold: Int = InProcessLLMClient.defaultChunkCharacterThreshold,
        chunkCharacterLimit: Int = InProcessLLMClient.defaultChunkCharacterLimit,
        idleUnloadDelaySeconds: TimeInterval = InProcessLLMClient.defaultIdleUnloadDelaySeconds
    ) {
        self.init(
            runtime: runtime,
            modelDirectoryResolver: modelDirectoryResolver,
            chunkCharacterThreshold: chunkCharacterThreshold,
            chunkCharacterLimit: chunkCharacterLimit,
            idleUnloadDelaySeconds: idleUnloadDelaySeconds,
            lifetimeCoordinator: LocalLLMLifetimeCoordinator()
        )
    }

    init(
        runtime: any LocalLLMRuntime = UnavailableLocalLLMRuntime(),
        modelDirectoryResolver: @escaping LocalLLMModelDirectoryResolver = {
            try InProcessLLMClient.environmentModelDirectory(for: $0)
        },
        chunkCharacterThreshold: Int = InProcessLLMClient.defaultChunkCharacterThreshold,
        chunkCharacterLimit: Int = InProcessLLMClient.defaultChunkCharacterLimit,
        idleUnloadDelaySeconds: TimeInterval = InProcessLLMClient.defaultIdleUnloadDelaySeconds,
        lifetimeCoordinator: LocalLLMLifetimeCoordinator
    ) {
        self.runtime = runtime
        self.modelDirectoryResolver = modelDirectoryResolver
        self.chunkCharacterThreshold = max(1, chunkCharacterThreshold)
        self.chunkCharacterLimit = max(1, chunkCharacterLimit)
        let boundedDelay = max(0, idleUnloadDelaySeconds)
        self.idleUnloadDelayNanoseconds = UInt64(boundedDelay * 1_000_000_000)
        self.lifetimeCoordinator = lifetimeCoordinator
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let generation = try await generateResponse(
            messages: messages,
            context: context,
            options: options,
            emit: nil
        )
        return ChatCompletionResponse(
            content: generation.content,
            finishReason: "stop",
            model: context.providerConfig.modelName,
            generationMetrics: generation.metrics
        )
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.generateResponse(
                        messages: messages,
                        context: context,
                        options: options,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        try Task.checkCancellation()
        let lease = try await lifetimeCoordinator.beginGeneration()
        do {
            try Task.checkCancellation()
            try await loadRuntime(for: context.providerConfig)
            await lifetimeCoordinator.endGeneration(
                lease,
                runtime: runtime,
                delayNanoseconds: 0
            )
        } catch {
            await lifetimeCoordinator.endGeneration(
                lease,
                runtime: runtime,
                delayNanoseconds: 0
            )
            throw error
        }
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        [context.providerConfig.modelName].filter { !$0.isEmpty }
    }

    public static func environmentModelDirectory(for config: LLMProviderConfig) throws -> URL {
        guard let rawPath = ProcessInfo.processInfo.environment[modelDirectoryEnvironmentVariable],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.modelNotFound(
                "Set \(modelDirectoryEnvironmentVariable) to a local MLX model directory for \(config.modelName)."
            )
        }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    // MARK: - Generation

    private func generateResponse(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions,
        emit: (@Sendable (String) -> Void)?
    ) async throws -> CollectedLocalLLMResponse {
        guard context.providerConfig.id == .inProcessLocal else {
            throw LLMError.providerError("InProcessLLMClient received \(context.providerConfig.id.rawValue).")
        }

        try Task.checkCancellation()
        let lease = try await lifetimeCoordinator.beginGeneration()

        do {
            try Task.checkCancellation()
            try await loadRuntime(for: context.providerConfig)

            let response: CollectedLocalLLMResponse
            if shouldChunk(messages) {
                response = try await generateChunked(
                    messages: messages,
                    options: options,
                    emit: emit
                )
            } else {
                response = try await generateSingle(
                    messages: messages,
                    options: options,
                    emit: emit
                )
            }

            log(metrics: response.metrics, inputCharacters: Self.inputCharacterCount(messages))
            await lifetimeCoordinator.endGeneration(
                lease,
                runtime: runtime,
                delayNanoseconds: idleUnloadDelayNanoseconds
            )
            return response
        } catch {
            await lifetimeCoordinator.endGeneration(
                lease,
                runtime: runtime,
                delayNanoseconds: idleUnloadDelayNanoseconds
            )
            throw error
        }
    }

    private func loadRuntime(for config: LLMProviderConfig) async throws {
        let directory = try modelDirectoryResolver(config)
        try await runtime.load(
            model: LocalLLMModelReference(
                modelName: config.modelName,
                directory: directory
            )
        )
    }

    private func generateChunked(
        messages: [ChatMessage],
        options: ChatCompletionOptions,
        emit: (@Sendable (String) -> Void)?
    ) async throws -> CollectedLocalLLMResponse {
        guard Self.inputCharacterCount(messages) > chunkCharacterLimit else {
            return try await generateSingle(messages: messages, options: options, emit: emit)
        }

        let promptBudget = Self.promptBudget(maxCharacters: chunkCharacterLimit)
        let chunks = Self.splitForMapReduce(messages, maxCharacters: promptBudget.chunkCharacters)
        guard chunks.count > 1 else {
            return try await generateSingle(messages: messages, options: options, emit: emit)
        }

        var partials: [String] = []
        var mergedMetrics: LLMGenerationMetrics?

        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let mapMessages = Self.mapMessages(
                originalMessages: messages,
                chunk: chunk,
                index: offset + 1,
                total: chunks.count,
                conversationContextMaxCharacters: promptBudget.contextCharacters
            )
            let response = try await generateSingle(
                messages: mapMessages,
                options: options,
                emit: nil
            )
            partials.append(response.content)
            mergedMetrics = Self.merge(mergedMetrics, response.metrics)
        }

        let reduceMessages = Self.reduceMessages(
            originalMessages: messages,
            partials: partials,
            conversationContextMaxCharacters: promptBudget.contextCharacters,
            partialResultsMaxCharacters: promptBudget.partialResultCharacters
        )
        let reduceResponse = try await generateSingle(
            messages: reduceMessages,
            options: options,
            emit: emit
        )
        return CollectedLocalLLMResponse(
            content: reduceResponse.content,
            metrics: Self.merge(mergedMetrics, reduceResponse.metrics)
        )
    }

    private func generateSingle(
        messages: [ChatMessage],
        options: ChatCompletionOptions,
        emit: (@Sendable (String) -> Void)?
    ) async throws -> CollectedLocalLLMResponse {
        try Task.checkCancellation()
        let rssBefore = ProcessRSSSampler.currentResidentSetSizeBytes()
        let stream = try await runtime.generateStream(messages: messages, options: options)

        var content = ""
        var metrics: LLMGenerationMetrics?
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .text(let text):
                content += text
                emit?(text)
            case .metrics(let eventMetrics):
                metrics = eventMetrics
            }
        }

        let runtimeMetrics: LLMGenerationMetrics?
        if let metrics {
            runtimeMetrics = metrics
        } else {
            runtimeMetrics = await runtime.instrumentation()
        }
        let peakRSS = [rssBefore, ProcessRSSSampler.currentResidentSetSizeBytes(), runtimeMetrics?.peakRSSBytes]
            .compactMap { $0 }
            .max()
        return CollectedLocalLLMResponse(
            content: content,
            metrics: (runtimeMetrics ?? LLMGenerationMetrics()).withPeakRSS(peakRSS)
        )
    }

    private func shouldChunk(_ messages: [ChatMessage]) -> Bool {
        Self.inputCharacterCount(messages) > chunkCharacterThreshold
    }

    private func log(metrics: LLMGenerationMetrics?, inputCharacters: Int) {
        logger.info(
            "Local LLM generation completed inputCharacters=\(inputCharacters, privacy: .public) tokensPerSecond=\(metrics?.tokensPerSecond ?? -1, privacy: .public) promptTokensPerSecond=\(metrics?.promptTokensPerSecond ?? -1, privacy: .public) ttftMs=\(metrics?.timeToFirstTokenMs ?? -1, privacy: .public) peakRSSBytes=\(metrics?.peakRSSBytes ?? 0, privacy: .public)"
        )
    }

    // MARK: - Chunking

    private static func inputCharacterCount(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.modelContent.count }
    }

    private static func splitForMapReduce(_ messages: [ChatMessage], maxCharacters: Int) -> [String] {
        let joined = messages
            .map { "\($0.role.rawValue.uppercased()): \($0.modelContent)" }
            .joined(separator: "\n\n")
        return split(joined, maxCharacters: maxCharacters)
    }

    private static func split(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[cursor..<end]))
            cursor = end
        }
        return chunks
    }

    private static func mapMessages(
        originalMessages: [ChatMessage],
        chunk: String,
        index: Int,
        total: Int,
        conversationContextMaxCharacters: Int
    ) -> [ChatMessage] {
        let systemMessages = originalMessages.filter { $0.role == .system }
        let originalConversationContext = compactConversationContext(
            originalMessages,
            maxCharacters: conversationContextMaxCharacters
        )
        return systemMessages + [
            ChatMessage(
                role: .user,
                content: """
                Process chunk \(index) of \(total) for the user's request. Preserve facts exactly and do not infer missing details.

                Original conversation context, including user and assistant turns:
                \(originalConversationContext)

                Chunk:
                \(chunk)
                """
            ),
        ]
    }

    private static func reduceMessages(
        originalMessages: [ChatMessage],
        partials: [String],
        conversationContextMaxCharacters: Int,
        partialResultsMaxCharacters: Int
    ) -> [ChatMessage] {
        let systemMessages = originalMessages.filter { $0.role == .system }
        let originalConversationContext = compactConversationContext(
            originalMessages,
            maxCharacters: conversationContextMaxCharacters
        )
        let combined = partials.enumerated()
            .map { "Chunk \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        let boundedCombined = middleTruncated(combined, maxCharacters: partialResultsMaxCharacters)
        return systemMessages + [
            ChatMessage(
                role: .user,
                content: """
                Combine the chunk results into one final answer for the original request. Preserve source facts exactly, remove duplication, and do not add unstated details.

                Original conversation context, including user and assistant turns:
                \(originalConversationContext)

                Chunk results:
                \(boundedCombined)
                """
            ),
        ]
    }

    private static func compactConversationContext(
        _ messages: [ChatMessage],
        maxCharacters: Int = 6_000
    ) -> String {
        let context = messages
            .filter { $0.role != .system }
            .map { "\($0.role.rawValue.uppercased()): \($0.modelContent)" }
            .joined(separator: "\n\n")

        guard !context.isEmpty else { return "(no user or assistant context)" }
        return middleTruncated(context, maxCharacters: maxCharacters)
    }

    private static func middleTruncated(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }

        let boundedLimit = max(1, maxCharacters)
        let marker = "\n\n[...truncated for local model memory...]\n\n"
        guard boundedLimit > marker.count + 2 else {
            return String(text.prefix(boundedLimit))
        }

        let remainingCharacters = boundedLimit - marker.count
        let headCount = remainingCharacters / 2
        let tailCount = remainingCharacters - headCount
        let headEnd = text.index(text.startIndex, offsetBy: headCount)
        let tailStart = text.index(text.endIndex, offsetBy: -tailCount)
        return "\(text[..<headEnd])\(marker)\(text[tailStart...])"
    }

    private static func promptBudget(maxCharacters: Int) -> LocalLLMPromptBudget {
        let boundedLimit = max(1, maxCharacters)
        let contextCharacters = max(1, boundedLimit / 3)
        let payloadCharacters = max(1, boundedLimit - contextCharacters)
        return LocalLLMPromptBudget(
            chunkCharacters: payloadCharacters,
            contextCharacters: contextCharacters,
            partialResultCharacters: payloadCharacters
        )
    }

    private static func merge(
        _ lhs: LLMGenerationMetrics?,
        _ rhs: LLMGenerationMetrics?
    ) -> LLMGenerationMetrics? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }

        return LLMGenerationMetrics(
            tokensPerSecond: rhs.tokensPerSecond ?? lhs.tokensPerSecond,
            promptTokensPerSecond: rhs.promptTokensPerSecond ?? lhs.promptTokensPerSecond,
            timeToFirstTokenMs: rhs.timeToFirstTokenMs ?? lhs.timeToFirstTokenMs,
            peakRSSBytes: [lhs.peakRSSBytes, rhs.peakRSSBytes].compactMap { $0 }.max()
        )
    }
}

private struct CollectedLocalLLMResponse: Sendable {
    let content: String
    let metrics: LLMGenerationMetrics?
}

private struct LocalLLMPromptBudget: Sendable {
    let chunkCharacters: Int
    let contextCharacters: Int
    let partialResultCharacters: Int
}

typealias LocalLLMLifetimeHook = @Sendable () async -> Void

actor LocalLLMLifetimeCoordinator {
    private var unloadTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var idleUnloadGeneration: UInt64 = 0
    private var unloadInProgress = false
    private var waitingGenerations: [WaitingGeneration] = []
    private let beforeWaitContinuationHook: LocalLLMLifetimeHook?
    private let beforeIdleUnloadHook: LocalLLMLifetimeHook?

    init(
        beforeWaitContinuationHook: LocalLLMLifetimeHook? = nil,
        beforeIdleUnloadHook: LocalLLMLifetimeHook? = nil
    ) {
        self.beforeWaitContinuationHook = beforeWaitContinuationHook
        self.beforeIdleUnloadHook = beforeIdleUnloadHook
    }

    func beginGeneration() async throws -> LocalLLMGenerationLease {
        try Task.checkCancellation()
        if activeGenerationID != nil || unloadInProgress {
            let lease = LocalLLMGenerationLease(id: UUID())
            return try await withTaskCancellationHandler {
                if let beforeWaitContinuationHook {
                    await beforeWaitContinuationHook()
                }
                return try await withCheckedThrowingContinuation { (
                    continuation: CheckedContinuation<LocalLLMGenerationLease, Error>
                ) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waitingGenerations.append(
                            WaitingGeneration(lease: lease, continuation: continuation)
                        )
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelWaitingGeneration(id: lease.id)
                }
            }
        }

        let lease = LocalLLMGenerationLease(id: UUID())
        activeGenerationID = lease.id
        cancelPendingUnload()
        return lease
    }

    func endGeneration(
        _ lease: LocalLLMGenerationLease,
        runtime: any LocalLLMRuntime,
        delayNanoseconds: UInt64
    ) {
        guard activeGenerationID == lease.id else { return }

        if resumeNextWaitingGeneration() {
            return
        }

        activeGenerationID = nil
        scheduleUnload(runtime: runtime, delayNanoseconds: delayNanoseconds)
    }

    private func cancelWaitingGeneration(id: UUID) {
        guard let index = waitingGenerations.firstIndex(where: { $0.lease.id == id }) else { return }

        let waitingGeneration = waitingGenerations.remove(at: index)
        waitingGeneration.continuation.resume(throwing: CancellationError())
    }

    private func cancelPendingUnload() {
        idleUnloadGeneration &+= 1
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func scheduleUnload(runtime: any LocalLLMRuntime, delayNanoseconds: UInt64) {
        cancelPendingUnload()
        let generation = idleUnloadGeneration
        unloadTask = Task {
            guard delayNanoseconds > 0 else {
                if let beforeIdleUnloadHook {
                    await beforeIdleUnloadHook()
                }
                await self.unloadIfStillIdle(
                    generation: generation,
                    runtime: runtime
                )
                return
            }

            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                if let beforeIdleUnloadHook {
                    await beforeIdleUnloadHook()
                }
                await self.unloadIfStillIdle(
                    generation: generation,
                    runtime: runtime
                )
            } catch {
                return
            }
        }
    }

    private func unloadIfStillIdle(
        generation: UInt64,
        runtime: any LocalLLMRuntime
    ) async {
        guard generation == idleUnloadGeneration,
              activeGenerationID == nil,
              waitingGenerations.isEmpty,
              !unloadInProgress else {
            return
        }

        unloadTask = nil
        unloadInProgress = true
        await runtime.unload()
        finishIdleUnload(generation: generation)
    }

    private func finishIdleUnload(generation: UInt64) {
        guard unloadInProgress else { return }
        unloadInProgress = false

        if generation == idleUnloadGeneration {
            unloadTask = nil
        }

        _ = resumeNextWaitingGeneration()
    }

    private func resumeNextWaitingGeneration() -> Bool {
        guard !waitingGenerations.isEmpty else { return false }

        let next = waitingGenerations.removeFirst()
        activeGenerationID = next.lease.id
        next.continuation.resume(returning: next.lease)
        return true
    }
}

struct LocalLLMGenerationLease: Sendable {
    let id: UUID
}

private struct WaitingGeneration {
    let lease: LocalLLMGenerationLease
    let continuation: CheckedContinuation<LocalLLMGenerationLease, Error>
}

private enum ProcessRSSSampler {
    static func currentResidentSetSizeBytes() -> UInt64? {
        #if os(macOS)
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(MPKCurrentTaskPort(), task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }
}
