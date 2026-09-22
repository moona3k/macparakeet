# CLI vs GUI Command/Feature Matrix

> Investigated against `origin/main` @ `fb186349e8498904109d77b52121f7373cb0b88a`
> (this checkout's HEAD matched `origin/main` at investigation time). CLI
> version `4.3.0` (`Sources/CLI/MacParakeetCLI.swift:11`).
>
> Scope per brief: the CLI is a first-class automation surface, **not a GUI
> mirror** (`integrations/README.md:15-18`). This matrix classifies every
> place the two surfaces diverge, not just literal 1:1 command mapping.
> Classifications used for actual gaps: `by-design`, `meaningful-automation-gap`,
> `robustness-bug`, `docs-drift`, `not-worth-it`. Rows with no gap are marked
> `parity`.

## Method

Four parallel read-only investigations covered (1) the full CLI command tree
(`Sources/CLI/MacParakeetCLI.swift` + every file in `Sources/CLI/Commands/`),
(2) the GUI Settings surface (`Sources/MacParakeet/Views/Settings/`,
`SettingsViewModel.swift`, `EngineSettingsViewModel.swift`,
`LLMSettingsViewModel.swift`), (3) GUI Library/Meetings surfaces
(`Sources/MacParakeet/Views/Transcription/`, `Views/Meetings/`,
`Views/MeetingRecording/`), and (4) GUI Prompts/Transforms/Vocab/Models
surfaces. Findings below were then independently spot-verified (grep/read)
before inclusion — several initial hypotheses were revised or dropped after
that check (see inline notes and the Doubts section).

---

## Matrix

### Dictation

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Hotkey capture, recording overlay, live preview, auto-paste, soft-cancel/undo | none | `by-design` | `integrations/README.md:49-51` ("Interactive dictation... The CLI does not record from the microphone"); `spec/02-features.md:139-352` (F1) |
| Dictation history: list, substring search, play, delete, favorite/unfavorite, retranscribe | `history dictations\|search\|delete-dictation\|favorite\|unfavorite`, `retranscribe --kind dictation` | `parity` | `Sources/CLI/Commands/HistoryCommand.swift:26,137,257,532,555` |
| "Preserve discarded dictations" (cancelled takes saved to History instead of dropped) | `config get\|set preserve-discarded-dictations` | `parity` | `Sources/CLI/Commands/ConfigCommand.swift:166-171,482-486` |
| Bulk multi-select delete of dictations (`Select Many...` → `Delete`) | only single-id `history delete-dictation <id>` | `not-worth-it` | `spec/02-features.md:659`; loop-over-ids is trivial for a script, no bulk verb needed |

### File / URL / Podcast transcription

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Drag-drop, multi-select/folder batch (200-file cap, sequential), progress UI, completion chime/banner | `transcribe <inputs...>` (multiple paths/folder, sequential batch) | `by-design`/`parity` for batch mechanics; live progress UI is inherently GUI-only | `spec/02-features.md:449-464` (F2 batch, REQ-TRANS-004); `Sources/CLI/Commands/TranscribeCommand.swift:70` |
| Embedded multi-audio-track picker | `--audio-track N` (local files/folders only) | `parity` | `spec/02-features.md:466-481`; `integrations/README.md:222-231` |
| Apple Podcasts URL paste | `transcribe <podcast-url>` / `transcribe --podcast "query"` (CLI adds freetext search GUI doesn't have) | `parity` (CLI is a superset) | `spec/02-features.md:504-513` — spec explicitly notes "the GUI surfaces URL paste" only, freetext search is CLI-only |
| **Rename a saved file transcription or meeting title** | **none** | **`meaningful-automation-gap`** | GUI: `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift:415-421` (row-menu rename, file-sourced only) and `TranscriptResultView.swift:1900-1922` (`canRenameTitle` = `.file` or `.meeting`; calls `TranscriptionLibraryViewModel.renameTranscriptionTitle` at `TranscriptionLibraryViewModel.swift:661-663`, or `TranscriptionViewModel.renameCurrentTranscription` at `TranscriptionViewModel.swift:3104` for meetings). CLI: exhaustive grep of `Sources/CLI/` for `rename`/`title` finds rename only for **prompt collections**, **meeting types**, and **meeting labels** (`MeetingClassificationCommands.swift:58,177`; `PromptsCommand.swift:131-166`) — no command renames a transcription/meeting's own title. URL/podcast-sourced items are excluded from renaming in the GUI too (`canRenameTitle` only allows `.file`/`.meeting`), so this gap tracks exactly the CLI's existing `--kind dictation\|transcription\|meeting` vocabulary. |
| **Export to `.docx` / `.pdf`** | `export -f {txt\|markdown\|srt\|vtt\|dapt\|json}`, `transcribe --format` (same 6, no docx/pdf) | **`meaningful-automation-gap`** | GUI: `TranscriptExportFormat` includes `.docx`/`.pdf` (`Sources/MacParakeet/Views/Transcription/TranscriptResultActions.swift:6,304-305`), implemented via `Sources/MacParakeetCore/Services/ExportService.swift:242(exportToPDF),313(exportToDocx)` — **already in the shared `MacParakeetCore` module the CLI links against**, just gated `@MainActor` (AppKit-based rendering per `TranscriptResultActions.swift:283` comment). CLI: `Sources/CLI/Commands/ExportCommand.swift:5-11` enum has only `txt, markdown, srt, vtt, dapt, json` — confirmed via direct grep, no `docx`/`pdf` case anywhere in `Sources/CLI/`. |
| Completion notification (chime + background banner) | none | `by-design` | Synchronous CLI invocation has no background/notification concept; `spec/02-features.md:515-523` |

### Meetings — live capture

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Record/pause/resume/stop, floating pill, mute, Notes/Transcript/Ask 3-tab live panel | none | `by-design` | `integrations/README.md:52-55`; `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift`, `MeetingRecordingPillView.swift` |
| Mid-recording "Discard Recording" (abort before transcription starts) | none | `by-design` | `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPillController.swift:274-298` (explicitly: no in-flight abort once transcribing has started — post-stop deletion goes through the normal Library "Delete Meeting?" flow, which the CLI's `history delete-transcription` covers) |

### Meetings — post-capture management

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Import an existing audio/video file as a managed meeting | `meetings import <path> --title --started-at` | `parity` | `Sources/MacParakeet/Views/Meetings/MeetingImportSheetView.swift`; `Sources/CLI/Commands/MeetingImportCommand.swift:12` |
| Split a long recording into parts (preview/create/status/resume/discard) | `meetings split preview\|create\|status\|resume\|discard` | `parity` (GUI adds an interactive "stop processing" not needed as a separate CLI verb since Ctrl-C already settles in-flight work per `integrations/README.md:686-687`) | `Sources/MacParakeet/Views/Meetings/MeetingSplitSheetView.swift`; `Sources/CLI/Commands/MeetingSplitCommand.swift:38,87,232,316,387` |
| Meeting notes (autosaving editor) | `meetings notes get\|set\|append\|clear` | `parity` (typing achieves the same effect as CLI `append`) | `TranscriptResultView.swift:2731-2913`; `Sources/CLI/Commands/MeetingsCommand.swift:455-634` |
| Generated results/summaries tabs (copy/export/delete/generate) | `meetings results list\|add` | `parity` — `results add` is specifically an agent-write path for externally generated content, matching the CLI's "Prompt management and meeting inspection" scope | `TranscriptResultView.swift:3005-3069`; `MeetingsCommand.swift:635-732` |
| Meeting **labels**: create/rename/recolor/archive | `meetings labels list\|add\|rename\|set\|archive` | `parity` | `Sources/MacParakeet/Views/MeetingRecording/MeetingClassificationControls.swift:539-734` (`MeetingLabelManagementSheet`); `Sources/CLI/Commands/MeetingClassificationCommands.swift:108-278` |
| Meeting **types**: create/rename/archive | `meetings types list\|add\|rename\|archive` | `robustness-bug` (see detail) | CLI is fully functional (`MeetingClassificationCommands.swift:6-107`). GUI code exists — `MeetingTypesManagementCard`/`MeetingTypeSearchMenu`/`MeetingPromptPolicyEditor` (`MeetingClassificationControls.swift:857-1314`) and the matching `selectedMeetingTypeIDs` filter (`TranscriptionLibraryViewModel.swift:176-290,846-847`) — but a repo-wide search found **zero call sites** instantiating any of those views outside their own definitions. If confirmed live (not verified by launching the app — see Doubts), meeting Types is currently reachable **only through the CLI**. |
| Timed transcript corrections (edit-line/split/merge/reassign speaker/undo/redo/reset) | `meetings corrections edit-line\|merge-lines\|undo\|redo\|reset` | `meaningful-automation-gap` (scope) | GUI correction UI (`TranscriptResultView.swift:2544-4846`) is gated on `transcriptTextAlignment != .untimed`, i.e. it works for **any** transcript with word-level timing — not just meetings. CLI's equivalent is nested exclusively under `meetings`, so a Whisper/Parakeet file or URL transcription with word timestamps and speaker turns has no CLI-scriptable correction path at all. |
| Meeting artifact bundle (`manifest.json`/`meeting.md`/`transcript.json`/`notes.md`/`prompt-results/*`) | `meetings artifact <id>`, `meetings export <id> --stdout` | `by-design` (CLI-exclusive; reverse direction) | GUI only reveals/copies the folder path (`Sources/MacParakeet/Views/Transcription/MeetingArtifactActions.swift:22-40`) or does a generic single-file transcript/result export — no "export the structured bundle" action exists (`grep` for `ArtifactExport`/`exportMeetingArtifact` across `Sources/MacParakeet*` returns nothing). This is intentionally an agent-facing contract (`spec/contracts/meeting-artifacts-v1.md`), not a missing GUI feature to fix on the CLI side. |
| Post-meeting automation webhook (`meeting-hook-path/-timeout/-enabled`) | `config set meeting-hook-path\|meeting-hook-timeout\|meeting-hook-enabled` | `by-design` (CLI-exclusive; reverse direction) | Runtime consumer `Sources/MacParakeetCore/Services/MeetingRecording/MeetingAutomationHookRunner.swift:14-16`. Zero references to `meetingAutomationHookEnabled`/`meetingAutomationHookExecutablePath`/`meetingAutomationHookTimeoutSeconds` anywhere in `Sources/MacParakeet`/`Sources/MacParakeetViewModels` — this is deliberately a scripting-only feature, fits CLI scope well as-is |
| Primary meeting-artifacts storage folder (change location) | `config get\|set meeting-artifacts-folder` (full read/write) | `by-design` (CLI-exclusive; reverse direction) | GUI only **displays** the resolved path read-only (`Sources/MacParakeet/Views/Settings/SettingsView.swift:1505,1561-1562`); no picker bound to the underlying `meetingArtifactsFolderKey` (`Sources/MacParakeetCore/Services/AppPaths.swift:7,71-77`) exists anywhere in the GUI target. (Do not confuse with the separate, GUI-only "Also save meetings to a folder" **secondary copy** feature below.) |
| "Also save meetings to a folder" (secondary auto-save copy: enable, format, folder) | none | `meaningful-automation-gap` | GUI: `SettingsView.swift:1351,1503-1523` toggle/format-picker/folder-chooser, backed by `SettingsViewModel.meetingAutoSave`/`meetingAutoSaveFormat`/`meetingAutoSaveFolderPath` (`SettingsViewModel.swift:692,698,727`). CLI: confirmed absent from the complete 25-key `config` catalog (`ConfigCommand.swift:81-232`) — no way to turn this on/off or point it at a folder headlessly (e.g. an Obsidian vault sync folder), unlike its `meeting-artifacts-folder` sibling above. |
| "Live transcription during recording" toggle | none | `meaningful-automation-gap` (minor) | GUI: `SettingsView.swift:1315`, backed by `meetingLiveTranscriptionEnabled` (`SettingsViewModel.swift:595`). CLI: absent from the config catalog. Low-value on its own since the CLI cannot record meetings live anyway, but cheap to add for headless demo/environment prep, following the exact pattern already used for `start-meetings-muted`. |

### Library

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Search (title + transcript substring) | `history search-transcriptions <query>`; CLI additionally has segment-level `search` (FTS5) | `parity` (CLI superset) | `TranscriptionLibraryView.swift:148`; `Sources/MacParakeetCore/Database/TranscriptionRepository.swift:316-427`; `HistoryCommand.swift:189` |
| Favorite/unfavorite | `history favorite\|unfavorite\|favorites` | `parity` | `TranscriptionLibraryView.swift:543-550`; `HistoryCommand.swift:475,532,555` |
| Delete (single + bulk multi-select) | single-id `history delete-transcription <id>` only | `not-worth-it` | Same reasoning as dictations above — scriptable via a loop |
| Export (single + bulk; 8 formats incl. docx/pdf) | `export`/`transcribe --format` (6 formats) | see File/URL row above — same `meaningful-automation-gap` | `TranscriptionLibraryView.swift:672-899` |
| Retranscribe | `retranscribe <id> --update` | `parity` | `TranscriptResultView.swift:1167-1210` |
| Reveal/copy audio, Download Audio, Open Finder | none (path is available via `history dictations/transcriptions --json` fields) | `not-worth-it` | Raw filesystem convenience; the underlying path is already machine-readable, a script can `cp` it directly |
| Filter chips (source type, favorites, labels) | `meetings list --type/--label/--unclassified`, `search --source` cover most of this; no single filter flag on `history transcriptions` itself | `meaningful-automation-gap` (minor) | `TranscriptionLibraryView.swift:1150-1186`; `MeetingClassificationControls.swift:52-122`. `history transcriptions`/`history dictations` (`HistoryCommand.swift:80,26`) take only `--limit`, no `--favorite`/`--source` filter |

### Share links

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Compose/publish encrypted share snapshot, manage shares, recovery-code flow | none | `not-worth-it` (for now) | GUI is fully implemented, not aspirational: `Sources/MacParakeet/Views/Transcription/ShareTranscriptSheet.swift:17-198`, `SharedSharesView.swift:6-132`. But the feature itself is **disabled in shipping builds** — `Sources/MacParakeetCore/AppFeatures.swift:9` (`shareLinksEnabled = false`), reachable only in `DEBUG` or via `--enable-share-links` (`AppFeatures.swift:10,14`). `spec/README.md:91`: "Encrypted text sharing is implemented but not publicly enabled." Building CLI parity for a feature that isn't released is premature; revisit when the flag flips. |

### Prompts, Transforms, Live Ask, Collections, Labels

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Create/edit/delete transcript prompt; version history/diff/restore | `prompts add\|set\|delete\|restore-deleted\|show\|history\|diff\|restore` | `parity` | `Sources/MacParakeet/Views/Transcription/PromptLibraryView.swift:87-1272`; `Sources/CLI/Commands/PromptsCommand.swift` |
| Inference settings (temp/topP/topK/maxTokens/thinking/reasoning) + model override | `prompts set --temperature/--top-p/--top-k/--max-tokens/--thinking-mode/--reasoning-effort/--model/--active-model/--provider-default-settings` | `parity` | `PromptLibraryView.swift:1413-2006`; `PromptsCommand.swift:552+` |
| Collections (create/rename/reorder/delete/assign) | `prompts collections add\|rename\|delete\|reorder`, `prompts set --collection` | `parity` | `PromptLibraryView.swift:345-405`; `PromptsCommand.swift:50-231` |
| Label availability rules (per-label / all-labels fallback) | `prompts set --label X --available\|--unavailable --all-labels` | `parity` | `PromptLibraryView.swift:990-1092`; `integrations/README.md:928-942` |
| Source auto-run toggle (file/youtube/podcast/meeting) | `prompts set --source X --auto-run\|--no-auto-run` | `parity` | `PromptLibraryView.swift:720-743` |
| Transforms: create/run/delete/reset, run history | `transforms create\|run\|delete\|restore-defaults\|history` | `parity` | `Sources/MacParakeet/Views/Transforms/TransformsView.swift`; `Sources/CLI/Commands/TransformsCommand.swift` |
| *(reverse note)* Transform editor UI exposes only name/shortcut/prompt body — no version history, inference settings, model override, collections, or label rules in the GUI, even though Transforms share the same `Prompt`/`PromptEditingService` backend as transcript prompts and `prompts set <transform-name>` can already configure all of that from the CLI | n/a — CLI is the superset here | `by-design` (not a CLI gap) | `Sources/MacParakeet/Views/Transforms/TransformEditorSheet.swift:80-151`; `Sources/MacParakeetCore/Database/PromptEditingService.swift:230` (auto-run hard-forced off for `.transform`) |
| Live Ask quick prompts: pin/unpin/create/edit/delete/reorder/restore-defaults | `quick-prompts list\|show\|add\|set\|delete\|pin\|unpin\|restore-defaults` | `parity` | `Sources/MacParakeet/Views/MeetingRecording/AskPromptsSheet.swift` (implied path per subagent); `Sources/CLI/Commands/QuickPromptsCommand.swift` |
| Quick-prompts export/import as a portable JSON bundle | `quick-prompts export\|import` | `by-design` (CLI-exclusive; reverse direction) | Zero references to `QuickPromptBundle`/`macparakeet.quick_prompts` outside `Sources/CLI/` and `MacParakeetCore`; this is a deliberate cross-machine backup/restore automation feature |

### Vocabulary

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Custom words: list/add/delete/enable-disable | `vocab words list\|add\|delete\|set(--enabled/--disabled)` | `parity` | `Sources/MacParakeet/Views/Vocabulary/CustomWordsView.swift`; `Sources/CLI/Commands/VocabWordsCommand.swift:35,98,129,180` |
| **Edit an existing word's replacement text** | **no equivalent flag** | **`meaningful-automation-gap`** (a shared product gap — see note) | GUI: `CustomWordsView.swift`'s word row (delete + enable-toggle only, no edit affordance) and `CustomWordsViewModel` (only `addWord`/`toggleEnabled`/delete, no `setWord`). CLI: `VocabWordsCommand.swift:129` (`SetWord`) only accepts `--enabled`/`--disabled`, not a new replacement value. **Note:** since neither surface supports this today, fixing only the CLI (`vocab words set <id> --replacement <text>`) wouldn't achieve GUI parity — it would make the CLI *lead* on this capability rather than match the GUI. Still counts as a real automation gap worth closing on the CLI side independent of the GUI. |
| Snippets: list/add/edit-in-place/delete | `vocab snippets list\|add\|edit\|delete` | `parity` | `Sources/MacParakeet/Views/Vocabulary/TextSnippetsView.swift:92-380`; `Sources/CLI/Commands/VocabSnippetsCommand.swift:18,61,88,175` |
| Vocabulary bundle export/import (Backup & Restore, issue #67) | `vocab export\|import\|schema` | `parity` (same shared `VocabularyImportExportService`) | `Sources/MacParakeet/Views/Vocabulary/VocabularyBackupSection.swift:228-274`; `Sources/CLI/Commands/VocabBundleCommands.swift:9,56,230` |
| Recognition-time custom-vocabulary boosting toggle | none — read-only status display only | `not-worth-it` | The feature is **paused product-wide**, not merely unexposed: default hardcoded `false` with no setter anywhere in the codebase (`Sources/MacParakeetCore/AppRuntimePreferences.swift:790-791`); explicit "paused" copy at `Sources/MacParakeetCore/STT/CustomVocabularyBoosting.swift:57`. Both GUI (`CustomWordsView.swift`, `VocabularyView.swift:134`) and CLI (`VocabWordsCommand.swift:17-31`) only *display* the same read-only status. |
| "Test my pipeline on this text" (standalone) | `vocab process <text> [--copy]` | `by-design` (CLI-exclusive; reverse direction) | The GUI's clean pipeline only runs live during dictation; no standalone GUI test tool exists (`Sources/CLI/Commands/VocabProcessCommand.swift:6-54`) |
| Filter custom words by source (manual vs learned) | `vocab words list --source all\|manual\|learned` | `by-design` (CLI-exclusive; reverse direction) | `CustomWordsViewModel.loadWords()` has no source filter/UI |

### Models / Engines

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Engine tiles (Parakeet/Nemotron/Whisper/Cohere), model variant pickers, download/repair/delete | `models list\|select\|download\|repair\|delete\|clear\|status` | `parity` | `Sources/MacParakeet/Views/Settings/SettingsView.swift:2252-2889`; `Sources/CLI/Commands/ModelsCommand.swift` |
| Automatic warm-up during engine switch | `models warm-up` (manual trigger) | `parity` (different UX, same outcome) | `Sources/MacParakeetViewModels/EngineSettingsViewModel.swift:1435-1478`; `ModelsCommand.swift:214` |
| Per-invocation engine/model/language override at transcribe time | `transcribe/retranscribe --engine/--parakeet-model/--nemotron-model/--language` (per call) | `by-design` (CLI-exclusive; reverse direction) | GUI only supports two **saved defaults** (a "Live" engine and an optional separate "Recordings & files" engine via the Advanced disclosure, `SettingsView.swift:2410-2528`) — no per-file override at the point of transcribing (`TranscriptResultView.swift:1580,1598` only *displays* which engine produced a transcript) |

### Calendar auto-start

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Read-only: list upcoming events with trigger filter + skip annotations | `calendar upcoming --days --filter --json` | `parity` | `Sources/CLI/Commands/CalendarCommand.swift:9-125` |
| **Enable/mode (off / notify / auto-start), reminder lead time, trigger filter, excluded calendars, per-event/series skip** | **none** | **`meaningful-automation-gap`** | GUI: `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift:194-402` (mode toggle/segmented picker, reminder-lead picker, event-filter picker, per-calendar include list), backed by `SettingsViewModel.calendarAutoStartMode` et al. (`SettingsViewModel.swift:734-805`), persisted at `CalendarAutoStart.*` UserDefaults keys (`Sources/MacParakeetCore/AppPreferences.swift:66-74`). CLI: `calendar` exposes **only** `upcoming` (read-only) — confirmed via `grep -n -i "calendar" Sources/CLI/Commands/ConfigCommand.swift` returning zero matches, and `CalendarCommand.swift` has a single `UpcomingCommand` subcommand. No way to flip auto-start on/off, change the trigger filter, exclude a calendar, or manage per-event skips headlessly. |

### Knowledge layer (search / cards / transcript context)

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| *(none — deliberately CLI-exclusive)* | `search`, `transcript --around/--around-seq`, `cards list\|generate` | `by-design` | Confirmed via repo-wide search: zero references to `SegmentRepository`/`CardRepository`/`CardGenerationService`/`KnowledgeLayerMutationService` anywhere in `Sources/MacParakeet`/`Sources/MacParakeetViewModels`. This matches the product's stated design: `spec/02-features.md:2180` points local retrieval at "[Integration guide]" rather than a GUI surface, and the north star (`spec/adr/027-product-north-star.md:71`, referenced by subagent) frames segment search/cards as agent-facing. The GUI's own search (`TranscriptionLibraryView.swift:148`) and in-transcript find (`TranscriptFindBar.swift`) are row-level/manual, not the same capability. **Do not build a GUI mirror of this.** |

### Config / Health / LLM

| GUI surface | CLI command | Classification | Evidence |
|---|---|---|---|
| Settings controls for 22 of 25 `config` keys (telemetry, processing-mode, remove-um-filler, speech-engine + variants/languages, speaker-detection ×2, auto-meeting-titles, voice-return, preserve-discarded-dictations, save-transcription-audio, meeting-audio-retention/source, start-meetings-muted, youtube-audio-quality) | `config get\|set\|list` (25 keys total, `ConfigCommand.swift:81-232`) | `parity` | Cross-referenced directly: `ConfigCommand.swift:333-395` vs `SettingsViewModel.swift` properties reported by subagent |
| — | `config set meeting-hook-enabled\|meeting-hook-path\|meeting-hook-timeout` (3 of the 25 keys) | `by-design` (CLI-exclusive; reverse direction, see Meetings section above) | Zero GUI references confirmed |
| — | `config get\|set meeting-artifacts-folder` | `by-design` (CLI-exclusive; reverse direction, see Meetings section above) | GUI read-only display only |
| Per-engine status chips + individual Repair/Download buttons | `health --json [--repair-models] [--repair-binaries]` (single consolidated report) | `parity` (different shape, same diagnostic coverage) | `Sources/CLI/Commands/HealthCommand.swift:5` |
| Full persistent LLM provider config (API key, base URL, model, CLI-subprocess template) across Anthropic/OpenAI/Gemini/OpenRouter/Ollama/LM Studio/OpenAI-compatible/local-CLI, saved to Keychain/UserDefaults | `llm test-connection\|summarize\|chat\|transform` via `@OptionGroup LLMInlineOptions` (**explicit `--provider` + credentials every call, no saved-config fallback**) | **`meaningful-automation-gap`** | GUI: `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift` (provider picker `:271`, API key `SecureField:82`, base URL `:103`, CLI-subprocess section `:1786-1847`). CLI: `Sources/CLI/Commands/LLMInlineConfig.swift:68-71` — doc comment "Shared options for CLI commands that call an LLM provider directly (**no Keychain**)"; `provider` is a required `@Option` with no `app-default` case and no fallback path (verified directly: `providerID()` at `LLMInlineConfig.swift:97-117` only maps the literal `provider` string, throwing on anything unrecognized — no code path reads the GUI's saved config). By contrast, `prompts run`/`cards generate` **do** reuse "the provider already opted into in MacParakeet Settings" (`integrations/README.md:454`). So an agent that wants ad-hoc `llm chat`/`summarize`/`transform`/`test-connection` to "just use what the user already configured" cannot do it — it must always fully respecify provider/key/model, unlike `transcribe --engine app-default` which explicitly supports reusing the saved default. |
| In-process local LLM (MLX) provider | none — explicitly rejected | `by-design` | GUI: gated behind `MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1` build flag, `inProcessLocalLLMEnabled = false` (`AppFeatures.swift:158`), not shipped-visible by default. CLI: `LLMInlineConfig.swift:113-115,211-212` already explicitly throws `"The in-process local provider is not exposed through inline CLI configuration yet."` — the gate is intentional and already documented in code, nothing to fix |
| AI Formatter (per-surface enable, smart defaults, custom prompts/profiles) | none | `not-worth-it` | Gated off product-wide: `aiFormatterProfilesEnabled = false` (`AppFeatures.swift:150`) — "App-aware AI Formatter profile code is present, but normal Settings/routing surfaces remain disabled" (`spec/README.md`, flag table). Not a shipped feature to build CLI parity for yet. |

---

## Top 10 candidate improvements

Ranked by agent usefulness vs. implementation cost (highest-value/lowest-cost first).

1. **`llm chat/summarize/transform/test-connection --provider app-default`** — let ad-hoc CLI LLM calls reuse the same saved/Keychain provider config that `prompts run`/`cards generate` already resolve through, instead of forcing every call to fully respecify provider/key/model. Highest daily-friction reduction for agents; the resolution path already exists elsewhere in the codebase (`integrations/README.md:454`), so this is largely plumbing `LLMInlineOptions` to fall back to it.
2. **`export`/`transcribe --format docx|pdf`** — the rendering logic already lives in shared `MacParakeetCore` (`ExportService.exportToDocx/PDF`, `ExportService.swift:242,313`); the CLI just needs to add the two enum cases and call the existing `@MainActor` methods.
3. **A rename command** (e.g. `history rename <id> --title "..."` or a shared `library rename`) for saved file transcriptions and meetings — the underlying mutation methods already exist (`TranscriptionLibraryViewModel.renameTranscriptionTitle`, `TranscriptionViewModel.renameCurrentTranscription`); this is a natural agent workflow (generate a title, then apply it) with currently zero CLI path.
4. **`config` keys for the meeting auto-save-to-folder feature** (`meeting-auto-save-enabled`, `meeting-auto-save-format`, `meeting-auto-save-folder`) — mirrors the existing `meeting-artifacts-folder` pattern exactly; unlocks headless "sync every meeting to my Obsidian vault" setups.
5. **CLI mutation surface for calendar auto-start** (mode, reminder lead, trigger filter, calendar include/exclude, per-event/series skip) — currently 100% GUI-only; useful for "disable auto-start before a screen recording" or CI/demo environment prep.
6. **Extend transcript corrections beyond `meetings`** to any transcript with word-level timing (file/URL), matching the GUI's actual scope — closes a real functional gap, though it needs a new top-level surface (`transcript corrections ...` or similar) and tests, so higher cost than the above.
7. **`vocab words set <id> --replacement <text>`** — lets an agent fix a mis-mapped custom word without delete+re-add (which loses the row's id/history). Note this would put the CLI *ahead* of the GUI, which has the identical limitation today — still a low-cost, real win for automation.
8. **Bulk/multi-id variants of `history delete-dictation`/`delete-transcription`** — accept repeated ids or a `--all-matching` filter; low cost, modest value (a loop already works).
9. **`--favorite`/`--source` filter flags on `history dictations`/`history transcriptions`** — parity with the Library's filter chips; low cost, modest value since `meetings list`/`search --source` already cover the meeting case.
10. **`config` key for `meeting-live-transcription-enabled`** — mirrors the existing `start-meetings-muted` key exactly; cheap, low-value environment-prep toggle.

## Explicit "do not build"

1. **Live mic dictation / hotkey / overlay in the CLI** — explicitly out of scope by design (`integrations/README.md:49-51`).
2. **Live meeting UI (3-tab panel, floating pill, live controls, in-flight abort) in the CLI** — explicitly out of scope (`integrations/README.md:52-55`).
3. **Onboarding, a Settings-UI mirror, library grids, sounds, overlays in the CLI** — explicitly out of scope (`integrations/README.md:56-58`).
4. **A GUI mirror of `search`/`transcript --around`/`cards`** — this asymmetry is the intended design (agent-facing knowledge layer, `spec/02-features.md:2180`, north star ADR-027); building it into the GUI would duplicate a deliberately CLI-first capability.
5. **CLI share-link commands** — the feature itself is disabled in shipping builds (`shareLinksEnabled = false`, `AppFeatures.swift:9`) and unreleased (`spec/README.md:91`). Building CLI parity for a gated-off feature is premature; revisit only if/when the flag flips.
6. **A setter for custom-vocabulary recognition-time boosting** (CLI or GUI) — the feature is paused product-wide with an explicit "paused" message in the code (`CustomVocabularyBoosting.swift:57`), not merely unexposed. Adding a toggle would surface a feature the product has deliberately shelved.
7. **CLI/GUI exposure of the AI Formatter profile system** — compiled but gated off product-wide (`aiFormatterProfilesEnabled = false`); not a shipped feature.
8. **CLI exposure of the in-process local LLM (MLX) provider** — already explicitly and correctly gated in both surfaces (`inProcessLocalLLMEnabled = false`; `LLMInlineConfig.swift` already throws a clear "not exposed yet" error). Respect the existing gate rather than opening a side door.
9. **Extending "Remove Audio Only" to file/URL transcriptions** — verified this is *not* currently a gap: both GUI (`spec/04-ui-patterns.md:341-343`, "for selected meetings with stored audio") and CLI (`history delete-meeting-audio`/`clear-meeting-audio` are meeting-scoped only) already agree on meeting-only scope. No CLI work needed here (an earlier hypothesis that this was a gap was disproved during investigation — see Doubts).

## Doubts / could not fully verify

1. **Meeting Types UI reachability.** `MeetingTypesManagementCard`/`MeetingTypeSearchMenu`/`MeetingPromptPolicyEditor` (`Sources/MacParakeet/Views/MeetingRecording/MeetingClassificationControls.swift:857-1314`) have full model/viewmodel/repository support but no call sites were found via static search. This was verified by grep, not by launching the app and clicking through Settings/Library/Meetings — it's possible a call site exists via a dynamic/reflection-based navigation path the search missed, or that this is genuinely dead code from an incomplete refactor. If dead, it means CLI's `meetings types` is currently the *only* working management surface for meeting Types, which would be worth flagging to whichever brief owns robustness/docs-drift.
2. **Cost estimate for the `llm --provider app-default` fix (top-10 #1).** I confirmed the current code requires an explicit `--provider` with no fallback (`LLMInlineConfig.swift:70-117`), and that `prompts run`/`cards generate` use a different, already-shared resolver path per `integrations/README.md:454`. I did not trace how much of that resolver is reusable by the `llm` command family specifically — the cost ranking is a judgment call, not a measured one.
3. **GUI Keychain vs. UserDefaults storage for the LLM API key field** was reported by a subagent investigation, not independently re-verified by reading `LLMSettingsViewModel.swift`'s persistence code myself.
4. **Whether meeting-only scoping of `meetings corrections` is deliberate or an oversight.** `spec/adr/031-timed-transcript-corrections.md` does not explicitly discuss excluding file/URL transcripts; the GUI clearly supports both, so this reads as a genuine CLI gap, but I found no document explaining why the CLI command was nested under `meetings` specifically rather than being source-type-agnostic.
5. **Overlap with sibling briefs.** This session observed other agents working in parallel on adjacent briefs (mutations, robustness, docs-drift, gui-lag) in the same `docs/research/2026-09-17-cli-gui-parity/` tree. The vocab-word-edit gap, the meeting-hook GUI absence, and the Meeting-Types dead-code finding may be independently surfaced (possibly with different framing) by those briefs — worth deduplicating when the research is assembled.
6. ~~`vocab words set` flag surface~~ — **resolved during write-up**: directly re-read `Sources/CLI/Commands/VocabWordsCommand.swift:128-172`. `SetWord`'s `CommandConfiguration.abstract` literally reads "Update a custom word's enabled state," and its only flags are `--enabled`/`--disabled` (mutually exclusive, one required per `validate()` at lines 148-153), `--json`, `--database`. No replacement-text field exists. Confirms the matrix row and top-10 item #7 independently of the subagent report.
