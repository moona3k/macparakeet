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
    private var generationInProgress = false
    private var unloadAfterGeneration = false

    public init() {}

    public func load(model: LocalLLMModelReference) async throws {
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

        modelContainer = try await loadModelContainer(
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
        guard modelContainer != nil else {
            throw LLMError.modelNotFound("Local MLX model is not loaded.")
        }
        guard !generationInProgress else {
            throw LLMError.providerError("Local MLX generation is already in progress.")
        }

        generationInProgress = true
        unloadAfterGeneration = false
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.generate(
                    messages: messages,
                    options: options,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
            let session = ChatSession(
                modelContainer,
                generateParameters: GenerateParameters(
                    maxTokens: options.maxTokens,
                    kvBits: 4,
                    temperature: Float(options.temperature ?? 0.2)
                )
            )
            let prompt = Self.prompt(from: messages)

            let start = Date()
            var firstTokenDate: Date?
            var tokenCount = 0

            for try await token in session.streamResponse(to: prompt) {
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
        generationInProgress = false
        guard unloadAfterGeneration else { return }

        unloadAfterGeneration = false
        clearLoadedState()
        logger.info("Unloaded local MLX model")
    }

    private func clearLoadedState() {
        modelContainer = nil
        loadedModel = nil
        latestMetrics = nil
    }

    private static func prompt(from messages: [ChatMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .system:
                return "System: \(message.content)"
            case .user:
                return "User: \(message.modelContent)"
            case .assistant:
                return "Assistant: \(message.content)"
            }
        }
        .joined(separator: "\n\n")
    }
}

#endif
