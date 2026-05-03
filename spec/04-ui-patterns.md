# MacParakeet UI Patterns

> Status: **ACTIVE**

## Overview

MacParakeet has these primary UI surfaces:
1. **Main Window** -- Sidebar + content area; **Transcribe** is the unified capture hub for all three modes
2. **Idle Pill** -- Persistent floating indicator, always visible when not dictating or meeting-recording
3. **Dictation Overlay** -- Compact pill for recording state
4. **Meeting Recording Tile** -- Capture tile on the Transcribe tab; reflects live recording state
5. **Meeting Recording Pill** -- Persistent floating pill during meeting recording (sacred geometry icon); shares state with the Transcribe tile
6. **Meeting Recording Panel** -- Floating Notes / Transcript / Ask panel with audio levels and stop controls
7. **Menu Bar** -- Quick access and status
8. **Calendar Countdown Toasts** -- Implemented but hidden from v0.6 by `AppFeatures.calendarEnabled = false`
9. **Settings** -- Preferences, permissions, local speech models, and update controls; calendar controls are hidden in v0.6

Design philosophy: **Simple, native, stays out of the way.** No chrome, no clutter. The app should feel like part of macOS, not a web app in a wrapper.

---

## Brand And Asset Sources

- In-app brand surfaces use the canonical parakeet PNG through
  `BreathWaveIcon.brandMark` and `BreathWaveLogo`; see
  `docs/brand-identity.md` for sizing, tinting, and usage rules.
- App chrome uses `DesignSystem.Colors.accent`, the warm coral-orange brand
  accent (`#E86B3B` in the light palette). System colors carry the rest of the
  UI.
- Promotional and editorial design uses `brand-assets/`: the recolorable
  `parakeet-line.svg`, Pop palette, composition templates, and generated PNG
  exports. The Pop palette is for campaigns, posters, social assets, and launch
  moments; it must not leak into app chrome.

---

## Main Window (v0.1)

### Layout

```
┌──────────────────────────────────────────────────────────────┐
│  MacParakeet                                          ─ □ ✕  │
├──────────────────┬───────────────────────────────────────────┤
│  Sidebar         │  Content                                  │
│  ────────────    │  ───────────────────────────────────────  │
│                  │                                           │
│  🎤 Transcribe   │  [Depends on sidebar selection]           │
│  🗂 Library      │                                           │
│  🕒 Dictations   │  - Transcribe: 3-mode capture hub        │
│  📖 Vocabulary   │  - Library: Grid (or list for Meetings)  │
│  💬 Feedback     │  - Dictations: History list               │
│  ⚙ Settings      │  - Vocabulary: Processing mode + manage   │
│                  │  - Feedback: Form + community link        │
│                  │  - Settings: Grouped form                 │
│                  │                                           │
└──────────────────┴───────────────────────────────────────────┘
```

Minimum window width: 800pt.

### Sidebar

The sidebar uses NavigationSplitView with flat items (icon + label):

- **Transcribe** (`waveform`) -- Capture hub: YouTube card + file drop card + Meeting Recording tile
- **Library** (`square.grid.2x2`) -- All transcriptions; filter chips switch between thumbnail grid (All/YouTube/Local/Favorites) and date-grouped list (Meetings)
- **Dictations** (`clock.arrow.circlepath`) -- Flat history list with bottom bar player
- **Vocabulary** (`book.fill`) -- Processing mode, pipeline guide, custom words & snippets management
- **Feedback** (`bubble.left.and.text.bubble.right`) -- Bug reports, feature requests, community link
- **Settings** (`gearshape`) -- Dictation prefs, meeting recording prefs, storage, permissions

There is no dedicated Meetings tab. Meeting **capture** lives on the Transcribe tile (plus hotkey + menu bar); meeting **browse** lives under Library's Meetings filter. Reason: a separate sidebar entry was a third entry point for an action already covered by hotkey + menu bar, and meetings have no thumbnail-worthy visual asset, so the date-grouped list (preview text + speaker count) belongs in the unified Library rather than a dedicated tab.

Column width: `min: 160, ideal: 180, max: 220`. Window minimum width: 800pt.

Content transitions between tabs use `DesignSystem.Animation.contentSwap` (0.2s easeInOut).

### Transcribe Tab (capture hub)

```
+------------------------------------------------------------+
|  +----------------------+  +--------------------------+    |
|  |  > YouTube           |  |  Drop a file             |    |
|  |  [Paste link]   [->] |  |  [Browse Files]          |    |
|  |                      |  |  MP3, WAV, M4A, MP4...   |    |
|  +----------------------+  +--------------------------+    |
|  +------------------------------------------------------+  |
|  |  o  Record Meeting                          * Start  |  |
|  |     Capture system audio + mic, transcribed locally  |  |
|  +------------------------------------------------------+  |
+------------------------------------------------------------+
```

Two big input cards on top (equal weight), one ~96pt strip below (lighter weight — meeting capture is a single-click action, doesn't need real estate for paste fields or drop areas). The Meeting Recording tile is gated behind `AppFeatures.meetingRecordingEnabled`; when disabled it's hidden and the layout collapses to two cards.

### Meeting Recording Tile

A horizontal strip on the Transcribe tab. Mirrors the floating recording pill's visual language (flower-of-life rosette + stem + leaves) at a larger scale on a light surface — green strokes on `surfaceElevated` instead of the pill's white-on-black.

States, all bound to the long-lived `MeetingRecordingPillViewModel` shared with the floating pill:

- **Idle**: green rosette + stem (subtle 4s glow breathing), "Record Meeting" + subtitle, red "Start" capsule on the right.
- **Recording**: rosette rotates (12s/turn — matches the floating pill exactly), audio halo grows with mic level, breathing red dot + monospaced MM:SS timer, white-on-red Stop button. Border picks up `recordingRed` opacity.
- **Completing / Transcribing**: spinner replaces rosette; "Wrapping up..." then "Transcribing..." labels.
- **Completed**: green checkmark + "Saved to Library"; auto-reverts to idle.
- **Error**: amber triangle + recovery message; auto-dismisses through the recording flow coordinator.

The tile body is informational. Only the visible Start and Stop capsules are real SwiftUI `Button`s, and both call the same `toggleRecording` path the menu bar uses. Completing, transcribing, completed, and error states render as inert status surfaces and must not expose button traits or no-op accessibility actions. The floating pill stays visible during recording so users who hide the main window keep an active control surface.

### Library Meetings Filter

When `Library.filter == .meeting`, the view renders a date-grouped list (`Today` / `Yesterday` / `Previous 7 Days` / `Previous 30 Days` / `{Month Year}`) using `MeetingDateGroupHeader` + `MeetingRowCard` instead of the thumbnail grid the other filters use.

---

## Dictation History (v0.1)

### Layout

Full-width flat chronological list with bottom bar audio player. No split pane — dictations are typically short (a sentence or two), so a detail pane wastes space. Content transitions use `DesignSystem.Animation.contentSwap`.

```
┌──────────────────────────────────────────────────────────────┐
│  🔍 Search dictations...                                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  TODAY                                                       │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  2:34 PM │ Can we move the standup to 3pm tomorrow?  │    │
│  │     12s  │ I have a conflict with the design review, │    │
│  │          │ so it would be great if we could shift it  │    │
│  │          │ by an hour.           [▶] [📋] [···]       │    │  ← hover actions
│  └──────────────────────────────────────────────────────┘    │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ 11:02 AM │ Remember to update the API documentation  │    │
│  │      8s  │ before the release.                       │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  YESTERDAY                                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  5:15 PM │ Hi Sarah, following up on our             │    │
│  │     23s  │ conversation about the Q3 budget...       │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  [▶ 32pt]  "Can we move the standup..."  ═══░░░  0:03/0:12  [✕] │  ← bottom bar player
└──────────────────────────────────────────────────────────────┘
```

### Row Anatomy

```
┌──────────────────────────────────────────────────────────┐
│  {time}  │  {full transcript text}     [▶] [📋] [···]    │  ← hover actions (right)
│  {dur}   │                                               │
└──────────────────────────────────────────────────────────┘

Components:
- Timestamp column: 56pt wide, right-aligned — time (caption.monospacedDigit) + duration below (caption2.monospacedDigit, tertiary)
- Transcript: cleanTranscript ?? rawTranscript, NO line limit, full text always visible
- Text selection enabled on transcript
- Hover actions: Play (if audio) + Copy + three-dot Menu (Download Audio, Delete)
- Currently-playing row: subtle accent tint background (accentColor 6%)
- Hover background: subtle tint (primary 4%)
- Context menu: Play/Pause, Copy, Download Audio, Delete (⌘⌫)
- No selection state — no accent bar, no List(selection:)
- Delete shows confirmation alert (shared at view level, not per-row)
```

### Bottom Bar Audio Player

Fixed 52pt bar at the bottom of the history view. Slides in when audio is playing, slides out when stopped.

```
┌──────────────────────────────────────────────────────────────┐
│  [▶ 32pt accent circle]  "Transcript snippet..."  ═══░░░  0:15 / 2:30  [✕]  │
└──────────────────────────────────────────────────────────────┘

Components:
- Accent-filled 32pt circle with white play/pause icon (identical to old playback card)
- Single-line transcript snippet for context (callout font)
- 120pt capsule progress bar (playbackTrack / playbackFill tokens)
- Monospaced time display (timestamp font)
- Close button (xmark.circle.fill) calls stopPlayback()
- Background: controlBackgroundColor with top Divider
- Transition: .move(edge: .bottom).combined(with: .opacity)
```

---

## Idle Pill (v0.1)

Persistent floating pill at the bottom-center of the screen, always visible when the app is running and not actively dictating. Provides a visual anchor so users always know MacParakeet is ready.

### Dimensions

- **Collapsed:** 48×10pt dark grey capsule (subtle nub)
- **Expanded (hover):** 148×30pt dark capsule with dots + tooltip above
- **Position:** Bottom-center, 12pt above dock (same location as dictation overlay)
- **Panel:** NSPanel, `.nonactivatingPanel`, `.borderless`, `.floating` level

### States

**1. Collapsed (Idle)**

```
┌────────────────────────────┐
│         ╭──────╮           │
│         ╰──────╯           │  ← subtle dark grey nub
└────────────────────────────┘

- 48×10pt dark grey capsule (25% white, 90% opacity)
- Subtle inner capsule stroke (white 6%)
- No accent line — minimal footprint
```

**2. Expanded (Hover)**

```
  ╭────────────────────────────────────────────╮
  │  Click or hold fn to start dictating       │  ← tooltip bubble
  ╰────────────────────────────────────────────╯
┌──────────────────────────────────────────┐
│    ╭──────────────────────────────╮      │
│    │  · · · · · · · · · · · ·    │      │  ← 12 small dots
│    ╰──────────────────────────────╯      │
└──────────────────────────────────────────┘

- 148×30pt expanded dark capsule (black 85%)
- 12 small dots (3pt, white 25%) inside pill
- Tooltip bubble above: "Click or hold fn to start dictating"
  - "fn" in pink (0.85, 0.55, 0.75)
  - Dark capsule background (black 90%) with white 10% stroke
```

### Behavior

- **Show:** On app launch and after every dictation exit (stop, cancel, error, dismiss)
- **Hide:** When dictation starts
- **Click:** Starts persistent dictation (same as double-tap Fn)
- **Hover:** Expands pill, shows tooltip
- **Mouse exit:** Collapses pill, hides tooltip
- **Focus:** Never steals focus (non-activating panel)
- **Spaces:** Visible on all spaces and fullscreen apps

### Animation

| Animation | Duration | Curve | Usage |
|-----------|----------|-------|-------|
| Pill expand/collapse | 0.35s | `.spring(dampingFraction: 0.8)` | Hover state change |
| Tooltip appear | 0.2s | `.easeOut` + scale 0.9→1.0 | Show on hover |
| Tooltip disappear | 0.2s | `.easeOut` | Hide on mouse exit |

---

## Dictation Overlay / Pill (v0.1)

Compact dark pill overlay, always-on-top, bottom-center of screen. This is the primary recording UI and must be polished from day one.

### Dimensions

- **Height:** 36px
- **Corner radius:** 18px (fully rounded)
- **Width:** Dynamic, fits content + 16px horizontal padding
- **Position:** Bottom-center of main screen, 48px from bottom edge
- **Background:** `#1C1C1E` (system dark) at 95% opacity
- **Shadow:** 0 4px 12px rgba(0,0,0,0.3)

### States

**1. Recording**

```
┌──────────────────────────────────────────┐
│  [✕]  |||||||||||||||  0:03  [■]        │
│        ← waveform →   timer              │
└──────────────────────────────────────────┘

- [✕] Cancel button (SF Symbol: xmark.circle.fill, red tint)
  - Hover: brightens background (white 12% → 25%), icon fully opaque
- Waveform: 12 bars, animating to audio amplitude, white
- Timer: Recording duration (e.g., "0:03"), updates every second
- [■] Stop button (SF Symbol: stop.circle.fill, white)
  - Hover: red glow (red 30% background), 10% scale-up
- Tooltip on [✕]: "Cancel (Esc)"
- Tooltip on [■]: "Stop & Paste (↵)"
```

**2. Cancelled**

```
┌──────────────────────────────────────────┐
│  [countdown ring]  Cancelled  [Undo]    │
└──────────────────────────────────────────┘

- Countdown ring: 3-second circular progress, then auto-dismiss
- "Cancelled" label in secondary text color
- [Undo] button: re-opens recording state with buffered audio
- Dismisses after 3 seconds if no interaction
```

**3. Processing**

```
┌──────────────────────────────────────────┐
│  [merkaba]  Processing...               │
└──────────────────────────────────────────┘

- [merkaba]: Sacred geometry spinner — two counter-rotating equilateral triangles
  - Clockwise triangle: 3s full rotation, white 50% stroke
  - Counter-clockwise triangle: 3s full rotation (opposite), white 30% stroke
  - 6 vertex dots: 2.5pt core (white 80%) + 7pt blur glow, pulsing 0.6→1.0 over 1.5s
  - Center nexus: 3pt core (white 90%) + 10pt blur glow, pulsing 0.3→0.7 over 2s
  - Faint outer guide ring: white 8%, 0.5pt stroke
- "Processing..." label
- Cross-fades in from recording state via `.opacity` transition
```

**4. Formatting (AI Formatter refinement)**

```text
┌──────────────────────────────────────────┐
│             [seed of life]               │
└──────────────────────────────────────────┘
```

- Only entered when the AI Formatter is enabled and about to run on the
  transcript. Sits between Processing and Success; skipped entirely
  when the formatter is disabled.
- [seed of life]: Sacred geometry bloom — six coral petal circles
  growing in place from tiny vertex dots into a full Seed of Life,
  rotating continuously at ~10s/rev. Rendered by `FormatterVisualView`.
  - 6-fold symmetry matches the `.processing` Merkaba's six vertex
    lights so the cross-fade reads as "six things re-composing."
  - Petal outer edges reach `size * 0.44`, visually close to the
    Merkaba's outer-vertex radius of `size * 0.423` — same bounding
    ring on both states.
  - Color: `DesignSystem.Colors.accent` (warm coral), signaling a
    different kind of work than the white `.processing` spinner.
  - Phases: Bud (0 → 0.15s, dots ignite) → Bloom (0.15 → 1.00s,
    petals grow in place) → Hold (1.00s → ∞, flower rotates and
    breathes until the formatter returns).
- Pill size: same 46×46 as Processing — the state change is a
  hue/geometry evolution, not a resize.
- Triggered by the `.macParakeetAIFormatterDidStart` notification
  (posted from `DictationService.formatTranscriptIfNeeded`) which the
  `DictationFlowCoordinator` observes to promote the overlay state
  from `.processing` → `.formatting`. Terminal transitions
  (cancellation, success, error) take precedence — the coordinator
  only promotes when currently in `.processing`.
- For command sessions, falls back to a spinner + "Refining..." label
  so the visible command context continues to read during refinement.
- Reduce Motion: presents the fully-bloomed peak state statically.
- VoiceOver: "Refining transcript".

**5. Success**

```
┌──────────────────────────────────────────┐
│  [✓]  Pasted                            │
└──────────────────────────────────────────┘

- [✓] Checkmark (SF Symbol: checkmark.circle.fill, green tint)
- "Pasted" label
- Auto-dismisses after 1.5 seconds
```

**6. Error Card**

Errors use a wider rounded-rectangle card instead of the compact pill — distinct shape signals a different kind of information.

```
┌──────────────────────────────────────────┐
│                                          │
│  (⚠)  Speech Engine Not Ready           │
│       STT model failed to load.          │
│       Try restarting the app.            │
│                                          │
│                            [ Dismiss ]   │
│                                          │
└──────────────────────────────────────────┘

- Shape: RoundedRectangle (14px radius), not Capsule
- Width: 260px content (wider than pill)
- Icon: exclamationmark.triangle.fill in red, inside a tinted circle (red 15%)
- Two-line text hierarchy:
  - Title: 13pt semibold white (e.g., "Speech Engine Not Ready")
  - Subtitle: 11pt regular white 50% opacity (actionable hint)
- Dismiss button: capsule, white 10% fill, right-aligned
- Auto-dismisses after 5 seconds (no visible countdown)
- Dismiss button allows immediate dismissal
- Error messages mapped from technical to user-friendly categories:
  STT/CoreML/model   → "Speech Engine Not Ready"
  Microphone/audio  → "Microphone Unavailable"
  Permission/access → "Permission Required"
  Timeout           → "Transcription Timed Out"
  Memory/OOM        → "Out of Memory"
  Fallback          → "Something Went Wrong"
```

### Hover Tooltips

Tooltips use AppKit `NSTrackingArea` with `.activeAlways` because the pill is a non-activating `NSPanel`. Standard SwiftUI `.help()` modifiers and `.onHover` do not work on non-activating panels.

**Unified tooltip styling** (shared by idle pill and dictation overlay):
- Font: 14pt `.medium` (keys: 14pt `.semibold`)
- Text color: white 90%
- Key highlights (fn, Esc, ↵): pink tint `(0.85, 0.55, 0.75)` — stands out from white text
- Background: black 90% capsule fill with white 10% strokeBorder (0.5pt)
- Shadow: black 30%, radius 8, y-offset 4
- Padding: 20pt horizontal, 10pt vertical

Implementation pattern:
- `MouseTrackingOverlay` NSView layered on top of the pill
- `hitTest` returns `nil` for click passthrough (dictation overlay) or `self` for click-to-dictate (idle pill)
- `NSTrackingArea` with `.mouseMoved` + `.activeAlways` for precise hover detection
- Show/hide tooltip label (opacity toggle, not add/remove, to prevent resize jitter)
- Reserve space for tooltip text in the layout at all times

### Pill Window Properties

```swift
// NSPanel configuration for overlay pill
let panel = NSPanel(
    contentRect: rect,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.level = .floating
panel.isMovableByWindowBackground = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

---

## Meeting Recording Pill (v0.6)

Persistent floating pill that appears during meeting recording. Uses the sacred-geometry Merkaba icon as the anchor. Clicking the pill opens the meeting recording panel. Shares its state (`MeetingRecordingPillViewModel`) with the **Meeting Recording Tile** on the Transcribe tab — both surfaces stay in sync because they bind to the same long-lived view model owned by `AppDelegate`.

### Layout

```
┌──────────────────────────────────────┐
│  [✿]  Recording  01:23:45  [■ Stop] │
└──────────────────────────────────────┘

- [✿]: Merkaba (sacred geometry) icon — animated rotating triangles
- "Recording" label
- Elapsed timer (HH:MM:SS)
- [■ Stop] button — stops recording and triggers transcription
```

### Behavior

- **Appears** when meeting recording starts (after permissions granted)
- **Persists** for the entire recording session — does not auto-dismiss
- **Click** anywhere on the pill opens the meeting recording panel
- **Stays visible** during concurrent dictation — dictation overlay appears separately
- **Hides** idle pill while visible (meeting pill replaces it)
- **Disappears** when recording stops (transitions to transcription in library)

### Panel: `NSPanel` (non-activating)

Same `KeylessPanel` pattern as dictation overlay — never steals focus from the active app. `.floating` window level.

---

## Meeting Recording Panel (v0.6)

Floating panel opened from the meeting recording pill. Shows live notes, live transcript preview, live Ask chat, audio levels, and recording controls. Notes is the default tab.

### Layout

```text
┌──────────────────────────────────────────┐
│  Meeting Recording         01:23:45      │
│  🎤 ██████████░░░░   🔊 ████████░░░░     │
│  ──────────────────────────────────────  │
│  [Notes]   [Transcript]   [Ask · ●]      │
│                                          │
│  **Decision:** ship Friday               │
│  /action QA smoke test                   │
│                                          │
│  ──────────────────────────────────────  │
│  [■ Stop Recording]                      │
└──────────────────────────────────────────┘
```

### Components

- **Elapsed timer** — updates every second
- **Dual audio level meters** — mic and system audio levels (visual feedback that both streams are capturing)
- **Tabs** — Notes / Transcript / Ask, with ⌘1 / ⌘2 / ⌘3 shortcuts; Notes and Transcript are plain labels, Ask adds a streaming dot while `chatViewModel.isStreaming` and collapses that dot into the tooltip at narrow width
- **Notes pane** — plaintext editor with slash commands, debounced auto-save through `MeetingRecordingService.updateNotes(_:)`, soft-cap warning near 8,000 words, and lock-file crash recovery
- **Transcript pane** — scrolling live preview with source labels ([Me] = mic, [Them] = system audio); lag notice appears when preview chunks fall behind or are dropped
- **Ask pane** — live chat against the rolling transcript using the configured LLM provider; follow-up state is handed off after finalization
- **Stop button** — stops recording, triggers batch transcription, navigates to result
- **Meetings empty state copy** — one-line guidance: "For the cleanest separation between you and other participants, use headphones."
- Notes and Ask own their own bottom UI; the shared footer is hidden on those tabs. The final saved meeting transcript remains authoritative even if live preview lagged.

### Concurrent Operation (ADR-015)

During concurrent dictation + meeting recording:
- Meeting panel stays open and continues showing live preview
- Dictation overlay appears/disappears independently
- Both pills are visible simultaneously
- Menu bar icon follows priority: meeting > dictation > file transcription > idle

---

## Menu Bar (v0.1, updated v0.6)

### Menu Structure

```
┌────────────────────────────────┐
│  MacParakeet                   │
├────────────────────────────────┤
│  Start Dictation    (hotkey)  │
│  Record Meeting     (hotkey)  │
│  Open Window           ⌘O     │
├────────────────────────────────┤
│  Recent Transcriptions   ►    │
│  ├─ interview.mp3  (2m ago)   │
│  ├─ podcast-ep42.m4a  (1h)   │
│  └─ lecture-notes.wav  (3d)   │
├────────────────────────────────┤
│  Settings...           ⌘,     │
│  Quit MacParakeet      ⌘Q     │
└────────────────────────────────┘
```

- **Record Meeting** toggles meeting recording on/off. Label changes to "Stop Meeting" while recording is active.

### Menu Bar Icon

- **Idle:** Parrot outline (SF Symbol or custom asset), 18x18pt
- **Recording:** Parrot with red dot badge
- **Processing:** Parrot with spinner indicator

### Behavior

- Left-click opens the menu
- The menu bar icon is always visible when the app is running
- "Recent Transcriptions" submenu shows last 5 transcriptions with relative timestamps
- Clicking a recent transcription opens the main window to that transcription's detail

---

## File Transcription View (v0.1)

### Drop Zone (Empty State)

Premium double-border treatment with `MeditativeMerkabaView` centerpiece. Drag-over accelerates the merkaba and adds accent glow.

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│           ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐      │
│          ┌┤                                       ├┐     │  ← double border
│          │╎         [merkaba spinner]              ╎│     │
│          │╎                                       ╎│     │
│          │╎    Drop audio or video file here      ╎│     │
│          │╎    MP3, WAV, M4A, FLAC, MP4, MOV, MKV╎│     │
│          └┤                                       ├┘     │
│           └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘      │
│                                                          │
│                     [Browse Files]                       │
│                                                          │
└──────────────────────────────────────────────────────────┘

Drop zone components:
- Outer thin solid border: 0.5pt, primary 6% (accent 30% on drag-over)
- Inner dashed border: 1.5pt, dash [8, 4], primary 15% (accentColor on drag-over)
- Accent glow fill: accentColor 4% (on drag-over only)
- MeditativeMerkabaView(size: 80): 6s revolution (constant), tintColor switches to .accentColor on drag; opacity 0.7 idle → 0.9 on drag (eased over 0.3s)
- "Browse Files" button: .borderedProminent style
- Supported formats text: caption, tertiary
- Drop zone height: 200pt (DesignSystem.Layout.dropZoneHeight)
```

### Processing State

Uses `SpinnerRingView` plus phase-aware progress feedback.

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│                    [merkaba spinner]                     │
│                                                          │
│               "Downloading audio... 42%"                │
│                     [linear 42% bar]                     │
│                                                          │
│                    [error if any]                        │
│                                                          │
└──────────────────────────────────────────────────────────┘

- SpinnerRingView(size: 48, tintColor: .accentColor)
- Phase icon behind spinner:
  - Download phase (`"download"` in phase text): `arrow.down.circle`
  - Transcription phase: `waveform`
- Progress text: body font, secondary color (`viewModel.progress`)
- Determinate progress bar shown when phase text ends with `%` (parsed from phase string)
- During download phases without parsable percent, show indeterminate linear bar + helper text
- Error text: caption, red (if present)
```

### Result Display

```
┌──────────────────────────────────────────────────────────┐
│  [←]  interview.mp3                        ╭─45:12─╮    │  ← hover back button + duration pill
│                                            ╰───────╯    │
│  ─────────────◇───────────                              │  ← sacred geometry divider
│                                                          │
│  ┌──────┐                                                │
│  │00:00 │  Welcome everyone to today's product review.  │  ← timestamp with faint bg
│  └──────┘  We have three items on the agenda.           │
│  ┌──────┐                                                │
│  │00:08 │  First, let's look at the Q3 metrics          │
│  └──────┘  dashboard.                                   │
│                                                          │
│  [scrollable, selectable text with lineSpacing(3)]      │
│                                                          │
│  ──────────────────────────────────────────────────────  │
│  [Export .txt]  [Copy]                                  │
└──────────────────────────────────────────────────────────┘

Header:
- Back button: chevron.left in 24pt circle, hover effect (primary 8% bg, foreground brightens)
- Filename: headline font
- Duration pill: Capsule (primary 5%), fixedSize

Transcript:
- SacredGeometryDivider between header and content
- Timestamped segments: grouped by gaps (>500ms) or word count (15)
- Timestamp column: faint RoundedRectangle background (primary 3%), monospaced digit font
- Text: body font, selectable, lineSpacing(3)

Export bar:
- Export .txt + Copy buttons, bordered style
```

### Recent Transcriptions List

Appears below the drop zone when transcription history exists. Section header includes count badge.

```
┌──────────────────────────────────────────────────────────┐
│  Recent Transcriptions  (3)                              │  ← section header + count badge
│  ┌────────────────────────────────────────────────────┐  │
│  │ [🎵]  interview.mp3          ╭─Done ✓─╮           │  │  ← status-tinted icon + status pill
│  │       2 min ago · 24 MB · 45:12   ╰────────╯      │  │
│  ├────────────────────────────────────────────────────┤  │
│  │ [⚠️]  podcast.m4a            ╭─Failed ✗─╮          │  │
│  │       1h ago · 108 MB         ╰─────────╯          │  │
│  │                                Timeout err...      │  │  ← truncated error message
│  ├────────────────────────────────────────────────────┤  │
│  │ [🎵]  lecture.wav             ╭─Done ✓─╮           │  │
│  │       3d ago · 12 MB · 1:02:15 ╰───────╯          │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘

Row anatomy:
- Status-tinted icon square: 32×32pt rounded rect (cornerRadius 6) with tinted fill
  - Completed: waveform icon, successGreen 10% bg / successGreen fg
  - Processing: rotating arrows, accentColor 10% bg / accentColor fg + SpinnerRingView in pill
  - Error: exclamationmark.triangle, statusDenied 10% bg / statusDenied fg
  - Cancelled: xmark, primary 5% bg / secondary fg
- Two-line content: filename (body, primary) + metadata (relative time · file size · duration)
- Status pill: Capsule with tinted fill (color 10%) + icon + label
  - "Done" (checkmark, successGreen), "Processing" (merkaba spinner, accentColor),
    "Failed" (xmark, statusDenied), "Cancelled" (minus, secondary)
  - Error rows show truncated errorMessage (9pt, tertiary) below pill
- Hover: subtle background tint (rowHoverBackground)
- Row separators: hidden
- List maxHeight: 260pt
- Clicking a row navigates to TranscriptResultView
```

---

## Settings (v0.6)

Settings open in the content area when "Settings" is selected in the sidebar. The current information architecture is a four-tab shell with a persistent header, search field, and status-aware tab badges:

- **Modes** — Audio Input, Dictation, Transcription, and Meeting Recording cards. Calendar controls are folded into Meeting Recording but hidden in v0.6 while `AppFeatures.calendarEnabled = false`.
- **Engine** — Speech engine selector, Whisper language picker, and local model status/management.
- **AI** — Optional provider setup for summaries, transcript chat, prompt actions, and live Ask.
- **System** — Startup, permissions, storage, updates, privacy/telemetry, onboarding reset, about, and fenced Reset & Cleanup actions.

`SettingsRootViewModel` owns active-tab persistence and search state. `SettingsSearchIndex` provides cross-tab search results and hides calendar entries while the calendar feature flag is off. The legacy card sketches below are retained only as historical content references; their grouping is not the current v0.6 IA.

### General (v0.1)

```
┌───────────────────────────────────────────────────────────┐
│  GENERAL                                                  │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Launch at login              [toggle: OFF]              │
│  Menu bar only                [toggle: OFF]              │
│  (Hide dock icon, access via menu bar only)              │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Dictation (v0.1)

```
┌───────────────────────────────────────────────────────────┐
│  DICTATION                                                │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Hotkey                       [fn Fn        ▾]          │
│  (Double-tap to start dictation)                         │
│                                                           │
│  Stop mode                    [● Hold to record]         │
│                               [  Double-tap toggle]      │
│  (Hold: release key to stop. Toggle: tap again to stop)  │
│                                                           │
│  Silence threshold            [──●──────── 2.0s]        │
│  (Auto-stop after this much silence)                     │
│                                                           │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Vocabulary (v0.2)

The Vocabulary sidebar item is a dedicated panel for managing the text processing pipeline. It replaces the Processing section that was previously in Settings, promoting vocabulary management to a first-class feature.

```
┌───────────────────────────────────────────────────────────┐
│  PROCESSING MODE                                          │
│  ─────────────────────────────────────────────────────    │
│  [● Clean (fillers removed)]  [  Raw (no processing)]    │
│  Raw outputs STT text as-is. Clean removes filler words, │
│  applies custom word corrections, and expands snippets.   │
│                                                           │
│  HOW IT WORKS                                             │
│  ─────────────────────────────────────────────────────    │
│  1. Filler Removal — Strips um, uh, like, you know       │
│  2. Custom Words — Fixes domain terms STT gets wrong      │
│  3. Text Snippets — Expands trigger phrases to full text  │
│  4. Whitespace Cleanup — Normalizes spacing/punctuation   │
│                                                           │
│  TIPS                                                     │
│  ─────────────────────────────────────────────────────    │
│  💡 Parakeet already handles punctuation and caps...      │
│  💡 Custom words fix domain terms STT gets wrong...       │
│  💡 Leave replacement empty to enforce casing...          │
│  💡 Snippet triggers should be natural phrases...         │
│  💡 Changes take effect on the next dictation.            │
│                                                           │
│  CUSTOM WORDS                              [Manage...]    │
│  Words defined                                  12        │
│                                                           │
│  TEXT SNIPPETS                             [Manage...]    │
│  Snippets defined                                5        │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

Note: How It Works, Tips, Custom Words, and Text Snippets sections are only visible when processing mode is set to "Clean".

### Custom Words Management (v0.2)

```
┌───────────────────────────────────────────────────────────┐
│  ← Vocabulary    CUSTOM WORDS                            │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  🔍 Search words...                          [+ Add]     │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Word              Replacement         Enabled      │  │
│  │  ─────────────────────────────────────────────────  │  │
│  │  para keet         Parakeet            [✓]          │  │
│  │  mac o s           macOS               [✓]          │  │
│  │  jay son           JSON                [✓]          │  │
│  │  kubernetes        (anchor)            [✓]          │  │
│  │  eye phone         iPhone              [ ]          │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Anchors (no replacement) tell the STT model to keep     │
│  the word as-is. Corrections replace the STT output.     │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Table view with inline editing
- "(anchor)" shown in italic for words with no replacement
- Toggle enables/disables without deleting
- Swipe-to-delete or select + Delete key
```

### Text Snippets Management (v0.2)

```
┌───────────────────────────────────────────────────────────┐
│  ← Processing    TEXT SNIPPETS                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  🔍 Search snippets...                       [+ Add]     │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Say...        Expands to...           Uses  On     │  │
│  │  ─────────────────────────────────────────────────  │  │
│  │  my address    123 Main St, Suite 4... 42    [✓]    │  │
│  │  my signature  Best regards, Dan Moon  18    [✓]    │  │
│  │  my calendly   calendly.com/you/30...  7     [✓]    │  │
│  │  intro email   Hey, would love to...   12    [✓]    │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Say a trigger phrase while dictating and it expands     │
│  automatically. Use natural phrases, not abbreviations.  │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Expansion column truncated with ellipsis, full text on hover/click
- "Uses" column shows use_count, sortable
- Same enable/disable and delete patterns as Custom Words
```

### Storage (v0.1 + v0.3)

```
┌───────────────────────────────────────────────────────────┐
│  STORAGE                                                  │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  [x] Save audio recordings                               │
│  (Controls whether dictation audio is saved to disk)     │
│                                                           │
│  [x] Keep downloaded YouTube audio                        │
│  (Enabled by default. If off, URL audio is deleted        │
│   after transcription completes.)                         │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  STATISTICS                                              │
│  Total dictations:            32                         │
│  Total transcriptions:        5                          │
│  YouTube downloads:           4 files • 182.1 MB         │
│  Audio storage used:          48.2 MB                    │
│  Database size:               1.2 MB                     │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  [Clear All Dictation History]                           │
│  [Clear Downloaded YouTube Audio]                        │
│  (These actions cannot be undone)                        │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Speech Recognition (v0.6)

```text
┌───────────────────────────────────────────────────────────┐
│  SPEECH RECOGNITION                                       │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Engine                                                   │
│  [ Parakeet ] [ Whisper ]                                 │
│                                                           │
│  Whisper language                                         │
│  [ Auto-detect                         ▾ ]                │
│                                                           │
│  Parakeet          ╭─✓ Ready─╮              [Repair]      │
│  Loaded in memory and ready.                              │
│                                                           │
│  Whisper           ╭─↓ Not Downloaded─╮     [Download]    │
│  Download before switching to Whisper.                    │
│                                                           │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

- Engine picker options: Parakeet (default) and Whisper.
- Whisper language picker is shown for the Whisper path. `Auto-detect` stores no explicit language; specific languages are normalized before saving.
- Status pill states: `Unknown`, `Checking`, `Ready`, `Not Loaded`, `Not Downloaded`, `Downloading`, `Repairing`, `Failed`.
- `Repair` retries Parakeet model download/initialization with bounded backoff.
- `Download` explicitly downloads the configured Whisper model into `~/Library/Application Support/MacParakeet/models/stt/whisper/`.
- Switching engines is disabled while STT work is queued/running or an active meeting recording holds a speech-engine lease.

### Permissions (v0.1)

Permission badges use pill-shaped capsules with tinted fill, matching the onboarding style:

```
Microphone          ╭─✓ Granted─╮    ← green tinted capsule
                    ╰───────────╯
Accessibility       ╭─✗ Not Granted─╮  ← red tinted capsule
                    ╰───────────────╯

Pill anatomy:
- Icon: checkmark.circle.fill (granted) or xmark.circle.fill (not granted), 10pt
- Text: "Granted" or "Not Granted", caption2
- Color: statusGranted (green) or statusDenied (red)
- Background: Capsule with color at 10% opacity
```

### Version Footer

Centered at the bottom of the settings form:
- `SpinnerRingView(size: 16, revolutionDuration: 8.0, tintColor: .secondary)` at 50% opacity
- "MacParakeet {version}" in caption, tertiary color

### Onboarding

Button to re-run onboarding flow: "Run Onboarding Again..."

---

## Discover (v0.4)

A curated content feed displayed as a sidebar item with a full-page content view. Discover surfaces tips, quotes, affirmations, and sponsored items fetched from a remote JSON feed (`macparakeet.com/api/discover.json`) with local cache fallback and a bundled default.

### Sidebar Card

The Discover item is **not** part of the regular sidebar `List`. It renders as a pinned card below the sidebar list via `.safeAreaInset(edge: .bottom)`. This keeps it visually distinct and always visible regardless of scroll position.

```
┌──────────────────┐
│  Sidebar List     │
│  ────────────     │
│  🎤 Transcribe   │
│  🕒 Dictations   │
│  📖 Vocabulary   │
│  💬 Feedback     │
│  ⚙ Settings      │
│                   │
│  ─── pinned ───   │  ← safeAreaInset(edge: .bottom)
│  ┌──────────────┐ │
│  │ [icon] Title  │ │  ← DiscoverSidebarCard
│  │  (2-line max) │ │
│  └──────────────┘ │
└──────────────────┘

Card anatomy:
- 28×28pt accent-tinted icon square (item.icon or "sparkles" fallback)
- Title: caption.weight(.semibold), 2-line limit
- Background: accentLight when selected, surfaceElevated on hover, clear otherwise
- Accent strokeBorder (0.5pt, 40%) when selected
- Tooltip: item.body
- Rotates through feed items every 30 seconds
```

### Content View

Full-page scrollable feed rendered when the Discover sidebar item is selected. Uses the standard `DesignSystem.Animation.contentSwap` transition.

```
┌──────────────────────────────────────────────────────────┐
│  Discover                                                │
│  ───                                                     │  ← accent underline
│  Intro text...                                           │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Title                                    [copy]   │  │  ← hover-reveal copy button
│  │  Body text...                                      │  │
│  │  — Attribution                                     │  │
│  │  [Verify ↗]                                        │  │  ← HTTPS links only
│  │                               [watermark icon]     │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  │
│  ╎  Share your thoughts                               ╎  │  ← dashed border card
│  ╎  [text editor]                    [Submit Thought]  ╎  │
│  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  │
└──────────────────────────────────────────────────────────┘

Content types (DiscoverContentType):
- tip: bodyLarge font, lightbulb.fill watermark
- quote: serif font (italic), quote.bubble watermark
- affirmation: rounded font, sparkles watermark
- sponsored: bodyLarge font, custom icon, "Learn More" link text

Card features:
- Hover: accent border (20%), elevated shadow
- Copy button: copies title + body + attribution to clipboard
- External links: HTTPS-only, opens in default browser
- Text selection enabled on all text
```

### Thoughts Submission

Users can submit suggestions via a text form at the bottom of the feed. Submissions POST to `macparakeet.com/api/discover-thoughts` with system info (app version, build, macOS version, chip type). Success shows a confirmation banner that auto-dismisses after 4 seconds.

### Components

| Component | Location | Role |
|-----------|----------|------|
| `DiscoverView` | `Views/Discover/` | Full content view (card list + thoughts form) |
| `DiscoverSidebarCard` | `Views/Discover/` | Pinned sidebar preview card |
| `DiscoverViewModel` | `MacParakeetViewModels/` | Feed state, sidebar rotation (30s timer), cache + refresh |
| `DiscoverService` | `MacParakeetCore/Services/` | Feed loading: cache → bundled fallback → empty. Background refresh from remote. |
| `DiscoverThoughtsService` | `MacParakeetCore/Services/` | POST user thoughts to private endpoint |
| `DiscoverItem` / `DiscoverFeed` | `MacParakeetCore/Models/DiscoverContent.swift` | Data model (Codable, versioned feed with `featuredIndex`) |

### Data Flow

```
App launch → DiscoverViewModel.loadCached() → DiscoverService reads disk cache (or bundled fallback)
          → DiscoverViewModel.refreshInBackground() → DiscoverService fetches remote JSON, writes cache
          → Sidebar card rotates through items every 30s
```

---

## Design System

All design tokens are centralized in `DesignSystem.swift` (`Views/Components/DesignSystem.swift`). A debug-only `DesignSystemGalleryView` (`#if DEBUG`) renders every token in one preview canvas — open it from Xcode when auditing for drift.

### Buttons

Buttons use the `parakeetAction(_:)` modifier (in `Views/Components/ParakeetActionStyle.swift`) to express *intent* at the callsite, not styling primitives. This replaced ad-hoc `.buttonStyle(.bordered) + .tint(...)` composition.

| Role | Treatment | Usage |
|------|-----------|-------|
| `.primary` | bordered, brand coral tint | Primary action, non-prominent placement |
| `.primaryProminent` | borderedProminent, brand coral tint | The single highest-priority CTA on a sheet/surface |
| `.secondary` | bordered, system label tint (neutral) | Default action weight; most chrome |
| `.destructive` | bordered, system red tint | Irreversible action, non-prominent |
| `.destructiveProminent` | borderedProminent, system red tint | Highest-priority irreversible action (e.g. "Delete account?") |
| `.subtle` | borderless, secondary label color | Inline links, dense rows |

Hard rules — coral is brand, not chrome:

- One `.primary*` per surface. If you have two equally-weighted CTAs, both are `.secondary`.
- Pair `.destructive*` with `Button(role: .destructive)` so VoiceOver carries the role too.
- Never re-tint the SwiftUI environment with `.tint(coral)` at NSHostingView roots or sheet wrappers — `parakeetAction` is the only place coral cascades from. Cascading tint overrides destructive role styling and erases the hierarchy `parakeetAction` exists to provide.

### Colors

| Token | Value | Usage |
|-------|-------|-------|
| **Brand** | | |
| `accent` | warm coral-orange (`#E86B3B` light / `#FF8A5C` dark) | The single primary CTA per surface, recording state, brand mark |
| `accentLight` | coral 92% / coral 12% | Hover/selection backgrounds tied to accent |
| `accentDark` | deeper coral | Pressed states, accent variants |
| **Surfaces** | | |
| `background` | warm off-white / near-black | App-level background |
| `surface` | white / dark gray | Cards, sheet content |
| `surfaceElevated` | warm cream / lighter dark | Elevated surfaces, hover targets |
| `cardBackground` | white / dark gray | Card body fill |
| `rowHoverBackground` | warm cream / primary 6% | List/row hover state |
| **Text** | | |
| `textPrimary` | near-black / white | Primary copy |
| `textSecondary` | mid-gray | Subtitles, captions |
| `textTertiary` | light-mid gray | Disabled, hints |
| `tintNeutral` | system label color | `.secondary` button tint (coral-free chrome) |
| **Semantic** | | |
| `successGreen` | green | Confirmations, completion |
| `warningAmber` | amber | Cautions, "catching up" |
| `errorRed` | red | Destructive actions, errors |
| **Lines** | | |
| `border` | warm gray / mid-dark gray | Card borders, dividers |
| `divider` | softer warm gray | Inline dividers |
| **Pills & overlays** | | |
| `pillBackground` | black 70% | Dictation/idle pill backing |
| `pillBorder` | white 15% | Pill stroke |
| `recordingRed` | `.red` | Recording indicator dot |
| `meetingPillBackground` / `meetingPillBackgroundHover` / `meetingPillStroke` / `meetingPillStrokeHover` / `meetingPillText` / `meetingPillBadgeBackground` | dark-on-dark variants | Floating meeting recording pill |
| **Sacred geometry** | | |
| `sacredGlow` | green | Bloom highlight on completion animations |
| `sacredStem` | deeper green | Stem/anchor in sacred geometry |
| **Other** | | |
| `playbackTrack` | primary 8% | Audio scrubber track |
| `playbackFill` | `.accentColor` | Audio scrubber fill |
| `youtubeRed` | `.red` | YouTube source badge |
| `speakerColors` | 6-color palette (blue, purple, teal, amber, red, green) | Speaker diarization, accessed via `speakerColor(for:)` |
| `contentBackground` | `NSColor.textBackgroundColor` | Sidebar / list content backing |

### Typography

All families use `.system` with `.rounded` design on headlines for warmth.

| Token | Style | Usage |
|-------|-------|-------|
| `heroTitle` | 28 / bold rounded | Sheet/page hero titles |
| `pageTitle` | 22 / semibold rounded | View-level titles, large summary values |
| `sectionTitle` | 17 / semibold | Section headers |
| `bodyLarge` | 15 | Form fields, prominent body |
| `body` | 14 | Default body, transcript text |
| `bodySmall` | 13 | Subtitles, secondary copy |
| `caption` | 12 | Hints, labels |
| `micro` | 11 | Metadata, fine print |
| `timestamp` | 12 monodigit | Times |
| `duration` | 11 monodigit | Duration pills, file sizes |
| `meetingPillStatus` | 13 semibold | Meeting recording pill status text |
| `meetingPillBadge` | 10 medium monospaced | Meeting pill badge text |
| `meetingPillCheckmark` | 24 semibold | Meeting completion checkmark |
| `dictationOverlayTerminalLabel` | 9.5 medium rounded | "More audio pls" label inside the no-speech terminal pill |

### Spacing

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4pt | Inline element gaps |
| `sm` | 8pt | Related element spacing |
| `md` | 16pt | Standard content padding |
| `lg` | 24pt | Section gaps |
| `xl` | 32pt | Major section separation |
| `xxl` | 48pt | Large visual spacing |
| `hero` | 64pt | Hero/onboarding margins |

### Layout

| Token | Value | Usage |
|-------|-------|-------|
| `sidebarMinWidth` | 200pt | NavigationSplitView sidebar |
| `contentMinWidth` | 500pt | Content pane minimum |
| `windowMinHeight` | 560pt | Main window minimum height |
| `cornerRadius` | 16pt | Standard rounded surfaces |
| `cardCornerRadius` | 14pt | Cards, detail surfaces |
| `rowCornerRadius` | 12pt | List row hover backgrounds |
| `dropZoneCornerRadius` | 20pt | File drop zone |
| `buttonCornerRadius` | 12pt | Custom-drawn buttons |
| `minTouchTarget` | 44pt | HIG-compliant touch target |
| `dropZoneHeight` | 200pt | File drop zone target height |
| `playbackBarHeight` | 6pt | Audio playback progress bar |
| `audioScrubberHeight` | 44pt | Audio scrubber row |
| `videoPlayerMinWidth` | 320pt | Video player split min |
| `videoPlayerIdealRatio` | 0.4 | Video pane share of split |
| `thumbnailCardMinWidth` | 200pt | Library thumbnail card |
| `thumbnailAspectRatio` | 16:9 | Thumbnail card aspect |

### Shadows

| Token | Color · radius · y | Usage |
|-------|-------|-------|
| `cardRest` | black 6% · 4 · 2 | Cards at rest |
| `cardHover` | black 10% · 12 · 6 | Cards on hover |
| `portalLift` | black 12% · 16 · 8 | Floating panels, popovers |
| `meetingPill` | black 28% · 12 · 6 | Meeting recording pill |

### Animation

| Token | Duration | Curve | Usage |
|-------|----------|-------|-------|
| `selectionChange` | 0.15s | `.easeInOut` | List row selection, accent bar |
| `hoverTransition` | 0.12s | `.easeInOut` | Row hover, button hover effects |
| `contentSwap` | 0.2s | `.easeInOut` | Tab transitions, detail pane changes |
| `portalLift` | spring (0.3 / 0.7) | spring | Floating panel entry |
| `meetingPillHover` | 0.15s | `.easeOut` | Meeting pill hover |

**Overlay-specific animations** (in DictationOverlayView / IdlePillView):

| Animation | Duration | Curve | Usage |
|-----------|----------|-------|-------|
| Pill appear | 0.2s | `.easeOut` | Overlay show |
| Pill dismiss | 0.15s | `.easeIn` | Overlay hide |
| State cross-fade | 0.3s | `.easeInOut` | Pill state changes (opacity transition) |
| Waveform | 0.05s | `.linear` | Audio bars (tied to amplitude) |
| Success appear | 0.5s | `.spring(response: 0.4, dampingFraction: 0.7)` | Scale 0.8→1.0 + opacity |
| Button hover | 0.15s | `.easeInOut` | Cancel brighten / stop red glow |

### Sacred Geometry Components

Shared components in `Views/Components/SacredGeometry.swift`:

| Component | Description | Usage |
|-----------|-------------|-------|
| `TriangleShape` | Equilateral triangle inscribed in circle | Building block for merkaba |
| `SpinnerRingView` | Compact merkaba spinner (two counter-rotating triangles, glowing vertices, center nexus) | Dictation processing, transcription processing, settings footer |
| `MeditativeMerkabaView` | Larger, slower merkaba for empty states (softer opacity, primary-tinted) | Drop zone centerpiece, empty states |
| `SacredGeometryDivider` | Thin line with centered diamond ornament (Canvas) | Section dividers in detail views |

**SpinnerRingView parameters:**
- `size`: Default 26pt (overlay), 40pt (transcription), 16pt (settings), 10pt (row pills)
- `revolutionDuration`: Default 3.0s (overlay), 2.0–2.5s (processing), 8.0s (decorative)
- `tintColor`: Default `.white` (overlay), `.accentColor` (main window), `.secondary` (decorative)

**MeditativeMerkabaView parameters:**
- `size`: Default 64pt, typically 40–80pt in app (drop zone 80, empty states 40–72)
- `revolutionDuration`: Default 6.0s, 8.0s for background idle (DictationHistoryView), 12.0s for compact empty states (PromptLibraryView)
- `tintColor`: Default nil (uses `.primary`), `.accentColor` when drawing user attention
- `animate`: Default `true`. Respects `accessibilityReduceMotion` automatically

| Animation | Duration | Curve | Usage |
|-----------|----------|-------|-------|
| Merkaba rotation | configurable | `.linear` (repeating) | Two counter-rotating triangles — the only animated property |

Center and vertex glow are static (constants `centerGlow = 0.32`, `vertexGlow = 0.45`, set to the visual midpoint of the former pulse ranges). Removed in the idle CPU fix: pulsing those opacities alongside `.drawingGroup()` forced per-frame bitmap re-rasterization.

---

## Version Roadmap

### v0.1 (MVP)

All UI listed above is v0.1 except where noted:
- Main window with sidebar
- Dictation history (flat list + bottom bar player)
- Dictation overlay (all 5 states)
- Menu bar with status
- File transcription (drop zone + progress + result)
- Settings: Modes / Engine / AI / System tab shell with search

### v0.2 (AI Refinement)

- Vocabulary sidebar item (processing mode, pipeline guide, custom words & snippets management)
- Custom Words management view (sheet from Vocabulary)
- Text Snippets management view (sheet from Vocabulary)
- Context mode selector in dictation (raw/clean badge on overlay)

### v0.3 (Import & Export, In Progress)

- Feedback sidebar item (form with category cards, community link)
- YouTube URL input field in transcription view
- YouTube download phase text + determinate percent bar in transcription processing UI
- Batch processing queue view
- Export format picker (TXT, SRT, VTT, DOCX, PDF, JSON)
- Export history on transcription detail

### v0.4 (Polish & Launch)

- Speaker labels in transcript display
- Speaker color coding
- Onboarding flow (permissions, first dictation)
- Empty states for all views

---

## Accessibility

- All interactive elements must have accessibility labels
- Keyboard navigation: Tab through all controls, Enter to activate
- VoiceOver: All states announced (recording, processing, success, error)
- Reduced Motion: Disable waveform animation, use static indicators
- High Contrast: Pill uses solid background, no transparency

---

## Platform Conventions

MacParakeet follows standard macOS patterns:

- **Window management:** Standard traffic lights, resizable, remembers position
- **Keyboard shortcuts:** Standard (Cmd+C copy, Cmd+Q quit, Cmd+, settings)
- **Context menus:** Right-click on dictation/transcription rows for actions
- **Drag and drop:** Native file drop with visual feedback
- **Menu bar:** NSStatusItem with NSMenu, standard submenu patterns
- **Settings:** In-app settings view (not a separate Preferences window), matching modern macOS apps

---

*Last updated: 2026-03-14*
