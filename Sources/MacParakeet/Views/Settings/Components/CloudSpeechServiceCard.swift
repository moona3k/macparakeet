import MacParakeetCore
import SwiftUI

/// Connection settings for the online speech engine: any server that speaks
/// the OpenAI `audio/transcriptions` API.
struct CloudSpeechServiceCard: View {
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var savedMessage: String?
    @State private var errorMessage: String?

    private let store = CloudSTTConfigStore()

    private var draft: CloudSTTConfig {
        CloudSTTConfig(baseURL: baseURL, model: model, apiKey: apiKey)
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
                    TextField(CloudSTTConfig.defaultModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field("API key") {
                    SecureField("Stored in your Keychain", text: $apiKey)
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
                        .disabled(!draft.isUsable)
                    if let savedMessage {
                        Label(savedMessage, systemImage: "checkmark")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.errorRed)
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

    private func load() {
        let metadata = store.loadMetadata()
        baseURL = metadata.baseURL
        model = metadata.model
        // The saved key is not read back into the field; leaving the field
        // empty on save keeps whatever is already stored.
        apiKey = ""
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
            savedMessage = "Saved"
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
