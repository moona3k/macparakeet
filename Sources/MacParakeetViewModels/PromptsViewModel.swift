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

        var unvalidatedSettings: PromptInferenceSettings? {
            PromptInferenceSettings(
                temperature: Self.parseUnvalidatedDouble(temperature),
                topP: Self.parseUnvalidatedDouble(topP),
                topK: Self.parseUnvalidatedInt(topK),
                maxTokens: Self.parseUnvalidatedInt(maxTokens),
                thinkingMode: thinkingMode,
                reasoningEffort: reasoningEffort
            ).normalized
        }

        nonisolated public static func renderNumber(_ value: Double) -> String {
            var rendered = String(value)
            if rendered.hasSuffix(".0") {
                rendered.removeLast(2)
            }
            return rendered
        }

        public func hasExplicitValue(for field: PromptInferenceSettings.Field) -> Bool {
            switch field {
            case .temperature:
                return !temperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .topP:
                return !topP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .topK:
                return !topK.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .maxTokens:
                return !maxTokens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinkingMode:
                return thinkingMode != .providerDefault
            case .reasoningEffort:
                return reasoningEffort != nil
            }
        }

        public mutating func clearField(_ field: PromptInferenceSettings.Field) {
            switch field {
            case .temperature: temperature = ""
            case .topP: topP = ""
            case .topK: topK = ""
            case .maxTokens: maxTokens = ""
            case .thinkingMode:
                thinkingMode = .providerDefault
                reasoningEffort = nil
            case .reasoningEffort:
                reasoningEffort = nil
            }
        }

        private static func parseUnvalidatedDouble(_ rawValue: String) -> Double? {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let parsed = Double(value), parsed.isFinite else { return nil }
            return parsed
        }

        private static func parseUnvalidatedInt(_ rawValue: String) -> Int? {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return Int(value)
        }
    }

    /// Editor intent for the prompt model chooser. Independent of the stored
    /// override string so choosing Custom does not require writing a model ID,
    /// and Use AI settings can clear an override without losing the next Custom
    /// interaction.
    public struct GenerationModelSelection: Equatable, Sendable {
        public enum Source: Equatable, Sendable, Hashable {
            case useAISettings
            case custom
        }

        public var source: Source
        public var prefersCustomModelID: Bool

        public init(source: Source = .useAISettings, prefersCustomModelID: Bool = false) {
            self.source = source
            self.prefersCustomModelID = prefersCustomModelID
        }

        public init(modelOverride: String, availableModels: [String]) {
            let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if override.isEmpty {
                source = .useAISettings
                prefersCustomModelID = false
            } else {
                source = .custom
                prefersCustomModelID = !availableModels.contains(override)
            }
        }

        public var showsCustomControls: Bool { source == .custom }

        public func showsCustomIDField(availableModels: [String]) -> Bool {
            source == .custom && (prefersCustomModelID || availableModels.isEmpty)
        }

        public func showsModelList(availableModels: [String]) -> Bool {
            source == .custom && !prefersCustomModelID && !availableModels.isEmpty
        }

        public mutating func selectUseAISettings() {
            source = .useAISettings
            prefersCustomModelID = false
        }

        public mutating func selectCustom(availableModels: [String]) {
            source = .custom
            prefersCustomModelID = availableModels.isEmpty
        }

        public mutating func chooseFromList() {
            source = .custom
            prefersCustomModelID = false
        }

        public mutating func useCustomModelID() {
            source = .custom
            prefersCustomModelID = true
        }

        public mutating func reset() {
            selectUseAISettings()
        }

        /// Updates list-versus-ID presentation from a saved or typed override
        /// without snapping Custom back to Use AI settings when the override
        /// is still empty.
        public mutating func reconcile(modelOverride: String, availableModels: [String]) {
            let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if source == .useAISettings {
                if !override.isEmpty {
                    source = .custom
                    prefersCustomModelID = !availableModels.contains(override)
                }
                return
            }
            if !override.isEmpty, !availableModels.contains(override) {
                prefersCustomModelID = true
            }
        }
    }

    public typealias InferenceValidationErrors = [PromptInferenceSettings.Field: String]

    public var prompts: [Prompt] = []
    public private(set) var managedPrompts: [Prompt] = []
    public private(set) var deletedPrompts: [Prompt] = []
    public private(set) var collections: [PromptCollection] = []
    public private(set) var promptVersions: [PromptVersion] = []
    public private(set) var availableLabels: [MeetingLabel] = []
    public private(set) var labelIDsByPromptID: [UUID: Set<UUID>] = [:]
    /// The configured AI provider and model shown by prompt-level generation
    /// settings. Keep the configuration itself private because it can carry an
    /// API key; views only need this display-safe projection.
    public private(set) var generationProviderID: LLMProviderID?
    public private(set) var generationModelName = ""
    public private(set) var generationAvailableModels: [String] = []
    public var newName: String = "" {
        didSet { resetValidationError() }
    }
    public var newContent: String = "" {
        didSet { resetValidationError() }
    }
    public var newIncludeMeetingNotes = false {
        didSet { resetValidationError() }
    }
    public var newModelOverride: String = "" {
        didSet { resetValidationError() }
    }
    public var newCollectionID: UUID?
    public var newTargetLabelIDs: Set<UUID> = []
    public var newPromptCategory: Prompt.Category = .result
    public var newCollectionName = ""
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
    public var editingIncludeMeetingNotes = false {
        didSet { resetValidationError() }
    }
    public var editingModelOverride: String = "" {
        didSet { resetValidationError() }
    }
    public var editingCollectionID: UUID?
    public var editingTargetLabelIDs: Set<UUID> = []
    private var originalEditingTargetLabelIDs: Set<UUID> = []
    private var editingTargetingWasExplicitlyChanged = false
    private var customTargetingPromptIDs: Set<UUID> = []

    public var editingHasCustomTargetingRules: Bool {
        guard let prompt = editingPrompt else { return false }
        return hasCustomTargetingRules(for: prompt)
            && !editingTargetingWasExplicitlyChanged
            && editingTargetLabelIDs == originalEditingTargetLabelIDs
    }

    public func hasCustomTargetingRules(for prompt: Prompt) -> Bool {
        customTargetingPromptIDs.contains(prompt.id)
    }

    /// Choosing All must clear custom policies even when their projection is empty.
    public func setEditingTargetLabels(_ labels: Set<UUID>) {
        editingTargetLabelIDs = labels
        editingTargetingWasExplicitlyChanged = true
    }
    public private(set) var newInferenceValidationErrors: InferenceValidationErrors = [:]
    public private(set) var editingInferenceValidationErrors: InferenceValidationErrors = [:]
    public var errorMessage: String?
    /// Rebuild live Transform hotkeys after a successful manager mutation.
    public var onTransformsChanged: (() -> Void)?
    public var pendingDeletePrompt: Prompt?
    public var editingPrompt: Prompt?

    private var repo: PromptRepositoryProtocol?
    private var versionRepo: PromptVersionRepositoryProtocol?
    private var collectionRepo: PromptCollectionRepositoryProtocol?
    private var editingService: PromptEditingServiceProtocol?
    private var labelRepository: MeetingLabelRepositoryProtocol?
    private var labelPolicyRepository: PromptLabelPolicyRepositoryProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?
    private var generationConfig: LLMProviderConfig?
    private var generationConfigLoadTask: Task<Void, Never>?
    private var generationModelListTask: Task<Void, Never>?
    private var generationContextRevision = 0

    public init() {}

    public func configure(
        repo: PromptRepositoryProtocol,
        versionRepo: PromptVersionRepositoryProtocol? = nil,
        collectionRepo: PromptCollectionRepositoryProtocol? = nil,
        editingService: PromptEditingServiceProtocol? = nil,
        labelRepository: MeetingLabelRepositoryProtocol? = nil,
        labelPolicyRepository: PromptLabelPolicyRepositoryProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil,
        llmClient: LLMClientProtocol? = nil
    ) {
        self.repo = repo
        self.versionRepo = versionRepo
        self.collectionRepo = collectionRepo
        self.editingService = editingService
        self.labelRepository = labelRepository
        self.labelPolicyRepository = labelPolicyRepository
        self.configStore = configStore
        self.llmClient = llmClient
        loadPrompts()
        loadDeletedPrompts()
        loadCollections()
        loadLabels()
        refreshGenerationSettingsContext()
    }

    public func loadPrompts() {
        guard let repo else { return }
        do {
            managedPrompts = try repo.fetchAll()
            prompts = managedPrompts.filter { $0.category == .result }
            errorMessage = nil
            loadPromptLabelPolicies()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refresh() {
        loadPrompts()
        loadDeletedPrompts()
        loadCollections()
        loadLabels()
        refreshGenerationSettingsContext()
    }

    /// Refreshes the display-safe provider/model context used by prompt-level
    /// settings. Configuration access is kept off the main actor; the existing
    /// model-list helper owns network work and its configuration staleness
    /// guard.
    public func refreshGenerationSettingsContext() {
        generationConfigLoadTask?.cancel()
        generationModelListTask?.cancel()
        generationContextRevision += 1
        let revision = generationContextRevision

        guard let configStore else {
            applyGenerationSettingsConfig(nil, revision: revision)
            return
        }

        let llmClient = self.llmClient
        generationConfigLoadTask = Task { [weak self, configStore] in
            let config = await Task.detached(priority: .utility) {
                try? configStore.loadConfig()
            }.value
            guard !Task.isCancelled else { return }
            self?.applyGenerationSettingsConfig(
                config,
                llmClient: llmClient,
                revision: revision
            )
        }
    }

    private func applyGenerationSettingsConfig(
        _ config: LLMProviderConfig?,
        llmClient: LLMClientProtocol? = nil,
        revision: Int
    ) {
        guard revision == generationContextRevision else { return }
        generationConfig = config
        generationProviderID = config?.id
        generationModelName = config?.modelName ?? ""

        guard let config else {
            generationAvailableModels = []
            return
        }

        generationAvailableModels = LLMModelAvailability.pickerModels(
            for: config,
            discoveredModels: []
        )
        generationModelListTask = LLMModelAvailability.refreshPickerModelsTask(
            for: config,
            llmClient: llmClient,
            configStore: configStore
        ) { [weak self] models in
            guard self?.generationContextRevision == revision else { return }
            self?.generationAvailableModels = models
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
        switch validateInferenceSettings(newInferenceSettings, modelOverride: newModelOverride) {
        case .valid(let settings):
            inferenceSettings = settings
            newInferenceValidationErrors = [:]
        case .invalid(let errors):
            newInferenceValidationErrors = errors
            return
        }

        let nextSortOrder = (managedPrompts.map(\.sortOrder).max() ?? 0) + 1
        let prompt = Prompt(
            name: trimmedName,
            content: trimmedContent,
            category: newPromptCategory,
            isBuiltIn: false,
            isVisible: true,
            sortOrder: nextSortOrder,
            inferenceSettings: inferenceSettings,
            includeMeetingNotes: newIncludeMeetingNotes,
            modelOverride: normalizedOptional(newModelOverride),
            collectionId: newCollectionID
        )

        do {
            let targetLabels: Set<UUID>? =
                prompt.category == .result && !newTargetLabelIDs.isEmpty ? newTargetLabelIDs : nil
            if let editingService {
                _ = try editingService.save(prompt, targetLabelIDs: targetLabels)
            } else {
                guard targetLabels == nil else {
                    errorMessage = "Prompt editing is unavailable. Your draft has not been saved."
                    return
                }
                try repo.save(prompt)
            }
            if prompt.category == .transform { onTransformsChanged?() }
            Telemetry.send(.promptCreated)
            newName = ""
            newContent = ""
            newIncludeMeetingNotes = false
            newModelOverride = ""
            newCollectionID = nil
            newTargetLabelIDs = []
            newPromptCategory = .result
            newInferenceSettings = InferenceSettingsDraft()
            newInferenceValidationErrors = [:]
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updatePrompt(_ prompt: Prompt, name: String, content: String) {
        guard let repo else { return }
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
        let ownsEditingState = editingPrompt?.id == prompt.id
        let inferenceDraft =
            ownsEditingState
            ? editingInferenceSettings
            : InferenceSettingsDraft(settings: prompt.inferenceSettings)
        let inferenceSettings: PromptInferenceSettings?
        let modelOverrideForValidation =
            ownsEditingState ? editingModelOverride : (prompt.modelOverride ?? "")
        switch validateInferenceSettings(inferenceDraft, modelOverride: modelOverrideForValidation) {
        case .valid(let settings):
            inferenceSettings = settings
            if ownsEditingState { editingInferenceValidationErrors = [:] }
        case .invalid(let errors):
            if ownsEditingState {
                editingInferenceValidationErrors = errors
            } else {
                errorMessage = "Open this prompt to correct its inference settings before saving changes."
            }
            return
        }

        var updated = prompt
        updated.name = trimmedName
        updated.content = trimmedContent
        updated.includeMeetingNotes =
            editingPrompt?.id == prompt.id
            ? editingIncludeMeetingNotes
            : prompt.includeMeetingNotes
        updated.inferenceSettings = inferenceSettings
        updated.modelOverride =
            editingPrompt?.id == prompt.id
            ? normalizedOptional(editingModelOverride)
            : prompt.modelOverride
        updated.collectionId = editingPrompt?.id == prompt.id ? editingCollectionID : prompt.collectionId
        updated.updatedAt = Date()

        do {
            // Preserve detailed policies unless the editor changes targeting.
            // Metadata, version and targeting must commit together.
            let targetLabels: Set<UUID>? =
                updated.category == .result && ownsEditingState
                    && (editingTargetingWasExplicitlyChanged
                        || editingTargetLabelIDs != originalEditingTargetLabelIDs)
                ? editingTargetLabelIDs : nil
            if let editingService {
                _ = try editingService.save(updated, targetLabelIDs: targetLabels)
            } else {
                guard targetLabels == nil else {
                    errorMessage = "Prompt editing is unavailable. Your changes have not been saved."
                    return
                }
                try repo.save(updated)
            }
            if updated.category == .transform { onTransformsChanged?() }
            Telemetry.send(.promptUpdated)
            editingPrompt = nil
            editingIncludeMeetingNotes = false
            editingInferenceSettings = InferenceSettingsDraft()
            editingModelOverride = ""
            editingCollectionID = nil
            editingTargetLabelIDs = []
            editingInferenceValidationErrors = [:]
            promptVersions = []
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func beginEditing(_ prompt: Prompt) {
        refreshGenerationSettingsContext()
        editingIncludeMeetingNotes = prompt.includeMeetingNotes
        editingInferenceSettings = InferenceSettingsDraft(settings: prompt.inferenceSettings)
        editingModelOverride = prompt.modelOverride ?? ""
        editingCollectionID = prompt.collectionId
        editingTargetLabelIDs = labelIDsByPromptID[prompt.id] ?? []
        originalEditingTargetLabelIDs = editingTargetLabelIDs
        editingTargetingWasExplicitlyChanged = false
        editingInferenceValidationErrors = [:]
        editingPrompt = prompt
        loadVersions(for: prompt.id)
    }

    public func cancelEditing() {
        editingTargetingWasExplicitlyChanged = false
        editingPrompt = nil
        editingIncludeMeetingNotes = false
        editingInferenceSettings = InferenceSettingsDraft()
        editingModelOverride = ""
        editingCollectionID = nil
        editingTargetLabelIDs = []
        editingInferenceValidationErrors = [:]
        promptVersions = []
    }

    public func hasEditingChanges(prompt: Prompt, name: String, content: String) -> Bool {
        name != prompt.name
            || content != prompt.content
            || editingInferenceSettings != InferenceSettingsDraft(settings: prompt.inferenceSettings)
            || editingIncludeMeetingNotes != prompt.includeMeetingNotes
            || normalizedOptional(editingModelOverride) != prompt.modelOverride
            || editingCollectionID != prompt.collectionId
            || editingTargetingWasExplicitlyChanged
            || editingTargetLabelIDs != (labelIDsByPromptID[prompt.id] ?? [])
    }

    @discardableResult
    public func restoreVersion(_ version: PromptVersion) -> Prompt? {
        guard let prompt = editingPrompt, let repo, let editingService else { return nil }
        do {
            _ = try editingService.restore(promptId: prompt.id, versionId: version.id, changeNote: nil)
            if prompt.category == .transform { onTransformsChanged?() }
            loadPrompts()
            guard let restored = try repo.fetch(id: prompt.id) else { return nil }
            editingPrompt = restored
            editingInferenceSettings = InferenceSettingsDraft(settings: restored.inferenceSettings)
            editingModelOverride = restored.modelOverride ?? ""
            loadVersions(for: prompt.id)
            errorMessage = nil
            return restored
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func resetNewInferenceSettings() {
        newInferenceSettings = InferenceSettingsDraft()
    }

    public func resetEditingInferenceSettings() {
        editingInferenceSettings = InferenceSettingsDraft()
    }

    public static func hasCustomGenerationSettings(
        draft: InferenceSettingsDraft,
        modelOverride: String
    ) -> Bool {
        !draft.isDefault || !modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Presentation metadata for the current draft. Invalid numeric text is
    /// omitted from `requestedSettings` but field availability still comes from
    /// the saved provider and effective model. The saved configuration stays
    /// private so API keys never reach the editor.
    public func generationSettingsPresentation(
        draft: InferenceSettingsDraft,
        modelOverride: String
    ) -> PromptInferencePresentation? {
        guard let config = generationConfig else { return nil }
        return PromptInferenceCapabilityResolver.presentation(
            config: config,
            modelOverride: normalizedOptional(modelOverride),
            requested: draft.unvalidatedSettings
        )
    }

    public func generationSettingsCollapsedSummary(
        draft: InferenceSettingsDraft,
        modelOverride: String
    ) -> String? {
        var parts: [String] = []
        if let providerID = generationProviderID {
            parts.append(providerID.displayName)
        }
        let override = normalizedOptional(modelOverride)
        if let override {
            parts.append(override)
        } else if !generationModelName.isEmpty {
            parts.append(generationModelName)
        }
        if let draftSummary = Self.compactInferenceDraftSummary(draft) {
            parts.append(draftSummary)
        } else if let requested = draft.unvalidatedSettings {
            parts.append(contentsOf: Self.compactRequestedParts(requested))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    public static func compactInferenceDraftSummary(_ draft: InferenceSettingsDraft) -> String? {
        guard case .valid(let settings) = validateInferenceSettings(draft) else { return nil }
        return compactInferenceSummary(settings)
    }

    public static func inferenceCompatibilityMessage(
        settings: PromptInferenceSettings?,
        config: LLMProviderConfig,
        modelOverride: String? = nil
    ) -> String? {
        switch config.resolvingModelOverride(modelOverride) {
        case .invalid(_, let reason):
            return "This prompt's model isn't available with \(config.id.displayName): \(reason)"
        case .resolved(let effectiveConfig):
            do {
                let unsupported = try PromptInferenceCapabilityResolver.resolve(
                    config: effectiveConfig,
                    requested: settings
                ).unsupportedSettings
                guard !unsupported.isEmpty else { return nil }
                let names = PromptInferenceSettings.Field.allCases
                    .filter { unsupported.contains($0) }
                    .map(Self.displayName)
                return "Not applied with this provider/model and setting combination: \(names.joined(separator: ", "))."
            } catch {
                return "Cannot generate with this provider/model: \(error.localizedDescription)"
            }
        }
    }

    public func toggleVisibility(_ prompt: Prompt) {
        guard let repo else { return }
        do {
            try repo.toggleVisibility(id: prompt.id)
            if prompt.category == .transform { onTransformsChanged?() }
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

    public func setIncludeMeetingNotes(_ prompt: Prompt, enabled: Bool) {
        guard let repo, prompt.category == .result else { return }
        do {
            try repo.setIncludeMeetingNotes(id: prompt.id, enabled: enabled)
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
        guard let repo else { return }
        do {
            let deleted = try repo.delete(id: prompt.id)
            if deleted, prompt.category == .transform { onTransformsChanged?() }
            Telemetry.send(.promptDeleted)
            errorMessage = nil
            loadPrompts()
            loadDeletedPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreDeletedPrompt(_ prompt: Prompt) {
        guard let editingService else { return }
        do {
            let restored = try editingService.restoreDeleted(id: prompt.id)
            if restored, prompt.category == .transform { onTransformsChanged?() }
            loadPrompts()
            loadDeletedPrompts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createCollection() {
        guard let collectionRepo else { return }
        let name = normalized(newCollectionName)
        guard !name.isEmpty else {
            errorMessage = "Collection name is required."
            return
        }
        do {
            try collectionRepo.save(
                PromptCollection(
                    name: name,
                    sortOrder: (collections.map(\.sortOrder).max() ?? -1) + 1
                )
            )
            newCollectionName = ""
            loadCollections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func renameCollection(_ collection: PromptCollection, name: String) {
        guard let collectionRepo else { return }
        var updated = collection
        updated.name = name
        do {
            try collectionRepo.save(updated)
            loadCollections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteCollection(_ collection: PromptCollection) {
        guard let collectionRepo else { return }
        do {
            _ = try collectionRepo.delete(id: collection.id)
            loadCollections()
            loadPrompts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func moveCollection(_ collection: PromptCollection, by offset: Int) {
        guard let collectionRepo,
            let sourceIndex = collections.firstIndex(where: { $0.id == collection.id })
        else { return }
        let destinationIndex = sourceIndex + offset
        guard collections.indices.contains(destinationIndex) else { return }
        var ids = collections.map(\.id)
        ids.swapAt(sourceIndex, destinationIndex)
        do {
            try collectionRepo.reorder(ids: ids)
            loadCollections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreDefaults() {
        guard let repo else { return }
        do {
            try repo.restoreDefaults()
            onTransformsChanged?()
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func targetLabels(for prompt: Prompt) -> [MeetingLabel] {
        let ids = labelIDsByPromptID[prompt.id] ?? []
        return availableLabels.filter { ids.contains($0.id) }
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

    private func loadVersions(for promptID: UUID) {
        guard let versionRepo else {
            promptVersions = []
            return
        }
        do {
            promptVersions = try versionRepo.fetchAll(promptId: promptID)
        } catch {
            promptVersions = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadCollections() {
        guard let collectionRepo else {
            collections = []
            return
        }
        do {
            collections = try collectionRepo.fetchAll()
        } catch {
            collections = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadLabels() {
        guard let labelRepository else {
            availableLabels = []
            return
        }
        do {
            availableLabels = try labelRepository.fetchAll(includeArchived: true)
        } catch {
            availableLabels = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadPromptLabelPolicies() {
        guard let labelPolicyRepository else {
            labelIDsByPromptID = [:]
            customTargetingPromptIDs = []
            return
        }
        do {
            let policies = try labelPolicyRepository.fetchPolicies(promptIds: Set(prompts.map(\.id)))
            let grouped = Dictionary(grouping: policies, by: \.promptId)
            customTargetingPromptIDs = Set(
                grouped.compactMap { promptID, rules in
                    let fallbacks = rules.filter { $0.scopeKind == .all }
                    let labels = rules.filter { $0.scopeKind == .label }
                    let representsAll = rules.count == 1 && fallbacks.first?.isAvailable == true
                    let representsSelectedLabels =
                        fallbacks.count == 1
                        && fallbacks.first?.isAvailable == false && !labels.isEmpty
                        && labels.allSatisfy { $0.isAvailable && $0.labelId != nil }
                    return representsAll || representsSelectedLabels ? nil : promptID
                })
            labelIDsByPromptID = grouped.reduce(into: [:]) { result, entry in
                let hasRestrictedFallback = entry.value.contains {
                    $0.scopeKind == .all && !$0.isAvailable
                }
                guard hasRestrictedFallback else {
                    result[entry.key] = []
                    return
                }
                result[entry.key] = Set(
                    entry.value.compactMap {
                        $0.scopeKind == .label && $0.isAvailable ? $0.labelId : nil
                    })
            }
        } catch {
            labelIDsByPromptID = [:]
            customTargetingPromptIDs = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadDeletedPrompts() {
        guard let repo else {
            deletedPrompts = []
            return
        }
        do {
            deletedPrompts = try repo.fetchDeleted()
        } catch {
            deletedPrompts = []
            errorMessage = error.localizedDescription
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptional(_ value: String) -> String? {
        let value = normalized(value)
        return value.isEmpty ? nil : value
    }

    private enum InferenceDraftValidationResult {
        case valid(PromptInferenceSettings?)
        case invalid(InferenceValidationErrors)
    }

    private func validateInferenceSettings(
        _ draft: InferenceSettingsDraft,
        modelOverride: String
    ) -> InferenceDraftValidationResult {
        switch Self.validateInferenceSettings(draft) {
        case .invalid(let errors):
            return .invalid(errors)
        case .valid(let settings):
            guard let config = generationConfig else {
                return .valid(settings)
            }
            let presentation = PromptInferenceCapabilityResolver.presentation(
                config: config,
                modelOverride: normalizedOptional(modelOverride),
                requested: settings
            )
            guard let error = presentation.validationError else {
                return .valid(settings)
            }
            return .invalid(Self.fieldErrors(from: error))
        }
    }

    private static func fieldErrors(
        from error: PromptInferenceSettings.ValidationError
    ) -> InferenceValidationErrors {
        switch error {
        case .outOfRange(let field, let minimum, let maximum):
            return [field: rangeValidationMessage(for: field, minimum: minimum, maximum: maximum)]
        case .nonFinite(let field):
            return [field: validationMessage(for: field)]
        case .unsupportedPromptCategory:
            return [:]
        }
    }

    private static func rangeValidationMessage(
        for field: PromptInferenceSettings.Field,
        minimum: Double,
        maximum: Double
    ) -> String {
        switch field {
        case .temperature, .topP:
            return
                "Enter a number from \(InferenceSettingsDraft.renderNumber(minimum)) to \(InferenceSettingsDraft.renderNumber(maximum))."
        case .topK, .maxTokens:
            return "Enter a whole number from \(Int(minimum)) to \(Int(maximum))."
        case .thinkingMode, .reasoningEffort:
            return validationMessage(for: field)
        }
    }

    private static func compactRequestedParts(_ settings: PromptInferenceSettings) -> [String] {
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
        case .enabled: parts.append("Thinking on")
        case .disabled: parts.append("Thinking off")
        }
        return parts
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
            return .valid(
                PromptInferenceSettings(
                    temperature: temperature,
                    topP: topP,
                    topK: topK,
                    maxTokens: maxTokens,
                    thinkingMode: draft.thinkingMode,
                    reasoningEffort: draft.reasoningEffort
                ).normalized)
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

    nonisolated public static func displayName(for field: PromptInferenceSettings.Field) -> String {
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
        for mode: PromptInferenceSettings.ThinkingMode
    ) -> String {
        switch mode {
        case .providerDefault: return "Automatic"
        case .enabled: return "On"
        case .disabled: return "Off"
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
