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
    public private(set) var managedPrompts: [Prompt] = []
    public private(set) var deletedPrompts: [Prompt] = []
    public private(set) var collections: [PromptCollection] = []
    public private(set) var promptVersions: [PromptVersion] = []
    public private(set) var availableLabels: [MeetingLabel] = []
    public private(set) var labelIDsByPromptID: [UUID: Set<UUID>] = [:]
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
    public private(set) var newInferenceValidationErrors: InferenceValidationErrors = [:]
    public private(set) var editingInferenceValidationErrors: InferenceValidationErrors = [:]
    public var errorMessage: String?
    public var pendingDeletePrompt: Prompt?
    public var editingPrompt: Prompt?

    private var repo: PromptRepositoryProtocol?
    private var versionRepo: PromptVersionRepositoryProtocol?
    private var collectionRepo: PromptCollectionRepositoryProtocol?
    private var editingService: PromptEditingServiceProtocol?
    private var labelRepository: MeetingLabelRepositoryProtocol?
    private var labelPolicyRepository: PromptLabelPolicyRepositoryProtocol?

    public init() {}

    public func configure(
        repo: PromptRepositoryProtocol,
        versionRepo: PromptVersionRepositoryProtocol? = nil,
        collectionRepo: PromptCollectionRepositoryProtocol? = nil,
        editingService: PromptEditingServiceProtocol? = nil,
        labelRepository: MeetingLabelRepositoryProtocol? = nil,
        labelPolicyRepository: PromptLabelPolicyRepositoryProtocol? = nil
    ) {
        self.repo = repo
        self.versionRepo = versionRepo
        self.collectionRepo = collectionRepo
        self.editingService = editingService
        self.labelRepository = labelRepository
        self.labelPolicyRepository = labelPolicyRepository
        loadPrompts()
        loadDeletedPrompts()
        loadCollections()
        loadLabels()
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
            try repo.save(prompt)
            if prompt.category == .result {
                try labelPolicyRepository?.replaceTargetLabels(
                    promptId: prompt.id,
                    labelIds: newTargetLabelIDs
                )
            }
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
        switch Self.validateInferenceSettings(inferenceDraft) {
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
            try repo.save(updated)
            // The picker is a simplified projection: migrated policies may
            // contain denials or no fallback. Preserve those exact rules
            // unless this editor actually changes the target selection.
            if updated.category == .result, editingPrompt?.id == prompt.id,
                editingTargetLabelIDs != originalEditingTargetLabelIDs
            {
                try labelPolicyRepository?.replaceTargetLabels(
                    promptId: updated.id,
                    labelIds: editingTargetLabelIDs
                )
            }
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
        editingIncludeMeetingNotes = prompt.includeMeetingNotes
        editingInferenceSettings = InferenceSettingsDraft(settings: prompt.inferenceSettings)
        editingModelOverride = prompt.modelOverride ?? ""
        editingCollectionID = prompt.collectionId
        editingTargetLabelIDs = labelIDsByPromptID[prompt.id] ?? []
        originalEditingTargetLabelIDs = editingTargetLabelIDs
        editingInferenceValidationErrors = [:]
        editingPrompt = prompt
        loadVersions(for: prompt.id)
    }

    public func cancelEditing() {
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
            || editingTargetLabelIDs != (labelIDsByPromptID[prompt.id] ?? [])
    }

    @discardableResult
    public func restoreVersion(_ version: PromptVersion) -> Prompt? {
        guard let prompt = editingPrompt, let repo, let editingService else { return nil }
        do {
            _ = try editingService.restore(promptId: prompt.id, versionId: version.id, changeNote: nil)
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
            _ = try repo.delete(id: prompt.id)
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
            _ = try editingService.restoreDeleted(id: prompt.id)
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
            return
        }
        do {
            let policies = try labelPolicyRepository.fetchPolicies(promptIds: Set(prompts.map(\.id)))
            let grouped = Dictionary(grouping: policies, by: \.promptId)
            labelIDsByPromptID = grouped.reduce(into: [:]) { result, entry in
                let hasRestrictedFallback = entry.value.contains {
                    $0.scopeKind == .all && !$0.isAvailable
                }
                guard hasRestrictedFallback else {
                    result[entry.key] = []
                    return
                }
                result[entry.key] = Set(entry.value.compactMap {
                    $0.scopeKind == .label && $0.isAvailable ? $0.labelId : nil
                })
            }
        } catch {
            labelIDsByPromptID = [:]
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
