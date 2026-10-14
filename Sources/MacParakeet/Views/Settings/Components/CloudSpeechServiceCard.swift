import MacParakeetCore
import SwiftUI

/// Connection settings for the online speech engine: any server that speaks
/// the OpenAI `audio/transcriptions` API.
struct CloudSpeechServiceCard: View {
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var realtimeModel = ""
    @State private var catalog = CloudSTTModelCatalog.fallback
    @State private var isLoadingModels = false
    @State private var modelListNote: String?
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
                        hasSavedKey ? "A key is saved — leave empty to keep it" : "Stored in your Keychain",
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Text(
                    "Whisper-family models (for example whisper-1, or whisper-large-v3 on Groq at https://api.groq.com/openai/v1) return word timings, which speaker labels and the live meeting preview need. Other models give a plain-text transcript."
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
    /// saved key when the field is empty. Keeps the current list on failure.
    private func loadModels() {
        isLoadingModels = true
        modelListNote = nil
        Task {
            do {
                var config = draft
                if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    config.apiKey = try store.load().apiKey
                }
                let loaded = try await CloudSTTModelCatalog.load(config: config)
                if loaded.fileModels.isEmpty && loaded.realtimeModels.isEmpty {
                    modelListNote =
                        "The server listed no speech models. Showing common models; you can also type a name."
                } else {
                    catalog = loaded
                }
            } catch {
                modelListNote =
                    "Could not load the list: \(error.localizedDescription) You can still type a model name."
            }
            isLoadingModels = false
        }
    }

    private func load() {
        let metadata = store.loadMetadata()
        baseURL = metadata.baseURL
        model = metadata.model
        realtimeModel = metadata.realtimeModel
        // The saved key is not read back into the field; leaving the field
        // empty on save keeps whatever is already stored.
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
            var config = draft
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                config.apiKey = try store.load().apiKey
            }
            try store.save(config)
            apiKey = ""
            hasSavedKey = store.hasAPIKey
            savedMessage = hasSavedKey ? "Saved — key stored in Keychain" : "Saved (no API key)"
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
