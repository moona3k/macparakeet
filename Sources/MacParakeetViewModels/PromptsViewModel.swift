import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class PromptsViewModel {
    public struct InferenceSettingsDraft: Equatable, Sendable {
        public var temperature: String
        public var topP: String
        public var topK: String
        public var maxTokens: String
        public var thinkingMode: PromptInferenceSettings.ThinkingMode
        public var reasoningEffort: PromptInferenceSettings.ReasoningEffort?

        public init(
            temperature: String = "",
            topP: String = "",
            topK: String = "",
            maxTokens: String = "",
            thinkingMode: PromptInferenceSettings.ThinkingMode = .providerDefault,
            reasoningEffort: PromptInferenceSettings.ReasoningEffort? = nil
        ) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.maxTokens = maxTokens
            self.thinkingMode = thinkingMode
            self.reasoningEffort = thinkingMode == .enabled ? reasoningEffort : nil
        }

        public init(settings: PromptInferenceSettings?) {
            temperature = settings?.temperature.map(Self.renderNumber) ?? ""
            topP = settings?.topP.map(Self.renderNumber) ?? ""
            topK = settings?.topK.map(String.init) ?? ""
            maxTokens = settings?.maxTokens.map(String.init) ?? ""
            thinkingMode = settings?.thinkingMode ?? .providerDefault
            reasoningEffort = thinkingMode == .enabled ? settings?.reasoningEffort : nil
        }

        public var isDefault: Bool {
            temperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && topP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && topK.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && maxTokens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && thinkingMode == .providerDefault
                && reasoningEffort == nil
        }

        fileprivate static func renderNumber(_ value: Double) -> String {
            var rendered = String(value)
            if rendered.hasSuffix(".0") {
                rendered.removeLast(2)
            }
            return rendered
        }
    }

    public typealias InferenceValidationErrors = [PromptInferenceSettings.Field: String]

    public var prompts: [Prompt] = []
    public var newName: String = "" {
        didSet { resetValidationError() }
    }
    public var newContent: String = "" {
        didSet { resetValidationError() }
    }
    public var newInferenceSettings = InferenceSettingsDraft() {
        didSet {
            newInferenceValidationErrors = [:]
            resetValidationError()
        }
    }
    public var editingInferenceSettings = InferenceSettingsDraft() {
        didSet {
            editingInferenceValidationErrors = [:]
            resetValidationError()
        }
    }
    public private(set) var newInferenceValidationErrors: InferenceValidationErrors = [:]
    public private(set) var editingInferenceValidationErrors: InferenceValidationErrors = [:]
    public var errorMessage: String?
    public var pendingDeletePrompt: Prompt?
    public var editingPrompt: Prompt?

    private var repo: PromptRepositoryProtocol?

    public init() {}

    public func configure(repo: PromptRepositoryProtocol) {
        self.repo = repo
        loadPrompts()
    }

    public func loadPrompts() {
        guard let repo else { return }
        do {
            prompts = try repo.fetchAll().filter { $0.category == .result }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addPrompt() {
        guard let repo else { return }
        let trimmedName = normalized(newName)
        let trimmedContent = normalized(newContent)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = "Prompt name and content are required."
            return
        }
        do {
            guard try isUniqueName(trimmedName, repo: repo) else {
                errorMessage = "'\(trimmedName)' already exists"
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let inferenceSettings: PromptInferenceSettings?
        switch Self.validateInferenceSettings(newInferenceSettings) {
        case .valid(let settings):
            inferenceSettings = settings
            newInferenceValidationErrors = [:]
        case .invalid(let errors):
            newInferenceValidationErrors = errors
            return
        }

        let nextSortOrder = (prompts.map(\.sortOrder).max() ?? 0) + 1
        let prompt = Prompt(
            name: trimmedName,
            content: trimmedContent,
            category: .result,
            isBuiltIn: false,
            isVisible: true,
            sortOrder: nextSortOrder,
            inferenceSettings: inferenceSettings
        )

        do {
            try repo.save(prompt)
            Telemetry.send(.promptCreated)
            newName = ""
            newContent = ""
            newInferenceSettings = InferenceSettingsDraft()
            newInferenceValidationErrors = [:]
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updatePrompt(_ prompt: Prompt, name: String, content: String) {
        guard let repo, !prompt.isBuiltIn else { return }
        let trimmedName = normalized(name)
        let trimmedContent = normalized(content)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = "Prompt name and content are required."
            return
        }
        do {
            guard try isUniqueName(trimmedName, excluding: prompt.id, repo: repo) else {
                errorMessage = "'\(trimmedName)' already exists"
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let inferenceDraft =
            editingPrompt?.id == prompt.id
            ? editingInferenceSettings
            : InferenceSettingsDraft(settings: prompt.inferenceSettings)
        let inferenceSettings: PromptInferenceSettings?
        switch Self.validateInferenceSettings(inferenceDraft) {
        case .valid(let settings):
            inferenceSettings = settings
            editingInferenceValidationErrors = [:]
        case .invalid(let errors):
            editingInferenceValidationErrors = errors
            return
        }

        var updated = prompt
        updated.name = trimmedName
        updated.content = trimmedContent
        updated.inferenceSettings = inferenceSettings
        updated.updatedAt = Date()

        do {
            try repo.save(updated)
            Telemetry.send(.promptUpdated)
            editingPrompt = nil
            editingInferenceSettings = InferenceSettingsDraft()
            editingInferenceValidationErrors = [:]
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func beginEditing(_ prompt: Prompt) {
        guard !prompt.isBuiltIn else { return }
        editingInferenceSettings = InferenceSettingsDraft(settings: prompt.inferenceSettings)
        editingInferenceValidationErrors = [:]
        editingPrompt = prompt
    }

    public func cancelEditing() {
        editingPrompt = nil
        editingInferenceSettings = InferenceSettingsDraft()
        editingInferenceValidationErrors = [:]
    }

    public func resetNewInferenceSettings() {
        newInferenceSettings = InferenceSettingsDraft()
    }

    public func resetEditingInferenceSettings() {
        editingInferenceSettings = InferenceSettingsDraft()
    }

    public static func compactInferenceSummary(_ settings: PromptInferenceSettings?) -> String? {
        guard let settings = settings?.normalized else { return nil }
        var parts: [String] = []
        if let temperature = settings.temperature {
            parts.append("Temp \(InferenceSettingsDraft.renderNumber(temperature))")
        }
        if let topP = settings.topP {
            parts.append("Top P \(InferenceSettingsDraft.renderNumber(topP))")
        }
        if let topK = settings.topK { parts.append("Top K \(topK)") }
        if let maxTokens = settings.maxTokens { parts.append("Max \(maxTokens)") }
        switch settings.thinkingMode {
        case .providerDefault: break
        case .enabled:
            parts.append("Thinking on")
            if let reasoningEffort = settings.reasoningEffort {
                parts.append("Effort \(displayName(for: reasoningEffort))")
            }
        case .disabled: parts.append("Thinking off")
        }
        return parts.joined(separator: " · ")
    }

    public static func inferenceCompatibilityMessage(
        settings: PromptInferenceSettings?,
        config: LLMProviderConfig
    ) -> String? {
        let unsupported = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: settings
        ).unsupportedSettings
        guard !unsupported.isEmpty else { return nil }
        let names = PromptInferenceSettings.Field.allCases
            .filter { unsupported.contains($0) }
            .map(Self.displayName)
        return "Not supported by this provider/model: \(names.joined(separator: ", "))."
    }

    public func toggleVisibility(_ prompt: Prompt) {
        guard let repo else { return }
        do {
            try repo.toggleVisibility(id: prompt.id)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleAutoRun(_ prompt: Prompt) {
        guard let repo else { return }
        do {
            try repo.toggleAutoRun(id: prompt.id)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Enable/disable auto-run of a result prompt for a single transcription
    /// source (e.g. the Meetings "After each meeting" card scopes `.meeting`),
    /// without affecting whether it auto-runs for other sources.
    public func setAutoRun(_ prompt: Prompt, source: Transcription.SourceType, enabled: Bool) {
        guard let repo else { return }
        do {
            try repo.setAutoRun(id: prompt.id, source: source, enabled: enabled)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func confirmDelete() {
        guard let prompt = pendingDeletePrompt else { return }
        pendingDeletePrompt = nil
        deletePrompt(prompt)
    }

    public func deletePrompt(_ prompt: Prompt) {
        guard let repo, !prompt.isBuiltIn else { return }
        do {
            _ = try repo.delete(id: prompt.id)
            Telemetry.send(.promptDeleted)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreDefaults() {
        guard let repo else { return }
        do {
            try repo.restoreDefaults()
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isUniqueName(
        _ name: String,
        excluding promptID: UUID? = nil,
        repo: PromptRepositoryProtocol
    ) throws -> Bool {
        let allPrompts = try repo.fetchAll()
        return !allPrompts.contains {
            $0.id != promptID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum InferenceDraftValidationResult {
        case valid(PromptInferenceSettings?)
        case invalid(InferenceValidationErrors)
    }

    private static func validateInferenceSettings(
        _ draft: InferenceSettingsDraft
    ) -> InferenceDraftValidationResult {
        var nextErrors: InferenceValidationErrors = [:]
        let temperature = parseDouble(
            draft.temperature,
            field: .temperature,
            range: 0...2,
            message: "Enter a number from 0 to 2.",
            errors: &nextErrors
        )
        let topP = parseDouble(
            draft.topP,
            field: .topP,
            range: 0...1,
            message: "Enter a number from 0 to 1.",
            errors: &nextErrors
        )
        let topK = parseInt(
            draft.topK,
            field: .topK,
            range: 0...1000,
            message: "Enter a whole number from 0 to 1000.",
            errors: &nextErrors
        )
        let maxTokens = parseInt(
            draft.maxTokens,
            field: .maxTokens,
            range: 1...131_072,
            message: "Enter a whole number from 1 to 131072.",
            errors: &nextErrors
        )
        if nextErrors.isEmpty {
            do {
                let settings = PromptInferenceSettings(
                    temperature: temperature,
                    topP: topP,
                    topK: topK,
                    maxTokens: maxTokens,
                    thinkingMode: draft.thinkingMode,
                    reasoningEffort: draft.reasoningEffort
                )
                let validated = try settings.validated()
                return .valid(validated)
            } catch let error as PromptInferenceSettings.ValidationError {
                switch error {
                case .nonFinite(let field), .outOfRange(let field, _, _):
                    nextErrors[field] = validationMessage(for: field)
                }
            } catch {
                return .invalid([.thinkingMode: error.localizedDescription])
            }
        }

        return .invalid(nextErrors)
    }

    private static func parseDouble(
        _ rawValue: String,
        field: PromptInferenceSettings.Field,
        range: ClosedRange<Double>,
        message: String,
        errors: inout InferenceValidationErrors
    ) -> Double? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let parsed = Double(value), parsed.isFinite, range.contains(parsed) else {
            errors[field] = message
            return nil
        }
        return parsed
    }

    private static func parseInt(
        _ rawValue: String,
        field: PromptInferenceSettings.Field,
        range: ClosedRange<Int>?,
        message: String,
        errors: inout InferenceValidationErrors
    ) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let parsed = Int(value), range?.contains(parsed) ?? true else {
            errors[field] = message
            return nil
        }
        return parsed
    }

    private static func validationMessage(for field: PromptInferenceSettings.Field) -> String {
        switch field {
        case .temperature: return "Enter a number from 0 to 2."
        case .topP: return "Enter a number from 0 to 1."
        case .topK: return "Enter a whole number from 0 to 1000."
        case .maxTokens: return "Enter a whole number from 1 to 131072."
        case .thinkingMode: return "Choose a valid thinking mode."
        case .reasoningEffort: return "Choose a valid reasoning effort."
        }
    }

    nonisolated private static func displayName(for field: PromptInferenceSettings.Field) -> String {
        switch field {
        case .temperature: return "Temperature"
        case .topP: return "Top P"
        case .topK: return "Top K"
        case .maxTokens: return "Maximum output tokens"
        case .thinkingMode: return "Thinking"
        case .reasoningEffort: return "Reasoning effort"
        }
    }

    nonisolated public static func displayName(
        for effort: PromptInferenceSettings.ReasoningEffort
    ) -> String {
        switch effort {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        }
    }

    private func resetValidationError() {
        errorMessage = nil
    }
}
