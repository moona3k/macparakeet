import Foundation
import MacParakeetCore

/// A picker edits the route it displayed, including whether it inherited Default AI.
struct LLMModelSelectionRoute: Equatable {
    let config: LLMProviderConfig
    let isOverride: Bool

    static func load(from store: LLMConfigStoreProtocol, for task: LLMTaskGroup) throws -> Self? {
        if task.allowsOverride, let config = try store.loadTaskOverride(task) {
            return Self(config: config, isOverride: true)
        }
        return try store.loadConfig().map { Self(config: $0, isOverride: false) }
    }
}

enum LLMModelAvailability {
    static func pickerModels(for config: LLMProviderConfig, discoveredModels: [String]) -> [String] {
        let discovered = normalize(discoveredModels)
        let baseModels = discovered.isEmpty ? config.id.fallbackModels : discovered
        return includingCurrentModel(config.modelName, in: baseModels)
    }

    static func refreshPickerModelsTask(
        for config: LLMProviderConfig,
        llmClient: LLMClientProtocol?,
        configStore: LLMConfigStoreProtocol?,
        task: LLMTaskGroup? = nil,
        apply: @escaping @MainActor @Sendable ([String]) -> Void
    ) -> Task<Void, Never>? {
        guard let llmClient, let configStore, config.id.supportsModelListing else { return nil }
        return Task {
            do {
                let discoveredModels = try await llmClient.listModels(
                    context: LLMExecutionContext(providerConfig: config)
                )
                guard !Task.isCancelled else { return }
                let models = pickerModels(for: config, discoveredModels: discoveredModels)
                await MainActor.run {
                    guard shouldApplyModelListResult(for: config, configStore: configStore, task: task) else { return }
                    apply(models)
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    static func settingsModels(for providerID: LLMProviderID, discoveredModels: [String]) -> [String] {
        let discovered = normalize(discoveredModels)
        return discovered.isEmpty ? providerID.fallbackModels : discovered
    }

    static func normalize(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func shouldApplyModelListResult(
        for config: LLMProviderConfig,
        configStore: LLMConfigStoreProtocol,
        task: LLMTaskGroup?
    ) -> Bool {
        let storedConfig: LLMProviderConfig?
        if let task {
            storedConfig = try? configStore.loadConfig(for: task)
        } else {
            storedConfig = try? configStore.loadConfig()
        }
        return storedConfig == config
    }

    private static func includingCurrentModel(_ modelName: String, in models: [String]) -> [String] {
        let current = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }
}
