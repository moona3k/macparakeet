import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TransformsViewModelTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: PromptRepository!
    var historyRepo: TransformHistoryRepository!
    var clipboardService: MockTransformsClipboardService!
    var viewModel: TransformsViewModel!

    override func setUp() async throws {
        // The no-argument initializer is the in-memory test database.
        // `DatabaseManager(path:)` is the file-backed production path.
        manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
        historyRepo = TransformHistoryRepository(dbQueue: manager.dbQueue)
        clipboardService = MockTransformsClipboardService()
        viewModel = TransformsViewModel()
        viewModel.configure(
            repo: repo,
            historyRepo: historyRepo,
            clipboardService: clipboardService,
            hasLLMProvider: true
        )
        await viewModel.load()
    }

    func testLoadPullsOnlyTransformCategoryPrompts() {
        XCTAssertEqual(viewModel.transforms.count, 3, "Three built-in Transforms ship with the app.")
        XCTAssertTrue(viewModel.transforms.allSatisfy { $0.category == .transform })
        // Built-in count is exposed via the helper.
        XCTAssertEqual(viewModel.builtInTransforms.count, 3)
        XCTAssertEqual(viewModel.customTransforms.count, 0)
        XCTAssertFalse(viewModel.hasMissingBuiltInTransforms)
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

    func testHeroShortcutInstructionUsesCurrentBindings() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.keyboardShortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.command.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x12,
            keyLabel: "!"
        ).encodedString()

        let saved = await viewModel.save(polish)
        XCTAssertTrue(saved)

        XCTAssertEqual(
            viewModel.heroShortcutInstruction,
            "Press a Transform's hotkey (⇧⌘1, ⌥2, ⌥3)."
        )
    }

    func testSaveNewCustomTransformAppendsToList() async {
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
        let saved = await viewModel.save(prompt)
        XCTAssertTrue(saved)
        XCTAssertEqual(viewModel.transforms.count, 4)
        XCTAssertTrue(viewModel.customTransforms.contains(where: { $0.name == "Soften" }))
    }

    func testDeleteCustomTransformRemovesRow() async {
        let prompt = Prompt(
            id: UUID(),
            name: "Sharpen",
            content: "Make it crisper.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 201
        )
        await viewModel.save(prompt)
        XCTAssertEqual(viewModel.transforms.count, 4)

        let deleted = await viewModel.delete(prompt)
        XCTAssertTrue(deleted)
        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
    }

    func testDeleteBuiltInIsRejected() async {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let deleted = await viewModel.delete(polish)
        XCTAssertFalse(deleted, "Built-ins must be protected from deletion.")
        XCTAssertEqual(viewModel.transforms.count, 3)
    }

    func testConfirmPendingDeleteClearsAndDeletes() async {
        let prompt = Prompt(
            id: UUID(),
            name: "Temp",
            content: "Body.",
            category: .transform,
            isBuiltIn: false
        )
        await viewModel.save(prompt)
        viewModel.pendingDeleteTransform = prompt

        await viewModel.confirmPendingDelete()

        XCTAssertNil(viewModel.pendingDeleteTransform)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
    }

    func testResetBuiltInRestoresDefaultContent() async {
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
        await viewModel.save(polish)

        let reset = await viewModel.resetBuiltIn(polish)
        XCTAssertTrue(reset)

        let restored = viewModel.transforms.first(where: { $0.id == customized.id })!
        XCTAssertNotEqual(restored.content, "Custom polish prompt body.")
        XCTAssertEqual(restored.shortcut?.keyLabel, "1", "Default shortcut should be restored.")
        XCTAssertEqual(restored.runningLabel, "Polishing…", "Default running label should be restored.")
    }

    func testResetBuiltInRejectsDefaultShortcutWhenAlreadyUsed() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
        let savedPolish = await viewModel.save(polish)
        XCTAssertTrue(savedPolish)

        let custom = Prompt(
            id: UUID(),
            name: "Custom Opt One",
            content: "Body.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: KeyboardShortcut.parse("opt+1")!.encodedString()
        )
        let savedCustom = await viewModel.save(custom)
        XCTAssertTrue(savedCustom)

        let reset = await viewModel.resetBuiltIn(polish)
        XCTAssertFalse(reset)
        XCTAssertTrue(viewModel.errorMessage?.contains("already used") ?? false)

        let reloadedPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloadedPolish.content, "Custom polish prompt body.")
        XCTAssertEqual(reloadedPolish.shortcut?.displayString, "⌥4")

        let reloadedCustom = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == custom.id }))
        XCTAssertEqual(reloadedCustom.shortcut?.displayString, "⌥1")
    }

    func testResetBuiltInRejectsDefaultShortcutWhenReservedByAppHotkey() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
        let savedPolish = await viewModel.save(polish)
        XCTAssertTrue(savedPolish)

        let reset = await viewModel.resetBuiltIn(
            polish,
            reservedHotkeys: [
                TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .option)
            ]
        )
        XCTAssertFalse(reset)
        XCTAssertTrue(viewModel.errorMessage?.contains("conflicts with hands-free dictation") ?? false)

        let reloadedPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloadedPolish.content, "Custom polish prompt body.")
        XCTAssertEqual(reloadedPolish.shortcut?.displayString, "⌥4")
    }

    func testResetBuiltInAllowsDefaultShortcutWhenReservedByBareModifierDictationHotkey() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
        let savedPolish = await viewModel.save(polish)
        XCTAssertTrue(savedPolish)

        let reset = await viewModel.resetBuiltIn(
            polish,
            reservedHotkeys: [
                TransformShortcutReservedHotkey(
                    name: "push to talk",
                    trigger: .option,
                    conflictMode: .bareModifierDictation
                )
            ]
        )
        XCTAssertTrue(reset)

        let reloadedPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloadedPolish.shortcut?.displayString, "⌥1")
    }

    func testReseedMissingBuiltInsRecreatesDeletedDefault() async throws {
        // Force-delete Polish via raw SQL (bypassing the built-in protection)
        // to simulate a corrupted state where a built-in is missing.
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.transforms.count, 2, "Polish should be gone before reseed.")
        XCTAssertTrue(viewModel.hasMissingBuiltInTransforms)

        await viewModel.reseedMissingBuiltIns()

        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertTrue(viewModel.transforms.contains(where: { $0.name == "Polish" }))
        XCTAssertFalse(viewModel.hasMissingBuiltInTransforms)
    }

    func testReseedDoesNotOverwriteExistingBuiltIn() async {
        // Customize Polish, then reseed — the custom values must survive.
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let customContent = "User-customized Polish body."
        polish.content = customContent
        await viewModel.save(polish)

        await viewModel.reseedMissingBuiltIns()

        let reloaded = viewModel.transforms.first(where: { $0.name == "Polish" })!
        XCTAssertEqual(reloaded.content, customContent, "Reseed must not overwrite existing built-in customizations.")
    }

    func testReseedDoesNotOverwriteExistingBuiltInWhenVisibleStateIsStale() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        let customContent = "User-customized Polish body while UI state is stale."
        polish.content = customContent
        let saved = await viewModel.save(polish)
        XCTAssertTrue(saved)

        viewModel.transforms = []
        viewModel.allPrompts = []

        let reseeded = await viewModel.reseedMissingBuiltIns()
        XCTAssertTrue(reseeded)

        let reloaded = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloaded.content, customContent)
    }

    func testReseedMissingBuiltInsClearsDefaultShortcutWhenAlreadyUsed() async throws {
        let polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()

        let custom = Prompt(
            id: UUID(),
            name: "Custom Opt One",
            content: "Body.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: KeyboardShortcut.parse("opt+1")!.encodedString()
        )
        let savedCustom = await viewModel.save(custom)
        XCTAssertTrue(savedCustom)

        let reseeded = await viewModel.reseedMissingBuiltIns()
        XCTAssertTrue(reseeded)

        let restoredPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        XCTAssertNil(restoredPolish.shortcut)
        let reloadedCustom = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == custom.id }))
        XCTAssertEqual(reloadedCustom.shortcut?.displayString, "⌥1")
        XCTAssertTrue(viewModel.errorMessage?.contains("without conflicting shortcuts") ?? false)
    }

    func testReseedMissingBuiltInsClearsDefaultShortcutWhenReservedByAppHotkey() async throws {
        let polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()

        let reseeded = await viewModel.reseedMissingBuiltIns(
            reservedHotkeys: [
                TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .option)
            ]
        )
        XCTAssertTrue(reseeded)

        let restoredPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        XCTAssertNil(restoredPolish.shortcut)
        XCTAssertTrue(viewModel.errorMessage?.contains("conflicts with hands-free dictation") ?? false)
    }

    // MARK: - History

    func testLoadHistoryOrdersNewestFirst() async throws {
        try historyRepo.save(
            TransformHistoryEntry(
                transformName: "Polish",
                inputText: "first",
                outputText: "first-out",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        try historyRepo.save(
            TransformHistoryEntry(
                transformName: "Distill",
                inputText: "second",
                outputText: "second-out",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2,
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.history.map(\.transformName), ["Distill", "Polish"])
        XCTAssertEqual(viewModel.totalHistoryCount, 2)
    }

    func testDeleteHistoryEntryRemovesRowAndKeepsSnapshotFresh() async throws {
        let first = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        let second = TransformHistoryEntry(
            transformName: "Distill",
            inputText: "long",
            outputText: "short",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 3,
            totalElapsedMs: 4
        )
        try historyRepo.save(first)
        try historyRepo.save(second)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.history.count, 2)

        await viewModel.deleteHistoryEntry(first)

        XCTAssertEqual(viewModel.history.map(\.id), [second.id])
        XCTAssertEqual(viewModel.totalHistoryCount, 1)
    }

    func testDeleteHistoryEntryWorksWithoutPendingState() async throws {
        // Regression: SwiftUI alert sets `pendingDeleteHistoryEntry = nil`
        // before the Delete button's Task runs. The view must call
        // `deleteHistoryEntry(entry)` with the closure-captured entry, not
        // route through a pending-field wrapper that would read a now-nil
        // value and silently no-op.
        let entry = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        try historyRepo.save(entry)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.history.count, 1)

        viewModel.pendingDeleteHistoryEntry = nil  // simulate SwiftUI binding clear

        await viewModel.deleteHistoryEntry(entry)

        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertEqual(viewModel.totalHistoryCount, 0)
    }

    func testHistorySnapshotGenerationGuardsAgainstStaleLoadAfterDelete() async throws {
        // Regression: a `loadHistory` triggered by a transformHistoryChanged
        // notification can race a user-triggered delete. Without a
        // generation guard, the stale load could resurrect the just-deleted
        // row until the next notification reloaded.
        let first = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        try historyRepo.save(first)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.history.count, 1)

        // Kick off concurrent load + delete. The delete should win the
        // visible state regardless of which detached fetch lands first.
        async let load: Void = viewModel.loadHistory()
        async let delete: Void = viewModel.deleteHistoryEntry(first)
        _ = await (load, delete)

        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertEqual(viewModel.totalHistoryCount, 0)
    }

    func testPassiveLoadStartedDuringDeleteCannotOverrideMutationSnapshot() async throws {
        let entry = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        let blockingRepo = BlockingTransformHistoryRepository(entries: [entry])
        let viewModel = TransformsViewModel()
        viewModel.configure(
            repo: repo,
            historyRepo: blockingRepo,
            clipboardService: clipboardService,
            hasLLMProvider: true
        )
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.history.map(\.id), [entry.id])

        blockingRepo.shouldBlockDelete = true
        let delete = Task { await viewModel.deleteHistoryEntry(entry) }
        let deleteBlocked = await Task.detached {
            blockingRepo.waitForDeleteToBlock()
        }.value
        XCTAssertTrue(deleteBlocked, "Delete did not reach the controlled block point.")

        let load = Task { await viewModel.loadHistory() }
        let staleLoadRead = await Task.detached {
            blockingRepo.waitForFetchDuringBlockedDelete()
        }.value
        XCTAssertTrue(staleLoadRead, "Passive load did not read while delete was blocked.")
        blockingRepo.releaseDelete()

        await load.value
        await delete.value

        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertEqual(viewModel.totalHistoryCount, 0)
    }

    func testCopyOutputToClipboardWritesToClipboardAndFlagsCopied() async throws {
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

        XCTAssertEqual(clipboardService.lastCopied, "polished")
        XCTAssertEqual(viewModel.copiedHistoryEntryID, entry.id)
        XCTAssertEqual(viewModel.copiedHistoryTarget, .output)
        XCTAssertEqual(viewModel.copiedHistoryTarget?.statusLabel, "Copied result")
        XCTAssertNil(viewModel.historyErrorMessage)
    }

    func testCopyInputToClipboardWritesOriginalTextAndFlagsCopiedTarget() async throws {
        let entry = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )

        await viewModel.copyInputToClipboard(entry)

        XCTAssertEqual(clipboardService.lastCopied, "rough")
        XCTAssertEqual(viewModel.copiedHistoryEntryID, entry.id)
        XCTAssertEqual(viewModel.copiedHistoryTarget, .input)
        XCTAssertEqual(viewModel.copiedHistoryTarget?.statusLabel, "Copied original")
        XCTAssertNil(viewModel.historyErrorMessage)
    }
}

final class MockTransformsClipboardService: ClipboardServiceProtocol, @unchecked Sendable {
    var lastCopied: String?
    var copyReturnValue = true

    func pasteText(_ text: String) async throws {}

    func pasteText(_ text: String, restoresClipboard: Bool) async throws {}

    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        false
    }

    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?, restoresClipboard: Bool) async throws -> Bool {
        false
    }

    @discardableResult
    func copyToClipboard(_ text: String) async -> Bool {
        lastCopied = text
        return copyReturnValue
    }
}

private final class BlockingTransformHistoryRepository: TransformHistoryRepositoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TransformHistoryEntry]
    private var deleteIsBlocked = false
    private let deleteBlocked = DispatchSemaphore(value: 0)
    private let releaseBlockedDelete = DispatchSemaphore(value: 0)
    private let fetchDuringBlockedDelete = DispatchSemaphore(value: 0)

    var shouldBlockDelete = false

    init(entries: [TransformHistoryEntry]) {
        self.entries = entries
    }

    func save(_ entry: TransformHistoryEntry) throws {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func fetchAll() throws -> [TransformHistoryEntry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.sorted { $0.createdAt > $1.createdAt }
    }

    func fetchRecent(limit: Int) throws -> [TransformHistoryEntry] {
        Array(try fetchAll().prefix(max(0, limit)))
    }

    func fetchRecentWithCount(limit: Int) throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        lock.lock()
        let snapshot = entries
        let blocked = deleteIsBlocked
        lock.unlock()
        if blocked {
            fetchDuringBlockedDelete.signal()
        }
        return (Array(snapshot.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit))), snapshot.count)
    }

    func fetch(id: UUID) throws -> TransformHistoryEntry? {
        lock.lock()
        let entry = entries.first { $0.id == id }
        lock.unlock()
        return entry
    }

    func fetch(idPrefix: String) throws -> [TransformHistoryEntry] {
        let prefix = idPrefix.replacingOccurrences(of: "-", with: "").lowercased()
        lock.lock()
        let snapshot = entries.filter {
            $0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(prefix)
        }
        lock.unlock()
        return snapshot
    }

    func count() throws -> Int {
        lock.lock()
        let count = entries.count
        lock.unlock()
        return count
    }

    func delete(id: UUID) throws -> Bool {
        if shouldBlockDelete {
            lock.lock()
            deleteIsBlocked = true
            lock.unlock()
            deleteBlocked.signal()
            _ = releaseBlockedDelete.wait(timeout: .now() + 5)
            lock.lock()
            deleteIsBlocked = false
            lock.unlock()
        }

        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    func deleteAll() throws {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func waitForDeleteToBlock() -> Bool {
        deleteBlocked.wait(timeout: .now() + 5) == .success
    }

    func waitForFetchDuringBlockedDelete() -> Bool {
        fetchDuringBlockedDelete.wait(timeout: .now() + 5) == .success
    }

    func releaseDelete() {
        releaseBlockedDelete.signal()
    }
}
