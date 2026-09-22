import Foundation

public struct LocalLLMModelReference: Sendable, Equatable {
    public let modelName: String
    public let directory: URL

    public init(modelName: String, directory: URL) {
        self.modelName = modelName
        self.directory = directory
    }
}

public enum LocalLLMRuntimeEvent: Sendable, Equatable {
    case text(String)
    case metrics(LLMGenerationMetrics)
}

public protocol LocalLLMRuntime: Sendable {
    var isAvailable: Bool { get }

    func load(model: LocalLLMModelReference) async throws
    func unload() async
    func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error>
    func smokeTest(
        model: LocalLLMModelReference,
        timeoutNanoseconds: UInt64
    ) async throws
    func instrumentation() async -> LLMGenerationMetrics?
}

public extension LocalLLMRuntime {
    var isAvailable: Bool { false }

    func smokeTest(
        model: LocalLLMModelReference,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await load(model: model)
        try await LocalLLMRuntimeSmokeTest.run(
            runtime: self,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }
}

public actor UnavailableLocalLLMRuntime: LocalLLMRuntime {
    public init() {}

    public nonisolated var isAvailable: Bool { false }

    public func load(model: LocalLLMModelReference) async throws {
        throw LLMError.modelNotFound(
            "Local MLX runtime is not linked in this build. Enable the gated app build and set \(InProcessLLMClient.modelDirectoryEnvironmentVariable) to a local model directory."
        )
    }

    public func unload() async {}

    public func generateStream(
        messages: [ChatMessage],
        options: ChatCompletionOptions
    ) async throws -> AsyncThrowingStream<LocalLLMRuntimeEvent, Error> {
        throw LLMError.modelNotFound("Local MLX runtime is not linked in this build.")
    }

    public func instrumentation() async -> LLMGenerationMetrics? {
        nil
    }
}

private enum LocalLLMRuntimeSmokeTest {
    static let messages: [ChatMessage] = [
        ChatMessage(role: .system, content: "You are checking that local generation works."),
        ChatMessage(role: .user, content: "Reply with OK."),
    ]

    static let options = ChatCompletionOptions(temperature: 0, maxTokens: 4)

    static func run(
        runtime: any LocalLLMRuntime,
        timeoutNanoseconds: UInt64
    ) async throws {
        guard timeoutNanoseconds > 0 else {
            try await consume(runtime: runtime)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await consume(runtime: runtime)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw LLMError.providerError(
                    "Local AI runtime loaded, but the generation smoke test timed out after \(timeoutDescription(timeoutNanoseconds))."
                )
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func consume(runtime: any LocalLLMRuntime) async throws {
        let stream = try await runtime.generateStream(messages: messages, options: options)
        for try await event in stream {
            switch event {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
            case .metrics:
                break
            }
        }

        throw LLMError.providerError("Local AI runtime loaded, but the generation smoke test produced no text.")
    }

    private static func timeoutDescription(_ timeoutNanoseconds: UInt64) -> String {
        let seconds = Double(timeoutNanoseconds) / 1_000_000_000
        if seconds.rounded(.down) == seconds {
            return "\(Int(seconds)) seconds"
        }
        return String(format: "%.1f seconds", seconds)
    }
}
