# Open-Source UI Reference Audit

> Status: **ACTIVE**
> Date: 2026-05-15
> Purpose: Opinionated design and architecture references for improving
> MacParakeet without copying another app's product shape.

## Executive Take

MacParakeet should not chase generic "beautiful app" aesthetics. The strongest
direction is a native macOS utility with a warm, memorable voice layer:

- **Quiet shell:** NetNewsWire / CotEditor discipline for navigation, reading,
  and persistence.
- **Signature state surfaces:** Loop-level craft for the floating pill,
  recording tile, and completion states.
- **Serious media workspace:** IINA patterns for playback, transcript/audio
  alignment, and hover-revealed controls.
- **Modern SwiftUI modules:** IceCubes / CodeEdit patterns for feature-scoped
  packages and view model boundaries, but only where MacParakeet's current
  SPM target split benefits.
- **System trust:** Ice / Snapzy patterns for permissions, menu bar behavior,
  non-activating panels, and high-risk system integrations.

The product should feel "warm magical" only at moments that deserve emotion:
recording starts, voice is detected, transcription completes, and an audio
artifact becomes readable. The rest of the app should be restrained, scanable,
and native.

## Current MacParakeet Baseline

MacParakeet already has useful foundations:

- `NavigationSplitView` shell with Transcribe, Library, Dictations, Vocabulary,
  Feedback, Settings, and feature-gated Transforms.
- A centralized `DesignSystem` with warm coral, off-white surfaces, rounded
  typography, spacing, shadows, and semantic `parakeetAction` button styling.
- Floating dictation and meeting pills through AppKit-backed panels and
  SwiftUI content.
- Separate `MacParakeetViewModels` target for testable UI logic.
- A concise product/design direction in `docs/ui-inspiration.md`.
- A broad inspiration catalog in `docs/research/ui-design-inspiration-2026-05.md`.

This audit is narrower: what is worth borrowing next.

## Tier 1 References

### Loop

Repo: <https://github.com/MrKai77/Loop>

Why it matters: Loop is the best open-source reference for a macOS utility with
a distinctive, high-craft interaction. Its radial menu and preview windows are
not merely decorative; they preview the consequence of an action before the
system mutates state.

Observed code patterns:

- `WindowActionIndicator` protocol separates the indicator surface from the
  window-management domain.
- `RadialMenuController` and `PreviewController` own `NSPanel` lifecycle, while
  `RadialMenuView` and `PreviewView` stay SwiftUI.
- `PreviewController` uses `.borderless`, `.nonactivatingPanel`, clear
  background, `orderFrontRegardless`, full-screen joining behavior, and delayed
  close to let the view animate out before the panel is destroyed.
- `RadialMenuView` gates newer glass effects by OS availability and keeps a
  pre-Tahoe fallback path.

Borrow:

- Treat MacParakeet's floating surfaces as **state indicators with controllers**,
  not incidental views.
- Give meeting recording a preview-before-commit pattern where possible: before
  starting, show exactly which inputs are ready (`mic`, `system audio`,
  `engine`, `save location`) in one compact state surface.
- Use action-specific motion: idle breath, listening waveform, processing
  orbit, completion bloom. Do not use generic spinners when the audio state can
  speak visually.

Do not borrow:

- The radial menu itself. MacParakeet is not a spatial command tool.
- Heavy glass everywhere. The app should stay readable and local-first, not
  showroom-like.

MacParakeet application:

- Refactor dictation/meeting pill controllers toward a shared
  `FloatingStateSurfaceController` pattern only if duplication is becoming
  costly.
- Add a first-class "input readiness" strip to the Meeting Recording tile:
  mic, system audio, speech engine, and storage, each with one clear state.

### IINA

Repo: <https://github.com/iina/iina>

Why it matters: IINA is the best reference for media UI on macOS. MacParakeet's
transcription result view has the same hard problem in another form: the user
needs to read text, scrub audio/video, jump by time, and keep controls out of
the way.

Observed code patterns:

- `MainWindowController` coordinates the player window and on-screen controller
  (OSC) details rather than pushing all state into one SwiftUI tree.
- OSC position and toolbar composition are user-configurable.
- Thumbnail preview placement accounts for available window space rather than
  assuming one overlay location always fits.
- Playback state, history, mini-player, and quick settings are explicit
  sub-systems.

Borrow:

- A layered media detail layout: transcript as the main surface, player controls
  as a persistent but visually quiet bottom rail, deeper settings on demand.
- Hover-revealed time previews and thumbnail/audio-preview affordances for
  long files.
- Explicit layout fallback rules for narrow windows.

Do not borrow:

- IINA's controller density. It is appropriate for a pro media player, but too
  much for MacParakeet's consumer voice workflow.

MacParakeet application:

- Make `TranscriptResultView` feel less like a document page and more like a
  readable media artifact: text-first, time-aware, with persistent playback.
- Add "jump to active word/segment" and "copy segment" affordances near the
  transcript, not buried in global actions.

### NetNewsWire

Repo: <https://github.com/Ranchero-Software/NetNewsWire>

Why it matters: NetNewsWire is a mature reference for a durable native app that
users leave open all day. It is not flashy. That is the point.

Observed code patterns:

- Clear platform split: `Mac/`, `iOS/`, `Shared/`, `Modules/`, `Tests/`.
- Timeline behavior is factored through shared domain types like article arrays,
  sorters, fetch operations, and formatters.
- Preferences and inspectors are native AppKit surfaces, not over-styled custom
  dashboards.
- Shared resources include article themes and long-lived app defaults.

Borrow:

- Library/detail restraint. The Library should be fast to scan, not visually
  loud.
- Dedicated formatters/caches for row summaries, titles, timestamps, and search
  snippets.
- Native preferences where settings are operational, not promotional.

Do not borrow:

- Three-pane RSS structure wholesale. MacParakeet should keep capture as the
  first tab and Library as browsing, not become a content reader clone.

MacParakeet application:

- Introduce a small formatting layer for transcription/dictation row text,
  summaries, dates, durations, and speaker labels if the current row code keeps
  growing.
- Keep Library's Meetings filter as a date-grouped list. This matches
  NetNewsWire's maturity better than thumbnail grids for non-visual artifacts.

### CotEditor

Repo: <https://github.com/coteditor/CotEditor>

Why it matters: CotEditor is a native macOS text app with excellent restraint.
It is a better text-editing reference than visually louder SwiftUI apps.

Borrow:

- Native text behavior: selection, find, copy, keyboard affordances, typography
  controls, document-window expectations.
- Minimalism around the text itself. Transcript content should not compete with
  ornamental UI.

Do not borrow:

- Document-based app assumptions. MacParakeet stores recordings/transcripts in a
  local database and Library, not arbitrary user documents.

MacParakeet application:

- Treat long transcripts like first-class reading/editing surfaces. Add
  predictable text selection, search-in-transcript, copy with timestamps, and
  font-size controls before adding more visual decoration.

### IceCubesApp

Repo: <https://github.com/Dimillian/IceCubesApp>

Why it matters: IceCubes is a modern SwiftUI app with feature packages,
`@Observable` view models, environment services, timelines, composer flows, and
rich list cells.

Observed code patterns:

- Feature packages such as `Timeline`, `StatusKit`, `DesignSystem`, `Models`,
  `Env`, and `NetworkClient`.
- `TimelineView` keeps a local `@State` view model and composes environment
  services for account, client, router path, theme, and stream watcher.
- Timeline filters are surfaced as quick-access pills above the scroll area.
- Pull-to-refresh includes sound/haptic feedback, but the feedback is tied to a
  meaningful state transition.

Borrow:

- Feature-local packages only when a domain is large enough to earn the split.
- Quick-access pills for active filters in Library, Prompt results, or
  Transcript views.
- Feed/composer discipline for Prompt Library and Ask flows.

Do not borrow:

- Heavy global environment injection everywhere. MacParakeet already has
  explicit view model injection and testable targets; keep that unless a shared
  environment is clearly simpler.

MacParakeet application:

- Consider extracting reusable transcript row / prompt result row components
  into a small UI package only if reuse grows across Dictations, Library,
  Meetings, and Prompt Results.
- Borrow the idea of "pinned filters" for Library: Meetings, Favorites, Local,
  YouTube, and maybe "Has summary".

## Tier 2 References

### Ice

Repo: <https://github.com/jordanbaird/Ice>

Why it matters: Ice is a strong reference for menu bar, permissions, settings,
and low-friction macOS utility behavior.

Observed code patterns:

- Separate folders for `MenuBar`, `Permissions`, `Settings`, `Hotkeys`, `Events`,
  `UI`, and `Main`.
- Settings panes are backed by dedicated settings managers.
- Menu bar search uses an `NSPanel` with non-activating utility/hud behavior and
  a SwiftUI hosting view.

Borrow:

- Settings IA: permissions, hotkeys, appearance, advanced controls should feel
  operational and searchable.
- Menu bar as a real control surface, not just "open app / quit".

Do not borrow:

- Ice's deep menu-bar manipulation domain. MacParakeet only needs status,
  capture controls, and quick access.

MacParakeet application:

- Add a compact menu bar popover audit: start dictation, start/stop meeting,
  recent item, current permissions, model state, open settings.

### Snapzy

Repo: <https://github.com/duongductrong/Snapzy>

Why it matters: Snapzy is newer but directly relevant for ScreenCaptureKit,
recording overlays, shortcuts, onboarding permissions, and recording state.

Observed code patterns:

- Feature folders for Capture, Recording, Annotate, History, QuickAccess,
  Onboarding, Preferences.
- Tests mirror feature and service folders.
- `ScreenRecordingManager` models recording state and localized errors
  explicitly.
- Toasts use non-activating panels with clear backgrounds, `statusBar` level,
  all-spaces collection behavior, and SwiftUI content.

Borrow:

- Permission onboarding language and status rows for screen recording and mic.
- Recording state as a compact enum with localized errors and recovery actions.
- Feature/service test mirroring.

Do not borrow:

- Screenshot/annotation workflows. They are adjacent but not MacParakeet's core.

MacParakeet application:

- Improve meeting recording errors by grouping them as recoverable permission,
  setup, write, cancellation, and already-active states with one clear action.

### CodeEdit

Repo: <https://github.com/CodeEditApp/CodeEdit>

Why it matters: CodeEdit is a large SwiftUI/AppKit hybrid with serious
workspace architecture. It is useful as an upper-bound reference, not something
to copy wholesale.

Observed code patterns:

- `Features/` folder structure by product surface.
- `CodeEditSplitViewController` uses AppKit split views where SwiftUI alone is
  not enough, preserving snap widths, collapsed state, and haptic feedback.
- Commands, command palette, keybindings, status bar, terminal, source control,
  and settings are domain-separated.

Borrow:

- Feature-folder naming discipline when MacParakeet app target gets crowded.
- AppKit split-view bridges only for precise native behavior SwiftUI cannot
  provide.
- Command palette thinking for power users, especially if Transforms/Prompts
  grow.

Do not borrow:

- IDE-level complexity. MacParakeet is a voice app, not a workspace OS.

MacParakeet application:

- If the main window gains an inspector/detail panel, prefer a small AppKit
  split-view bridge with persisted widths over fighting `NavigationSplitView`.

### Pearcleaner

Repo: <https://github.com/alienator88/Pearcleaner>

Why it matters: Pearcleaner is visually polished and operationally rich for a
system utility, but it is source-available with Commons Clause and currently on
hold. Study it as product UX, not as code to borrow.

Borrow:

- Drag/drop and deep-link automation patterns.
- Clear high-risk action confirmations.
- List/grid toggles where the object type supports both.

Do not borrow:

- License-sensitive code.
- Dense utility sprawl.

MacParakeet application:

- Use deep links/URL commands for automation parity with CLI, especially
  `macparakeet://transcribe`, `macparakeet://record-meeting`, and
  `macparakeet://open?id=...` if this becomes a product goal.

## Design Principles To Apply

### 1. One Signature Interaction Per Mode

Each primary mode should have one unmistakable, high-craft interaction:

- Dictation: the floating pill and honest waveform.
- File/URL transcription: portal drop/paste state and media processing bloom.
- Meeting recording: persistent meeting pill + notes/transcript/ask panel.
- Transforms: compact selected-text rewrite pill with diff/revert affordance.

Do not add a new signature flourish to every card. That dilutes the product.

### 2. Text Is The Product

For a voice app, the output is readable text. UI polish must improve reading,
editing, selecting, copying, searching, summarizing, and navigating transcript
content.

Priority order:

1. Transcript readability.
2. Timestamp and playback alignment.
3. Summary / notes / Ask context.
4. Visual identity.

### 3. State Must Be Honest

No fake equalizers, fake progress, or generic "AI shimmer" for speech work.

Use real signals:

- Mic level.
- System audio level.
- Silence detection.
- STT job stage.
- File conversion stage.
- Prompt/LLM streaming stage.
- Engine/model availability.

### 4. Native First, Custom Second

Borrow from Loop only where custom UI earns its place. Borrow from NetNewsWire
and CotEditor everywhere else.

Native controls should remain native:

- Sidebar.
- Settings rows.
- Text selection.
- Menus.
- Keyboard shortcuts.
- Alerts and confirmation sheets.

Custom controls should be reserved for:

- Floating pills.
- Recording state.
- Audio/media timeline.
- Drop/portal affordance.
- Completion states.

### 5. Architecture Should Follow Surfaces

MacParakeet already has a good target split. Do not prematurely create many UI
packages. The next architectural improvement should be feature-scoped app
folders and small reusable components, not a broad rewrite.

Good next splits:

- `Views/Transcript/` for shared transcript reading, timestamp, selection, and
  segment actions.
- `Views/FloatingStateSurfaces/` only if pill/toast/panel controllers converge.
- `Views/Library/Rows/` for reusable row/card/list formats.

## Concrete UI Moves

### Move 1: Transcript Detail Refresh

Reference: IINA + CotEditor + NetNewsWire.

Goal: make transcription results feel like a first-class media document.

Changes:

- Persistent bottom playback rail for audio/video files.
- Search-in-transcript field.
- Segment hover actions: play from here, copy text, copy with timestamp.
- Optional font-size control.
- Speaker color bands that remain quiet enough for long reading.

Do not:

- Add a decorative waveform behind transcript text.
- Make the transcript card-heavy.

### Move 2: Meeting Tile Readiness Strip

Reference: Loop + Snapzy + Ice.

Goal: meeting start should feel safe and obvious.

Add four compact readiness chips:

- Mic.
- System audio.
- Speech engine.
- Storage.

Each chip should show ready / warning / blocked, and blocked chips should route
to the exact fix. This reduces pre-meeting anxiety more than a larger Start
button would.

### Move 3: Library List Discipline

Reference: NetNewsWire.

Goal: make Library faster to scan.

Changes:

- Keep visual grid for video/YouTube/local files where thumbnails help.
- Keep Meetings as date-grouped rows.
- Add a compact row option for all library items.
- Standardize row metadata: title, source, duration, date, summary state,
  engine, favorite, prompt result count.

### Move 4: Settings Search And Status

Reference: Ice + CodeEdit.

Goal: Settings should answer "is my app ready?" quickly.

Changes:

- Keep Settings native, but add a top readiness summary for permissions,
  hotkey, local model, update status, and AI provider.
- Search should surface exact settings rows, not just tabs.
- Avoid coral tint cascades; keep `parakeetAction` semantics.

### Move 5: Floating Surface Unification

Reference: Loop + Snapzy.

Goal: make floating UI easier to reason about.

Changes:

- Audit `IdlePillController`, `DictationOverlayController`,
  `MeetingRecordingPillController`, `MeetingRecordingPanelController`, and
  toast controllers.
- Extract only the repeated AppKit panel setup if duplication is real.
- Keep each surface's view model distinct because state semantics differ.

## Patterns To Avoid

- Building a custom "beautiful dashboard" for its own sake.
- Turning every repeated item into a card.
- Copying Loop's radial menu or IINA's full media-player complexity.
- Treating Pearcleaner as an open-source code source despite license limits.
- Overusing particles, gradients, or sacred geometry until the app reads as a
  theme demo rather than a voice tool.
- Hiding primary actions behind hover-only controls.

## Suggested Implementation Order

1. **Transcript detail refresh**: highest daily-use value and least product
   ambiguity.
2. **Meeting readiness strip**: directly improves trust around a high-risk
   recording action.
3. **Library row discipline**: improves scanning and reduces visual clutter.
4. **Settings readiness/search polish**: useful once permissions/model setup
   complexity grows.
5. **Floating surface controller cleanup**: do only after concrete UI changes
   expose duplication.

## Reference Ranking For MacParakeet

| Rank | Reference | Primary Lesson | Confidence |
|------|-----------|----------------|------------|
| 1 | IINA | Media detail, playback, hover controls | High |
| 2 | Loop | Signature floating state craft | High |
| 3 | NetNewsWire | Durable native library/detail restraint | High |
| 4 | CotEditor | Text-first native behavior | High |
| 5 | Ice | Menu bar, settings, permissions | High |
| 6 | Snapzy | ScreenCaptureKit/recording/permission patterns | Medium |
| 7 | IceCubesApp | Modern SwiftUI feature modules and timelines | Medium |
| 8 | CodeEdit | Large-app architecture upper bound | Medium |
| 9 | Pearcleaner | Utility UX and deep-link ideas | Low for code, medium for UX |

## Bottom Line

MacParakeet's next design pass should be less about finding a prettier visual
style and more about tightening the three places users judge the app:

1. **Can I trust it before I record?**
2. **Can I understand what it is doing while it works?**
3. **Can I use the transcript effortlessly after it finishes?**

The references above are useful only insofar as they help answer those three
questions.
