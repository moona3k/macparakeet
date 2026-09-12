import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Everything MacParakeet has stored about people's voices, and every way to
/// remove it. Reachable only from the revealed "Remember speakers" block, so a
/// voice store is never advertised to someone who has not asked for one.
struct VoiceProfilesSheet: View {
    @Bindable var viewModel: VoiceProfilesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Renaming?
    @State private var pendingForget: EnrolledVoice?
    @State private var pendingForgetAll = false
    @State private var pendingForgetSelected = false

    private struct Renaming: Identifiable {
        let id: UUID
        var name: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            if let errorMessage = viewModel.errorMessage {
                errorRow(errorMessage)
            }
            content
            footer
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 560, height: 520)
        .background(.thickMaterial)
        // One presenter for the whole sheet: attaching it per row would create
        // as many presentations as there are voices.
        .sheet(item: $renaming) { target in
            renameSheet(target)
        }
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "waveform.badge.person")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Profiles")
                    .font(DesignSystem.Typography.pageTitle)
                Text(headerSubtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .parakeetAction(.secondary)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var headerSubtitle: String {
        let count = viewModel.voices.count
        let noun = count == 1 ? "voice" : "voices"
        return "\(count) \(noun) · stored only on this Mac"
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.voices) { voice in
                        voiceRow(voice)
                    }
                }
            }
        }
    }

    /// An empty state that says how to leave it. A silent one would be a
    /// product bug: nothing else in the app explains where voices come from.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("No voices saved yet")
                .font(DesignSystem.Typography.body.weight(.semibold))
            Text(
                "Rename a speaker in a meeting transcript, then choose \"Remember\" when MacParakeet offers. Saved voices are suggested in later meetings, and never applied without your confirmation."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func voiceRow(_ voice: EnrolledVoice) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.selectedProfileIDs.contains(voice.id) },
                        set: { selected in
                            if selected {
                                viewModel.selectedProfileIDs.insert(voice.id)
                            } else {
                                viewModel.selectedProfileIDs.remove(voice.id)
                            }
                        }
                    )
                ) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select \(voice.profile.displayName)")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(voice.profile.displayName)
                            .font(DesignSystem.Typography.body.weight(.semibold))
                        if voice.usesRetiredModel {
                            Text("Older model")
                                .font(DesignSystem.Typography.micro)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(DesignSystem.Colors.warningAmber.opacity(0.18))
                                )
                        }
                    }
                    Text(recognitionSummary(voice))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.statusDetail(for: voice))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                VStack(alignment: .trailing, spacing: 4) {
                    Button("Rename") {
                        renaming = Renaming(id: voice.id, name: voice.profile.displayName)
                    }
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                    Button("Forget") { pendingForget = voice }
                        .parakeetAction(.subtle)
                        .controlSize(.small)
                }
            }

            Button {
                Task { await viewModel.toggleExpansion(voice.id) }
            } label: {
                Label(
                    viewModel.expandedProfileIDs.contains(voice.id)
                        ? "Hide samples" : "Show samples",
                    systemImage: viewModel.expandedProfileIDs.contains(voice.id)
                        ? "chevron.up" : "chevron.down"
                )
                .font(DesignSystem.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.accent)

            if viewModel.expandedProfileIDs.contains(voice.id) {
                samples(for: voice)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func recognitionSummary(_ voice: EnrolledVoice) -> String {
        let recordings = voice.recognizedCount == 1 ? "recording" : "recordings"
        return
            "\(voice.sampleCount) of \(voice.maxSamples) samples · recognized in \(voice.recognizedCount) \(recordings)"
    }

    private func samples(for voice: EnrolledVoice) -> some View {
        samplesList(viewModel.samplesByProfile[voice.id] ?? [], profileId: voice.id)
    }

    private func samplesList(
        _ stored: [SpeakerProfileExemplar],
        profileId: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(stored) { sample in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(sample.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DesignSystem.Typography.caption)
                    Text(sample.captureDomain.displayName)
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete") {
                        Task { await viewModel.deleteSample(id: sample.id, profileId: profileId) }
                    }
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                    // The last one is refused by the store anyway; disabling it
                    // says so before the click instead of after.
                    .disabled(stored.count <= 1)
                }
            }
        }
        .padding(.leading, DesignSystem.Spacing.lg)
    }

    private func renameSheet(_ target: Renaming) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Rename voice")
                .font(DesignSystem.Typography.pageTitle)
            TextField(
                "Name",
                text: Binding(
                    get: { renaming?.name ?? target.name },
                    set: { renaming?.name = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .parakeetAction(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = renaming?.name ?? ""
                    let id = target.id
                    renaming = nil
                    Task { await viewModel.rename(id, to: name) }
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 340)
        .background(.thickMaterial)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(message)
                .font(DesignSystem.Typography.caption)
            Spacer()
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.warningAmber.opacity(0.12))
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Divider()
            HStack {
                if !viewModel.selectedProfileIDs.isEmpty {
                    Button("Forget \(viewModel.selectedProfileIDs.count) Selected") {
                        pendingForgetSelected = true
                    }
                    .parakeetAction(.destructive)
                    .controlSize(.small)
                }
                Spacer()
                if !viewModel.voices.isEmpty {
                    Button("Forget All Voices") { pendingForgetAll = true }
                        .parakeetAction(.destructiveProminent)
                        .controlSize(.small)
                }
            }
            Text("Forgetting a voice never changes names already applied to your transcripts.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .alert(
            "Forget this voice?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { voice in
            Button("Cancel", role: .cancel) { pendingForget = nil }
            Button("Forget", role: .destructive) {
                let id = voice.id
                pendingForget = nil
                Task { await viewModel.forget(id) }
            }
        } message: { voice in
            Text(
                "\(voice.profile.displayName)'s voice samples are deleted from this Mac. Names already applied to your transcripts stay as they are."
            )
        }
        .alert("Forget the selected voices?", isPresented: $pendingForgetSelected) {
            Button("Cancel", role: .cancel) { pendingForgetSelected = false }
            Button("Forget", role: .destructive) {
                pendingForgetSelected = false
                Task { await viewModel.forgetSelected() }
            }
        } message: {
            Text(
                "\(viewModel.selectedProfileIDs.count) saved voices and their samples are deleted from this Mac. Names already applied to your transcripts stay as they are."
            )
        }
        .alert("Forget all voices?", isPresented: $pendingForgetAll) {
            Button("Cancel", role: .cancel) { pendingForgetAll = false }
            Button("Forget All", role: .destructive) {
                pendingForgetAll = false
                Task { await viewModel.forgetAll() }
            }
        } message: {
            Text(
                "Every saved voice, its samples and any voices still waiting to be named are deleted from this Mac. Names already applied to your transcripts stay as they are."
            )
        }
    }
}

extension View {
    /// `sheet(item:)` spelled with the optional-identifiable shape this file
    /// uses, so the rename sheet carries its target rather than reading state
    /// back out mid-presentation.
    fileprivate func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}
