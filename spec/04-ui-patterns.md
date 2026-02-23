# MacParakeet UI Patterns

> Status: **ACTIVE**

## Overview

MacParakeet has four UI surfaces:
1. **Main Window** -- Sidebar + content area for history and transcriptions
2. **Idle Pill** -- Persistent floating indicator, always visible when not dictating
3. **Dictation Overlay** -- Compact pill for recording state
4. **Menu Bar** -- Quick access and status

Design philosophy: **Simple, native, stays out of the way.** No chrome, no clutter. The app should feel like part of macOS, not a web app in a wrapper.

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
│  🕒 Dictations   │                                           │
│  📖 Vocabulary   │  - Transcribe: Drop zone + recent list   │
│  ⚙ Settings      │  - Dictations: History list               │
│                  │  - Vocabulary: Processing mode + manage   │
│                  │  - Settings: Grouped form                 │
│                  │                                           │
└──────────────────┴───────────────────────────────────────────┘
```

Minimum window width: 800pt.

### Sidebar

The sidebar uses NavigationSplitView with four flat items (icon + label):

- **Transcribe** (`waveform`) -- Drop zone and recent transcriptions
- **Dictations** (`clock.arrow.circlepath`) -- Flat history list with bottom bar player
- **Vocabulary** (`book.fill`) -- Processing mode, pipeline guide, custom words & snippets management
- **Settings** (`gearshape`) -- License, dictation prefs, storage, permissions

Column width: `min: 160, ideal: 180, max: 220`. Window minimum width: 800pt.

Content transitions between tabs use `DesignSystem.Animation.contentSwap` (0.2s easeInOut).

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

**4. Success**

```
┌──────────────────────────────────────────┐
│  [✓]  Pasted                            │
└──────────────────────────────────────────┘

- [✓] Checkmark (SF Symbol: checkmark.circle.fill, green tint)
- "Pasted" label
- Auto-dismisses after 1.5 seconds
```

**5. Error Card**

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

## Menu Bar (v0.1)

### Menu Structure

```
┌────────────────────────────────┐
│  MacParakeet                   │
├────────────────────────────────┤
│  Start Dictation    (hotkey)  │
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
- MeditativeMerkabaView(size: 48): 6s revolution idle, 2s revolution on drag-over, tintColor switches to .accentColor on drag
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

## Settings (v0.1 + v0.2)

Settings open in the content area when "Settings" is selected in the sidebar. Tab-based layout using a segmented picker or vertical tab list.

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

### Local Models (v0.2)

```
┌───────────────────────────────────────────────────────────┐
│  LOCAL MODELS                                             │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Parakeet (Speech)   ╭─✓ Ready─╮              [Repair]   │
│  Loaded in memory and ready.                              │
│                                                           │
│  Updated 4:27 PM                            [Check Now]  │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

- Status pill states: `Unknown`, `Checking`, `Ready`, `Not Loaded`, `Not Downloaded`, `Repairing`, `Failed`
- `Repair` retries with bounded backoff (up to 3 attempts) and shows attempt-aware detail text
- `Repair` retries the Parakeet model download/initialization with bounded backoff

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

## Design System

All design tokens are centralized in `DesignSystem.swift` (`Views/Components/DesignSystem.swift`).

### Colors

| Token | Value | Usage |
|-------|-------|-------|
| `pillBackground` | `black 90%` | Dictation overlay / idle pill |
| `pillBorder` | `white 10%` | Pill border stroke |
| `recordingRed` | `.red` | Recording indicator |
| `successGreen` | `.green` | Success states, completed status |
| `warningYellow` | `.yellow` | Warning states |
| `warningOrange` | `.orange` | Warning highlights |
| `statusGranted` | `.green` | Permission granted badges |
| `statusDenied` | `.red` | Permission denied badges |
| `sidebarBackground` | `NSColor.controlBackgroundColor` | Sidebar pane |
| `contentBackground` | `NSColor.textBackgroundColor` | Content pane |
| `rowHoverBackground` | `primary 4%` | List row hover highlight |
| `subtleBorder` | `primary 8%` | Card borders, dividers |
| `playbackTrack` | `primary 8%` | Playback bar track |
| `playbackFill` | `.accentColor` | Playback bar filled portion |

### Typography

| Token | Style | Usage |
|-------|-------|-------|
| `caption` | `.caption` | Hints, small labels |
| `body` | `.body` | Transcript text, descriptions |
| `headline` | `.headline` | Section titles, filenames |
| `title` | `.title2` | View-level titles |
| `largeTitle` | `.largeTitle` | Onboarding headers |
| `timestamp` | `.caption.monospacedDigit()` | Times, monospaced numbers |
| `duration` | `.caption2.monospacedDigit()` | Duration pills, file sizes |
| `sectionHeader` | `.subheadline.weight(.semibold)` | Section headers (Today, Transcript, etc.) |

### Spacing

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4pt | Inline element gaps, row vertical padding |
| `sm` | 8pt | Related element spacing |
| `md` | 12pt | Standard content padding |
| `lg` | 16pt | Section gaps, content padding |
| `xl` | 24pt | Major section separation, drop zone padding |
| `xxl` | 40pt | Large visual spacing |

### Layout

| Token | Value | Usage |
|-------|-------|-------|
| `sidebarMinWidth` | 180pt | NavigationSplitView sidebar |
| `contentMinWidth` | 400pt | Content pane minimum |
| `windowMinHeight` | 500pt | Main window minimum height |
| `cornerRadius` | 12pt | Standard card/drop zone corners |
| `dropZoneHeight` | 200pt | File drop zone target height |
| `playbackBarHeight` | 6pt | Audio playback progress bar |
| `cardCornerRadius` | 10pt | Playback cards, detail cards |
| `rowCornerRadius` | 8pt | List row hover backgrounds |

### Animation

| Token | Duration | Curve | Usage |
|-------|----------|-------|-------|
| `selectionChange` | 0.15s | `.easeInOut` | List row selection, accent bar |
| `hoverTransition` | 0.12s | `.easeInOut` | Row hover, button hover effects |
| `contentSwap` | 0.2s | `.easeInOut` | Tab transitions, detail pane changes |

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
- `size`: Default 64pt, typically 48–56pt for empty states
- `revolutionDuration`: Default 6.0s, 8.0s for background, 2.0s for drag-over acceleration
- `tintColor`: Default nil (uses `.primary`), `.accentColor` on drag-over

| Animation | Duration | Curve | Usage |
|-----------|----------|-------|-------|
| Merkaba rotation | configurable | `.linear` (repeating) | Two counter-rotating triangles |
| Merkaba vertex pulse | 1.0–1.6s | `.easeInOut` (repeating) | Vertex dot glow |
| Merkaba center pulse | 1.4–2.0s | `.easeInOut` (repeating) | Center nexus glow |

---

## Version Roadmap

### v0.1 (MVP)

All UI listed above is v0.1 except where noted:
- Main window with sidebar
- Dictation history (flat list + bottom bar player)
- Dictation overlay (all 5 states)
- Menu bar with status
- File transcription (drop zone + progress + result)
- Settings: General, Dictation, Storage, About

### v0.2 (AI Refinement)

- Vocabulary sidebar item (processing mode, pipeline guide, custom words & snippets management)
- Custom Words management view (sheet from Vocabulary)
- Text Snippets management view (sheet from Vocabulary)
- Context mode selector in dictation (raw/clean badge on overlay)

### v0.3 (Import & Export, In Progress)

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

*Last updated: 2026-02-11*
