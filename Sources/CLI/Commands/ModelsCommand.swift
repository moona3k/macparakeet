import ArgumentParser
import Foundation
import MacParakeetCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect and manage the local speech and speaker models.",
        subcommands: [
            Status.self,
            WarmUp.self,
            Repair.self,
            Clear.self,
        ]
    )
}

extension ModelsCommand {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show speech-stack status without forcing downloads."
        )

        func run() async throws {
            let sttClient = STTClient()
            let diarizationService = DiarizationService()
            let status = await loadSpeechStackStatus(
                sttClient: sttClient,
                diarizationService: diarizationService
            )
            printSpeechStackStatus(status)
            await sttClient.shutdown()
        }
    }

    struct WarmUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "warm-up",
            abstract: "Warm up the local speech stack. May download on first run."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 1

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            let diarizationService = DiarizationService()
            try await prepareSpeechStack(
                attempts: attempts,
                sttClient: sttClient,
                diarizationService: diarizationService,
                log: { print($0) }
            )
            await sttClient.shutdown()
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair",
            abstract: "Best-effort retry for the local speech stack."
        )

        @Option(name: .long, help: "Maximum attempts.")
        var attempts: Int = 3

        func run() async throws {
            let attempts = try validatedAttempts(attempts)
            let sttClient = STTClient()
            let diarizationService = DiarizationService()
            try await prepareSpeechStack(
                attempts: attempts,
                sttClient: sttClient,
                diarizationService: diarizationService,
                log: { print($0) }
            )
            await sttClient.shutdown()
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Delete cached speech and speaker models."
        )

        func run() async throws {
            let sttClient = STTClient()
            await sttClient.clearModelCache()
            DiarizationService.clearModelCache()
            print("Local speech and speaker model caches cleared")
        }
    }
}

struct SpeechStackStatus: Sendable, Equatable {
    let speechModelCached: Bool
    let speechRuntimeReady: Bool
    let speakerModelsCached: Bool
    let speakerModelsPrepared: Bool

    var summary: String {
        if speechRuntimeReady && speakerModelsPrepared {
            return "Ready"
        }
        if speechModelCached && speakerModelsCached {
            return "Downloaded (loads on demand)"
        }
        if speechModelCached {
            return "Speech model present, speaker models missing"
        }
        if speakerModelsCached {
            return "Speaker models present, speech model missing"
        }
        return "Not downloaded"
    }
}

func validatedAttempts(_ attempts: Int) throws -> Int {
    guard attempts >= 1 else {
        throw ValidationError("--attempts must be >= 1")
    }
    return attempts
}

func loadSpeechStackStatus(
    sttClient: STTClientProtocol,
    diarizationService: DiarizationServiceProtocol,
    isSpeechModelCached: @escaping @Sendable () -> Bool = { STTClient.isModelCached() }
) async -> SpeechStackStatus {
    async let speechRuntimeReady = sttClient.isReady()
    async let speakerModelsCached = diarizationService.hasCachedModels()
    async let speakerModelsPrepared = diarizationService.isReady()

    return await SpeechStackStatus(
        speechModelCached: isSpeechModelCached(),
        speechRuntimeReady: speechRuntimeReady,
        speakerModelsCached: speakerModelsCached,
        speakerModelsPrepared: speakerModelsPrepared
    )
}

func printSpeechStackStatus(_ status: SpeechStackStatus, includeHeader: Bool = true) {
    if includeHeader {
        print("Local speech stack:")
    }
    print("  Speech model cached:   \(status.speechModelCached ? "Yes" : "No")")
    print("  Speech runtime loaded: \(status.speechRuntimeReady ? "Yes" : "No")")
    print("  Speaker models cached: \(status.speakerModelsCached ? "Yes" : "No")")
    print("  Speaker models prepared: \(status.speakerModelsPrepared ? "Yes" : "No")")
    print("  Status: \(status.summary)")
}

func prepareSpeechStack(
    attempts: Int,
    sttClient: STTClientProtocol,
    diarizationService: DiarizationServiceProtocol,
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

    log("Speaker models: preparing...")
    try await runWithRetry(attempts: attempts, label: "Speaker models", log: log) { _ in
        try await diarizationService.prepareModels { message in
            log("Speaker models: \(message)")
        }
    }

    let status = await loadSpeechStackStatus(
        sttClient: sttClient,
        diarizationService: diarizationService
    )
    log("Speech stack: \(status.summary)")
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
