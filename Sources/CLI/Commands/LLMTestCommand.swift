import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-connection",
        abstract: "Test connectivity to an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Flag(name: .long, help: "Emit a structured JSON envelope on success ({ok:true,…}) or failure ({ok:false,error,errorType}). Exit code is the source of truth for branching.")
    var json: Bool = false

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
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
            } catch {
                guard json else {
                    // Plain-text path: print the friendly "Connection failed: …"
                    // line ourselves and throw `ExitCode.failure` to suppress
                    // ArgumentParser's auto-printed error (which would
                    // otherwise duplicate the stderr message). Catches every
                    // Error type, not just LLMError — covers URLError,
                    // decoding errors, etc. (was AUDIT-034; PR #153 also
                    // landed an outer catch with the same goal, superseded
                    // here by the wrapped form).
                    let message: String
                    if let llm = error as? LLMError {
                        message = llm.errorDescription ?? String(describing: llm)
                    } else {
                        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                    printErr("Connection failed: \(message)")
                    throw ExitCode.failure
                }
                throw error
            }
        }
    }
}

struct LLMTestConnectionResult: Encodable {
    let ok: Bool
    let provider: String
    let model: String
    let latencyMs: Int
}
