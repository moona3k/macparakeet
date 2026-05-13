import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TransformsViewModelTests: XCTestCase {
    private final class StubCollisionChecker: TransformShortcutCollisionChecking {
        var result: TransformShortcutCollision?

        func checkForEditor(
            candidate: KeyboardShortcut,
            existing: [UUID: KeyboardShortcut],
            excludingPromptID: UUID?,
            reservedHotkeys: [TransformShortcutReservedHotkey]
        ) -> TransformShortcutCollision? {
            result
        }
    }

    var manager: DatabaseManager!
    var repo: PromptRepository!
    var profileRepo: TransformProfileRepository!
    var historyRepo: TransformHistoryRepository!
    var clipboardService: MockClipboardService!
    var writingSampleRepo: WritingSampleRepository!
    var viewModel: TransformsViewModel!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
        profileRepo = TransformProfileRepository(dbQueue: manager.dbQueue)
        historyRepo = TransformHistoryRepository(dbQueue: manager.dbQueue)
        clipboardService = MockClipboardService()
        writingSampleRepo = WritingSampleRepository(dbQueue: manager.dbQueue)
        viewModel = TransformsViewModel()
        viewModel.configure(
            repo: repo,
            profileRepo: profileRepo,
            historyRepo: historyRepo,
            clipboardService: clipboardService,
            writingSampleRepo: writingSampleRepo,
            hasLLMProvider: true
        )
    }

    func testLoadPullsOnlyTransformCategoryPrompts() {
        XCTAssertEqual(viewModel.transforms.count, 3, "Three built-in Transforms ship with the app.")
        XCTAssertTrue(viewModel.transforms.allSatisfy { $0.category == .transform })
        // Built-in count is exposed via the helper.
        XCTAssertEqual(viewModel.builtInTransforms.count, 3)
        XCTAssertEqual(viewModel.customTransforms.count, 0)
    }

    func testLoadOrdersBySortOrder() {
        let names = viewModel.transforms.map(\.name)
        XCTAssertEqual(names, ["Polish", "Distill", "Decide"])
    }

    func testShortcutBindingsExposesNonNilShortcuts() {
        let bindings = viewModel.shortcutBindings
        XCTAssertEqual(bindings.count, 3, "All three built-ins ship with default shortcuts.")
        let labels = Set(bindings.values.map(\.keyLabel))
        XCTAssertEqual(labels, ["1", "2", "3"])
    }

    func testSaveNewCustomTransformAppendsToList() {
        let prompt = Prompt(
            id: UUID(),
            name: "Soften",
            content: "Make the message warmer.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: nil,
            runningLabel: nil
        )
        XCTAssertTrue(viewModel.save(prompt))
        XCTAssertEqual(viewModel.transforms.count, 4)
        XCTAssertTrue(viewModel.customTransforms.contains(where: { $0.name == "Soften" }))
    }

    func testConfigureLoadsPersistedProfileIntoSelectedDraft() throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        var profile = TransformProfile.defaultProfile(for: polish)
        profile.setEnabledRuleIDs(["polish.tone"])
        profile.customInstructions = "Use contractions."
        profile.useWritingSamples = true
        try profileRepo.save(profile)

        let fresh = TransformsViewModel()
        fresh.configure(
            repo: repo,
            profileRepo: profileRepo,
            historyRepo: historyRepo,
            clipboardService: clipboardService,
            writingSampleRepo: writingSampleRepo,
            hasLLMProvider: true
        )

        XCTAssertEqual(fresh.selectedTransformID, polish.id)
        XCTAssertEqual(fresh.draftEnabledRuleIDs, ["polish.tone"])
        XCTAssertEqual(fresh.draftCustomInstructions, "Use contractions.")
        XCTAssertTrue(fresh.draftUseWritingSamples)
        XCTAssertFalse(fresh.isDraftDirty)
    }

    func testSaveDraftPersistsProfileSettings() throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        try writingSampleRepo.save(WritingSample(title: "Sample", text: (1...50).map { "word\($0)" }.joined(separator: " ")))
        viewModel.loadWritingSamples()
        viewModel.selectTransform(polish)
        viewModel.draftEnabledRuleIDs = ["polish.concise", "polish.tone"]
        viewModel.draftCustomInstructions = "Keep the user's punctuation style."
        viewModel.draftUseWritingSamples = true

        XCTAssertTrue(
            viewModel.saveDraft(
                reservedHotkeys: [],
                collisionChecker: StubCollisionChecker()
            )
        )

        let saved = try XCTUnwrap(profileRepo.fetch(promptId: polish.id))
        XCTAssertEqual(saved.enabledRuleIDs, ["polish.concise", "polish.tone"])
        XCTAssertEqual(saved.customInstructions, "Keep the user's punctuation style.")
        XCTAssertTrue(saved.useWritingSamples)
    }

    func testDraftDirtyTracksPromptAndProfileChanges() throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        viewModel.selectTransform(polish)

        XCTAssertFalse(viewModel.isDraftDirty)

        viewModel.draftCustomInstructions = "Keep it direct."
        XCTAssertTrue(viewModel.isDraftDirty)

        XCTAssertTrue(
            viewModel.saveDraft(
                reservedHotkeys: [],
                collisionChecker: StubCollisionChecker()
            )
        )
        XCTAssertFalse(viewModel.isDraftDirty)

        viewModel.draftName = "Polish better"
        XCTAssertTrue(viewModel.isDraftDirty)
    }

    func testDraftDirtyComparesDecodedShortcutValue() throws {
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        polish.keyboardShortcut = #"{"keyLabel":"1","modifiers":524288,"keyCode":18}"#
        try repo.save(polish)
        viewModel.load()
        let reloaded = viewModel.transforms.first(where: { $0.name == "Polish" })!

        viewModel.selectTransform(reloaded)

        XCTAssertFalse(viewModel.isDraftDirty)
    }

    func testDeleteCustomTransformRemovesRow() {
        let prompt = Prompt(
            id: UUID(),
            name: "Sharpen",
            content: "Make it crisper.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 201
        )
        viewModel.save(prompt)
        try? historyRepo.save(TransformHistoryEntry(
            transformId: prompt.id,
            transformName: prompt.name,
            inputText: "rough",
            outputText: "sharp",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        ))
        XCTAssertEqual(viewModel.transforms.count, 4)

        XCTAssertTrue(viewModel.delete(prompt))
        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
        XCTAssertEqual(try? historyRepo.count(transformId: prompt.id), 0)
    }

    func testDeleteBuiltInIsRejected() {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        XCTAssertFalse(viewModel.delete(polish), "Built-ins must be protected from deletion.")
        XCTAssertEqual(viewModel.transforms.count, 3)
    }

    func testConfirmPendingDeleteClearsAndDeletes() {
        let prompt = Prompt(
            id: UUID(),
            name: "Temp",
            content: "Body.",
            category: .transform,
            isBuiltIn: false
        )
        viewModel.save(prompt)
        viewModel.pendingDeleteTransform = prompt

        viewModel.confirmPendingDelete()

        XCTAssertNil(viewModel.pendingDeleteTransform)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
    }

    func testResetBuiltInRestoresDefaultContent() {
        // User customizes Polish: prompt body + shortcut + label.
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let customized = polish
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x23,
            keyLabel: "P"
        ).encodedString()
        polish.runningLabel = "Refining…"
        viewModel.save(polish)

        XCTAssertTrue(viewModel.resetBuiltIn(polish))

        let restored = viewModel.transforms.first(where: { $0.id == customized.id })!
        XCTAssertNotEqual(restored.content, "Custom polish prompt body.")
        XCTAssertEqual(restored.shortcut?.keyLabel, "1", "Default shortcut should be restored.")
        XCTAssertEqual(restored.runningLabel, "Polishing…", "Default running label should be restored.")
    }

    func testReseedMissingBuiltInsRecreatesDeletedDefault() throws {
        // Force-delete Polish via raw SQL (bypassing the built-in protection)
        // to simulate a corrupted state where a built-in is missing.
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        viewModel.load()
        XCTAssertEqual(viewModel.transforms.count, 2, "Polish should be gone before reseed.")

        viewModel.reseedMissingBuiltIns()

        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertTrue(viewModel.transforms.contains(where: { $0.name == "Polish" }))
    }

    func testReseedDoesNotOverwriteExistingBuiltIn() {
        // Customize Polish, then reseed — the custom values must survive.
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let customContent = "User-customized Polish body."
        polish.content = customContent
        viewModel.save(polish)

        viewModel.reseedMissingBuiltIns()

        let reloaded = viewModel.transforms.first(where: { $0.name == "Polish" })!
        XCTAssertEqual(reloaded.content, customContent, "Reseed must not overwrite existing built-in customizations.")
    }

    func testLoadHistoryOrdersNewestFirst() async throws {
        try historyRepo.save(
            TransformHistoryEntry(
                transformName: "Polish",
                inputText: "rough",
                outputText: "polished",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try historyRepo.save(
            TransformHistoryEntry(
                transformName: "Distill",
                inputText: "long",
                outputText: "short",
                capturePath: "clipboard",
                replacementPath: "clipboardPaste",
                llmElapsedMs: 3,
                totalElapsedMs: 4,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        )

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.history.map(\.transformName), ["Distill", "Polish"])
        XCTAssertEqual(viewModel.totalHistoryCount, 2)
    }

    func testLoadHistoryTotalCountIncludesRowsPastFetchLimit() async throws {
        for index in 0..<205 {
            try historyRepo.save(
                TransformHistoryEntry(
                    transformName: "Transform \(index)",
                    inputText: "input",
                    outputText: "output",
                    capturePath: "ax",
                    replacementPath: "ax",
                    llmElapsedMs: 1,
                    totalElapsedMs: 2,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.history.count, TransformsViewModel.historyFetchLimit)
        XCTAssertEqual(viewModel.totalHistoryCount, 205)
    }

    func testSelectedHistoryFiltersToSelectedTransform() async throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let distill = viewModel.transforms.first(where: { $0.name == "Distill" })!
        try historyRepo.save(
            TransformHistoryEntry(
                transformId: polish.id,
                transformName: "Polish",
                inputText: "rough",
                outputText: "polished",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try historyRepo.save(
            TransformHistoryEntry(
                transformId: distill.id,
                transformName: "Distill",
                inputText: "long",
                outputText: "short",
                capturePath: "clipboard",
                replacementPath: "clipboardPaste",
                llmElapsedMs: 3,
                totalElapsedMs: 4,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        )

        viewModel.selectTransform(polish)
        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.selectedHistory.map(\.transformName), ["Polish"])
    }

    func testSelectedHistoryLoadsTransformSpecificRowsOutsideGlobalRecentWindow() async throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let distill = viewModel.transforms.first(where: { $0.name == "Distill" })!
        try historyRepo.save(
            TransformHistoryEntry(
                transformId: polish.id,
                transformName: "Polish",
                inputText: "old polish",
                outputText: "Old polish.",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        )
        for index in 0..<TransformsViewModel.historyFetchLimit {
            try historyRepo.save(
                TransformHistoryEntry(
                    transformId: distill.id,
                    transformName: "Distill",
                    inputText: "long \(index)",
                    outputText: "short \(index)",
                    capturePath: "clipboard",
                    replacementPath: "clipboardPaste",
                    llmElapsedMs: 3,
                    totalElapsedMs: 4,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(10 + index)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(10 + index))
                )
            )
        }

        viewModel.selectTransform(polish)
        await viewModel.loadHistory()

        XCTAssertFalse(viewModel.history.contains(where: { $0.transformId == polish.id }))
        XCTAssertEqual(viewModel.selectedHistory.map(\.inputText), ["old polish"])
        XCTAssertEqual(viewModel.selectedHistoryTotalCount, 1)
        XCTAssertEqual(viewModel.historyCountsByTransformID[polish.id], 1)
        XCTAssertEqual(viewModel.historyCountsByTransformID[distill.id], TransformsViewModel.historyFetchLimit)
    }

    func testDeleteAndClearHistory() async throws {
        let first = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "one",
            outputText: "One.",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        let second = TransformHistoryEntry(
            transformName: "Decide",
            inputText: "two",
            outputText: "Choose two.",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 3,
            totalElapsedMs: 4
        )
        try historyRepo.save(first)
        try historyRepo.save(second)
        await viewModel.loadHistory()

        await viewModel.deleteHistoryEntry(first)

        XCTAssertEqual(viewModel.history.map(\.id), [second.id])
        XCTAssertEqual(viewModel.totalHistoryCount, 1)

        await viewModel.clearHistory()

        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertEqual(viewModel.totalHistoryCount, 0)
        XCTAssertEqual(try historyRepo.count(), 0)
    }

    func testClearSelectedHistoryPreservesOtherTransforms() async throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let distill = viewModel.transforms.first(where: { $0.name == "Distill" })!
        for index in 0..<205 {
            try historyRepo.save(
                TransformHistoryEntry(
                    transformId: polish.id,
                    transformName: "Polish",
                    inputText: "rough \(index)",
                    outputText: "polished \(index)",
                    capturePath: "ax",
                    replacementPath: "ax",
                    llmElapsedMs: 1,
                    totalElapsedMs: 2,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        try historyRepo.save(
            TransformHistoryEntry(
                transformId: distill.id,
                transformName: "Distill",
                inputText: "long",
                outputText: "short",
                capturePath: "clipboard",
                replacementPath: "clipboardPaste",
                llmElapsedMs: 3,
                totalElapsedMs: 4,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        viewModel.selectTransform(polish)
        await viewModel.loadHistory()

        await viewModel.clearSelectedHistory()

        XCTAssertTrue(viewModel.selectedHistory.isEmpty)
        XCTAssertEqual(viewModel.selectedHistoryTotalCount, 0)
        XCTAssertEqual(viewModel.history.map(\.transformName), ["Distill"])
        XCTAssertEqual(viewModel.totalHistoryCount, 1)
        XCTAssertEqual(try historyRepo.count(), 1)
    }

    func testCopyHistoryOutputUsesInjectedClipboardService() async {
        let entry = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )

        await viewModel.copyOutputToClipboard(entry)

        let copiedText = await clipboardService.lastCopiedText
        XCTAssertEqual(copiedText, "polished")
        XCTAssertEqual(viewModel.copiedHistoryEntryID, entry.id)
    }

    func testSaveWritingSampleRejectsShortSample() throws {
        viewModel.writingSampleTitle = "Short"
        viewModel.writingSampleText = "Too short."

        XCTAssertFalse(viewModel.saveWritingSample())
        XCTAssertTrue(viewModel.writingSamples.isEmpty)
        XCTAssertTrue(try writingSampleRepo.fetchAll().isEmpty)
        XCTAssertEqual(
            viewModel.writingSampleErrorMessage,
            "Add at least 50 words so MacParakeet can learn from the sample."
        )
    }

    func testSaveWritingSamplePersistsValidSample() throws {
        viewModel.writingSampleTitle = "Launch email"
        viewModel.writingSampleText = (1...50).map { "word\($0)" }.joined(separator: " ")
        viewModel.isAddingWritingSample = true

        XCTAssertTrue(viewModel.saveWritingSample())

        let saved = try XCTUnwrap(writingSampleRepo.fetchAll().first)
        XCTAssertEqual(saved.title, "Launch email")
        XCTAssertEqual(saved.wordCount, 50)
        XCTAssertEqual(viewModel.writingSamples.map(\.id), [saved.id])
        XCTAssertFalse(viewModel.isAddingWritingSample)
        XCTAssertNil(viewModel.writingSampleErrorMessage)
    }

    func testSavingDraftDoesNotPersistWritingSamplePreferenceWithoutSamples() throws {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        viewModel.selectTransform(polish)
        viewModel.draftUseWritingSamples = true

        XCTAssertTrue(
            viewModel.saveDraft(
                reservedHotkeys: [],
                collisionChecker: StubCollisionChecker()
            )
        )

        let saved = try XCTUnwrap(profileRepo.fetch(promptId: polish.id))
        XCTAssertFalse(saved.useWritingSamples)
        XCTAssertFalse(viewModel.draftUseWritingSamples)
    }

    func testTurningOnWritingSamplesWithoutSamplesStartsSampleEditor() {
        XCTAssertTrue(viewModel.writingSamples.isEmpty)

        viewModel.setDraftUseWritingSamples(true)

        XCTAssertFalse(viewModel.draftUseWritingSamples)
        XCTAssertTrue(viewModel.isAddingWritingSample)
    }

    func testDeletingLastWritingSampleDisablesDraftWritingSamples() throws {
        let sample = WritingSample(
            title: "Launch email",
            text: (1...50).map { "word\($0)" }.joined(separator: " ")
        )
        try writingSampleRepo.save(sample)
        viewModel.loadWritingSamples()
        viewModel.draftUseWritingSamples = true

        viewModel.deleteWritingSample(sample)

        XCTAssertTrue(viewModel.writingSamples.isEmpty)
        XCTAssertFalse(viewModel.draftUseWritingSamples)
    }

    func testHasUnsavedDraftCoversCreatingAndEditingStates() {
        XCTAssertFalse(viewModel.hasUnsavedDraft)

        viewModel.startCreatingTransform()
        XCTAssertFalse(viewModel.hasUnsavedDraft)

        viewModel.draftName = "Boss Mode"
        XCTAssertTrue(viewModel.hasUnsavedDraft)

        viewModel.cancelCreate()
        XCTAssertFalse(viewModel.hasUnsavedDraft)

        viewModel.draftCustomInstructions = "Be crisp."
        XCTAssertTrue(viewModel.hasUnsavedDraft)
    }
}
