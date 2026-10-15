import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Tab-bar button on a transcript that opens the "Make Flashcards" sheet.
struct TranscriptFlashcardsButton: View {
    var viewModel: FlashcardsViewModel
    let transcription: Transcription
    var onSetUpAI: (() -> Void)?
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityLabel("Make flashcards")
        .help("Make Anki flashcards from this transcript")
        .sheet(isPresented: $showingSheet) {
            MakeFlashcardsSheet(viewModel: viewModel, transcription: transcription, onSetUpAI: onSetUpAI)
        }
    }
}

struct MakeFlashcardsSheet: View {
    @Bindable var viewModel: FlashcardsViewModel
    let transcription: Transcription
    var onSetUpAI: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("flashcards.style") private var styleRaw = FlashcardStyle.vocabulary.rawValue
    @AppStorage("flashcards.meaningLanguage") private var languageRaw = TranslationLanguage.english.rawValue
    @AppStorage("flashcards.maxCards") private var maxCards = 15
    @State private var deckName = ""

    private var style: FlashcardStyle { FlashcardStyle(rawValue: styleRaw) ?? .vocabulary }
    private var language: TranslationLanguage { TranslationLanguage(rawValue: languageRaw) ?? .english }

    private var transcriptText: String {
        transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Make Flashcards").font(DesignSystem.Typography.pageTitle)

            generatorControls
            Divider()
            draftList

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }

            HStack {
                Text("Deck")
                TextField("Deck name", text: $deckName)
                    .frame(maxWidth: 240)
                if !viewModel.decks.isEmpty {
                    Menu {
                        ForEach(viewModel.decks) { summary in
                            Button(summary.deck.name) { deckName = summary.deck.name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                Button("Cancel") {
                    viewModel.cancelGeneration()
                    viewModel.clearDrafts()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add \(validCount) Card\(validCount == 1 ? "" : "s")") {
                    viewModel.saveDrafts(
                        toDeckNamed: deckName,
                        sourceTranscriptionId: transcription.id,
                        tag: "macparakeet"
                    )
                    dismiss()
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validCount == 0 || viewModel.isGenerating)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 680, height: 600)
        .onAppear {
            viewModel.clearDrafts()
            viewModel.reload()
            if deckName.isEmpty {
                deckName = transcription.titleOverride ?? URL(fileURLWithPath: transcription.fileName)
                    .deletingPathExtension().lastPathComponent
            }
        }
    }

    private var validCount: Int { viewModel.drafts.filter(\.isValid).count }

    private var generatorControls: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Picker("Cards", selection: $styleRaw) {
                ForEach(FlashcardStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            Picker(style == .vocabulary ? "Meaning in" : "Language", selection: $languageRaw) {
                ForEach(TranslationLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .fixedSize()
            Stepper("Up to \(maxCards)", value: $maxCards, in: 5...50, step: 5)
                .fixedSize()
            Spacer()
            if viewModel.isGenerating {
                ProgressView().controlSize(.small)
                Button("Stop") { viewModel.cancelGeneration() }
            } else if viewModel.canGenerate {
                Button {
                    viewModel.generateDrafts(
                        from: transcriptText, style: style, meaningLanguage: language, maxCards: maxCards)
                } label: {
                    Label("Generate with AI", systemImage: "sparkles")
                }
                .parakeetAction(.primary)
            } else if let onSetUpAI {
                Button("Set Up AI…") {
                    dismiss()
                    onSetUpAI()
                }
                .help("AI card generation needs an AI provider. You can still add cards by hand.")
            }
        }
        .controlSize(.small)
    }

    private var draftList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Cards").font(DesignSystem.Typography.sectionTitle)
                Spacer()
                Button {
                    viewModel.addEmptyDraft()
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if viewModel.drafts.isEmpty {
                Text(
                    viewModel.canGenerate
                        ? "Generate cards with AI, or add your own. You can edit every card before saving."
                        : "Add cards by hand, or set up an AI provider to generate them from this transcript."
                )
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach($viewModel.drafts) { $draft in
                            draftRow($draft)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func draftRow(_ draft: Binding<FlashcardDraft>) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(spacing: 4) {
                HStack {
                    TextField("Front", text: draft.front, axis: .vertical)
                    TextField("Back", text: draft.back, axis: .vertical)
                }
                TextField(
                    "Context (optional)",
                    text: Binding(get: { draft.wrappedValue.context ?? "" }, set: { draft.wrappedValue.context = $0 }),
                    axis: .vertical
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .textFieldStyle(.roundedBorder)
            Button {
                let id = draft.wrappedValue.id
                viewModel.drafts.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this card")
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(DesignSystem.Colors.surfaceElevated)
        )
    }
}
