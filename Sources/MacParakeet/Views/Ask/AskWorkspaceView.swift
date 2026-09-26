import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AskWorkspaceView: View {
    @Bindable var model: AskWorkspaceViewModel
    var onOpenAISettings: () -> Void
    var onOpenSource: (UUID) -> Void
    @State private var selectedEvidence: AskEvidenceReference?
    @State private var isNearBottom = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                workspace
                    .frame(maxWidth: .infinity)
                if geometry.size.width >= 1050, selectedEvidence != nil {
                    Divider()
                    evidenceInspector
                        .frame(width: 330)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { geometry.size.width < 1050 && selectedEvidence != nil },
                    set: { if !$0 { selectedEvidence = nil; model.closeEvidence() } }
                )
            ) {
                evidenceInspector
                    .frame(minWidth: 430, minHeight: 400)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.load() }
        .sheet(isPresented: $model.showingSourcePicker) {
            AskSourcePickerView(model: model)
                .id(model.sourcePickerID)
        }
        .alert("Rename conversation", isPresented: $model.showingRename) {
            TextField("Conversation name", text: $model.renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await model.renameConversation() } }
                .disabled(model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete conversation?", isPresented: $model.showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete conversation", role: .destructive) {
                Task { await model.deleteConversation() }
            }
        } message: {
            Text("This removes its questions, answers, and draft. Library recordings remain available.")
        }
        .confirmationDialog("Send recording context to this provider?", isPresented: $model.showingRemoteConsent) {
            Button("Send question and source excerpts") {
                Task { await model.approveRemoteSend() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let provider = model.provider {
                Text(
                    "Your question, relevant conversation context, and selected recording excerpts may be sent to \(provider.name) using \(provider.model) at \(provider.endpoint)."
                )
            }
        }
        .onDisappear {
            Task { await model.flushDraft() }
        }
        .onChange(of: model.conversation?.id) { _, _ in
            selectedEvidence = nil
            model.closeEvidence()
        }
        .onChange(of: model.conversation?.activeSection?.id) { _, _ in
            selectedEvidence = nil
            model.closeEvidence()
        }
        .onChange(of: model.evidenceResetID) { _, _ in
            selectedEvidence = nil
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && model.conversation == nil {
                ProgressView("Loading conversations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let conversation = model.conversation {
                conversationContent(conversation)
            } else {
                welcome
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New conversation", systemImage: "plus") {
                    Task { await model.createConversation() }
                }
                .disabled(model.savedDraftAtConflict != nil)
                if !model.conversations.isEmpty {
                    Divider()
                    ForEach(model.conversations) { conversation in
                        Button(conversation.title.isEmpty ? "Untitled conversation" : conversation.title) {
                            Task { await model.openConversation(conversation.id) }
                        }
                        .disabled(model.savedDraftAtConflict != nil)
                    }
                    Divider()
                    Button("Rename…", systemImage: "pencil") {
                        model.renameDraft = model.conversation?.title ?? ""
                        model.showingRename = true
                    }
                    .disabled(model.conversation == nil)
                    Button("Delete conversation…", systemImage: "trash", role: .destructive) {
                        model.showingDeleteConfirmation = true
                    }
                    .disabled(model.conversation == nil)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.conversation?.title.isEmpty == false ? model.conversation!.title : "Ask")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: 310, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(minWidth: 80, maxWidth: 310, alignment: .leading)
            .accessibilityLabel("Conversations")
            .help(
                model.savedDraftAtConflict == nil
                    ? "Conversations" : "Choose which draft to keep before changing conversations")

            Spacer(minLength: 8)

            Button {
                Task { await model.beginSourceSelection() }
            } label: {
                Label("Sources \(model.conversation?.activeSection?.sourceIDs.count ?? 0)", systemImage: "square.stack")
            }
            .parakeetAction(.secondary)
            .accessibilityLabel("Choose sources, \(model.conversation?.activeSection?.sourceIDs.count ?? 0) selected")
            .disabled(model.isStopping)

            Button {
                Task { await model.createConversation() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .parakeetAction(.subtle)
            .help(model.savedDraftAtConflict == nil ? "New conversation" : "Choose which draft to keep first")
            .accessibilityLabel("New conversation")
            .disabled(model.savedDraftAtConflict != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private func conversationContent(_ conversation: AskConversation) -> some View {
        VStack(spacing: 0) {
            if !model.activeSourceSnapshots.isEmpty {
                sourceStrip
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if conversation.messages.isEmpty && model.pendingQuestion == nil && !model.isSending {
                            emptyConversation
                        } else {
                            ForEach(conversation.sections) { section in
                                if section.id != conversation.sections.first?.id {
                                    contextBoundary(section)
                                }
                                ForEach(conversation.messages.filter { $0.sectionID == section.id }) { message in
                                    AskMessageView(message: message) { reference in
                                        selectedEvidence = reference
                                        Task { await model.openEvidence(reference) }
                                    }
                                }
                            }
                        }
                        if let pendingQuestion = model.pendingQuestion {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("You")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(pendingQuestion)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.isSending {
                            streamMessage
                        }
                        Color.clear.frame(height: 1)
                            .id("bottom")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 30)
                }
                .onChange(of: model.streamingText) { _, _ in
                    if isNearBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.pendingQuestion) { _, question in
                    if question != nil && isNearBottom {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            Divider()
            composer
        }
    }

    private var sourceStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
            Text(model.activeSourceSnapshots.prefix(2).map(\.descriptor.title).joined(separator: ", "))
                .lineLimit(1)
            if model.activeSourceSnapshots.count > 2 {
                Text("+\(model.activeSourceSnapshots.count - 2)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeSourceSnapshots.contains(where: { $0.status != .available }) {
                Label("Some sources changed or are unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask across your recordings")
                .font(.title2.weight(.semibold))
            Text("Choose meetings or other transcripts to start a conversation grounded in your Library.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if model.recoveredDraft != nil {
                Text("Your unsent question will be restored in a new conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Choose sources") { Task { await model.beginSourceSelection() } }
                .parakeetAction(.primaryProminent)
            if let error = model.errorMessage { errorText(error) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about what was said")
                .font(.title2.weight(.semibold))
            if model.conversation?.activeSection?.sourceIDs.isEmpty ?? true {
                Text("Choose sources first. Nothing is selected automatically.")
                    .foregroundStyle(.secondary)
                Button("Choose sources") { Task { await model.beginSourceSelection() } }
                    .parakeetAction(.primary)
            } else {
                Text("Compare discussions, trace a changing decision, or find an unresolved question.")
                    .foregroundStyle(.secondary)
                ForEach(
                    [
                        "How did the decision change across these recordings?",
                        "What commitments were discussed, and where?",
                        "Where did people disagree?",
                    ], id: \.self
                ) { suggestion in
                    Button(suggestion) {
                        model.updateDraft(suggestion)
                        composerFocused = true
                    }
                    .parakeetAction(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 45)
    }

    private func contextBoundary(_ section: AskContextSection) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text("Sources changed · \(section.sourceIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .accessibilityLabel("New context section, \(section.sourceIDs.count) sources selected")
    }

    private var streamMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activity = model.activity {
                Label(activity, systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.streamingText.isEmpty {
                MarkdownContentView(model.streamingText, isStreaming: true)
                    .textSelection(.enabled)
            }
            HStack {
                ProgressView().controlSize(.small)
                Text(model.isStopping ? "Stopping…" : "Investigating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    errorText(error)
                    Spacer()
                    Button("Reload") { Task { await model.load() } }
                        .parakeetAction(.secondary)
                        .font(.caption)
                        .disabled(model.isSending || model.isLoading)
                }
            }
            if model.recoveredDraft != nil {
                Text(
                    "An unsent question from a removed conversation will be restored when you start a new conversation."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if model.savedDraftAtConflict != nil {
                Text("This draft also changed outside Ask. Choose which version to keep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Keep my draft") { Task { await model.keepMyDraft() } }
                        .parakeetAction(.secondary)
                    Button("Use saved draft") { model.useSavedDraft() }
                        .parakeetAction(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Ask about these sources",
                    text: Binding(
                        get: { model.draft },
                        set: { model.updateDraft($0) }
                    ), axis: .vertical
                )
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .accessibilityLabel("Question")
                .onSubmit { Task { await model.send() } }
                if model.isSending {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.stopAndSettle() }
                    }
                    .parakeetAction(.secondary)
                    .disabled(model.isStopping)
                } else {
                    Button("Send", systemImage: "arrow.up") {
                        Task { await model.send() }
                    }
                    .parakeetAction(.primaryProminent)
                    .disabled(
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.savedDraftAtConflict != nil
                            || (model.conversation?.activeSection?.sourceIDs.isEmpty ?? true))
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                if let provider = model.provider {
                    Text("\(provider.name) · \(provider.model)")
                        .lineLimit(1)
                        .help(provider.endpoint)
                } else {
                    Text("AI provider unavailable")
                }
                Spacer()
                Button("AI settings") { onOpenAISettings() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func errorText(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(DesignSystem.Colors.errorRed)
            .accessibilityAddTraits(.isStaticText)
    }

    private var evidenceInspector: some View {
        AskEvidenceView(
            evidence: model.evidence,
            isLoading: model.isEvidenceLoading,
            onClose: {
                selectedEvidence = nil
                model.closeEvidence()
                composerFocused = true
            },
            onOpenSource: { id in
                selectedEvidence = nil
                model.closeEvidence()
                onOpenSource(id)
            }
        )
    }
}
