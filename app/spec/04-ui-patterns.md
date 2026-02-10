# MacParakeet UI Patterns

> Status: **ACTIVE**

## Overview

MacParakeet has three UI surfaces:
1. **Main Window** -- Sidebar + content area for history and transcriptions
2. **Dictation Overlay** -- Compact pill for recording state
3. **Menu Bar** -- Quick access and status

Design philosophy: **Simple, native, stays out of the way.** No chrome, no clutter. The app should feel like part of macOS, not a web app in a wrapper.

---

## Main Window (v0.1)

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  MacParakeet                                     ─ □ ✕  │
├──────────────────┬──────────────────────────────────────┤
│  Sidebar         │  Content                             │
│  ────────────    │  ──────────────────────────────────  │
│                  │                                      │
│  DICTATIONS (32) │  [Depends on sidebar selection]      │
│  ──────────────  │                                      │
│  ▸ Today         │  - Dictation history list            │
│  ▸ Yesterday     │  - Transcription detail              │
│  ▸ This Week     │  - File drop zone                   │
│  ▸ Older         │  - Settings panes                   │
│                  │                                      │
│  TRANSCRIPTIONS  │                                      │
│  ──────────────  │                                      │
│  (5)             │                                      │
│                  │                                      │
│  ──────────────  │                                      │
│  ⚙ Settings      │                                      │
│                  │                                      │
└──────────────────┴──────────────────────────────────────┘
```

### Sidebar

The sidebar uses NavigationSplitView with three sections:

**Dictations section** -- Shows count badge. Selecting opens the dictation history list in the content area. Date-grouped sublists (Today, Yesterday, This Week, Older) expand inline.

**Transcriptions section** -- Shows count badge. Selecting opens the transcription list. Each row shows filename, date, duration, status badge.

**Settings** -- Fixed at bottom. Opens settings panes in content area.

### Sidebar Item Styles

```
┌──────────────────────────────────────┐
│  DICTATIONS                    (32)  │   ← Uppercase label, count badge
│  ────────────────────────────────    │
│  ▸ Today                       (5)  │   ← Expandable date group
│  ▸ Yesterday                   (8)  │
│  ▸ This Week                  (12)  │
│  ▸ Older                       (7)  │
└──────────────────────────────────────┘
```

---

## Dictation History (v0.1)

### List View

Date-grouped list of dictation records. Each row shows essential info with hover actions.

```
┌───────────────────────────────────────────────────────────┐
│  🔍 Search dictations...                                  │
├───────────────────────────────────────────────────────────┤
│                                                           │
│  TODAY                                                    │
│  ─────────────────────────────────────────────────────    │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  2:34 PM  ·  12s  ·  Slack                         │  │
│  │  "Can we move the standup to 3pm tomorrow? I have   │  │
│  │  a conflict with the design review..."              │  │
│  │                                          [▶] [⎘] [⌫]│  │  ← Hover actions
│  └─────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  11:02 AM  ·  8s  ·  Notes                         │  │
│  │  "Remember to update the API documentation for the  │  │
│  │  new endpoints before Friday."                      │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  YESTERDAY                                                │
│  ─────────────────────────────────────────────────────    │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  5:15 PM  ·  23s  ·  Mail                          │  │
│  │  "Hi Sarah, following up on our conversation about  │  │
│  │  the Q3 budget allocation..."                       │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Row Anatomy

```
┌─────────────────────────────────────────────────────────┐
│  {time}  ·  {duration}  ·  {pasted_to_app}             │
│  "{transcript preview, 2 lines max, truncated...}"     │
│                                                [▶] [⎘] [⌫] │
└─────────────────────────────────────────────────────────┘

- Time: 12-hour format (2:34 PM)
- Duration: Compact (8s, 1m 23s)
- App: Display name of pasted_to_app (Slack, Notes, Mail)
- Transcript: clean_transcript if available, else raw_transcript
- Hover actions:
  - [▶] Play audio (if retained)
  - [⎘] Copy transcript to clipboard
  - [⌫] Delete with confirmation
```

### Dictation Detail (v0.1)

Clicking a dictation row expands or navigates to a detail view.

```
┌───────────────────────────────────────────────────────────┐
│  ← Back                                                   │
│                                                           │
│  February 8, 2026  ·  2:34 PM  ·  12 seconds            │
│  Pasted to: Slack                                        │
│  Mode: Clean                                             │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  CLEAN TRANSCRIPT                                        │
│  Can we move the standup to 3pm tomorrow? I have a       │
│  conflict with the design review, so it would be great   │
│  if we could shift it by an hour.                        │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  RAW TRANSCRIPT                                  [Show ▾] │
│  can we move the standup to 3 pm tomorrow i have a       │
│  conflict with the design review so it would be great    │
│  if we could shift it by an hour                         │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  [▶ Play Audio]          [Copy Clean]    [Delete]        │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

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
- Waveform: 12 bars, animating to audio amplitude, white
- Timer: Recording duration (e.g., "0:03"), updates every second
- [■] Stop button (SF Symbol: stop.circle.fill, white)
- Tooltip on [✕]: "Cancel (Esc)"
- Tooltip on [■]: "Stop Recording"
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
│  [spinner]  Processing...  [●]          │
└──────────────────────────────────────────┘

- [spinner]: Indeterminate circular progress (small)
- "Processing..." label
- [●]: Red dot indicator (recording stopped, STT in progress)
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

**5. Error**

```
┌──────────────────────────────────────────┐
│  [⚠]  Transcription failed              │
└──────────────────────────────────────────┘

- [⚠] Warning triangle (SF Symbol: exclamationmark.triangle.fill, yellow tint)
- Error message, truncated to one line
- Auto-dismisses after 3 seconds
- Click to open main window with error details
```

### Hover Tooltips

Tooltips use AppKit `NSTrackingArea` with `.activeAlways` because the pill is a non-activating `NSPanel`. Standard SwiftUI `.help()` modifiers and `.onHover` do not work on non-activating panels.

Implementation pattern:
- `MouseTrackingOverlay` NSView layered on top of the pill
- `hitTest` returns `nil` for click passthrough
- `NSTrackingArea` with `.mouseEnteredAndExited` + `.activeAlways`
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
│  Start Dictation       Fn+Fn  │
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

```
┌───────────────────────────────────────────────────────────┐
│                                                           │
│                                                           │
│              ┌───────────────────────────┐                │
│              │                           │                │
│              │     ↓                     │                │
│              │                           │                │
│              │   Drop audio or video     │                │
│              │   file here to transcribe │                │
│              │                           │                │
│              │    or click to browse      │                │
│              │                           │                │
│              └───────────────────────────┘                │
│                                                           │
│              Supported: MP3, WAV, M4A, MP4, MOV...       │
│                                                           │
│                     [Browse Files]                        │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Dashed border on the drop zone, 2px, secondary color
- Drag-hover: border turns accent blue, background tints blue at 5% opacity
- Down arrow icon: SF Symbol arrow.down.doc
```

### Processing State

```
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  interview.mp3                                           │
│  24.3 MB  ·  45:12 duration                              │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  ████████████████░░░░░░░░░░░░░░░░░░░  42%          │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Transcribing... (estimated 8s remaining)                │
│                                                           │
│                     [Cancel]                              │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Progress bar: accent blue fill, rounded corners
- Percentage and ETA update live
- Cancel stops the Parakeet daemon request
```

### Result Display

```
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  interview.mp3                                 [✓ Done]  │
│  24.3 MB  ·  45:12  ·  Transcribed in 8.2s              │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  TRANSCRIPT                                              │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Welcome everyone to today's product review. We     │  │
│  │  have three items on the agenda. First, let's look  │  │
│  │  at the Q3 metrics dashboard. Sarah, could you      │  │
│  │  walk us through the highlights?                    │  │
│  │                                                     │  │
│  │  Sure. So the main thing to note is that our DAU    │  │
│  │  increased by 23% compared to last quarter...       │  │
│  │                                                     │  │
│  │  [scrollable text view]                             │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  WORD TIMESTAMPS                                 [Show ▾] │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  [Copy Text]    [Export .txt]    [Transcribe Another]    │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Transcript in a scrollable, selectable text view
- Word timestamps collapsible (hidden by default)
- Action buttons at bottom:
  - Copy Text: copies to clipboard, button shows "Copied!" briefly
  - Export .txt: save dialog
  - Transcribe Another: returns to drop zone
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
│  Hotkey                       [Fn+Fn        ▾]          │
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

### Processing (v0.2)

```
┌───────────────────────────────────────────────────────────┐
│  PROCESSING                                               │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Mode                         [● Clean]                  │
│                               [  Raw]                    │
│  (Clean: remove fillers, fix punctuation. Raw: exact.)   │
│                                                           │
│  Remove filler words          [toggle: ON]               │
│  ("um", "uh", "like", "you know")                        │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  CUSTOM WORDS                              [Manage ▸]    │
│  Vocabulary corrections applied during processing.       │
│  12 words configured                                     │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  TEXT SNIPPETS                              [Manage ▸]   │
│  Type a trigger, get an expansion.                       │
│  5 snippets configured                                   │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Custom Words Management (v0.2)

```
┌───────────────────────────────────────────────────────────┐
│  ← Processing    CUSTOM WORDS                            │
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
│  │  Trigger      Expansion                Uses  On     │  │
│  │  ─────────────────────────────────────────────────  │  │
│  │  addr1        123 Main St, Suite 4...  42    [✓]    │  │
│  │  sig1         Best regards, Dan Moon   18    [✓]    │  │
│  │  zoom1        https://zoom.us/j/123... 7     [✓]    │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Snippets expand automatically when the trigger text     │
│  appears in your dictation.                              │
│                                                           │
└───────────────────────────────────────────────────────────┘

- Expansion column truncated with ellipsis, full text on hover/click
- "Uses" column shows use_count, sortable
- Same enable/disable and delete patterns as Custom Words
```

### Storage (v0.1)

```
┌───────────────────────────────────────────────────────────┐
│  STORAGE                                                  │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  Audio retention              [● Keep all]               │
│                               [  Keep 7 days]            │
│                               [  Never keep]             │
│  (Controls whether dictation audio is saved to disk)     │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  STATISTICS                                              │
│  Total dictations:            32                         │
│  Total transcriptions:        5                          │
│  Audio storage used:          48.2 MB                    │
│  Database size:               1.2 MB                     │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│  [Clear All Dictation History]                           │
│  [Clear All Transcription History]                       │
│  (These actions cannot be undone)                        │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### About (v0.1)

```
┌───────────────────────────────────────────────────────────┐
│  ABOUT                                                    │
│  ─────────────────────────────────────────────────────    │
│                                                           │
│                     [Parrot Icon]                         │
│                   MacParakeet v0.1                        │
│                   Build 1 (2026.02)                       │
│                                                           │
│  The fastest, most private transcription app for Mac.    │
│                                                           │
│  Parakeet TDT 0.6B-v3  ·  100% local  ·  zero cloud    │
│                                                           │
│  [Website]    [Privacy Policy]    [Acknowledgments]      │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

---

## Design System

### Colors

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| `background` | `.white` | `Color(.windowBackgroundColor)` | Main window background |
| `secondaryBackground` | `.gray.opacity(0.05)` | `.gray.opacity(0.1)` | Cards, grouped sections |
| `pillBackground` | -- | `#1C1C1E` at 95% opacity | Dictation overlay |
| `accent` | `.accentColor` | `.accentColor` | Buttons, links, progress |
| `textPrimary` | `.primary` | `.primary` | Body text |
| `textSecondary` | `.secondary` | `.secondary` | Metadata, labels |
| `destructive` | `.red` | `.red` | Delete actions |
| `success` | `.green` | `.green` | Success states |
| `warning` | `.yellow` | `.yellow` | Error/warning states |

### Typography

| Token | Style | Usage |
|-------|-------|-------|
| `titleLarge` | `.title2.bold()` | View titles |
| `titleMedium` | `.headline` | Section headers |
| `sectionLabel` | `.caption.uppercaseSmallCaps()` | Sidebar section labels (DICTATIONS, TRANSCRIPTIONS) |
| `body` | `.body` | Transcript text, descriptions |
| `bodySecondary` | `.body.foregroundStyle(.secondary)` | Metadata, timestamps |
| `caption` | `.caption` | Hints, small labels |
| `mono` | `.body.monospaced()` | Timestamps, technical values |

### Spacing

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4pt | Inline element gaps |
| `sm` | 8pt | Related element spacing |
| `md` | 12pt | Standard content padding |
| `lg` | 16pt | Section gaps |
| `xl` | 24pt | Major section separation |
| `xxl` | 32pt | View-level padding |

### Button Styles

**Primary Action**
```swift
.buttonStyle(.borderedProminent)
// Used for: Copy, Export, Browse Files
```

**Secondary Action**
```swift
.buttonStyle(.bordered)
// Used for: Cancel, Transcribe Another
```

**Destructive Action**
```swift
.buttonStyle(.bordered)
.tint(.red)
// Used for: Delete, Clear All
```

**Toolbar Icon**
```swift
// Custom ToolbarIconButtonStyle
// 28x28pt hit target, subtle hover background
// Used for: hover actions on list rows (play, copy, delete)
```

### Dimensions

| Token | Value | Usage |
|-------|-------|-------|
| `sidebarWidth` | 200pt (min), 240pt (ideal) | NavigationSplitView sidebar |
| `pillHeight` | 36pt | Dictation overlay |
| `pillCornerRadius` | 18pt | Dictation overlay |
| `pillBottomOffset` | 48pt | Distance from screen bottom |
| `iconSize` | 16pt | Standard SF Symbol size |
| `iconSizeLarge` | 20pt | Emphasized SF Symbols |
| `rowMinHeight` | 56pt | List row minimum height |
| `dropZoneMinHeight` | 300pt | File drop zone |

### Animation

| Animation | Duration | Curve | Usage |
|-----------|----------|-------|-------|
| Pill appear | 0.2s | `.easeOut` | Overlay show |
| Pill dismiss | 0.15s | `.easeIn` | Overlay hide |
| State transition | 0.2s | `.easeInOut` | Pill state changes |
| Waveform | 0.05s | `.linear` | Audio bars (tied to amplitude) |
| Success checkmark | 0.3s | `.spring(dampingFraction: 0.6)` | Checkmark pop |
| Progress bar | 0.1s | `.linear` | Transcription progress |

---

## Version Roadmap

### v0.1 (MVP)

All UI listed above is v0.1 except where noted:
- Main window with sidebar
- Dictation history (list + detail)
- Dictation overlay (all 5 states)
- Menu bar with status
- File transcription (drop zone + progress + result)
- Settings: General, Dictation, Storage, About

### v0.2 (AI Refinement)

- Settings: Processing pane (mode picker, filler removal)
- Custom Words management view
- Text Snippets management view
- Context mode selector in dictation (raw/clean badge on overlay)

### v0.3 (Import & Export)

- YouTube URL input field in transcription view
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

*Last updated: 2026-02-08*
