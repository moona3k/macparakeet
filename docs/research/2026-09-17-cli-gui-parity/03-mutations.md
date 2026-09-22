# Brief 03 — Mutation parity: corrections, rename, export

Investigated against source on `feat/cli-gui-parity` (worktree HEAD, `fb186349` base). Read-only; no product code touched.

## Summary table

| # | Candidate | Classification | Ship / Skip |
| - | --- | --- | --- |
| 1 | Speaker-identity corrections (rename/add/assign/split/removeSplit/merge/remove) missing from `meetings corrections` | meaningful-automation-gap | Ship |
| 2 | Speaker/timed-text corrections unreachable for file/URL transcriptions (meeting-only lookup) | meaningful-automation-gap | Ship |
| 3 | No CLI command to rename a meeting or set a file's title override after creation | meaningful-automation-gap | Ship |
| 4 | PDF/DOCX export omitted from CLI `export`/`transcribe` | by-design (real constraint), but re-verify | Skip until verified headless |
| 5 | Calendar skip/unskip mutation missing from CLI (`calendar upcoming` only annotates) | meaningful-automation-gap (deliberately deferred, not rejected) | Ship (small) |
| 6 | Share snapshots absent from CLI | by-design / not-worth-it (flag default-off, release builds ignore the flag) | Skip |
| 7 | `favorite`/`unfavorite` lack `--json` that sibling mutators have | robustness-bug / docs-drift-adjacent inconsistency | Ship (trivial) |

---

## 1. Speaker-identity corrections missing from `meetings corrections`

**Core API.** `SpeakerCorrectionCommand` (`Sources/MacParakeetCore/Models/SpeakerCorrection.swift:89-99`) has 10 cases: `rename, add, assign, split, removeSplit, merge, remove, editText, mergeSegments, reset`. `SpeakerCorrectionService.apply/undo/redo` (`Sources/MacParakeetCore/Services/SpeakerCorrectionService.swift`) is sourceType-agnostic — no `.meeting` check anywhere in that file.

**GUI call site.** `TranscriptionViewModel.applySpeakerCorrection`/`applySpeakerCorrectionAndWait` (`Sources/MacParakeetViewModels/TranscriptionViewModel.swift:2073-2136`) and `renameSpeaker` (`:2850-2899`) accept any `SpeakerCorrectionCommand` and gate only on `speakerCorrectionService != nil` / transcript readiness — **not** on `sourceType`. `loadSpeakerAttribution` (`:2000-2028`) has the same lack of a sourceType gate. GUI diarization applies "on by default … for file/URL transcription and meeting finalization with a system-audio track" (`spec/02-features.md:1415`), so file/URL transcriptions genuinely have speaker attribution to correct in the GUI.

**CLI gap.** `Sources/CLI/Commands/MeetingsCommand.swift:208-453` (`CorrectionsSubcommand`) only wires `editText` (`edit-line`), `mergeSegments` (`merge-lines`), `undo`, `redo`, `reset` through `runMeetingCorrection`/`runMeetingCorrectionHistory` (`:1219-1288`). `rename`, `add`, `assign`, `split`, `removeSplit`, `merge`, `remove` have no CLI entry point at all — an agent cannot rename a misidentified speaker, merge two speaker labels, or reassign a line to a different speaker from the CLI on a meeting, even though this is one of the most common GUI corrections workflows (per ADR-031 and the corrections UI).

**Contract impact.** Additive — new subcommands under the existing `meetings corrections` tree (`meetings corrections rename|assign|split|unsplit|merge-speakers|remove`). Minor CLI bump. `SpeakerCorrectionCommand` is already `Codable`/versioned (payload version 2, `SpeakerCorrection.swift:135`), so no schema risk.

**Test seams.** `Tests/CLITests/MeetingsCommandTests.swift` (existing corrections coverage lives here — confirmed no separate `MeetingsCorrectionsCommandTests` file exists); `Tests/MacParakeetTests/Services/SpeakerCorrectionServiceTests.swift` for the Core contract already under test.

**Recommendation: Ship.** Same pattern as `edit-line`/`merge-lines` — thin CLI wrapper over an already-generic, already-tested Core service. The main design work is `SpeakerCorrectionTarget`/`ManualSpeaker`/`SpeakerAssignment` CLI argument shapes (e.g. `--speaker-id`, `--to-speaker`, `--word-index`), which is a normal CLI-ergonomics decision, not a new capability.

## 2. Corrections unreachable for file/URL transcriptions

**Core API.** Same `SpeakerCorrectionService`/`SpeakerAttributionReadService` as above — no meeting restriction.

**GUI call site.** Same as above; the GUI's speaker-correction and timed-text-correction UI is reached from the shared transcript detail view regardless of `sourceType`.

**CLI gap.** `runMeetingCorrection`/`runMeetingCorrectionHistory` hard-call `findMeeting(idOrName:repo:)` (`Sources/CLI/Commands/CLIHelpers.swift:159-184`), which filters `sourceType == .meeting` explicitly (line 165, `fetchBySourceType(.meeting, …)` at 170/177). So even the four operations the CLI *does* expose (`edit-line`, `merge-lines`, `undo`, `redo`, `reset`) are meeting-only. A generic `findTranscription(id:repo:)` already exists and is sourceType-agnostic (`CLIHelpers.swift:128-148`, used by the top-level `export` and `transcript` commands for "a saved meeting or file/URL transcript" per `TranscriptCommand.swift:7`). ADR-031 itself frames the shipped CLI surface as "CLI meeting JSON" (`spec/adr/031-timed-transcript-corrections.md:124`), suggesting file/URL was out of the original slice rather than deliberately excluded.

**Contract impact.** Additive. Two shapes are viable: (a) generalize `meetings corrections` internals to also accept file/URL transcriptions found via `findTranscription`, keeping the command tree under `meetings` (would need a rename or a note that "meeting" here is a loose synonym for any diarized transcription — confusing), or (b) add a top-level `corrections` command (sibling to `export`/`transcript`) that uses `findTranscription` and is shared by meetings and file/URL alike, with `meetings corrections` becoming a thin alias for backward compatibility. (b) is more honest to the data model and mirrors the existing `export`/`transcript` precedent of "transcription-generic, not meeting-specific" top-level commands.

**Test seams.** New coverage needed in `Tests/CLITests/` for a file/URL transcription fixture going through the same correction flow already tested for meetings.

**Recommendation: Ship, as a follow-on to #1.** This is the same underlying capability; the only difference is the lookup gate. Do this at the same time as #1 rather than as two separate PRs, since the command surface should be designed once.

## 3. No CLI rename/title-override mutation

**Core API.** `TranscriptionRepository.updateFileName(id:fileName:)` and `updateTitleOverride(id:titleOverride:)` (`Sources/MacParakeetCore/Database/TranscriptionRepository.swift:37-38`, impl `:676-710`).

**GUI call site — meetings.** `TranscriptionViewModel.renameCurrentTranscription(to:)` (`Sources/MacParakeetViewModels/TranscriptionViewModel.swift:3104-3135`) — gated `sourceType == .meeting`, calls `updateFileName`. Triggered from `TranscriptResultView.swift:1919`.

**GUI call site — files.** `TranscriptionViewModel.renameCurrentTranscriptionTitle(to:)` (`:3137-3161`) and the library-list equivalent `TranscriptionLibraryViewModel.renameTranscriptionTitle(_:to:)` (`Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift:660-689`) — both gated `sourceType == .file`, call `updateTitleOverride`. Triggered from `TranscriptResultView.swift:1921`.

**Dictations — confirmed N/A.** `dictations` is a separate table (`spec/01-data-model.md:213-234`) with no title column at all; `DictationHistoryViewModel.swift` has no rename method. Dictations are raw captured text, not named library items — there is nothing to rename in the GUI, so this is correctly out of scope, not a gap.

**YouTube/podcast — confirmed N/A (for now).** Both rename methods above gate strictly on `.file`; `.youtube`/`.podcast` sourceTypes have no rename entry point anywhere in the GUI either. Not a CLI gap — the GUI itself doesn't support it, so there's no parity to close.

**CLI gap.** No command anywhere in `Sources/CLI/` calls `updateFileName` or `updateTitleOverride` as a mutation. The only place `titleOverride` appears in CLI is `MeetingImportCommand.swift:63`, which sets it once at import time via `MeetingImportRequest.titleOverride` — there is no way to rename an existing meeting or override an existing file transcription's title after the fact from the CLI. Meeting *types* and *labels* can be renamed (`MeetingClassificationCommands.swift`), and prompt collections can be renamed, but the transcription's own title cannot.

**Contract impact.** Additive. Natural shape: `meetings rename <id> --title <new>` (wraps `updateFileName`, meeting-only) and a generic `transcript rename <id> --title <new>` or `history rename <id> --title <new>` (wraps `updateTitleOverride`, file-sourceType-only, erroring clearly for other sourceTypes to match GUI behavior). Minor CLI bump.

**Test seams.** No existing CLI test file covers rename; would be new tests in `Tests/CLITests/MeetingsCommandTests.swift` and `Tests/CLITests/HistoryCommandTests.swift`.

**Recommendation: Ship.** Small, reuses existing repository methods verbatim, and closes a basic parity gap (renaming a meeting/file is one of the most ordinary Library actions in the GUI).

## 4. PDF/DOCX export omitted from CLI

**Settled facts confirmed.** `ExportService.exportToPDF`/`exportToDocx` are `@MainActor` (`Sources/MacParakeetCore/Services/ExportService.swift:21-22, 242, 313`); CLI's `ExportFormat` (`Sources/CLI/Commands/ExportCommand.swift:5-23`) has no `.pdf`/`.docx` case, and `Tests/CLITests/ExportCommandTests.swift:26-27` asserts `ExportFormat(rawValue: "pdf"/"docx") == nil`.

**Why `@MainActor`, precisely.** Not the whole `ExportService` class (it's `final class … Sendable`, `ExportService.swift:121`) — only `exportToPDF`, `exportToDocx`, and their shared `buildRichTranscript` (`:667`) are actor-isolated, because `buildRichTranscript` resolves dynamic system colors (`Colors.primary/.secondary/.tertiary` via `NSColor.labelColor` etc., `:647-651`) which Apple's overlay marks MainActor. `exportToPDF` itself uses `NSTextStorage`/`NSLayoutManager`/`NSGraphicsContext`/`CGContext(url:mediaBox:)` for headless PDF pagination — the code comment explicitly says this path was chosen *to avoid* `NSPrintOperation`'s modal run loop deadlock (`:238-241`), i.e. it was already written to be run-loop-independent.

**This is not a simple "CLI can't call `@MainActor`" problem.** The CLI already awaits a `@MainActor` `ExportService` method today: `TranscribeCommand.formattedString(for:format:)` (`Sources/CLI/Commands/TranscribeCommand.swift:980-989`) is `@MainActor` and is called from the CLI's async `main()` (`Sources/CLI/MacParakeetCLI.swift:45-56`) to reuse `formatSRT`/`formatVTT`/`formatDAPT` for `transcribe` output. Swift's cooperative-thread-pool `MainActor` doesn't require `NSApplication`/a real run loop to be awaited from an async context — that part works today, in production.

**What's actually unverified.** `ExportServiceTests.testExportToPDF`/`testExportToDocx` (`Tests/MacParakeetTests/Services/ExportServiceTests.swift:721-834`) exercise the exact `NSColor`/`NSGraphicsContext`/`CGContext` path unconditionally in `swift test`, with no `XCTSkip` for a headless runner — so this presumably already passes in whatever environment `swift test` runs in CI. But `integrations/README.md:95,131-137` explicitly targets **genuinely headless Apple Silicon Macs** ("recommended for agents/headless Macs," "the CLI does not support Linux/x86 … a headless Apple Silicon Mac is the deployment target") — i.e., a Mac with no user logged into the console (SSH-only, or a LaunchDaemon), which is a materially different environment from a CI runner or a Terminal.app session on a logged-in Mac. Dynamic `NSColor` resolution and `CGContext`-based PDF rendering are known to be unreliable in that specific no-WindowServer-connection scenario on macOS, independent of MainActor/async concerns. The commit history's stated rationale ("AppKit @MainActor dependency, broken in headless context," found in `git log -p -- Sources/CLI/Commands/ExportCommand.swift`, "Root Intent" note) is asserted, not demonstrated with a citation to a specific failure — I could not find a bug report, crash log, or test proving the no-WindowServer failure mode, but I also could not disprove it: this repo's test suite and this research sandbox both run in sessions that already have WindowServer access, so neither confirms nor refutes the genuinely-headless case.

**Contract impact if shipped.** Additive (`ExportFormat` gains `.pdf`/`.docx` cases; existing `Tests/CLITests/ExportCommandTests.swift:26-27` nil-assertions would need updating — that's a deliberate contract change, not incidental breakage). Minor CLI bump.

**Recommendation: Skip for now, pending an empirical check on a real headless Mac** (no console session — e.g. SSH into a Mac with nobody logged in at the screen). The MainActor-async angle is a solved problem (proven by existing CLI code); the open question is specifically whether `NSColor` dynamic-color resolution and `CGContext(url:mediaBox:)` PDF writing behave correctly with zero WindowServer connection. That's a 10-minute manual test (`macparakeet-cli export <id> --format pdf` over SSH to a logged-out Mac) that would settle this decisively where static code reading cannot. Given the CLI's stated headless-first audience, shipping this without that check risks a silent-corruption or hang bug class that's expensive to diagnose remotely.

## 5. Calendar skip/unskip mutation missing from CLI

**Core API.** `CalendarAutoStartPreferences` (`Sources/MacParakeetCore/AppPreferences.swift:65-85`) exposes only read helpers (`skippedOccurrences(defaults:)`, `skippedEvents(defaults:)`) over two `UserDefaults` array keys — no write helper in Core at all; writes happen via raw `UserDefaults.set` in the GUI layer. `CalendarSkip.eventKey(for:)` is `public` (`Sources/MacParakeetCore/Calendar/CalendarSkip.swift:12-14`), but `CalendarEvent.dedupeKey` (the occurrence-scoped key, `id|startSeconds`) is **internal**, not `public` (`Sources/MacParakeetCore/Calendar/CalendarEvent.swift:208-210`) — the CLI module cannot construct it today.

**GUI call site.** `SettingsViewModel.skipOccurrence/skipEvent/unskipOccurrence/unskipEvent` (`Sources/MacParakeetViewModels/SettingsViewModel.swift:1147-1161`) mutate `calendarSkippedOccurrences`/`calendarSkippedEvents` (`:790-800`, `didSet` writes straight to `UserDefaults`). Called from `MeetingAutoStartCoordinator.swift:515` (skip, from the countdown/reminder UI) and `MeetingsWorkspaceViewModel.swift:665,675-684` (unskip, from `MeetingsView.swift:402-403`).

**CLI gap.** `CalendarCommand.UpcomingCommand` (`Sources/CLI/Commands/CalendarCommand.swift:15-96`) only reads the two `UserDefaults` sets to annotate `skipped`/`skipScope` on each event (matches the brief's "Settled" note) — there is no `calendar skip`/`calendar unskip` subcommand. This was an **explicit, scoped deferral**, not an oversight: `plans/active/2026-09-14-issue-609-calendar-event-skip.md:102-105,410` states "The CLI stays an inspection list for this feature; aligning its membership with `candidates` is a later compatibility change, not #609" and lists "CLI membership alignment with `candidates`" under "Explicitly out of scope." That's about read-path membership parity, though, not a rejection of ever adding CLI write support — worth confirming with the product owner before building, since it was consciously left for later rather than rejected outright.

**Contract impact.** Additive: `calendar skip <event> [--scope occurrence|event]` / `calendar unskip <event> [--scope occurrence|event]`, writing through the same `macParakeetAppDefaults()` suite the CLI already reads (`CalendarCommand.swift:49-53`). Needs one small Core addition: a public `CalendarSkip.dedupeKey(for:)` (mirroring the existing public `eventKey(for:)`) so the CLI doesn't need `CalendarEvent.dedupeKey` made public or need to hand-reconstruct the `"\(id)|\(Int(startTime...))"` format itself (fragile, duplicates format knowledge). Minor CLI bump; the Core addition is a pure new public API, not a behavior change.

**Test seams.** `Tests/CLITests/CalendarUpcomingJSONTests.swift` (existing annotation coverage); would need a new test file or additions there for the write path.

**Recommendation: Ship, but flag the plan's prior "not this feature" scoping to the user before starting.** The write is genuinely small (two `UserDefaults` keys, already read by the CLI, already mutated by trivial GUI code) and reuses `CalendarSkip`'s existing pure logic. The only real design decision is the one small Core visibility addition.

## 6. Share snapshots

**Confirmed flag-gated and incomplete, matching the brief's caution.** `AppFeatures.shareLinksEnabled = false` (`Sources/MacParakeetCore/AppFeatures.swift:9`), overridable only via `--enable-share-links`, and `spec/README.md:85,91` states release builds ignore that launch argument entirely ("Encrypted share links remain disabled" for "the stable download"; DEBUG builds may expose it). ADR-029 status line: "Accepted; implemented behind a default-off release flag" (`spec/adr/029-encrypted-shareable-transcript-snapshots.md:3`); `spec/README.md:27` lists it "Implemented behind a default-off flag; public release pending." Every GUI entry point (menu item, share sheet in `TranscriptResultView.swift:1073,3175`, `ShareManagementViewModel` construction in `AppDelegate.swift:39`, `shareCoordinator` in `AppEnvironment.swift:87`) is gated behind `AppFeatures.isShareLinksAvailable()`. No CLI file anywhere references `ShareCoordinator`/`ShareRemoteClient` — confirmed zero CLI surface today.

**Recommendation: Skip, per the brief's own instruction.** Building CLI mutation support for a feature that isn't reachable in a shipping build would create a CLI capability with no corresponding GUI-verifiable production behavior, and risks shipping a public CLI contract for something the product hasn't decided to launch. Revisit once `shareLinksEnabled` flips (or the flag becomes user-controllable in release builds).

## 7. `favorite`/`unfavorite` lack `--json`

**CLI gap, confirmed as an isolated inconsistency, not a design choice.** `FavoriteSubcommand`/`UnfavoriteSubcommand` (`Sources/CLI/Commands/HistoryCommand.swift:532-576`) have no `--json` flag and don't route through `emitJSONOrRethrow` — just a bare `print(...)`. Every structurally identical sibling in the same file does support `--json`: `FavoritesSubcommand` (list, `:475-482`), `DeleteDictationSubcommand` (`:257-293`), `DeleteTranscriptionSubcommand` (`:316-349`) all declare `@Flag(name: .long) var json: Bool = false` and call `emitJSONOrRethrow`, with `Delete*` emitting a small `Encodable` result struct (`HistoryDeleteResult`, `:578-582`) right next to where `favorite`/`unfavorite` live.

**Contract impact.** Purely additive: new optional flag, new small result struct (e.g. `HistoryFavoriteResult { ok, id, isFavorite }`), no behavior change to the non-JSON path. Minor CLI bump.

**Test seams.** `Tests/CLITests/HistoryCommandTests.swift` already tests the delete/favorites JSON shapes — natural place to add favorite/unfavorite JSON coverage.

**Recommendation: Ship — trivial, mechanical, and the lowest-risk item in this brief.** It's a one-file, few-line change that removes an inconsistency an agent would otherwise have to special-case (every other mutator in `HistoryCommand.swift` is JSON-scriptable; these two silently aren't).

---

## Doubts / could not verify

- **#4 (PDF/DOCX headless behavior):** could not empirically test on a genuinely headless (no WindowServer) Mac from this sandbox or from `swift test`'s CI environment; the recommendation to skip is based on the documented deployment target and an unverified-but-plausible technical concern, not a reproduced failure.
- **#2 (top-level `corrections` vs. extending `meetings corrections`):** I did not find a strong precedent either way beyond `export`/`transcript` already being transcription-generic; this is a naming/ergonomics call for whoever implements it, not something the source settles.
- **#5:** I could not find a follow-up plan or issue explicitly scheduling "CLI membership alignment with `candidates`" (referenced as deferred in `plans/active/2026-09-14-issue-609-calendar-event-skip.md:410`) — it's unclear whether skip/unskip mutation was meant to ride along with that later work or is independent of it.
