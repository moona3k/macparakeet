import MacParakeetCore
import SwiftUI

/// Connection settings for the online speech engine: any server that speaks
/// the OpenAI `audio/transcriptions` API.
struct CloudSpeechServiceCard: View {
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var realtimeModel = ""
    @State private var catalogState = CloudSpeechCatalogState()
    private var catalog: CloudSTTModelCatalog { catalogState.catalog }
    private var isLoadingModels: Bool { catalogState.isLoading }
    private var modelListNote: String? { catalogState.note }
    @State private var savedMessage: String?
    @State private var errorMessage: String?
    @State private var hasSavedKey = false
    @State private var isTesting = false

    private let store = CloudSTTConfigStore()

    private var draft: CloudSTTConfig {
        CloudSTTConfig(baseURL: baseURL, model: model, apiKey: apiKey, realtimeModel: realtimeModel)
    }

    var body: some View {
        SettingsCard(
            title: "Online Speech Service",
            subtitle:
                "Use an online model for transcription through any OpenAI-compatible server, such as OpenAI or Groq.",
            icon: "cloud",
            status: store.isConfigured
                ? SettingsCardStatus(.ok, label: "Set up") : nil
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Label(
                    "When this engine is selected, your audio is uploaded to this service. Every other engine keeps audio on this Mac.",
                    systemImage: "exclamationmark.shield"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .fixedSize(horizontal: false, vertical: true)

                field("Server address") {
                    TextField(CloudSTTConfig.defaultBaseURL, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field("Model") {
                    modelPicker(selection: $model, choices: catalog.fileModels, allowsNone: false)
                }
                field("Realtime model (optional)") {
                    modelPicker(selection: $realtimeModel, choices: catalog.realtimeModels, allowsNone: true)
                }
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button(isLoadingModels ? "Loading…" : "Load Models from Server") { loadModels() }
                        .parakeetAction(.secondary)
                        .controlSize(.small)
                        .disabled(isLoadingModels)
                    Text(
                        modelListNote
                            ?? (catalog.isFromServer
                                ? "Showing this server's speech models." : "Showing common models.")
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "With a realtime model, dictation shows text while you speak by streaming the microphone to the service. The final text still comes from the model above, so both are billed. Leave empty to transcribe only after you stop."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                field("API key") {
                    SecureField(
                        hasSavedKey ? "Leave empty to keep the key for the same server" : "Stored in your Keychain",
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    if hasSavedKey {
                        Button("Clear saved key") {
                            do {
                                try store.clearAPIKey()
                                hasSavedKey = false
                                apiKey = ""
                                errorMessage = nil
                            } catch {
                                errorMessage = "Could not clear the saved key: \(error.localizedDescription)"
                            }
                        }
                        .parakeetAction(.secondary)
                        .disabled(isTesting || isLoadingModels)
                    }
                }

                Text(
                    "Whisper-family models (for example whisper-1, or whisper-large-v3 on Groq at https://api.groq.com/openai/v1) can supply word timings for the final transcript and speaker labels. Other models give a plain-text transcript. Online speech does not support the live meeting preview."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DesignSystem.Spacing.md) {
                    Button("Save") { save() }
                        .parakeetAction(.primary)
                        .disabled(!draft.isUsable || isTesting)
                    Button(isTesting ? "Testing…" : "Save & Test") { saveAndTest() }
                        .parakeetAction(.secondary)
                        .disabled(!draft.isUsable || isTesting)
                        .help(
                            "Saves, then sends one second of silence to the service to check the address, model, and key."
                        )
                    if let savedMessage {
                        Label(savedMessage, systemImage: "checkmark")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.errorRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: draft.normalizedEndpoint) { _, endpoint in
            catalogState.endpointChanged(endpoint)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.caption.weight(.semibold))
            content()
                .frame(maxWidth: 460)
        }
    }

    /// A dropdown of known models beside a text field, so any other model name
    /// can still be typed by hand.
    private func modelPicker(selection: Binding<String>, choices: [String], allowsNone: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField(allowsNone ? "None" : CloudSTTConfig.defaultModel, text: selection)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Menu {
                if allowsNone {
                    Button("None") { selection.wrappedValue = "" }
                    Divider()
                }
                ForEach(choices, id: \.self) { choice in
                    Button {
                        selection.wrappedValue = choice
                    } label: {
                        if selection.wrappedValue == choice {
                            Label(choice, systemImage: "checkmark")
                        } else {
                            Text(choice)
                        }
                    }
                }
                if choices.isEmpty {
                    Text("No matching models on this server")
                }
            } label: {
                Text("Choose")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
        }
    }

    /// Fetches the server's model list using the key in the field, or the
    /// saved key for the same endpoint when empty. Keeps the list on failure.
    private func loadModels() {
        let requested = draft
        let request = catalogState.beginRequest(endpoint: requested.normalizedEndpoint)
        Task {
            let result: Result<CloudSTTModelCatalog, Error>
            do {
                let config = try store.resolvingSavedAPIKey(for: requested)
                result = .success(try await CloudSTTModelCatalog.load(config: config))
            } catch {
                result = .failure(error)
            }
            // Recheck the live draft as well as the request generation: SwiftUI
            // may not have delivered the endpoint's onChange callback yet.
            catalogState.endpointChanged(draft.normalizedEndpoint)
            catalogState.finish(request, result: result)
        }
    }

    private func load() {
        let metadata = store.loadMetadata()
        baseURL = metadata.baseURL
        model = metadata.model
        realtimeModel = metadata.realtimeModel
        // The saved key is not read back into the field; leaving the field
        // empty on save keeps it only while the endpoint is unchanged.
        apiKey = ""
        hasSavedKey = store.hasAPIKey
        if hasSavedKey, store.isConfigured { loadModels() }
    }

    /// Saves, then sends one second of silence so the service itself reports
    /// whether the address, model, and key work.
    private func saveAndTest() {
        save()
        guard errorMessage == nil else { return }
        savedMessage = nil
        isTesting = true
        Task {
            let engine = CloudTranscribeEngine(
                configStore: store,
                loadSamples: { _ in [Float](repeating: 0, count: 16_000) }
            )
            do {
                _ = try await engine.transcribe(
                    audioURL: URL(fileURLWithPath: "/dev/null"), job: .fileTranscription, language: nil)
                savedMessage = "Saved — the service accepted the request"
            } catch {
                errorMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func save() {
        savedMessage = nil
        errorMessage = nil
        do {
            let config = try store.resolvingSavedAPIKey(for: draft)
            try store.save(config)
            apiKey = ""
            hasSavedKey = store.hasAPIKey
            savedMessage = hasSavedKey ? "Saved — key stored in Keychain" : "Saved (no API key)"
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Endpoint-scoped request state shared by the view's success and error paths.
struct CloudSpeechCatalogState {
    struct Request {
        fileprivate let generation: Int
        fileprivate let endpoint: String?
    }

    private(set) var catalog = CloudSTTModelCatalog.fallback
    private(set) var isLoading = false
    private(set) var note: String?
    private var endpoint: String?
    private var generation = 0

    mutating func endpointChanged(_ endpoint: String?) {
        guard self.endpoint != endpoint else { return }
        self.endpoint = endpoint
        generation += 1
        catalog = .fallback
        note = nil
        isLoading = false
    }

    mutating func beginRequest(endpoint: String?) -> Request {
        endpointChanged(endpoint)
        generation += 1
        isLoading = true
        note = nil
        return Request(generation: generation, endpoint: endpoint)
    }

    mutating func finish(_ request: Request, result: Result<CloudSTTModelCatalog, Error>) {
        guard request.generation == generation, request.endpoint == endpoint else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            if loaded.fileModels.isEmpty && loaded.realtimeModels.isEmpty {
                catalog = .fallback
                note = "The server listed no speech models. Showing common models; you can also type a name."
            } else {
                catalog = loaded
            }
        case .failure(let error):
            note = "Could not load the list: \(error.localizedDescription) You can still type a model name."
        }
    }
}
