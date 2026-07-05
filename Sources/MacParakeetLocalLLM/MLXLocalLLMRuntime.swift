import Foundation
import MacParakeetCore
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import OSLog
import Tokenizers

#if MACPARAKEET_HAS_MLX_LOCAL_LLM

public actor MLXLocalLLMRuntime: LocalLLMRuntime {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MLXLocalLLMRuntime")
    private var modelContainer: ModelContainer?
    private var loadedModel: LocalLLMModelReference?
    private var latestMetrics: LLMGenerationMetrics?
    private var generationTask: Task<Void, Never>?
    private var generationInProgress: Bool { generationTask != nil }
    private var unloadAfterGeneration = false

    public init() {}

    public func load(model: LocalLLMModelReference) async throws {
        try Task.checkCancellation()
        await drainGenerationIfNeeded()
        try Task.checkCancellation()

        if generationInProgress {
            guard loadedModel == model, modelContainer != nil else {
                throw LLMError.providerError("Cannot switch local MLX models while generation is in progress.")
            }
            return
        }

        if loadedModel == model, modelContainer != nil {
            return
        }

        clearLoadedState()

        modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: model.directory,
            using: #huggingFaceTokenizerLoader()
        )
        loadedModel = model
        unloadAfterGeneration = false
        logger.info("Loaded local MLX model \(model.modelName, privacy: .public)")
    }

    public func unload() async {
        if generationInProgress {
            unloadAfterGeneration = true
            return
        }

        clearLoadedState()
        logger.info("Unloaded local MLX model")
    }

    public func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error> {
        try Task.checkCancellation()
        await drainGenerationIfNeeded()
        try Task.checkCancellation()

        guard modelContainer != nil else {
            throw LLMError.modelNotFound("Local MLX model is not loaded.")
        }

        unloadAfterGeneration = false
        let streamPair = AsyncThrowingStream<LocalLLMRuntimeEvent, Error>.makeStream()
        let task = Task {
            await self.generate(
                messages: messages,
                options: options,
                continuation: streamPair.continuation
            )
        }
        generationTask = task
        streamPair.continuation.onTermination = { _ in
            task.cancel()
        }
        return streamPair.stream
    }

    public func instrumentation() async -> LLMGenerationMetrics? {
        latestMetrics
    }

    private func generate(
        messages: [ChatMessage],
        options: ChatCompletionOptions,
        continuation: AsyncThrowingStream<LocalLLMRuntimeEvent, Error>.Continuation
    ) async {
        defer {
            finishGeneration()
        }

        do {
            guard let modelContainer else {
                throw LLMError.modelNotFound("Local MLX model is not loaded.")
            }

            try Task.checkCancellation()
            let parameters = GenerateParameters(
                maxTokens: options.maxTokens,
                kvBits: 4,
                temperature: Float(options.temperature ?? 0.2)
            )
            let input = Self.chatInput(from: messages)
            let session = ChatSession(
                modelContainer,
                instructions: input.instructions,
                history: input.history,
                generateParameters: parameters
            )

            let start = Date()
            var firstTokenDate: Date?
            var tokenCount = 0

            for try await token in session.streamResponse(
                to: input.prompt,
                role: input.role
            ) {
                try Task.checkCancellation()
                if firstTokenDate == nil {
                    firstTokenDate = Date()
                }
                tokenCount += 1
                continuation.yield(.text(token))
            }

            let duration = max(Date().timeIntervalSince(start), 0.001)
            let metrics = LLMGenerationMetrics(
                tokensPerSecond: Double(tokenCount) / duration,
                promptTokensPerSecond: nil,
                timeToFirstTokenMs: firstTokenDate.map { Int($0.timeIntervalSince(start) * 1_000) },
                peakRSSBytes: nil
            )
            latestMetrics = metrics
            continuation.yield(.metrics(metrics))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func finishGeneration() {
        generationTask = nil
        guard unloadAfterGeneration else { return }

        unloadAfterGeneration = false
        clearLoadedState()
        logger.info("Unloaded local MLX model")
    }

    private func drainGenerationIfNeeded() async {
        while let generationTask {
            await generationTask.value
        }
    }

    private func clearLoadedState() {
        modelContainer = nil
        loadedModel = nil
        latestMetrics = nil
    }

    private static func chatInput(from messages: [ChatMessage]) -> MLXChatInput {
        let instructions =
            messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let conversationalMessages = messages.compactMap { message -> Chat.Message? in
            switch message.role {
            case .system:
                return nil
            case .user:
                return .user(message.modelContent)
            case .assistant:
                return .assistant(message.content)
            }
        }

        guard let finalMessage = conversationalMessages.last else {
            return MLXChatInput(
                instructions: instructions.isEmpty ? nil : instructions,
                history: [],
                prompt: "",
                role: .user
            )
        }

        return MLXChatInput(
            instructions: instructions.isEmpty ? nil : instructions,
            history: Array(conversationalMessages.dropLast()),
            prompt: finalMessage.content,
            role: finalMessage.role
        )
    }
}

private struct MLXChatInput {
    let instructions: String?
    let history: [Chat.Message]
    let prompt: String
    let role: Chat.Message.Role
}

#endif
