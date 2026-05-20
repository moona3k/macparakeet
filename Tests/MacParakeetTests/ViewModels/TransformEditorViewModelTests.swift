import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TransformEditorViewModelTests: XCTestCase {

    private final class StubCollisionChecker: TransformShortcutCollisionChecking {
        var result: TransformShortcutCollision?
        var receivedReservedHotkeys: [TransformShortcutReservedHotkey]?
        func checkForEditor(
            candidate: KeyboardShortcut,
            existing: [UUID: KeyboardShortcut],
            excludingPromptID: UUID?,
            reservedHotkeys: [TransformShortcutReservedHotkey]
        ) -> TransformShortcutCollision? {
            receivedReservedHotkeys = reservedHotkeys
            return result
        }
    }

    private let opt1 = KeyboardShortcut(
        modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
        keyCode: 0x12,
        keyLabel: "1"
    )

    // MARK: - Mode

    func testCreateModeStartsBlank() {
        let vm = TransformEditorViewModel(mode: .create)
        XCTAssertTrue(vm.name.isEmpty)
        XCTAssertTrue(vm.content.isEmpty)
        XCTAssertNil(vm.shortcut)
        XCTAssertTrue(vm.runningLabel.isEmpty)
        XCTAssertTrue(vm.mode.isCreating)
        XCTAssertFalse(vm.mode.isEditing)
        XCTAssertFalse(vm.isBuiltIn)
    }

    func testEditModeSeedsFromExistingPrompt() {
        let prompt = Prompt(
            id: UUID(),
            name: "Custom",
            content: "Body",
            category: .transform,
            isBuiltIn: false,
            keyboardShortcut: opt1.encodedString(),
            runningLabel: "Customizing…"
        )
        let vm = TransformEditorViewModel(mode: .edit(prompt))
        XCTAssertEqual(vm.name, "Custom")
        XCTAssertEqual(vm.content, "Body")
        XCTAssertEqual(vm.shortcut?.keyLabel, "1")
        XCTAssertEqual(vm.runningLabel, "Customizing…")
        XCTAssertTrue(vm.mode.isEditing)
    }

    func testEditModeOnBuiltInExposesIsBuiltInTrue() {
        let polish = Prompt.builtInPrompts().first(where: { $0.name == "Polish" })!
        let vm = TransformEditorViewModel(mode: .edit(polish))
        XCTAssertTrue(vm.isBuiltIn)
    }

    // MARK: - Validation

    func testValidationRejectsEmptyName() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.content = "Some body."
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNotNil(vm.nameError)
        XCTAssertFalse(vm.isValid)
    }

    func testValidationRejectsEmptyContent() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNotNil(vm.contentError)
        XCTAssertFalse(vm.isValid)
    }

    func testValidationRejectsDuplicateNameCaseInsensitive() {
        let other = Prompt(
            id: UUID(),
            name: "Polish",
            content: "body",
            category: .transform
        )
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "polish"  // different case
        vm.content = "Body"
        vm.validate(
            existingPrompts: [other],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNotNil(vm.nameError)
        XCTAssertFalse(vm.isValid)
    }

    func testValidationRejectsDuplicateNameAcrossPromptCategories() {
        let summary = Prompt(
            id: UUID(),
            name: "Summary",
            content: "body",
            category: .result
        )
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "summary"
        vm.content = "Body"
        vm.validate(
            existingPrompts: [summary],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNotNil(vm.nameError)
        XCTAssertFalse(vm.isValid)
    }

    func testValidationDuplicateIgnoresSelfInEditMode() {
        let prompt = Prompt(
            id: UUID(),
            name: "Polish",
            content: "Body",
            category: .transform
        )
        let vm = TransformEditorViewModel(mode: .edit(prompt))
        vm.validate(
            existingPrompts: [prompt],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNil(vm.nameError, "Editing the same Transform with its existing name should not read as duplicate.")
    }

    func testShortcutCollisionSurfacesAsError() {
        let stub = StubCollisionChecker()
        stub.result = .missingModifier

        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.content = "Body"
        vm.shortcut = KeyboardShortcut(modifiers: 0, keyCode: 0x12, keyLabel: "1")
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: stub
        )
        XCTAssertNotNil(vm.shortcutError)
        XCTAssertFalse(vm.isValid)
    }

    func testValidationPassesReservedHotkeysToCollisionChecker() {
        let stub = StubCollisionChecker()
        let reserved = [
            TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .fn),
            TransformShortcutReservedHotkey(name: "file transcription", trigger: .option),
        ]

        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.content = "Body"
        vm.shortcut = opt1
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: reserved,
            collisionChecker: stub
        )

        XCTAssertEqual(stub.receivedReservedHotkeys, reserved)
    }

    func testNilShortcutIsValidDormantState() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.content = "Body"
        vm.shortcut = nil
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNil(vm.shortcutError)
        XCTAssertTrue(vm.isValid, "A Transform with no shortcut is a valid dormant state.")
    }

    // MARK: - buildSavable

    func testBuildSavableReturnsNilWhenInvalid() {
        let vm = TransformEditorViewModel(mode: .create)
        // Missing content + name.
        vm.name = ""
        vm.content = ""
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNil(vm.buildSavable())
    }

    func testBuildSavableForCreateGeneratesNewUUID() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.content = "Make it crisp."
        vm.runningLabel = "Sharpening…"
        vm.shortcut = opt1
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        let saved = vm.buildSavable()
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.name, "Sharpen")
        XCTAssertEqual(saved?.category, .transform)
        XCTAssertFalse(saved?.isBuiltIn ?? true)
        XCTAssertEqual(saved?.runningLabel, "Sharpening…")
        XCTAssertNotNil(saved?.keyboardShortcut)
    }

    func testBuildSavableForEditPreservesIDAndCreatedAt() {
        let originalID = UUID()
        let originalCreatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let prompt = Prompt(
            id: originalID,
            name: "Polish",
            content: "Old body",
            category: .transform,
            isBuiltIn: true,
            createdAt: originalCreatedAt,
            keyboardShortcut: opt1.encodedString(),
            runningLabel: "Polishing…"
        )
        let vm = TransformEditorViewModel(mode: .edit(prompt))
        vm.content = "New body"
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        let saved = vm.buildSavable()
        XCTAssertEqual(saved?.id, originalID)
        XCTAssertEqual(saved?.createdAt, originalCreatedAt)
        XCTAssertEqual(saved?.content, "New body")
        XCTAssertTrue(saved?.isBuiltIn ?? false, "Built-in flag must survive editing — protects the row from custom-transform deletion semantics.")
    }

    func testBuildSavableEmptyRunningLabelEncodesNil() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Sharpen"
        vm.content = "Body"
        vm.runningLabel = "   " // whitespace only
        vm.validate(
            existingPrompts: [],
            reservedHotkeys: [],
            collisionChecker: StubCollisionChecker()
        )
        XCTAssertNil(vm.buildSavable()?.runningLabel, "Whitespace-only running label normalizes to nil.")
    }

    func testDefaultRunningLabelPreviewMatchesPromptDerivation() {
        let vm = TransformEditorViewModel(mode: .create)
        vm.name = "Make concise"
        XCTAssertEqual(vm.defaultRunningLabelPreview, "Transforming…")

        vm.name = "Polish"
        XCTAssertEqual(vm.defaultRunningLabelPreview, "Polishing…")
    }
}
