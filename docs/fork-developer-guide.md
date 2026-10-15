# Fork developer guide: build, run, debug, and add features

How to build MacParakeet on this Mac, fix the problems that come up, and add a
new feature end to end. For pulling upstream changes and making an installable
release copy, see [`fork-update-and-build-guide.md`](./fork-update-and-build-guide.md).

---

## 1. One-time setup

| Need | Check | Notes |
|---|---|---|
| Xcode in `/Applications` | `ls /Applications/Xcode.app` | Full Xcode, not just Command Line Tools |
| Apple Silicon Mac | `uname -m` → `arm64` | Speech models run on the Neural Engine |
| Node.js + npm (release builds only) | `node -v` | See the update guide, step 4 |

### Point the tools at Xcode (fixes most build errors)

This Mac's active developer directory is the Command Line Tools, so these fail:

```
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
error: Failed to decode version info for '/usr/bin/actool'
```

**Permanent fix** (asks for your password once):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Per-command fix** (no password): put this in front of any build/test command,
or `export` it in your terminal session:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The rest of this guide assumes one of the two is in effect.

---

## 2. Build and run from the terminal

Always run commands from the **repository root** (`~/projects/macparakeet`).
Running a script from inside `scripts/dist` gives
`... does not contain an Xcode project, workspace or package`.

| Goal | Command | Result |
|---|---|---|
| Compile everything | `swift build` | Fast check that code compiles |
| Run the app for testing | `scripts/dev/run_app.sh` | Builds, signs, and launches **MacParakeet-Dev** |
| Run focused tests | `swift test --filter FlashcardRepositoryTests` | Seconds |
| Run all tests (once, at the end) | `swift test` | Several minutes |
| CLI | `swift run macparakeet-cli --help` | |
| Installable app | `scripts/dist/build_app_bundle.sh` | `dist/MacParakeet.app` (see update guide) |

The dev app is separate from your installed app:

- Database, media, models and logs: `~/Library/Application Support/MacParakeet-Dev`
- **Shared** with the installed app: preferences and Keychain (see section 4)
- Logs: `log show --last 30m --style compact --predicate 'subsystem BEGINSWITH "com.macparakeet"'`

Use `run_app.sh` rather than calling `xcodebuild` yourself: it adds the
required `-skipMacroValidation` flag and safely replaces the running dev app.

---

## 3. Build and debug in Xcode

MacParakeet is a Swift package; there is no `.xcodeproj`.

1. Open it: `open Package.swift` (or in Xcode: File → Open → choose the folder).
2. Wait for packages to resolve (status bar at the top).
3. If Xcode asks about the **EquatableMacros** macro, click **Trust & Enable**.
   (The command-line equivalent is `-skipMacroValidation`. Do not install
   another Markdown package to get around it.)
4. Pick the **MacParakeet** scheme and **My Mac** as destination.
5. Product → **Build** (⌘B) to compile, **Test** (⌘U) to run tests, or open a
   test file and click the diamond next to one test.

**Running/debugging:** pressing Run (⌘R) in Xcode launches a bare executable,
not a signed `.app`, so microphone, accessibility and Keychain behave
differently and the app may misbehave. Recommended flow:

1. Launch with `scripts/dev/run_app.sh`.
2. In Xcode: Debug → **Attach to Process** → `MacParakeet`.
3. Set breakpoints, use the debugger and view hierarchy as usual.

SwiftUI previews are not used in this project; verify UI in the running app.

---

## 4. The Keychain error ("Saved credential access is blocked")

**Symptom:** summaries, flashcard generation, meeting titles, etc. fail with
`Saved credential access is blocked. Allow MacParakeet access in Keychain Access, then retry.`
This can happen even with a local LLM.

**Why:** AI provider API keys live in the login Keychain under service
`com.macparakeet.llm` (for example `llm_api_key_openaiCompatible` for a local
OpenAI-compatible server such as LM Studio / oMLX / Ollama). macOS only lets
the app that saved an item read it. The installed MacParakeet and the dev build
are signed differently, and a rebuild can change the signature, so the dev app
is refused. MacParakeet reads the Keychain without showing a prompt, so you get
an error instead of an "Allow" dialog.

**Fix A, allow the dev app (keeps the key):**

1. Open **Keychain Access**, search for `com.macparakeet.llm`.
2. Double-click the item → **Access Control** tab.
3. **+** → add `.build/xcode-dev/Build/Products/Debug/MacParakeet-Dev.app`
   (in this repository) → **Save Changes**.

You may need to repeat this after some rebuilds.

**Fix B, delete and re-save from the app you use:**

```bash
security find-generic-password -s com.macparakeet.llm      # see what is stored
security delete-generic-password -s com.macparakeet.llm -a llm_api_key_openaiCompatible
```

Then in the app: Settings → AI → choose the provider again (leave the key empty
if your local server needs none). Note: this removes the key for the installed
app too; re-enter it there if needed.

---

## 5. Troubleshooting

| Error | Fix |
|---|---|
| `requires Xcode, but active developer directory ... command line tools` | Section 1 |
| `Failed to decode version info for '/usr/bin/actool'` | Section 1 |
| `xcstringstool is not an executable file` | Section 1 (same cause) |
| `does not contain an Xcode project, workspace or package` | Run from repo root |
| `Macro "EquatableMacros" ... must be enabled` | Xcode: Trust & Enable; CLI: use `run_app.sh` |
| `Saved credential access is blocked` | Section 4 |
| `Building Ask requires Node.js and npm` | Update guide, step 4 |
| `Code Signature Invalid` / app killed after rebuild | Quit the dev app, run `run_app.sh` again |
| Permissions (mic, accessibility) not working in dev app | System Settings → Privacy & Security → re-enable *MacParakeet-Dev* |
| Weird stale build errors | `rm -rf .build/xcode-dev` then rebuild (keeps your data) |

`VERSION not set; ... 0.0.0` is only a warning. Use `VERSION=0.9.0 scripts/dist/build_app_bundle.sh` for a real version.

---

## 6. How the project is organised

```
Sources/
  MacParakeetCore/        Logic, models, database, services. No SwiftUI views.
    Models/               Row types (GRDB records)
    Database/             DatabaseManager (all migrations) + one repository per table
    Services/LLM/         AI provider access (LLMService, task routes)
    Flashcards/           Example of a self-contained feature folder
  MacParakeetViewModels/  @Observable view models, testable without the GUI
  MacParakeet/            The SwiftUI app: Views/, App/ (wiring), AppDelegate
  CLI/                    macparakeet-cli
Tests/MacParakeetTests/   XCTest, mirrors the source folders
spec/                     Feature list (02-features.md), data model (01-data-model.md), ADRs
```

Data flows **View → ViewModel → Service / Repository → SQLite**. Views never
touch the database or the AI directly.

Before editing a core area, read its README (`Audio/`, `STT/`,
`TextProcessing/`, `Database/`, ...). Also read
[`AGENTS.md`](../AGENTS.md) for the project rules.

---

## 7. Adding a feature, step by step

Worked example: **Flashcards** (branch `feature/anki-flashcards`). Look at
those files to see each step in real code.

### Step 0: branch

```bash
git switch -c feature/my-feature
```

### Step 1: model (`Sources/MacParakeetCore/...`)

A `Codable` struct plus GRDB conformance:

```swift
public struct Flashcard: Codable, Identifiable, Sendable {
    public var id: UUID
    public var front: String
    ...
}
extension Flashcard: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "flashcards"
    public enum Columns: String, ColumnExpression { case id, front, ... }
}
```

→ `Flashcards/Flashcard.swift`

### Step 2: database migration

Add a **new** block at the end of `registerMigrations` in
`Database/DatabaseManager.swift`. Never edit an existing migration; use the
next number:

```swift
migrator.registerMigration("v0.53-flashcards") { db in
    try db.create(table: "flashcards") { t in
        t.column("id", .text).primaryKey()
        t.column("front", .text).notNull()
        ...
    }
}
```

Use `.references("transcriptions", onDelete: .cascade)` or `.setNull` to link
to existing tables.

### Step 3: repository

A protocol (so tests and previews can fake it) and a GRDB implementation:

```swift
public protocol FlashcardRepositoryProtocol: Sendable { func save(_ card: Flashcard) throws ... }
public final class FlashcardRepository: FlashcardRepositoryProtocol {
    private let dbQueue: DatabaseQueue
    public func save(_ card: Flashcard) throws { try dbQueue.write { try card.save($0) } }
}
```

→ `Flashcards/FlashcardRepository.swift`

### Step 4: service (logic, AI, files)

Pure logic goes in a struct you can unit-test. For AI, take an
`LLMServiceProtocol` and call it. The user's configured provider (cloud or
local) is used automatically:

```swift
let text = try await llmService.generatePromptResult(transcript: transcript, systemPrompt: prompt)
```

→ `FlashcardGenerationService.swift`, `FSRSScheduler.swift`, `AnkiPackageReader/Writer.swift`

### Step 5: view model (`Sources/MacParakeetViewModels/`)

`@MainActor @Observable final class`, with a `configure(...)` method that
receives its dependencies. It holds UI state and calls repositories and
services. Long work runs in `Task { }` / `Task.detached`, never blocking the
main actor.

→ `FlashcardsViewModel.swift`

### Step 6: views (`Sources/MacParakeet/Views/<Feature>/`)

SwiftUI views that take the view model. Use `DesignSystem.Colors/Spacing/Typography`
and `.parakeetAction(.primary)` for buttons so the feature matches the app.

→ `Views/Flashcards/FlashcardsView.swift`, `MakeFlashcardsSheet.swift`

### Step 7: wire it in

| What | Where |
|---|---|
| Create the repository | `App/AppEnvironment.swift` (property + init) |
| Configure the view model, refresh when AI settings change | `App/AppEnvironmentConfigurer.swift` |
| Own the view model | `TranscriptionViewModel` (like `translationViewModel`) or pass it through `AppWindowCoordinator` → `MainWindowView` |
| New sidebar page | `SidebarItem` enum + `switch` in `Views/MainWindowView.swift` |
| Button on a transcript | tab bar in `Views/Transcription/TranscriptResultView.swift` |

### Step 8: tests (`Tests/MacParakeetTests/<Feature>/`)

```swift
final class FlashcardRepositoryTests: XCTestCase {
    var repo: FlashcardRepository!
    override func setUp() async throws { repo = FlashcardRepository(dbQueue: try DatabaseManager().dbQueue) }
    func testSomething() throws { ... }
}
```

`DatabaseManager()` with no arguments is an in-memory database with all
migrations applied. Run while iterating:

```bash
swift test --filter 'FlashcardRepositoryTests|FSRSSchedulerTests'
```

Run the full `swift test` once at the end. Some layout/audio tests already fail
on this machine without your changes; compare against the previous commit
before assuming you broke them.

### Step 9: try it, document it, commit

```bash
scripts/dev/run_app.sh                      # click through the feature
```

- Add a section to `spec/02-features.md` (what the user sees).
- If you added tables, document them in `spec/01-data-model.md`.
- Commit with a message that says what and why:

```bash
git add -A && git commit -m "Add flashcards: ..."
git push fork feature/my-feature
```

### Rules that save time

- Keep user data (transcripts, recordings, the database) safe: never delete it in code paths the user didn't ask for.
- Audio and transcripts stay on the Mac unless the user picked a cloud provider; say so in the feature docs when a feature sends text to an AI.
- New I/O uses `async/await`; don't block the main thread.
- Put reusable logic in `MacParakeetCore` so the CLI and tests can use it too.
