import ArgumentParser
import Foundation
import MacParakeetCore

enum ModelTarget: String, ExpressibleByArgument, CaseIterable {
    case stt
    case llm
    case all
}

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect and manage local model lifecycle.",
        subcommands: [
            Status.self,
            WarmUp.self,
            Repair.self,
        ]
    )
}

extension ModelsCommand {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show local model status without forcing downloads."
        )

        @Option(help: "Target model: stt, llm, all.")
        var target: ModelTarget = .all

        func run() async throws {
            let sttClient = STTClient()
            let llmService = MLXLLMService()

            switch target {
            case .stt:
                await printSTTStatus(sttClient: sttClient)
            case .llm:
                await printLLMStatus(llmService: llmService)
            case .all:
                await printSTTStatus(sttClient: sttClient)
                print()
                await printLLMStatus(llmService: llmService)
            }
        }
    }

    struct WarmUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "warm-up",
            abstract: "Warm up local model(s). May download on first run."
        )

        @Option(help: "Target model: stt, llm, all.")
        var target: ModelTarget = .all

        @Option(name: .long, help: "Maximum attempts per model.")
        var attempts: Int = 1

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            let llmService = MLXLLMService()
            try await warmUpModels(
                target: target,
                attempts: attempts,
                sttClient: sttClient,
                llmService: llmService,
                log: { print($0) }
            )
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair",
            abstract: "Best-effort retry model repair (sequential for all)."
        )

        @Option(help: "Target model: stt, llm, all.")
        var target: ModelTarget = .all

        @Option(name: .long, help: "Maximum attempts per model.")
        var attempts: Int = 3

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            let llmService = MLXLLMService()
            try await warmUpModels(
                target: target,
                attempts: attempts,
                sttClient: sttClient,
                llmService: llmService,
                log: { print($0) }
            )
        }
    }
}

func validatedAttempts(_ attempts: Int) throws -> Int {
    guard attempts >= 1 else {
        throw ValidationError("--attempts must be >= 1")
    }
    return attempts
}

func printSTTStatus(sttClient: STTClientProtocol) async {
    let cached = STTClient.isModelCached()
    let ready = await sttClient.isReady()

    print("Parakeet (STT):")
    print("  Cached: \(cached ? "Yes" : "No")")
    print("  Ready:  \(ready ? "Yes" : "No")")
    if ready {
        print("  Status: Ready")
    } else if cached {
        print("  Status: Downloaded (loads on demand)")
    } else {
        print("  Status: Not downloaded")
    }
}

func printLLMStatus(llmService: any LLMServiceProtocol) async {
    let ready = await llmService.isReady()

    print("Qwen (LLM):")
    print("  Ready:  \(ready ? "Yes" : "No")")
    if ready {
        print("  Status: Ready")
    } else {
        print("  Status: Not loaded (loads on first AI use)")
    }
}

func warmUpModels(
    target: ModelTarget,
    attempts: Int,
    sttClient: STTClientProtocol,
    llmService: any LLMServiceProtocol,
    log: @escaping @Sendable (String) -> Void
) async throws {
    switch target {
    case .stt:
        try await warmUpSTT(attempts: attempts, sttClient: sttClient, log: log)
    case .llm:
        try await warmUpLLM(attempts: attempts, llmService: llmService, log: log)
    case .all:
        try await warmUpSTT(attempts: attempts, sttClient: sttClient, log: log)
        try await warmUpLLM(attempts: attempts, llmService: llmService, log: log)
    }
}

private func warmUpSTT(
    attempts: Int,
    sttClient: STTClientProtocol,
    log: @escaping @Sendable (String) -> Void
) async throws {
    log("Parakeet (STT): preparing...")
    try await runWithRetry(attempts: attempts, label: "Parakeet (STT)", log: log) { attempt in
        try await sttClient.warmUp { message in
            if attempt == 1 || message.contains("%") || message == "Ready" || message.contains("Loading model") {
                log("Parakeet (STT): \(message)")
            }
        }
    }

    let ready = await sttClient.isReady()
    log("Parakeet (STT): \(ready ? "Ready" : "Not ready")")
}

private func warmUpLLM(
    attempts: Int,
    llmService: any LLMServiceProtocol,
    log: @escaping @Sendable (String) -> Void
) async throws {
    log("Qwen (LLM): preparing...")
    try await runWithRetry(attempts: attempts, label: "Qwen (LLM)", log: log) { _ in
        try await llmService.warmUp()
    }

    let ready = await llmService.isReady()
    log("Qwen (LLM): \(ready ? "Ready" : "Not ready")")
}

private func runWithRetry(
    attempts: Int,
    label: String,
    log: @escaping @Sendable (String) -> Void,
    operation: @escaping @Sendable (_ attempt: Int) async throws -> Void
) async throws {
    var backoffNs: UInt64 = 250_000_000
    var lastError: Error?

    for attempt in 1...attempts {
        do {
            try await operation(attempt)
            return
        } catch {
            lastError = error
            guard attempt < attempts else { break }
            let nextAttempt = attempt + 1
            log("\(label): attempt \(attempt) failed (\(error.localizedDescription)). Retrying \(nextAttempt)/\(attempts)...")
            try await Task.sleep(nanoseconds: backoffNs)
            backoffNs *= 2
        }
    }

    throw lastError ?? LLMServiceError.generationFailed("\(label) warm-up failed.")
}
