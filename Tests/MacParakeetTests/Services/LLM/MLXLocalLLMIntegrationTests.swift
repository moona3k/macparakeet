import XCTest
@testable import MacParakeetCore

#if MACPARAKEET_HAS_MLX_LOCAL_LLM
@testable import MacParakeetLocalLLM
#endif

final class MLXLocalLLMIntegrationTests: XCTestCase {
    func testRealMLXConnectionSmokeWhenGatedBuildAndLocalModelArePresent() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["MACPARAKEET_RUN_MLX_LOCAL_LLM_INTEGRATION"] == "1",
            "Set MACPARAKEET_RUN_MLX_LOCAL_LLM_INTEGRATION=1 to run the real MLX local LLM smoke."
        )
        guard let modelPath = environment[InProcessLLMClient.modelDirectoryEnvironmentVariable],
            !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Set \(InProcessLLMClient.modelDirectoryEnvironmentVariable) to a local MLX model directory.")
        }

        #if MACPARAKEET_HAS_MLX_LOCAL_LLM
        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let runtime = MLXLocalLLMRuntime()
        let client = InProcessLLMClient(
            runtime: runtime,
            modelDirectoryResolver: { _ in modelDirectory },
            idleUnloadDelaySeconds: 0
        )

        try await client.testConnection(
            context: LLMExecutionContext(providerConfig: .inProcessLocal())
        )
        #else
        throw XCTSkip("Run with MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1 so the gated MLX target is linked.")
        #endif
    }
}
