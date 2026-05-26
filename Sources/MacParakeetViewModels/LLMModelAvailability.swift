import Foundation
import MacParakeetCore

enum LLMModelAvailability {
    static func pickerModels(for config: LLMProviderConfig, discoveredModels: [String]) -> [String] {
        let discovered = normalize(discoveredModels)
        let baseModels = discovered.isEmpty ? config.id.fallbackModels : discovered
        return includingCurrentModel(config.modelName, in: baseModels)
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

    private static func includingCurrentModel(_ modelName: String, in models: [String]) -> [String] {
        let current = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }
}
