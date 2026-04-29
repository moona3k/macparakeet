import Foundation
import MacParakeetCore

/// Pre-warms the bundled cleanup CLI's MLX daemon when the user first reaches
/// for dictation in a session. The daemon takes a few seconds to spin up the
/// model on cold start; firing the warm-up at hotkey press buys us most of
/// that time during the user's spoken input.
///
/// The warm-up is fire-and-forget: any error is silently dropped, since the
/// real cleanup call later carries its own error handling.
@MainActor
final class LocalFormattingModelWarmupCoordinator {
    private let llmClient: RoutingLLMClient
    private let configStore: LLMConfigStore
    private let formattingModelConfigStore: LocalFormattingModelConfigStore
    private var hasWarmedUpThisSession = false

    init(
        llmClient: RoutingLLMClient,
        configStore: LLMConfigStore,
        formattingModelConfigStore: LocalFormattingModelConfigStore = LocalFormattingModelConfigStore()
    ) {
        self.llmClient = llmClient
        self.configStore = configStore
        self.formattingModelConfigStore = formattingModelConfigStore
    }

    func warmUpIfNeeded() {
        guard !hasWarmedUpThisSession else { return }
        guard let providerConfig = try? configStore.loadConfig(),
              providerConfig.id == .localFormattingModel else { return }
        let formattingConfig = formattingModelConfigStore.load() ?? LocalFormattingModelConfig()
        let context = LLMExecutionContext(
            providerConfig: providerConfig,
            localFormattingModelConfig: formattingConfig
        )
        hasWarmedUpThisSession = true
        Task.detached(priority: .utility) { [llmClient] in
            await llmClient.warmUp(context: context)
        }
    }
}
