import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ankiPackage = UTType(filenameExtension: "apkg", conformingTo: .data) ?? .data
}

/// Flashcards page: decks on the left; review or browse the selection on
/// the right. Import and export use Anki's `.apkg` format.
struct FlashcardsView: View {
    @Bindable var viewModel: FlashcardsViewModel

    @State private var showingImporter = false
    @State private var showingNewDeck = false
    @State private var newDeckName = ""
    @State private var renamingDeck: FlashcardDeckSummary?
    @State private var renameText = ""
    @State private var deletingDeck: FlashcardDeckSummary?
    @State private var showingAddCard = false

    var body: some View {
        HSplitView {
            deckList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.Colors.background)
        .onAppear { viewModel.reload() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.ankiPackage]) { result in
            if case .success(let url) = result {
                Task { await viewModel.importPackage(from: url) }
            }
        }
        .alert("New Deck", isPresented: $showingNewDeck) {
            TextField("Deck name", text: $newDeckName)
            Button("Create") { viewModel.createDeck(named: newDeckName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename Deck",
            isPresented: Binding(get: { renamingDeck != nil }, set: { if !$0 { renamingDeck = nil } })
        ) {
            TextField("Deck name", text: $renameText)
            Button("Rename") {
                if let deck = renamingDeck { viewModel.renameDeck(deck.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletingDeck?.deck.name ?? "")” and its \(deletingDeck?.totalCount ?? 0) cards?",
            isPresented: Binding(get: { deletingDeck != nil }, set: { if !$0 { deletingDeck = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Deck", role: .destructive) {
                if let deck = deletingDeck { viewModel.deleteDeck(deck.id) }
            }
        }
        .sheet(isPresented: $showingAddCard) {
            if let deck = viewModel.selectedDeck {
                FlashcardEditorSheet(title: "Add Card", deckName: deck.deck.name) { front, back, context in
                    viewModel.addCard(front: front, back: back, context: context, deckId: deck.id)
                }
            }
        }
    }

    // MARK: - Deck list

    private var deckList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { viewModel.selectedDeckId }, set: { viewModel.selectDeck($0) })) {
                Section("Decks") {
                    deckRow(title: "All Decks", icon: "rectangle.stack", due: viewModel.totalDue, total: nil)
                        .tag(UUID?.none)
                    ForEach(viewModel.decks) { summary in
                        deckRow(
                            title: summary.deck.name,
                            icon: "rectangle.on.rectangle",
                            due: summary.dueCount + summary.newCount,
                            total: summary.totalCount
                        )
                        .tag(UUID?.some(summary.id))
                        .contextMenu {
                            Button("Rename…") {
                                renameText = summary.deck.name
                                renamingDeck = summary
                            }
                            Button("Delete…", role: .destructive) { deletingDeck = summary }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    newDeckName = ""
                    showingNewDeck = true
                } label: {
                    Label("New Deck", systemImage: "plus")
                }
                Spacer()
                Menu {
                    Button("Import Anki Deck (.apkg)…") { showingImporter = true }
                    Button(viewModel.selectedDeck == nil ? "Export All Decks (.apkg)…" : "Export This Deck (.apkg)…") {
                        exportPackage()
                    }
                    .disabled(viewModel.decks.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import or export Anki decks")
            }
            .controlSize(.small)
            .padding(DesignSystem.Spacing.sm)
        }
    }

    private func deckRow(title: String, icon: String, due: Int, total: Int?) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .lineLimit(1)
            Spacer()
            if due > 0 {
                Text("\(due)")
                    .font(DesignSystem.Typography.micro.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            } else if let total {
                Text("\(total)")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage ?? viewModel.statusMessage {
                banner(message, isError: viewModel.errorMessage != nil)
            }
            if viewModel.isReviewing {
                FlashcardReviewView(viewModel: viewModel)
            } else {
                overview
            }
        }
    }

    private func banner(_ message: String, isError: Bool) -> some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? DesignSystem.Colors.errorRed : DesignSystem.Colors.successGreen)
            Text(message).font(DesignSystem.Typography.bodySmall)
            Spacer()
            Button {
                viewModel.errorMessage = nil
                viewModel.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated)
    }

    private var overview: some View {
        let summary = viewModel.selectedDeck
        let due = summary.map(\.dueCount) ?? viewModel.decks.reduce(0) { $0 + $1.dueCount }
        let fresh = summary.map(\.newCount) ?? viewModel.decks.reduce(0) { $0 + $1.newCount }
        let total = summary.map(\.totalCount) ?? viewModel.decks.reduce(0) { $0 + $1.totalCount }

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary?.deck.name ?? "All Decks")
                    .font(DesignSystem.Typography.pageTitle)
                Spacer()
                if summary != nil {
                    Button {
                        showingAddCard = true
                    } label: {
                        Label("Add Card", systemImage: "plus")
                    }
                    .parakeetAction(.secondary)
                }
            }

            HStack(spacing: DesignSystem.Spacing.lg) {
                stat("Due", due, DesignSystem.Colors.accent)
                stat("New", fresh, DesignSystem.Colors.successGreen)
                stat("Total", total, DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    viewModel.startReview()
                } label: {
                    Label("Study Now", systemImage: "play.fill")
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(due + fresh == 0)
            }

            if total == 0 {
                emptyState
            } else if summary != nil {
                cardList
            } else {
                Text("Select a deck to browse and edit its cards.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(DesignSystem.Typography.pageTitle).foregroundStyle(color)
            Text(title).font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("No cards yet")
                .font(DesignSystem.Typography.sectionTitle)
            Text("Open a transcript and choose **Make Flashcards**, or import an Anki deck (.apkg).")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Import Anki Deck…") { showingImporter = true }
                .parakeetAction(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var cardList: some View {
        List {
            ForEach(viewModel.browsedCards) { card in
                FlashcardRow(card: card, onSave: viewModel.updateCard, onDelete: { viewModel.deleteCard(card.id) })
            }
        }
        .listStyle(.inset)
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.ankiPackage]
        let base = viewModel.selectedDeck?.deck.name ?? "MacParakeet Flashcards"
        panel.nameFieldStringValue = base.replacingOccurrences(of: "/", with: "-") + ".apkg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportPackage(to: url) }
    }
}

// MARK: - Review

struct FlashcardReviewView: View {
    @Bindable var viewModel: FlashcardsViewModel

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack {
                Button {
                    viewModel.endReview()
                } label: {
                    Label("Done", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(viewModel.reviewedThisSession) reviewed · \(viewModel.reviewQueue.count) left")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if let card = viewModel.currentCard {
                cardFace(card)
                controls
            } else {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("All done for now")
                    .font(DesignSystem.Typography.pageTitle)
                Text("You reviewed \(viewModel.reviewedThisSession) card\(viewModel.reviewedThisSession == 1 ? "" : "s").")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Button("Back to Decks") { viewModel.endReview() }
                    .parakeetAction(.primary)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private func cardFace(_ card: Flashcard) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer(minLength: 0)
            Text(card.front)
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if viewModel.isAnswerShown {
                Divider().padding(.horizontal, DesignSystem.Spacing.xl)
                Text(card.back)
                    .font(.system(size: 20))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let context = card.context {
                    Text(context)
                        .font(DesignSystem.Typography.body.italic())
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: 640, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border)
        )
    }

    @ViewBuilder
    private var controls: some View {
        if viewModel.isAnswerShown {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(FlashcardGrade.allCases) { grade in
                    Button {
                        viewModel.answer(grade)
                    } label: {
                        VStack(spacing: 2) {
                            Text(viewModel.preview(grade)).font(DesignSystem.Typography.micro)
                            Text(grade.title).font(DesignSystem.Typography.bodySmall.weight(.semibold))
                        }
                        .frame(minWidth: 72)
                    }
                    .parakeetAction(grade == .good ? .primary : .secondary)
                    .keyboardShortcut(KeyEquivalent(Character(String(grade.rawValue))), modifiers: [])
                    .help("\(grade.title) (\(grade.rawValue))")
                }
            }
        } else {
            Button {
                viewModel.isAnswerShown = true
            } label: {
                Text("Show Answer").frame(minWidth: 200)
            }
            .parakeetAction(.primaryProminent)
            .keyboardShortcut(.space, modifiers: [])
        }
    }
}

// MARK: - Browse rows

private struct FlashcardRow: View {
    let card: Flashcard
    let onSave: (Flashcard) -> Void
    let onDelete: () -> Void
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.front).font(DesignSystem.Typography.body.weight(.medium))
                Text(card.back)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(dueLabel)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = true }
        .contextMenu {
            Button("Edit…") { editing = true }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .sheet(isPresented: $editing) {
            FlashcardEditorSheet(
                title: "Edit Card", deckName: nil,
                front: card.front, back: card.back, context: card.context ?? ""
            ) { front, back, context in
                var updated = card
                updated.front = front
                updated.back = back
                updated.context = context
                onSave(updated)
            }
        }
    }

    private var dueLabel: String {
        guard card.phase != .new else { return "New" }
        if card.dueAt <= Date() { return "Due" }
        return "Due " + card.dueAt.formatted(.relative(presentation: .named))
    }
}

struct FlashcardEditorSheet: View {
    let title: String
    let deckName: String?
    @State var front: String = ""
    @State var back: String = ""
    @State var context: String = ""
    let onSave: (String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        title: String, deckName: String?, front: String = "", back: String = "", context: String = "",
        onSave: @escaping (String, String, String?) -> Void
    ) {
        self.title = title
        self.deckName = deckName
        _front = State(initialValue: front)
        _back = State(initialValue: back)
        _context = State(initialValue: context)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(title).font(DesignSystem.Typography.sectionTitle)
            if let deckName {
                Text("Deck: \(deckName)").font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Form {
                TextField("Front", text: $front, axis: .vertical)
                TextField("Back", text: $back, axis: .vertical)
                TextField("Context (optional)", text: $context, axis: .vertical)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(
                        front.trimmingCharacters(in: .whitespacesAndNewlines),
                        back.trimmingCharacters(in: .whitespacesAndNewlines),
                        trimmedContext.isEmpty ? nil : trimmedContext
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    front.trimmingCharacters(in: .whitespaces).isEmpty
                        || back.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 460)
    }
}
