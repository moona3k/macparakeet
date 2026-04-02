# Keystroke Action Snippets

> Status: **ACTIVE**
> GitHub Issue: moona3k/macparakeet#40
> Branch: `feature/keystroke-action-snippets`
> Reviewed by: Codex, Gemini (senior Swift/macOS engineer). All P0/P1 findings addressed.

## Overview

Extend the text snippets system to support **keystroke actions** — snippets where speaking a trigger phrase simulates a keypress (e.g., Return, Tab, Escape) instead of inserting replacement text. This enables hands-free command execution in terminal apps like Claude Code CLI.

**User story (from issue #40):** "I started using [MacParakeet] as input in claude code cli and similar. I notice a small thing that would make it work better... when using the terminal it would be amazing to have a configurable word (e.g. RETURN) that — if at the end of a detection — triggers a return keypress."

## Design Decisions

### End-of-text only matching

Keystroke action snippets **only trigger when they appear at the end** of the dictated text. If the trigger word appears mid-sentence, it is left as literal text.

**Why:** Simulating a keypress mid-paste would require splitting the text into multiple paste operations with interleaved keystrokes — complex, fragile, and not what the user asked for. End-of-text matching is simple, predictable, and covers the primary use case (terminal command submission).

**Example:**
- "list all files in src return" → pastes "list all files in src", simulates Return
- "press return to continue" → pastes "press return to continue" (no action)

### Punctuation-tolerant matching

Parakeet TDT almost always appends trailing punctuation (`.`, `,`, `?`) after the last spoken word. The regex must tolerate this or the feature appears broken out of the box.

**Pattern:** `\b<trigger>[.!?,;:]*\s*$` — matches trigger at end of text with optional trailing punctuation and whitespace.

**Example:** User says "hello return", Parakeet outputs "Hello return." → action fires, punctuation stripped.

### Reuse existing snippet infrastructure

The feature extends `TextSnippet` with an optional `action` field rather than creating a separate model. Snippet matching (word-boundary regex, longest-first, enable/disable, use counts) transfers directly.

**Why:** Keeps the mental model simple — one place to manage all trigger phrases. The UI already has search, toggle, delete, and use count tracking. No new sidebar item, no new repository, no new database table.

### Supported key actions (v1)

| Action | CGKeyCode | Use case |
|--------|-----------|----------|
| Return | `0x24` | Execute terminal commands |
| Tab | `0x30` | Autocomplete in terminals/shells |
| Escape | `0x35` | Cancel prompts, dismiss dialogs |

Extensible to more keys later via the enum, but ship with these three. They cover the terminal workflow Veit described.

### Post-paste timing

The keystroke fires **200ms after Cmd+V paste** to ensure the receiving app has processed the pasted text. 200ms is conservative enough for Electron-based apps (VS Code, iTerm2) while remaining imperceptible to the user.

Sequence: Paste (Cmd+V) → 200ms → Keystroke (e.g., Return) → Clipboard restore (250ms from paste start).

**Known limitation:** If the user switches focus between paste and keystroke (~200ms window), the keystroke hits the wrong app. This is accepted — the window is too short for intentional focus switching and matches the existing paste behavior.

### Empty text = keystroke only

If the trigger word is the entire dictation (e.g., user says just "return"), **skip the paste entirely** and only simulate the keystroke. Don't paste an empty string or trailing space.

### No trailing space with action

When a post-paste action is present, **do not append the trailing space** that normal dictation adds. For Tab autocomplete, a trailing space breaks completion ("git che " + Tab fails). The action replaces the role of the trailing space.

### Public service boundary: `DictationResult`

Introduce a lightweight `DictationResult` struct to carry both the `Dictation` model and the ephemeral `KeyAction?` through the public `DictationServiceProtocol` boundary. This avoids polluting the persisted `Dictation` model with transient state and avoids changing a private method's return type without updating the public interface.

### Partial success error handling

Paste-succeeded-but-keystroke-failed is a new failure mode. The coordinator must **not** fall back to copying the transcript to clipboard (which would duplicate input). Instead, log the keystroke failure and still report paste success — the text was delivered, only the bonus keystroke was lost.

## Implementation Steps

### Step 1: Add `KeyAction` enum to MacParakeetCore

Create `Sources/MacParakeetCore/Models/KeyAction.swift`:

```swift
import Foundation

/// A keystroke action that can be simulated after dictation paste.
public enum KeyAction: String, Codable, Sendable, CaseIterable, Equatable {
    case returnKey = "return"
    case tab = "tab"
    case escape = "escape"

    /// The CGKeyCode for this action.
    public var keyCode: UInt16 {
        switch self {
        case .returnKey: return 0x24
        case .tab:       return 0x30
        case .escape:    return 0x35
        }
    }

    /// Human-readable label for the UI.
    public var label: String {
        switch self {
        case .returnKey: return "⏎ Return"
        case .tab:       return "⇥ Tab"
        case .escape:    return "⎋ Escape"
        }
    }
}
```

### Step 2: Extend `TextSnippet` model

In `Sources/MacParakeetCore/Models/TextSnippet.swift`:

- Add `action: KeyAction?` field (nil = text snippet, non-nil = keystroke snippet)
- Text snippets: `expansion` is used, `action` is nil
- Keystroke snippets: `action` is set, `expansion` stores the action's label for display/search

```swift
public struct TextSnippet: Codable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var isEnabled: Bool
    public var useCount: Int
    public var action: KeyAction?     // nil = text expansion, non-nil = keystroke
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        isEnabled: Bool = true,
        useCount: Int = 0,
        action: KeyAction? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
        self.useCount = useCount
        self.action = action
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

GRDB `Codable` conformance handles the optional column automatically (nil when column is NULL). Unknown `action` values decode as nil (graceful degradation if a future version adds actions then rolls back).

### Step 3: Database migration

In `Sources/MacParakeetCore/Database/DatabaseManager.swift`, add after the last migration:

```swift
// v0.7 — Keystroke action snippets (issue #40)
migrator.registerMigration("v0.7-snippet-key-action") { db in
    try db.alter(table: "text_snippets") { t in
        t.add(column: "action", .text)  // NULL = text snippet, non-NULL = KeyAction rawValue
    }
}
```

Existing rows get `action = NULL` → remain text snippets. Zero data migration needed.

### Step 4: Add `DictationResult` to the public service boundary

Create `Sources/MacParakeetCore/Models/DictationResult.swift`:

```swift
import Foundation

/// Result of processing a dictation — carries the persisted Dictation
/// plus any ephemeral post-paste action from the text processing pipeline.
public struct DictationResult: Sendable {
    public let dictation: Dictation
    public let postPasteAction: KeyAction?

    public init(dictation: Dictation, postPasteAction: KeyAction? = nil) {
        self.dictation = dictation
        self.postPasteAction = postPasteAction
    }
}
```

Update `DictationServiceProtocol` in `Sources/MacParakeetCore/Services/DictationService.swift`:

```swift
// Change return types from Dictation to DictationResult
func stopRecording() async throws -> DictationResult
func undoCancel() async throws -> DictationResult
```

Update the private `processCapturedAudio()` to return `DictationResult` (carrying `refinement.postPasteAction`).

Update both `stopRecording()` and `undoCancel()` to propagate the result. Both methods call `processCapturedAudio()` internally, so both paths get action support automatically.

**Mock update:** `MockDictationService` in tests must conform to the new return type. Return `DictationResult(dictation: dictation)` (no action) for existing tests.

### Step 5: Modify text processing pipeline

In `Sources/MacParakeetCore/TextProcessing/TextProcessingPipeline.swift`:

**5a. Split snippets by type in `process()`:**

Before the pipeline runs, partition snippets into text snippets and action snippets:

```swift
let textSnippets = snippets.filter { $0.action == nil }
let actionSnippets = snippets.filter { $0.action != nil }
```

Text snippets flow through `expandSnippets()` as today (Step 3 of pipeline). Action snippets are checked separately.

**5b. Add `extractTrailingAction()` method:**

After Step 4 (whitespace cleanup), check if the text ends with an action snippet's trigger. The regex is **punctuation-tolerant** to handle Parakeet's trailing punctuation:

```swift
func extractTrailingAction(
    from text: String,
    actionSnippets: [TextSnippet]
) -> (String, TextSnippet?) {
    guard !actionSnippets.isEmpty else { return (text, nil) }

    // Sort longest-trigger-first (same as expandSnippets)
    let sorted = actionSnippets
        .filter { $0.isEnabled }
        .sorted { $0.trigger.count > $1.trigger.count }

    for snippet in sorted {
        // Punctuation-tolerant: match trigger at end with optional trailing punctuation
        let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
        let pattern = "\\b\(escaped)[.!?,;:]*\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            continue
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range) {
            // Remove the trigger + trailing punctuation from the text
            let cleaned = (text as NSString).replacingCharacters(in: match.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned, snippet)
        }
    }

    return (text, nil)
}
```

**5c. Update `TextProcessingResult`:**

In `Sources/MacParakeetCore/TextProcessing/TextProcessingResult.swift`:

```swift
public struct TextProcessingResult: Sendable {
    public let text: String
    public let expandedSnippetIDs: Set<UUID>
    public let postPasteAction: KeyAction?

    public init(
        text: String,
        expandedSnippetIDs: Set<UUID> = [],
        postPasteAction: KeyAction? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.postPasteAction = postPasteAction
    }
}
```

**5d. Wire it in `process()`:**

```swift
public func process(
    text: String,
    customWords: [CustomWord],
    snippets: [TextSnippet]
) -> TextProcessingResult {
    guard !text.isEmpty else {
        return TextProcessingResult(text: "")
    }

    let textSnippets = snippets.filter { $0.action == nil }
    let actionSnippets = snippets.filter { $0.action != nil }

    var result = text

    // Step 1: Filler removal
    result = removeFillers(from: result)

    // Step 2: Custom word replacements
    result = applyCustomWords(to: result, words: customWords)

    // Step 3: Text snippet expansion (text-type only)
    let (expandedText, expandedIDs) = expandSnippets(in: result, snippets: textSnippets)
    result = expandedText

    // Step 4: Whitespace cleanup
    result = cleanWhitespace(in: result)

    // Step 5: Extract trailing action snippet (after cleanup, so trigger isn't mangled)
    var actionIDs = Set<UUID>()
    var postPasteAction: KeyAction? = nil
    let (actionCleanedText, matchedSnippet) = extractTrailingAction(
        from: result, actionSnippets: actionSnippets
    )
    if let matchedSnippet {
        result = actionCleanedText
        postPasteAction = matchedSnippet.action
        actionIDs.insert(matchedSnippet.id)
    }

    return TextProcessingResult(
        text: result,
        expandedSnippetIDs: expandedIDs.union(actionIDs),
        postPasteAction: postPasteAction
    )
}
```

**5e. Regression guard — text snippet expansion ending in action trigger:**

Because action extraction runs on the fully-expanded text (after Step 3), a text snippet whose expansion ends with a word matching an action trigger could false-match. Example: text snippet "sign off" → "Best regards, Daniel\nReturn" would trigger an action.

**Mitigation:** The `\b` word boundary in the regex requires the trigger to be a standalone word. Most action triggers are common English words, but the recommended multi-word triggers ("press return", "hit tab") make false matches extremely unlikely. The UI guidance card recommends multi-word triggers for this reason.

If this becomes a real issue, a future iteration can match against the pre-expansion text by recording which trailing words were original vs expanded. Not implementing this now — YAGNI.

### Step 6: Propagate action through refinement layer

In `Sources/MacParakeetCore/TextProcessing/TextRefinementService.swift`, update `TextRefinementResult`:

```swift
public struct TextRefinementResult: Sendable {
    public let text: String?
    public let expandedSnippetIDs: Set<UUID>
    public let path: TextRefinementPath
    public let postPasteAction: KeyAction?

    public init(
        text: String?,
        expandedSnippetIDs: Set<UUID>,
        path: TextRefinementPath,
        postPasteAction: KeyAction? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.path = path
        self.postPasteAction = postPasteAction
    }
}
```

In `refine()`, pass through the action for deterministic mode. Raw mode returns `postPasteAction: nil` — action snippets require the deterministic pipeline.

### Step 7: Add `simulateKeystroke()` to ClipboardService

In `Sources/MacParakeetCore/Services/ClipboardService.swift`:

**7a. Add to protocol with default implementation:**

```swift
public protocol ClipboardServiceProtocol: Sendable {
    func pasteText(_ text: String) async throws
    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws
    func copyToClipboard(_ text: String) async
}

// Default implementation preserves backward compatibility for existing mocks
extension ClipboardServiceProtocol {
    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws {
        try await pasteText(text)
    }
}
```

The protocol extension provides a default implementation so `MockClipboardService` in tests compiles without modification. Existing tests continue to work — they never set a post-paste action, so the default (paste-only) is correct.

**7b. Implement `simulateKeystroke()`:**

```swift
private func simulateKeystroke(_ keyCode: UInt16) throws {
    guard AXIsProcessTrusted() else {
        throw ClipboardServiceError.accessibilityPermissionRequired
    }

    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ClipboardServiceError.eventSourceUnavailable
    }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw ClipboardServiceError.eventCreationFailed
    }

    // No modifier flags — bare keypress
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}
```

**7c. Implement `pasteTextWithAction()` on concrete class:**

```swift
public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws {
    guard let action = postPasteAction else {
        try await pasteText(text)
        return
    }

    // If text is empty (trigger was entire dictation), skip paste — just fire keystroke
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try simulateKeystroke(action.keyCode)
        return
    }

    // Paste text (no trailing space — action replaces the role of the space)
    try await pasteText(text)

    // Wait for paste to land in the receiving app before sending keystroke
    try await Task.sleep(for: .milliseconds(200))

    // Fire keystroke — if this fails, paste already succeeded so don't fallback
    try simulateKeystroke(action.keyCode)
}
```

**Note on clipboard restore timing:** The existing `defer` block in `pasteText()` restores the clipboard after 150ms. The keystroke fires at 200ms, after the restore. This is fine — the keystroke doesn't use the clipboard. If the 150ms restore feels too early (before the app fully processes the paste), we can increase it to 250ms during testing.

### Step 8: Wire action through DictationFlowCoordinator

In `Sources/MacParakeet/App/DictationFlowCoordinator.swift`:

**8a. Store the action alongside the dictation:**

```swift
private var pendingPostPasteAction: KeyAction?
```

**8b. Set it in both stop paths:**

In the `.stopRecordingAndTranscribe` effect handler:

```swift
let result = try await dictationService.stopRecording()
self.currentDictation = result.dictation
self.pendingPostPasteAction = result.postPasteAction
```

In the `.undoCancelAndTranscribe` effect handler (same pattern):

```swift
let result = try await dictationService.undoCancel()
self.currentDictation = result.dictation
self.pendingPostPasteAction = result.postPasteAction
```

**8c. Use it in the `.pasteTranscript` effect:**

Replace the current paste call (line 382) with:

```swift
let transcript = dictation.cleanTranscript ?? dictation.rawTranscript

if self.pendingPostPasteAction != nil {
    // Action mode: no trailing space, action replaces the space role
    try await self.clipboardService.pasteTextWithAction(
        transcript,
        postPasteAction: self.pendingPostPasteAction
    )

    // Telemetry for keystroke action
    if let action = self.pendingPostPasteAction {
        Telemetry.send(.keystrokeSnippetFired, props: ["action": action.rawValue])
    }
} else {
    // Normal mode: trailing space as before
    try await self.clipboardService.pasteText(transcript + " ")
}
self.pendingPostPasteAction = nil
```

**8d. Partial success error handling:**

In the `.pasteTranscript` catch block, distinguish paste failure from keystroke failure. If `pasteTextWithAction` throws after the paste succeeded (during the keystroke phase), the text was already delivered. **Do not** fall back to `copyToClipboard` — that would duplicate input.

The simplest approach: `pasteTextWithAction` should catch keystroke errors internally and log them, only re-throwing paste errors. This keeps the coordinator's error handling unchanged.

Update `pasteTextWithAction`:

```swift
// After paste succeeds, keystroke failure is non-fatal
do {
    try simulateKeystroke(action.keyCode)
} catch {
    // Log but don't throw — text was already pasted successfully
    // The user gets their text; they just need to press Return manually
}
```

**8e. Clear action on cancel/failure paths:**

In cancel, dismiss, and failure event handlers, nil out the pending action:

```swift
self.pendingPostPasteAction = nil
```

### Step 9: Update the Snippets UI

In `Sources/MacParakeetViewModels/TextSnippetsViewModel.swift`:

**9a. Add state for snippet type selection:**

```swift
public var newSnippetIsKeystroke: Bool = false
public var newKeystrokeAction: KeyAction = .returnKey
```

**9b. Update `addSnippet()`:**

```swift
public func addSnippet() {
    guard let repo else { return }
    let trimmedTrigger = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrigger.isEmpty else { return }

    // Duplicate check (case-insensitive, across both snippet types)
    if snippets.contains(where: { $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame }) {
        errorMessage = "'\(trimmedTrigger)' already exists"
        return
    }

    let snippet: TextSnippet
    if newSnippetIsKeystroke {
        snippet = TextSnippet(
            trigger: trimmedTrigger,
            expansion: newKeystrokeAction.label,  // Store label for display/search
            action: newKeystrokeAction
        )
    } else {
        let rawExpansion = newExpansion.trimmingCharacters(in: .whitespaces)
        let processedExpansion = rawExpansion.replacingOccurrences(of: "\\n", with: "\n")
        guard !processedExpansion.isEmpty else { return }
        snippet = TextSnippet(trigger: trimmedTrigger, expansion: processedExpansion)
    }

    do {
        try repo.save(snippet)
        Telemetry.send(.snippetAdded)
        newTrigger = ""
        newExpansion = ""
        newSnippetIsKeystroke = false
        errorMessage = nil
        loadSnippets()
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

**9c. Validation:** When `newSnippetIsKeystroke` is true, the expansion field is hidden and not required — the action picker replaces it. The "Add" button disabled state only checks trigger is non-empty. The duplicate check prevents creating both a text snippet and action snippet with the same trigger.

### Step 10: Update TextSnippetsView UI

In `Sources/MacParakeet/Views/Vocabulary/TextSnippetsView.swift`:

**10a. Add Snippet card — add type picker:**

Between the trigger field and expansion field, add a segmented picker:

```swift
Picker("Type", selection: $viewModel.newSnippetIsKeystroke) {
    Text("Text").tag(false)
    Text("Keystroke").tag(true)
}
.pickerStyle(.segmented)
.labelsHidden()
```

**10b. Conditional expansion input:**

```swift
if viewModel.newSnippetIsKeystroke {
    Picker("Action", selection: $viewModel.newKeystrokeAction) {
        ForEach(KeyAction.allCases, id: \.self) { action in
            Text(action.label).tag(action)
        }
    }
    .labelsHidden()
} else {
    TextField("Expansion", text: $viewModel.newExpansion)
        .textFieldStyle(.roundedBorder)
}
```

**10c. Snippet row display — show action badge for keystroke snippets:**

In `snippetRow()`, conditionally show action vs expansion:

```swift
if let action = snippet.action {
    Text("Action: \(action.label)")
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(DesignSystem.Colors.accent)
} else {
    Text("Expands to: \(snippet.expansion.replacingOccurrences(of: "\n", with: " ↵ "))")
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
}
```

**10d. Update guidance card — add keystroke tip with multi-word trigger recommendation:**

```swift
HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
    Image(systemName: "command")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(DesignSystem.Colors.warningAmber)
    Text("Use Keystroke type to simulate a keypress at the end of dictation — great for terminal command execution. Use distinctive trigger phrases like \"press return\" or \"hit tab\" to avoid false matches with common words.")
        .font(DesignSystem.Typography.bodySmall)
        .foregroundStyle(.secondary)
}
```

### Step 11: Tests

**11a. Pipeline unit tests** in `Tests/MacParakeetTests/TextProcessing/TextProcessingPipelineTests.swift`:

```swift
// MARK: - Keystroke Action Snippets

func testActionSnippetAtEndOfText() {
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "hello world return", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Hello world")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}

func testActionSnippetMidTextIgnored() {
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "press return to continue", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Press return to continue")
    XCTAssertNil(result.postPasteAction)
}

func testActionSnippetCaseInsensitive() {
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "hello RETURN", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Hello")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}

func testActionSnippetWithTrailingPunctuation() {
    // Parakeet almost always adds trailing punctuation — must still match
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "hello world return.", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Hello world")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}

func testActionSnippetWithTrailingComma() {
    let snippets = [
        TextSnippet(trigger: "press tab", expansion: "tab", action: .tab)
    ]
    let result = pipeline.process(text: "git che press tab,", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Git che")
    XCTAssertEqual(result.postPasteAction, .tab)
}

func testActionSnippetTracksExpandedID() {
    let snippet = TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    let result = pipeline.process(text: "hello return", customWords: [], snippets: [snippet])
    XCTAssertTrue(result.expandedSnippetIDs.contains(snippet.id))
}

func testNoActionSnippetsReturnsNilAction() {
    let snippets = [
        TextSnippet(trigger: "my sig", expansion: "Best regards, Daniel")
    ]
    let result = pipeline.process(text: "hello my sig", customWords: [], snippets: snippets)
    XCTAssertNil(result.postPasteAction)
}

func testTextAndActionSnippetsTogether() {
    let snippets = [
        TextSnippet(trigger: "my sig", expansion: "Best regards"),
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "my sig return", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Best regards")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}

func testDisabledActionSnippetIgnored() {
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", isEnabled: false, action: .returnKey)
    ]
    let result = pipeline.process(text: "hello return", customWords: [], snippets: snippets)
    XCTAssertNil(result.postPasteAction)
    XCTAssertEqual(result.text, "Hello return")
}

func testTabActionSnippet() {
    let snippets = [
        TextSnippet(trigger: "press tab", expansion: "tab", action: .tab)
    ]
    let result = pipeline.process(text: "git che press tab", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Git che")
    XCTAssertEqual(result.postPasteAction, .tab)
}

func testActionOnlyDictation() {
    // User says just "return" — text should be empty after extraction
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "return", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}

func testTriggerMidTextAndAtEnd() {
    // "press return and then return" — should match trailing "return" only
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = pipeline.process(text: "press return and then return", customWords: [], snippets: snippets)
    XCTAssertEqual(result.text, "Press return and then")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}
```

**11b. Refinement service test** in `Tests/MacParakeetTests/TextProcessing/TextRefinementServiceTests.swift`:

```swift
func testRawModeSkipsActionSnippets() async {
    let service = TextRefinementService()
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = await service.refine(
        rawText: "hello return",
        mode: .raw,
        customWords: [],
        snippets: snippets
    )
    XCTAssertNil(result.text)  // Raw mode returns nil text
    XCTAssertNil(result.postPasteAction)
}

func testDeterministicModeReturnsAction() async {
    let service = TextRefinementService()
    let snippets = [
        TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
    ]
    let result = await service.refine(
        rawText: "hello return",
        mode: .clean,
        customWords: [],
        snippets: snippets
    )
    XCTAssertEqual(result.text, "Hello")
    XCTAssertEqual(result.postPasteAction, .returnKey)
}
```

**11c. KeyAction model tests** in `Tests/MacParakeetTests/Models/KeyActionTests.swift`:

```swift
func testKeyActionKeyCodes() {
    XCTAssertEqual(KeyAction.returnKey.keyCode, 0x24)
    XCTAssertEqual(KeyAction.tab.keyCode, 0x30)
    XCTAssertEqual(KeyAction.escape.keyCode, 0x35)
}

func testKeyActionCodable() {
    for action in KeyAction.allCases {
        let data = try! JSONEncoder().encode(action)
        let decoded = try! JSONDecoder().decode(KeyAction.self, from: data)
        XCTAssertEqual(decoded, action)
    }
}

func testKeyActionLabels() {
    XCTAssertFalse(KeyAction.returnKey.label.isEmpty)
    XCTAssertFalse(KeyAction.tab.label.isEmpty)
    XCTAssertFalse(KeyAction.escape.label.isEmpty)
}
```

**11d. Database tests:**

- **Migration test** — verify existing text snippets survive migration with `action = nil`
- **Repository round-trip** — verify save/fetch of `TextSnippet` with `action: .returnKey` preserves the action

**11e. ViewModel tests** in `Tests/MacParakeetTests/ViewModels/TextSnippetsViewModelTests.swift`:

```swift
func testAddKeystrokeSnippet() {
    // Configure viewModel with mock repo
    viewModel.newTrigger = "press return"
    viewModel.newSnippetIsKeystroke = true
    viewModel.newKeystrokeAction = .returnKey
    viewModel.addSnippet()

    XCTAssertEqual(viewModel.snippets.count, 1)
    XCTAssertEqual(viewModel.snippets.first?.action, .returnKey)
    XCTAssertEqual(viewModel.snippets.first?.trigger, "press return")
    // State reset after add
    XCTAssertEqual(viewModel.newTrigger, "")
    XCTAssertFalse(viewModel.newSnippetIsKeystroke)
}

func testDuplicateTriggerAcrossTypes() {
    // Add a text snippet with trigger "return"
    viewModel.newTrigger = "return"
    viewModel.newExpansion = "some text"
    viewModel.addSnippet()
    XCTAssertEqual(viewModel.snippets.count, 1)

    // Try to add a keystroke snippet with same trigger — should fail
    viewModel.newTrigger = "return"
    viewModel.newSnippetIsKeystroke = true
    viewModel.newKeystrokeAction = .returnKey
    viewModel.addSnippet()
    XCTAssertEqual(viewModel.snippets.count, 1)  // Still 1
    XCTAssertNotNil(viewModel.errorMessage)
}
```

### Step 12: Telemetry

Add `keystrokeSnippetFired` event to `TelemetryEventName` in `Sources/MacParakeetCore/Services/TelemetryEvent.swift`:

```swift
case keystrokeSnippetFired = "keystroke_snippet_fired"
```

Fire it in the coordinator when a post-paste action executes. Props: `action` (return/tab/escape).

## Files Changed

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Models/KeyAction.swift` | **NEW** — enum with keyCode, label, Codable |
| `Sources/MacParakeetCore/Models/DictationResult.swift` | **NEW** — wraps Dictation + ephemeral KeyAction |
| `Sources/MacParakeetCore/Models/TextSnippet.swift` | Add `action: KeyAction?` field |
| `Sources/MacParakeetCore/TextProcessing/TextProcessingPipeline.swift` | Split snippet types, add `extractTrailingAction()`, wire in `process()` |
| `Sources/MacParakeetCore/TextProcessing/TextProcessingResult.swift` | Add `postPasteAction: KeyAction?` |
| `Sources/MacParakeetCore/TextProcessing/TextRefinementService.swift` | Pass through `postPasteAction` in result |
| `Sources/MacParakeetCore/Services/ClipboardService.swift` | Add `simulateKeystroke()`, `pasteTextWithAction()` with protocol default |
| `Sources/MacParakeetCore/Services/DictationService.swift` | Return `DictationResult` from `stopRecording()` and `undoCancel()` |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `keystrokeSnippetFired` event |
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | Add migration for `action` column |
| `Sources/MacParakeetViewModels/TextSnippetsViewModel.swift` | Add keystroke type state, update `addSnippet()` |
| `Sources/MacParakeet/Views/Vocabulary/TextSnippetsView.swift` | Type picker, conditional expansion/action UI, guidance tip |
| `Sources/MacParakeet/App/DictationFlowCoordinator.swift` | Store and execute `pendingPostPasteAction`, clear on cancel/failure |
| `Tests/MacParakeetTests/TextProcessing/TextProcessingPipelineTests.swift` | ~12 new test cases |
| `Tests/MacParakeetTests/TextProcessing/TextRefinementServiceTests.swift` | 2 new tests (raw mode, deterministic mode) |
| `Tests/MacParakeetTests/Models/KeyActionTests.swift` | **NEW** — keyCode, Codable, label tests |
| `Tests/MacParakeetTests/ViewModels/TextSnippetsViewModelTests.swift` | 2 new tests (add keystroke, duplicate prevention) |
| `Tests/MacParakeetTests/Database/TextSnippetRepositoryTests.swift` | Round-trip test with action field |
| Mock files (MockDictationService, etc.) | Update return types to `DictationResult` |

## Out of Scope

- Modifier key combinations (Cmd+Enter, Ctrl+C) — future extension if needed
- Multiple sequential actions in one dictation (e.g., Tab then Return)
- Mid-text action triggers (splitting paste into segments)
- Custom arbitrary keyCodes — only the three preset actions for now
- Action snippets in raw processing mode (requires deterministic pipeline)
- Pre-expansion trigger matching (matching against original text before text snippet expansion) — unnecessary given multi-word trigger recommendation and duplicate trigger prevention

## Invariants (Must Not Break)

- Existing text snippets behave identically (action defaults to nil)
- Raw processing mode skips all snippet processing (including action snippets)
- Whitespace cleanup rules unchanged for text content
- Clipboard save/restore still works correctly
- Disabled snippets are never matched (text or action)
- Longest-trigger-first priority preserved
- Snippet use counts track both text and action expansions
- Existing tests compile and pass (protocol defaults + mock updates for new return types)

## Review Findings Addressed

| Finding | Resolution |
|---------|------------|
| P0: Trailing punctuation breaks regex | Regex pattern updated to `\b<trigger>[.!?,;:]*\s*$` |
| P0: Trailing space before keystroke | No trailing space when action present; empty text skips paste |
| P0: Public service boundary gap | `DictationResult` struct, `stopRecording()` and `undoCancel()` updated |
| P1: Partial success error handling | Keystroke failure caught internally, paste success preserved |
| P1: `undoCancel()` path | Both stop paths now propagate `DictationResult` |
| P1: MockClipboardService breaks | Protocol extension provides default implementation |
| P1: Empty text after extraction | Skip paste, fire keystroke only |
| P1: Text expansion false-match | Multi-word trigger UI guidance; duplicate check prevents same trigger |
| P1: Testing gaps | Raw mode, coordinator flow, empty text, mid+end trigger, VM tests added |
| P2: Timing too aggressive | Increased to 200ms post-paste delay |
| P2: Focus race | Documented as accepted known limitation |
| P2: UI guidance for triggers | Guidance card recommends multi-word phrases |
| P2: ViewModel tests | Added keystroke CRUD and duplicate prevention tests |
