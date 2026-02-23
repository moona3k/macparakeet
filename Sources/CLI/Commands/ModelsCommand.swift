import ArgumentParser
import Foundation
import MacParakeetCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect and manage the local Parakeet speech model.",
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
            abstract: "Show speech model status without forcing downloads."
        )

        func run() async throws {
            let sttClient = STTClient()
            await printSTTStatus(sttClient: sttClient)
        }
    }

    struct WarmUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "warm-up",
            abstract: "Warm up speech model. May download on first run."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 1

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            try await warmUpModels(
                attempts: attempts,
                sttClient: sttClient,
                log: { print($0) }
            )
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair",
            abstract: "Best-effort retry speech model repair."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 3

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            try await warmUpModels(
                attempts: attempts,
                sttClient: sttClient,
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

func warmUpModels(
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

    throw lastError ?? STTError.engineStartFailed("\(label) warm-up failed.")
}
