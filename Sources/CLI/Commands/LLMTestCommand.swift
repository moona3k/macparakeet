import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-connection",
        abstract: "Test connectivity to an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Flag(name: .long, help: "Emit a structured JSON envelope ({ok, provider, model, latencyMs}) on success; on failure exit non-zero with error on stderr.")
    var json: Bool = false

    func run() async throws {
        let execution = try llm.buildExecutionContext()
        let config = execution.context.providerConfig

        if !json {
            print("Testing connection to \(config.id.displayName) (\(config.modelName))...")
        }

        let startedAt = Date()
        do {
            try await execution.client.testConnection(context: execution.context)
            let latencyMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
            if json {
                try printJSON(LLMTestConnectionResult(
                    ok: true,
                    provider: config.id.rawValue,
                    model: config.modelName,
                    latencyMs: latencyMs
                ))
            } else {
                print("Connection successful.")
            }
        } catch let error as LLMError {
            printErr("Connection failed: \(error.errorDescription ?? String(describing: error))")
            throw ExitCode.failure
        } catch {
            printErr("Connection failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct LLMTestConnectionResult: Encodable {
    let ok: Bool
    let provider: String
    let model: String
    let latencyMs: Int
}
