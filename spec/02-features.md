# MacParakeet: Features Specification

> Status: **ACTIVE** - Authoritative, current
> What we're building, in what order, and why.

**North Star:** The fastest, most private transcription app for Mac.

See [00-vision.md](./00-vision.md) for positioning and market context.

---

## Feature Tiers

```
┌─────────────────────────────────────────────────────────────────┐
│  v0.1 - "Core" (MVP)                                            │
│  "Dictation + Transcription — fast, private, done"              │
├─────────────────────────────────────────────────────────────────┤
│  • System-wide dictation (Fn key: double-tap + hold-to-talk)    │
│  • Persistent idle pill (always-visible click-to-dictate pill)  │
│  • File transcription (drag-and-drop audio/video)               │
│  • Menu bar app with main window                                │
│  • Dictation history (date-grouped, searchable, audio playback) │
│  • Settings (hotkey, stop mode, storage)                        │
│  • Basic export (plain text, clipboard)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  v0.2 - "Clean Pipeline"                                          │
│  "Clean text automatically with deterministic processing"       │
├─────────────────────────────────────────────────────────────────┤
│  • Clean text pipeline (deterministic: fillers, words, snippets) │
│  • Custom words & snippets management UI                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  v0.3 - "YouTube & Export"                                        │
│  "Import from anywhere, export anything"                        │
├─────────────────────────────────────────────────────────────────┤
│  • YouTube URL transcription (yt-dlp + Parakeet)                │
│  • Full export (.txt, .srt, .vtt, .docx, .pdf, .json)          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  v0.4 - "Polish & Launch"                                        │
│  "Ship it — diarization, non-blocking progress, distribution"   │
├─────────────────────────────────────────────────────────────────┤
│  • Speaker diarization (auto-detect, label, name)               │
│  • Non-blocking transcription progress (bottom bar UX)          │
│  • Direct distribution (notarized DMG, Sparkle auto-updates)    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  v0.5 - "Data, UI & Prompts"                                     │
│  "Data maturity, video player, prompt library, open source"    │
├─────────────────────────────────────────────────────────────────┤
│  • Private dictation, multi-conversation chat, favorites        │
│  • YouTube metadata, FTS5 cleanup, GPL-3.0 open source          │
│  • Video player (HLS streaming, local playback), split-pane     │
│  • Library grid with thumbnails, filters, search                 │
│  • Prompt Library (community + custom), multi-summary tabs       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  v0.6 - "Meeting Recording"                                      │
│  "Record meetings locally, transcribe with Parakeet"             │
├─────────────────────────────────────────────────────────────────┤
│  • Meeting recording (system audio + mic via Core Audio Taps)    │
│  • Concurrent with dictation (ADR-015) — dictate during meetings │
│  • Recording pill UI (floating timer + stop button)              │
│  • Results in transcription library (sourceType: meeting)        │
│  • Prompt library + multi-summary work automatically             │
│  • Screen Recording permission flow                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Future - "Platform"                                             │
├─────────────────────────────────────────────────────────────────┤
│  • iOS companion                                                 │
│  • Translation                                                     │
│  • API / Shortcuts integration                                   │
│  • Team vocabulary sharing                                       │
│  • Vibe coding integrations (Cursor, VS Code)                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## v0.1 Features (Core MVP)

### F0: First-Run Onboarding

**What:** A premium first-run setup window that guides users through permissions, hotkey basics, and local model setup so core dictation and file transcription are ready immediately.

**Goals:**
- Reduce first-run friction (no mysterious permission failures).
- Teach the core interaction model in under 60 seconds.
- Download and warm up the local speech model (Parakeet STT) on first run.

**Flow:**
1. Welcome
2. Microphone permission
3. Accessibility permission
4. Hotkey instructions (configurable trigger + Esc)
5. Speech model setup (Parakeet, retry required)
6. Ready

**Model failure recovery:**
- Before warm-up, onboarding runs lightweight preflight checks (runtime support + first-setup disk/network readiness).
- If local model setup fails, onboarding shows explicit recovery tips based on failure type.
- Users get direct CTAs: `Retry` and `Open Settings` (to `Settings > Local Models > Repair`).

**Dismiss behavior:**
- Closing onboarding before completion shows a confirmation prompt.
- If dismissed anyway, onboarding is re-opened on next app activation until setup is completed.

### F1: System-Wide Dictation

**What:** Press a hotkey anywhere on macOS, speak, and polished text appears in the active app. The core feature that makes MacParakeet worth using every day.

**Activation — Configurable Hotkey:**

The hotkey (default: `Fn`, configurable via a "record a shortcut" UI in Settings) serves as the universal activation trigger with two coexisting modes. Supports three trigger kinds: bare modifiers (Fn, Control, etc.), standalone keys (F5, Tab, etc.), and chord combos (modifier+key like Cmd+9 or Ctrl+Shift+D). See ADR-009 for full details.

| Mode | Gesture | Behavior |
|------|---------|----------|
| **Double-tap** | Tap hotkey twice within 400ms | Persistent recording. Press hotkey again to stop. |
| **Press-and-hold** | Hold hotkey for > 400ms | Hold-to-talk. Release auto-stops and pastes. |

Both modes coexist with no configuration required. The 400ms threshold distinguishes taps from holds.

**Implementation:**
- `CGEvent` tap for system-wide key event interception
- `HotkeyTrigger` struct with `.modifier` / `.keyCode` / `.chord` kind discriminator (see ADR-009)
- Modifier triggers: `flagsChanged` events with `CGEventFlags` mask, bare-tap filtering
- KeyCode triggers: `keyDown`/`keyUp` events with event swallowing, edge detection via `triggerKeyIsPressed` boolean
- Chord triggers: require ALL modifier flags present on `keyDown` of the trigger key. Release-any-part behavior: releasing either the trigger key or any required modifier stops dictation. `chordModifierReleased` flag prevents double-fire when modifier is released while trigger key is still held.
- Edge detection: only fire on actual transitions of the target key state
- Bare-tap filtering (modifiers only): if a regular key is pressed while the modifier is held (e.g., Ctrl+C), the release is not counted as a tap — prevents keyboard shortcuts from triggering dictation
- Gesture interruption: if a non-Escape key is pressed during `waitingForSecondTap`, the state machine resets — prevents double-tap detection across typing
- Chord validation: Escape blocked for all kinds. Chords containing Command warn about system shortcut conflicts (Cmd+Tab, Cmd+Space, Cmd+Q/W/H/M). Fn is bare-modifier-only — not allowed in chords.
- On key-down: schedule a 400ms `DispatchWorkItem`. If a second tap arrives before it fires, enter double-tap (persistent mode). If the timer fires with the key still held, enter hold-mode and begin recording.
- On key-up: if hold timer still pending, cancel it (was a quick tap). If recording in hold-mode, auto-stop and process.
- Escape is permanently reserved for cancel-dictation and cannot be assigned as hotkey
- Requires Accessibility permission (prompted on first activation).
- Stop orchestration is state-driven (proceed, defer-until-recording, reject-not-recording) to avoid first-start races when stop arrives before `startRecording()` fully transitions to `.recording`.
- Duplicate stop requests are ignored while a stop/cancel/undo overlay action is already in-flight (idempotent stop behavior).

**Recording flow:**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User activates recording:                                     │
│    - Double-tap Fn (persistent mode), OR                         │
│    - Hold Fn > 400ms (hold-to-talk mode)                        │
├─────────────────────────────────────────────────────────────────┤
│ 2. Overlay appears (bottom-center pill)                          │
│    - Recording indicator (waveform animation)                    │
│    - Icon-only controls (cancel, stop)                           │
├─────────────────────────────────────────────────────────────────┤
│ 3. User speaks                                                   │
│    - Audio captured via AVAudioEngine (mic input)                │
│    - Real-time waveform visualization in overlay                 │
├─────────────────────────────────────────────────────────────────┤
│ 4. User stops recording:                                         │
│    - Release Fn (hold-to-talk auto-stop), OR                     │
│    - Press Fn again (persistent mode), OR                        │
│    - Press Escape (soft cancel with undo window), OR             │
│    - Silence auto-stop (2s default, if enabled in settings)      │
│    - If stop is requested while startup is in-flight, stop is     │
│      deferred and executed immediately once recording is active    │
├─────────────────────────────────────────────────────────────────┤
│ 5. Processing                                                    │
│    - Overlay transitions to processing state                     │
│    - Audio buffer → temp WAV → FluidAudio STT (CoreML/ANE)       │
│    - Parakeet returns transcript (155x realtime, ~2.5% WER)      │
│    - (v0.2) Raw → clean pipeline → polished text                 │
├─────────────────────────────────────────────────────────────────┤
│ 6. Result                                                        │
│    - Auto-paste into target app (NSPasteboard + simulated Cmd+V) │
│    - Previous clipboard contents saved and restored after paste  │
│    - Save to dictation history (database)                        │
│    - Save audio file (if storage enabled)                        │
│    - Overlay shows success checkmark, auto-dismisses             │
└─────────────────────────────────────────────────────────────────┘
```

**Text insertion:**

```swift
// 1. Save current clipboard
let savedContents = NSPasteboard.general.pasteboardItems

// 2. Set transcript
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(transcript, forType: .string)

// 3. Simulate Cmd+V
let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
keyDown?.flags = .maskCommand
keyDown?.post(tap: .cghidEventTap)

let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
keyUp?.flags = .maskCommand
keyUp?.post(tap: .cghidEventTap)

// 4. Restore clipboard after short delay
DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
    NSPasteboard.general.clearContents()
    // Restore savedContents
}
```

**Soft cancel (Esc):**
- Pressing Escape during recording triggers soft cancel
- 5-second undo window: overlay shows countdown ring + Undo button
- During undo window, Fn key is blocked (prevents accidental re-activation)
- Audio buffer preserved until countdown expires or user confirms discard
- Tapping the countdown ring dismisses immediately (confirms discard)
- Tapping Undo resumes processing (transcribe + paste)

**Dictation overlay:**

Compact dark pill, icon-only controls, positioned at bottom-center of screen (40px above visible frame bottom). Inspired by WisprFlow's Apple-native aesthetic.

```
         ┌───────────────────────────────┐
         │  Stop & paste (Fn)            │  ← Hover tooltip (dark capsule)
         └───────────────────────────────┘
         ┌─────────────────────────────┐
         │  [X] ∿∿∿∿∿∿∿∿∿∿∿∿  [■]    │  ← Recording pill
         └─────────────────────────────┘
                  bottom-center, 40px above screen edge
```

**Pill dimensions:** ~150-180px wide, 36px tall, capsule shape (full corner radius)
**Background:** Solid dark (`Color.black.opacity(0.9)`)
**Position:** Bottom-center of screen, 40px above visible frame bottom
**Controls:** Icon buttons only, no text labels
**Border:** Subtle white stroke (`Color.white.opacity(0.1)`, 1px)

**Hover tooltips:** AppKit-level `MouseTrackingOverlay` using `NSTrackingArea` with `.activeAlways` flag (required because the overlay is a non-activating `NSPanel`). Sits on top of the hosting view with `hitTest -> nil` for click passthrough. Zone-based detection by relative X position. Tooltips render as dark capsule positioned above the pill with 13pt medium white text. Keyboard shortcuts highlighted in light blue.

| Zone | Tooltip | Shortcut Highlight |
|------|---------|-------------------|
| X button (left) | Cancel | `Esc` in blue |
| Stop button (right) | Stop & paste | Trigger key name in blue |
| Countdown ring | Dismiss | -- |
| Undo button | Undo | -- |

Space is always reserved for the tooltip (opacity toggle, not conditional rendering) to prevent panel resize jitter on hover transitions.

**Overlay states:**

1. **Recording** -- `[X cancel] [waveform 12 bars] [stop]` (~150px)
   - X button: white icon on dark circle (0.2 opacity background), triggers soft cancel (Esc)
   - Waveform: 12 white bars, 3px wide, max 20px tall, center-peaking wave pattern, updates in real-time from audio level
   - Stop button: white square (10x10, cornerRadius 3) inside red circle, triggers stop (Fn)
   - Recording timer displayed (e.g., "0:03") -- hover tooltips provide additional guidance

2. **Cancelled** -- `[countdown ring] [Undo button]` (~140px)
   - Countdown ring: circular progress indicator (accent color, depletes over 5 seconds) with remaining seconds number in center
   - Tap ring to dismiss immediately (confirms discard)
   - Undo button: "Undo" text on subtle white background (0.15 opacity), rounded rect
   - 5-second countdown, Fn key blocked during cancel window
   - Audio buffer preserved until confirmed discard

3. **Processing** -- `[spinner] [red dot]` (~100px)
   - Small ProgressView (tinted white, scale 0.6) + red dot indicator (7px)

4. **Success** -- `[checkmark]` (~70px)
   - Green checkmark, brief flash (500ms), auto-dismiss

5. **Error** -- `[warning icon] [truncated message]` (~180px)
   - Warning triangle icon + error message (max 35 characters, truncated)
   - "Couldn't hear you -- check mic" shown when no audio detected
   - Auto-dismiss after 3 seconds, tap or Esc to dismiss immediately

**Accessibility permission flow:**

```
┌─────────────────────────────────────────────────────────────┐
│ Enable Dictation                                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ MacParakeet needs Accessibility permission to:               │
│                                                              │
│   • Detect the hotkey when MacParakeet isn't focused         │
│   • Insert text into other applications                      │
│                                                              │
│ Your dictations stay on your device and are never sent       │
│ to external servers.                                         │
│                                                              │
│           [Open System Settings]  [Cancel]                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Acceptance criteria:**
- [x] Double-tap hotkey activates persistent recording from any app
- [x] Hold hotkey (> 400ms) activates hold-mode, release auto-stops and pastes
- [x] Hotkey trigger configurable to any single key (modifiers, function keys, navigation keys, etc.) via record-a-shortcut UI
- [x] Overlay appears at bottom-center with waveform animation
- [x] Hover tooltips display correctly on non-activating panel
- [ ] Parakeet transcribes with <500ms end-to-end latency for short dictations
- [x] Text auto-pastes into active app, clipboard restored afterward
- [x] Esc triggers soft cancel with 5-second undo window
- [x] Undo during cancel window resumes processing
- [x] Accessibility permission prompted gracefully on first use
- [x] Audio saved to disk (if storage enabled in settings)

---

### F2: File Transcription

**What:** Drag-and-drop audio or video files onto the app window or menu bar icon for fast, local transcription with word-level timestamps.

**Supported formats:**

| Type | Formats |
|------|---------|
| Audio | MP3, WAV, M4A, FLAC, OGG, OPUS |
| Video | MP4, MOV, MKV, WebM, AVI |

**Transcription flow:**

```
User drops file(s) onto window or menu bar icon
       │
       ▼
┌──────────────────┐
│  AudioProcessor  │ ── Detect format, convert to 16kHz mono WAV
│                  │    (FFmpeg for video → audio extraction)
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  STT Scheduler   │ ── Submit file transcription job to shared STT stack
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  FluidAudio STT  │ ── Transcribe with word-level timestamps
│                  │    155x realtime on Apple Silicon (ANE)
└────────┬─────────┘
         │
         ▼
Display in scrollable result view
  • Full transcript with timestamps
  • Word-level confidence scores
  • Copy to clipboard
  • Export options
```

**File transcription UI:**

```
┌─────────────────────────────────────────────────────┐
│  MacParakeet                                         │
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌─────────────────────────────────────────────┐    │
│  │                                              │    │
│  │       Drop audio or video file here          │    │
│  │           or click to browse                 │    │
│  │                                              │    │
│  │     MP3, WAV, M4A, FLAC, MP4, MOV, MKV      │    │
│  │                                              │    │
│  │              [Browse Files]                  │    │
│  │                                              │    │
│  └─────────────────────────────────────────────┘    │
│                                                      │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 67%         │ ← Progress bar
│  Transcribing interview.mp3 (4:23 remaining)         │
│                                                      │
└─────────────────────────────────────────────────────┘
```

**Result view (after transcription):**

```
┌─────────────────────────────────────────────────────┐
│  interview.mp3                    45:23  [Copy All] │
├─────────────────────────────────────────────────────┤
│                                                      │
│  [00:00] The advancement in cloud native technology  │
│  has been remarkable over the past year.             │
│                                                      │
│  [00:12] Kubernetes 2.0 introduces a completely      │
│  new scheduling architecture that we've been...      │
│                                                      │
│  [00:30] One of the key decisions we made early      │
│  on was to separate the control plane from...        │
│                                                      │
│  (scrollable)                                        │
│                                                      │
├─────────────────────────────────────────────────────┤
│  [Export .txt]  [Export .srt]  [Copy]                │
└─────────────────────────────────────────────────────┘
```

**Technical notes:**
- FFmpeg (bundled) for format conversion to 16kHz mono WAV
- Parakeet expects 16kHz mono WAV input
- Max file duration: configurable, default 4 hours
- Large files show progress bar with estimated time remaining
- Word-level timestamps preserved for subtitle export (v0.3)

**Acceptance criteria:**
- [x] Drag-and-drop file onto app window triggers transcription
- [x] Drag-and-drop onto menu bar icon triggers transcription
- [x] Click "Browse Files" opens file picker
- [x] Progress indicator shows during transcription with estimated time
- [x] Result displayed in scrollable text view with timestamps
- [x] Copy to clipboard button works
- [x] All supported audio formats transcribe correctly
- [x] All supported video formats extract audio and transcribe
- [x] Word-level timestamps stored for later export use
- [x] Handles corrupt/empty files gracefully (error message, not crash)

---

### F3: Basic UI

**What:** A native macOS app that lives in the menu bar with an optional main window. Simple, fast, and always accessible.

**Menu bar presence:**

The app lives primarily in the menu bar. Click the icon for quick actions, or open the full window for history and settings.

```
┌────────────────────────────┐
│ 🎙 MacParakeet              │
├────────────────────────────┤
│ Start Dictation        Fn   │
│ Open Window            ⌘O   │
├────────────────────────────┤
│ Recent Files            ►   │
├────────────────────────────┤
│ Settings...            ⌘,   │
│ Quit                   ⌘Q   │
└────────────────────────────┘
```

- Menu bar icon always visible, shows state: idle, recording (animated), processing
- Click icon opens dropdown menu
- "Start Dictation" activates recording (same as Fn double-tap)
- "Recent Files" shows last 5 transcriptions with one-click copy
- Dynamic dock behavior: dock icon appears when main window is open, hidden otherwise

**Main window:**

```
┌─────────────────────────────────────────────────────────────────┐
│  Sidebar          │ Main Content                                 │
│  ─────────────    │ ──────────────────────────────────────────── │
│                   │                                               │
│  Transcribe       │  Drop zone (when "Transcribe" selected)      │
│  ▸ Dictations     │  OR                                          │
│  Settings         │  Dictation history (when "Dictations")       │
│                   │  OR                                          │
│                   │  Settings view (when "Settings")             │
│                   │                                               │
└─────────────────────────────────────────────────────────────────┘
```

**Sidebar sections:**
- **Transcribe** -- Opens the drop zone + recent transcriptions
- **Dictations** -- Full dictation history (date-grouped, searchable)
- **Vocabulary** -- Processing mode, pipeline guide, custom words & snippets management
- **Settings** -- License, dictation prefs, storage, permissions

**Acceptance criteria:**
- [x] App launches to menu bar only (no dock icon initially)
- [x] Dock icon appears when main window opens, hides when closed
- [x] Menu bar icon reflects current state (idle, recording, processing)
- [x] Menu bar dropdown shows quick actions
- [x] Main window opens on demand (menu bar click or Cmd+O)
- [x] Sidebar navigation between Transcribe, Dictations, Vocabulary, Settings

---

### F4: Dictation History

**What:** Searchable, date-grouped flat list of all dictations with hover actions, bottom bar audio player, and copy/delete support.

**History view (flat list + bottom bar player):**

```
┌─────────────────────────────────────────────────────────────────┐
│ Sidebar          │ Dictation History                             │
│ ──────────       │ ─────────────────────────────────────────── │
│                  │                                               │
│ Transcribe       │ [Search dictations...]                       │
│ ▸ Dictations     │                                               │
│ Settings         │ TODAY                                         │
│                  │ 10:45 AM  I need to email Sarah about the    │
│                  │   00:05   budget. Can you send me the latest  │
│                  │           numbers by Friday?    [▶][📋][…]   │
│                  │ ─────────────────────────────────────────── │
│                  │ 10:32 AM  Remind me to review the Q1 report  │
│                  │   00:08   before the meeting tomorrow.        │
│                  │                                               │
│                  │ YESTERDAY                                     │
│                  │ 4:15 PM   The API deadline is March 15th and  │
│                  │   00:12   we need to finish the integration.  │
│                  │                                               │
│                  │ ┌───────────────────────────────────────────┐ │
│                  │ │ [▶] Transcript snippet...  ═══░░ 0:15  ✕ │ │
│                  │ └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Features:**
- Full-width flat chronological list (no split pane, no detail view)
- Grouped by date (Today, Yesterday, specific dates)
- Each entry shows: time, duration, full transcript text (no line limit)
- Hover actions: Play/Pause, Copy (with checkmark confirmation), three-dot menu (Download Audio, Delete)
- Currently-playing row has subtle accent tint background
- Bottom bar audio player (Spotify-style): play/pause, transcript snippet, progress bar, time, close
- Search bar filters by transcript content (substring match, case-insensitive)
- Context menu: Play/Pause, Copy, Download Audio, Delete
- Keyboard shortcut: Cmd+Backspace to delete
- Text selection enabled on transcript text
- Delete confirmation dialog before permanent removal

**Database schema:**

```sql
CREATE TABLE dictations (
    id TEXT PRIMARY KEY,
    createdAt TEXT NOT NULL,
    durationMs INTEGER NOT NULL,

    -- Transcript
    rawTranscript TEXT NOT NULL,
    cleanTranscript TEXT,             -- populated in v0.2 (clean pipeline)

    -- Audio
    audioPath TEXT,                   -- optional override; default: dictations/{id}.wav

    -- Metadata
    pastedToApp TEXT,                 -- "Slack", "Chrome", etc. (if detectable)

    -- Settings at time of dictation
    processingMode TEXT NOT NULL DEFAULT 'raw',  -- 'raw' in v0.1, 'clean' default in v0.2

    -- Status
    status TEXT NOT NULL DEFAULT 'completed',     -- recording | processing | completed | error
    errorMessage TEXT,                -- set when status = error

    -- Timestamps
    updatedAt TEXT NOT NULL
);

CREATE INDEX idx_dictations_created_at ON dictations(createdAt DESC);
```

**Audio storage:**

```
~/Library/Application Support/MacParakeet/dictations/
└── {uuid}.wav          # Audio file (metadata in database)
```

Audio path is computed from ID by default. Files stored as WAV (16kHz mono). User can disable storage in settings (audio discarded after transcription).

**Acceptance criteria:**
- [x] Dictation history shows all past dictations grouped by date in flat list
- [x] Search filters dictations by transcript content in real-time (substring match)
- [x] Can play audio via bottom bar player (Spotify-style progress bar)
- [x] Can copy transcript text to clipboard (with checkmark confirmation)
- [x] Can delete individual dictations (with confirmation dialog)
- [x] Can download audio files via three-dot menu
- [x] Hover actions appear without layout shift (overlay pattern)
- [x] History persists across app restarts (SQLite via GRDB)

---

### F5: Settings

**What:** Configure dictation behavior, recording preferences, and storage options.

**Settings UI:**

```
┌─────────────────────────────────────────────────────────────────┐
│ Settings                                                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│ GENERAL                                                          │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Launch at login                                    [toggle] │ │
│ └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│ DICTATION                                                        │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Hotkey: [fn Fn   Change...]  (double-tap / hold)            │ │
│ │                                                              │ │
│ │ Stop mode:                                                   │ │
│ │   ( ) Auto-stop after silence     Delay: [2 sec ▾]          │ │
│ │   (•) Manual stop (press Fn again)                           │ │
│ │                                                              │ │
│ └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│ STORAGE                                                          │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ [x] Save audio recordings                                   │ │
│ │                                                              │ │
│ │ Dictations: 127 recordings (42.3 MB)                         │ │
│ │ [Clear All Dictations...]                                    │ │
│ └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│ SPEECH MODEL                                                     │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Parakeet (Speech)        Ready                 [Repair]      │ │
│ │ [Check Now]                                                  │ │
│ └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│ PERMISSIONS                                                      │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Microphone           ✓ Granted                               │ │
│ │ Accessibility         ✓ Granted                              │ │
│ └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Settings table:**

| Setting | Options | Default |
|---------|---------|---------|
| Launch at login | On / Off | Off |
| Dictation hotkey | Any single key (record-a-shortcut UI) | Fn (double-tap / hold) |
| Stop mode | Auto-stop after silence / Manual | Manual |
| Silence delay | 1s, 1.5s, 2s, 3s, 5s | 2s |
| Save audio recordings | On / Off | On |
| Keep downloaded YouTube audio | On / Off | On |
| Speech model controls | Check status / Repair | Available |

**Acceptance criteria:**
- [x] All settings persist across app restarts (UserDefaults or GRDB)
- [x] Hotkey can be changed to any single key (modifiers, function keys, navigation keys, etc.) via record-a-shortcut UI
- [x] Stop mode switch works correctly for both modes
- [x] Storage toggle controls whether audio files are saved
- [x] YouTube storage toggle controls whether downloaded URL audio is kept after transcription
- [x] "Clear All" requires confirmation, deletes audio files and database entries
- [x] Permission status shown with current grant state
- [x] Speech model panel shows status for Parakeet and allows repair with retry

---

### F6: Basic Export

**What:** Export transcription results as plain text or copy to clipboard.

**Formats (v0.1):**

| Format | Method | Content |
|--------|--------|---------|
| Plain text | `.txt` file (Downloads) | Full transcript, no timestamps |
| Markdown | `.md` file (Downloads) | Full transcript in Markdown |
| Subtitles (SRT) | `.srt` file (Downloads) | Subtitle cues (word timestamps when available; fallback to a single cue) |
| Subtitles (VTT) | `.vtt` file (Downloads) | WebVTT cues (word timestamps when available; fallback to a single cue) |
| Clipboard | Copy button | Transcript text (clean preferred, raw fallback) |

**Acceptance criteria:**
- [x] "Copy to clipboard" copies full transcript text
- [x] Export buttons write files to the user's Downloads folder with sensible names
- [x] TXT export includes file name and duration header

---

## v0.2 Features (AI & Text Processing)

### F7: Clean Text Pipeline

**What:** Deterministic text processing pipeline that cleans up Parakeet output without any LLM involvement. Fast, predictable, user-controllable.

**Why deterministic (not LLM):**
1. **Predictable** -- Same input always produces same output. Users learn the system.
2. **Fast** -- No model loading, no GPU, sub-millisecond processing.
3. **Controllable** -- Users manage their own word list and snippets. No AI surprises.
4. **Debuggable** -- Pipeline reports exactly what it changed.

Parakeet TDT already outputs good punctuation and capitalization natively, so the pipeline focuses on what STT cannot do: removing verbal fillers, applying domain-specific corrections, and expanding shorthand.

**Pipeline steps (in order):**

```
Audio → Parakeet → raw transcript → clean pipeline → paste
                                    1. Filler removal (word list)
                                    2. Custom word replacements (user-defined)
                                    3. Snippet expansion (trigger → text)
                                    4. Whitespace cleanup
```

**Step 1: Filler removal**

Three-tier strategy with conservative defaults (false negatives are better than false positives):

| Tier | Words | Behavior |
|------|-------|----------|
| Multi-word (checked first) | "you know", "I mean", "sort of", "kind of" | Always removed |
| Always safe | um, uh, umm, uhh | Always removed |
| Sentence-start only | so, well, like, right | Removed only at sentence boundaries; preserved mid-sentence where meaningful |

**Step 2: Custom word replacements**

User-defined corrections for domain vocabulary and proper nouns that STT gets wrong:

```
"kubernetes" → "Kubernetes"
"mac parakeet" → "MacParakeet"
"jay son" → "JSON"
"post gress" → "PostgreSQL"
```

Each custom word is a `(word, replacement)` pair with an enabled/disabled toggle.

**Step 3: Snippet expansion**

Natural language trigger phrases that expand into longer text. Triggers are spoken phrases (not abbreviations) because Parakeet STT outputs natural speech — users say "my address" not "addr".

```
"my signature" → "Best regards,\nDavid"
"my address" → "123 Main Street, San Francisco, CA 94102"
"standup template" → "What I did yesterday:\n\nWhat I'm doing today:\n\nBlockers:"
"my LinkedIn" → "https://www.linkedin.com/in/john-doe/"
"my calendly" → "https://calendly.com/you/30min"
"intro email" → "Hey, would love to find some time to chat later..."
```

Each snippet has a trigger phrase, expansion text, and use count for tracking.

**Step 4: Whitespace cleanup**

- Collapse multiple spaces into single space
- Fix punctuation spacing (remove space before period/comma, ensure space after)
- Capitalize first letter after sentence-ending punctuation
- Trim leading/trailing whitespace

**Processing modes:**

| Mode | Description | Default? |
|------|-------------|----------|
| Raw | Parakeet output as-is, no processing | No |
| Clean | Filler removal + custom words + snippets + whitespace | **Yes** |

**Database tables:**

```sql
CREATE TABLE custom_words (
    id TEXT PRIMARY KEY,
    word TEXT NOT NULL,
    replacement TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    isEnabled INTEGER NOT NULL DEFAULT 1,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);

CREATE TABLE text_snippets (
    id TEXT PRIMARY KEY,
    trigger TEXT NOT NULL UNIQUE,
    expansion TEXT NOT NULL,
    useCount INTEGER NOT NULL DEFAULT 0,
    isEnabled INTEGER NOT NULL DEFAULT 1,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);
```

**Performance target:** <1ms for entire pipeline (no LLM, pure string operations).

**Acceptance criteria:**
- [x] Filler words removed from Parakeet output
- [x] Multi-word fillers handled correctly (checked before single-word)
- [x] Sentence-start-only fillers preserved mid-sentence
- [x] Custom word replacements applied (case-insensitive matching)
- [x] Snippet triggers expanded to full text
- [x] Whitespace normalized and punctuation fixed
- [x] Processing completes in sub-millisecond
- [x] Raw mode bypasses all processing
- [x] Clean mode is the default for new dictations

---

### F8: AI Text Refinement — REMOVED

> Status: **REMOVED** (2026-02-23) — LLM support removed. Formal/Email/Code modes and Qwen3-8B dependency eliminated. Only Raw and Clean (deterministic) modes remain.

**What:** ~~LLM-powered text transformation for cases where deterministic cleanup is not enough. Uses Qwen3-8B via MLX-Swift, running entirely on-device.~~

**Context modes:**

| Mode | Pipeline | Behavior |
|------|----------|----------|
| Raw | None | Parakeet output, no processing |
| Clean | Deterministic (F7) | Filler removal + custom words + snippets |
| Formal | Clean + LLM | Professional tone, grammar fixes, clear structure |
| Email | Clean + LLM | Format as email with greeting, body, sign-off |
| Code | Clean + LLM | Technical dictation, preserve syntax, format as code |

Modes stack: Formal/Email/Code always run the clean pipeline first, then apply LLM refinement on top.

**LLM details:**
- Model: Qwen3-8B (4-bit quantized, `mlx-community/Qwen3-8B-4bit`)
- Framework: MLX-Swift (Apple Silicon optimized)
- Non-thinking mode for all refinement (fast, `temp=0.7, topP=0.8`)
- System prompts per mode:

| Mode | System Prompt Summary |
|------|----------------------|
| Formal | "Rewrite into professional, clear language. Preserve meaning. Fix grammar." |
| Email | "Format as a professional email. Add appropriate greeting and sign-off." |
| Code | "This is technical dictation about programming. Preserve code terms, format appropriately." |

**Personal dictionary (auto-learn):**
- Track words the user corrects via custom words (F9)
- Over time, build a vocabulary profile
- Surface suggestions: "You frequently correct 'react' to 'React'. Add as custom word?"

**Acceptance criteria:**
- [ ] Formal mode produces professional, grammatically correct output
- [ ] Email mode formats text as proper email
- [ ] Code mode preserves technical terms and syntax
- [ ] LLM modes always apply clean pipeline first
- [ ] LLM processing completes in <5 seconds for typical dictations
- [x] Mode is a global default (set in Vocabulary, applies to all dictations)
- [ ] Graceful fallback to Clean if LLM fails or times out

---

### F9: Custom Words & Snippets Management

**What:** UI for managing custom word corrections and text snippet expansions.

**Custom Words view:**

```
┌─────────────────────────────────────────────────────────────────┐
│ Custom Words                                         [+ Add]    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [x] "kubernetes"     →  "Kubernetes"              [Edit] [X]   │
│  [x] "mac parakeet"   →  "MacParakeet"             [Edit] [X]   │
│  [x] "jay son"        →  "JSON"                    [Edit] [X]   │
│  [ ] "post gress"     →  "PostgreSQL"   (disabled) [Edit] [X]   │
│                                                                  │
│  ──────────────────────────────────────────────────────────────  │
│  Add Custom Word:                                                │
│  From: [________________]  To: [________________]  [Add]         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Text Snippets view:**

```
┌─────────────────────────────────────────────────────────────────┐
│ Text Snippets                                        [+ Add]    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  "my signature"  →  "Best regards, David"   (used 23x) [X]     │
│  "my address"    →  "123 Main St, SF 94102" (used 5x)  [X]     │
│  "my LinkedIn"   →  "linkedin.com/in/john"  (used 41x) [X]     │
│  "intro email"   →  "Hey, would love to..." (used 12x) [X]     │
│                                                                  │
│  ──────────────────────────────────────────────────────────────  │
│  Add Snippet:                                                    │
│  Say: [________________]  Expands to: [__________________]      │
│  [Add]                                                           │
│                                                                  │
│  Tip: Use natural phrases you'd actually say, like              │
│  "my email" or "intro email" — not abbreviations.               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Features:**
- Add, edit, delete, enable/disable custom words
- Add, delete text snippets
- Use count tracking for snippets (helps users know which are active)
- Accessible from Settings view ("Manage Custom Words...", "Manage Text Snippets...")
- Import/export word lists (future: share between Macs)

**Settings integration (v0.2 additions):**

```
│ PROCESSING                                                       │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Default mode:  ( ) Raw  (•) Clean  ( ) Formal               │ │
│ │                                                              │ │
│ │ [Manage Custom Words...]        12 words                     │ │
│ │ [Manage Text Snippets...]       5 snippets                   │ │
│ └──────────────────────────────────────────────────────────────┘ │
```

**Acceptance criteria:**
- [x] Can add/edit/delete/toggle custom words
- [x] Can add/delete text snippets
- [x] Use count displayed and updated for snippets
- [x] Changes take effect immediately for next dictation
- [x] Settings link opens management views
- [x] Default processing mode configurable

---

## v0.3 Features (Command Mode, Chat & Export)

### F10: Command Mode (Epic) — REMOVED

> Status: **REMOVED** (2026-02-23) — LLM support removed. Command Mode (F10a/F10b) and Chat with Transcript (F10c) eliminated along with Qwen3-8B dependency.

**What:** ~~Select text in any app, activate command mode, speak a natural language command, and the text is edited in-place by the local LLM.~~

~~To reduce implementation risk and keep delivery focused, Command Mode is split into:~~

~~- `F10a` core command workflow (GUI MVP)~~
~~- `F10b` command enhancements (quick commands + saved templates)~~

### F10a: Command Mode Core (GUI MVP) — REMOVED

**Scope:**
- Default shortcut: Fn+Ctrl (or configurable)
- Requires text selected in active app
- Can also be activated from menu bar: "Command Mode"
- Record spoken command, run local LLM transform, replace selected text in-place

**Flow:**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User selects text in any app                                  │
│    "The meeting is scheduled for next tuesday at 3pm"            │
├─────────────────────────────────────────────────────────────────┤
│ 2. User activates command mode (Fn+Ctrl)                         │
│    - Overlay shows "Speak your command..."                       │
│    - Selected text captured via Accessibility API                │
├─────────────────────────────────────────────────────────────────┤
│ 3. User speaks command                                           │
│    "Make this formal and fix the capitalization"                 │
├─────────────────────────────────────────────────────────────────┤
│ 4. Processing                                                    │
│    - Command transcribed via Parakeet                            │
│    - Selected text + command sent to Qwen3-8B                    │
│    - LLM edits text according to command                         │
├─────────────────────────────────────────────────────────────────┤
│ 5. Result                                                        │
│    - Original text replaced with edited version                  │
│    - "The meeting is scheduled for next Tuesday at 3:00 PM."     │
│    - Undo available via Cmd+Z in the target app                  │
└─────────────────────────────────────────────────────────────────┘
```

**Example commands:**

| Command | Input | Output |
|---------|-------|--------|
| "Translate to Spanish" | "Hello, how are you?" | "Hola, como estas?" |
| "Make this formal" | "hey can u send the file" | "Hello, could you please send the file?" |
| "Fix grammar" | "Their going to the meeting" | "They're going to the meeting." |
| "Summarize" | (long paragraph) | (concise summary) |
| "Add bullet points" | "We discussed budgets timelines and staffing" | "- Budgets\n- Timelines\n- Staffing" |
| "Make it shorter" | (verbose text) | (concise version) |
| "Convert to code" | "create a function that adds two numbers" | `func add(_ a: Int, _ b: Int) -> Int { a + b }` |

**Technical implementation:**
- Read selected text via Accessibility API (`AXUIElement`) with fallback retrieval chain
- Enforce selected text hard cap: 16,000 characters with explicit error
- Transcribe spoken command via Parakeet
- Send `(selected_text, command)` to Qwen3-8B with system prompt: "Apply the user's command to the provided text. Return only the edited text, no explanation."
- Replace selected text by simulating Cmd+V with the result (same paste mechanism as dictation)
- Thinking mode for command interpretation (`temp=0.6, topP=0.95`) to ensure accurate command understanding

**Command overlay (different from dictation overlay):**

```
     ┌─────────────────────────────────────────────┐
     │  Speak your command...                      │
     │  [X]  ∿∿∿∿∿∿∿∿∿∿∿∿  [■]                   │
     │  Selected: "hey can u send the file" (37c) │
     └─────────────────────────────────────────────┘
```

Overlay shows selected text preview (truncated) so the user confirms the right text is selected.

**Acceptance criteria:**
- [ ] Fn+Ctrl activates command mode when text is selected
- [ ] "Command Mode" menu bar action enters same start flow
- [ ] Selected text read from active app via Accessibility API
- [ ] Spoken command transcribed via Parakeet
- [ ] LLM applies command to selected text correctly
- [ ] Result replaces selected text in the active app exactly once
- [ ] Cmd+Z in target app undoes the replacement
- [ ] Works across apps (Safari, Notes, Slack, VS Code, etc.)
- [ ] Graceful errors for: no permission, no text selected ("Select text first"), text too long, and LLM/paste failures

### F10b: Command Mode Enhancements

**Scope:**
- Pre-built quick commands exposed in overlay
- User-defined saved command templates
- Faster repeat-command UX and command organization polish

**Acceptance criteria:**
- [ ] Pre-built commands are accessible from overlay
- [ ] Custom commands can be created, edited, deleted, and reused
- [ ] Reusing a saved command routes through same F10a execution path
- [ ] Failure behavior matches F10a error handling policy

---

### F10c: Transcript Chat (GUI MVP) — REMOVED

> Status: **REMOVED** (2026-02-23) — LLM support removed.

**What:** ~~Ask questions about the currently selected transcript from the transcript detail screen using local Qwen3-8B.~~

**Scope (MVP):**
- Current transcript scope only (no cross-transcript retrieval yet)
- In-memory thread per transcript for current app session
- Bounded transcript context assembly to avoid prompt overflow
- Local-only execution (no cloud calls)

**Flow:**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User opens transcript detail                                 │
├─────────────────────────────────────────────────────────────────┤
│ 2. User asks a question in the chat side panel                 │
│    "What action items were discussed?"                         │
├─────────────────────────────────────────────────────────────────┤
│ 3. App assembles bounded transcript context                    │
│    - current transcript text                                   │
│    - truncation marker if needed                               │
├─────────────────────────────────────────────────────────────────┤
│ 4. Qwen3-8B generates response locally                         │
│    - loading state shown in panel                              │
│    - no network dependency                                     │
├─────────────────────────────────────────────────────────────────┤
│ 5. Response appears in thread                                  │
│    - retry available for failed generations                    │
│    - thread stays attached to this transcript in-session       │
└─────────────────────────────────────────────────────────────────┘
```

**Technical implementation:**
- Prompt composed via shared `TranscriptChatPromptComposer`
- Prompt task uses `LLMTask.transcriptChat(question:transcript:)`
- Context bounded by `TranscriptContextAssembler.assemble(...)`
- Response generated through `LLMServiceProtocol.generate(...)`

**Acceptance criteria:**
- [x] Transcript detail shows chat panel UI
- [x] User can send a question and receive a response in-thread
- [x] Context is bounded for long transcripts
- [x] Failed responses surface inline error with retry path
- [x] Local model readiness status is visible in panel

---

### F11: YouTube URL Transcription

**What:** Paste a YouTube URL to download and transcribe the video's audio locally.

**Flow:**

```
User pastes YouTube URL
       │
       ▼
┌──────────────────────┐
│  URL validation      │ ── Verify URL format, extract video ID
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  yt-dlp download     │ ── Download audio track (best quality)
│                      │    Emits determinate progress: 0–100%
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  AudioProcessor      │ ── Convert to 16kHz mono WAV
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Parakeet STT        │ ── Transcribe with word timestamps
│                      │    Emits chunk progress updates
└──────────┬───────────┘
           │
           ▼
Display result (same view as file transcription)
```

**YouTube UI integration:**

```
┌─────────────────────────────────────────────────────┐
│                                                      │
│  ┌─────────────────────────────────────────────┐    │
│  │       Drop audio or video file here          │    │
│  │           or click to browse                 │    │
│  └─────────────────────────────────────────────┘    │
│                                                      │
│  ────────────────── or ──────────────────            │
│                                                      │
│  YouTube: [https://youtube.com/watch?v=...] [Go]     │
│                                                      │
└─────────────────────────────────────────────────────┘
```

**Technical requirements:**
- yt-dlp standalone managed binary for YouTube audio download (weekly non-blocking `--update`)
- Bundled FFmpeg binary for media demux/conversion (no system dependency)
- Supports standard YouTube URL forms (`youtube.com/watch`, `youtu.be`, `youtube.com/shorts`, `youtube.com/embed`, `youtube.com/v`)
- Playlist pages are processed in single-video mode (`--no-playlist`); full playlist batch transcription is deferred
- Audio-only download (no video, saves bandwidth and time)
- Downloaded YouTube audio is retained by default and can be auto-deleted via Settings > Storage

**Limitations:**
- Age-restricted videos may fail (requires auth cookies)
- Live streams not supported
- Very long videos (6+ hours) can take significant time to download/transcribe even with progress updates
- Download for personal use only (noted in UI)

**Acceptance criteria:**
- [x] Paste YouTube URL into text field and click "Transcribe" to start
- [x] Download phase emits determinate percent progress (`Downloading audio... X%`)
- [x] Transcription phase emits chunk progress updates (`Transcribing... X%`)
- [x] Result displayed same as file transcription
- [x] Handles invalid URLs gracefully (error message)
- [x] Handles private/restricted videos with clear error
- [x] Downloaded YouTube audio is kept by default, with a Settings toggle to auto-delete after transcription
- [ ] Playlist URLs supported (batch transcription) — deferred to v0.4

---

### F12: Full Export Options

**What:** Export transcription results in multiple formats for different use cases.

**Export formats:**

| Format | Extension | Use Case | Content |
|--------|-----------|----------|---------|
| Plain Text | `.txt` | General | Full transcript, no timestamps |
| Subtitles (SRT) | `.srt` | Video editing | Timed subtitle segments |
| Subtitles (VTT) | `.vtt` | Web video | WebVTT format subtitles |
| Word Document | `.docx` | Documents | Formatted with headings |
| PDF | `.pdf` | Sharing | Print-ready formatted |
| JSON | `.json` | Development | Full data with word-level timestamps + confidence |

**SRT format example:**
```
1
00:00:00,000 --> 00:00:05,230
The advancement in cloud native technology
has been remarkable over the past year.

2
00:00:05,450 --> 00:00:12,100
Kubernetes 2.0 introduces a completely
new scheduling architecture.
```

**JSON format example:**
```json
{
  "file": "interview.mp3",
  "duration": 2723.5,
  "text": "The advancement in cloud native technology...",
  "words": [
    {"word": "The", "start": 0.0, "end": 0.15, "confidence": 0.99},
    {"word": "advancement", "start": 0.16, "end": 0.72, "confidence": 0.97}
  ],
  "segments": [
    {"start": 0.0, "end": 5.23, "text": "The advancement in cloud native technology has been remarkable over the past year."}
  ]
}
```

**Acceptance criteria:**
- [ ] All 6 formats generate correctly
- [ ] SRT/VTT contain properly timed segments from word-level timestamps
- [ ] DOCX opens correctly in Word/Pages/Google Docs
- [ ] PDF is well-formatted and print-ready
- [ ] JSON includes all word-level data with confidence scores
- [ ] Export via standard macOS save dialog with format picker
- [ ] Batch export: select format, export all recent transcriptions at once

---

## v0.4 Features (Polish & Launch)

### F13: Speaker Diarization

**What:** Automatically detect and label different speakers in file transcriptions.

**Scope:** File transcription and YouTube transcription only. Dictation is single-speaker by design.

**Features:**
- Automatic speaker segmentation (detect speaker changes)
- Labels: Speaker 1, Speaker 2, etc. (auto-generated)
- Manual renaming: click speaker label to assign real name
- Speaker colors in transcript view (visual differentiation)
- Per-speaker analytics: speaking time, word count
- Always-on for file transcription (Option-key alternate to skip for power users)

**Transcript with speakers:**

```
┌─────────────────────────────────────────────────────┐
│  interview.mp3                              45:23    │
├─────────────────────────────────────────────────────┤
│                                                      │
│  Speaker 1 (Sarah)           62% speaking time       │
│  Speaker 2 (Interviewer)     38% speaking time       │
│                                                      │
│  ────────────────────────────────────────────────── │
│                                                      │
│  [00:00] Sarah:                                      │
│  The advancement in cloud native technology has      │
│  been remarkable over the past year.                 │
│                                                      │
│  [00:12] Interviewer:                                │
│  Can you tell us more about the scheduling           │
│  changes in Kubernetes 2.0?                          │
│                                                      │
│  [00:18] Sarah:                                      │
│  Of course. The new scheduler was designed from      │
│  the ground up to handle heterogeneous workloads...  │
│                                                      │
└─────────────────────────────────────────────────────┘
```

**Export with speakers:**
- All export formats (F12) support speaker labels when diarization is available
- SRT/VTT: speaker name prefix per subtitle
- TXT/Markdown: speaker label before each turn
- DOCX/PDF: speaker name in bold before each turn
- JSON: `speakerId` field per word in `wordTimestamps`

**Technical notes:**
- Uses FluidAudio's offline diarization pipeline (separate from ASR, see ADR-010)
- Three-stage pipeline: pyannote community-1 (segmentation) + WeSpeaker v2 (embeddings) + VBx (clustering)
- ~15% DER on VoxConverse (CoreML), ~11.2% PyTorch reference — competitive with commercial APIs
- ~130 MB additional model download (one-time, cached alongside ASR models)
- Runs after ASR completes, merges speaker segments with word-level timestamps by time overlap
- Diarization is non-fatal — if it fails, ASR result is still persisted without speaker data
- Stable speaker IDs (`"S1"`, `"S2"`) stored on words; display labels in separate mapping (rename is O(1))
- Overlapping speech regions are trimmed (exclusive output) — words in overlap zones may lack speaker assignment
- No cross-file speaker identity (Speaker 1 in file A is not linked to Speaker 1 in file B)
- Single-speaker files correctly return one speaker label with no overhead
- Total file transcription time: ~53-79 seconds per hour of audio (ASR ~23s + diarization ~30-56s)

**Acceptance criteria:**
- [x] Speakers automatically detected and separated in transcript
- [x] Speaker labels displayed in transcript view with colors (Step 8 — UI PR)
- [x] Click speaker label to rename with real name (Step 8 — UI PR)
- [x] Speaking time (from diarization segments) and word count per speaker (Step 8 — UI PR)
- [x] Export includes speaker information in all formats
- [x] SRT/VTT cues split at speaker boundaries
- [x] Works with 2+ speakers (no artificial upper limit)
- [x] Diarization models downloaded during onboarding (~130 MB)
- [x] Single-speaker files handled gracefully (one speaker label)
- [x] Diarization failure is non-fatal (ASR result preserved)
- [x] Progress shows "Identifying speakers..." headline
- [x] Settings toggle for speaker detection (on by default, replaces planned Option-key alternate)
- [x] CLI: `macparakeet-cli transcribe` runs diarization by default, `--no-diarize` to skip

---

### F14: Non-Blocking Transcription Progress

> Status: **IMPLEMENTED**

**What:** Replace the full-screen progress takeover with a compact bottom bar so users can browse old transcripts while a transcription runs.

**Problem:** Currently, starting a transcription replaces the entire Transcribe tab with a progress card. Users can't view previous transcriptions, and the drop zone disappears. The tab feels "stuck" until processing completes.

**Solution:** Show progress as a sticky bottom bar. The drop zone and recent transcriptions list remain visible (drop zone disabled during transcription). Single-job — no queue.

**Layout during transcription:**

```
┌─────────────────────────────────────────────────────────────────┐
│ [Drop zone / URL input — disabled during transcription]         │
│                                                                  │
│ Recent Transcriptions                                            │
│  interview.mp3          12:34    [View]                         │
│  podcast.m4a            45:00    [View]                         │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│ ⟳ podcast-ep42.m4a  Transcribing... 67%                 [View]  │
└─────────────────────────────────────────────────────────────────┘
```

**Acceptance criteria:**
- [x] Progress shown as compact bottom bar during transcription
- [x] Drop zone and recent transcriptions list remain visible
- [x] Drop zone visually disabled (no new drops accepted while transcribing)
- [x] "View" button on progress bar shows full progress detail view
- [x] Clicking a recent transcription still opens it during transcription
- [x] When transcription completes, bottom bar disappears, result is shown

---

### F15: Whisper Mode — REMOVED

> **Removed:** Parakeet TDT is a fixed CoreML model with no tunable parameters for low-energy speech. "Whisper Mode" would amount to a mic gain preset — not a real STT feature. Users can adjust mic sensitivity in macOS System Settings. Removed to avoid shipping marketing fluff as a feature.

---

### F16: Direct Distribution

> Status: **IMPLEMENTED**

**What:** Distribute MacParakeet as a notarized DMG via macparakeet.com and LemonSqueezy. Auto-updates via Sparkle.

**Why not App Store:** MacParakeet bundles FFmpeg and yt-dlp as standalone binaries, uses Accessibility APIs for global hotkeys, and uses LemonSqueezy for licensing. App Store sandboxing would block the bundled binaries and the licensing model conflicts with App Store payments.

**Distribution pipeline (implemented):**
- Notarized DMG signed with Developer ID
- Direct download from downloads.macparakeet.com (Cloudflare R2)
- LemonSqueezy product page (free, $0 — originally $49 one-time, now GPL-3.0)
- Sparkle 2 auto-updates via EdDSA-signed appcast
- Privacy policy live at macparakeet.com/privacy

---

## v0.5 Features (Data & Reliability)

> Status: **IMPLEMENTED**

Internal data model improvements, reliability fixes, and open-source release. No new UI surfaces — these are foundational changes that support future work.

### F17: Private Dictation Mode

> Status: **IMPLEMENTED**

**What:** A `hidden` flag on dictations that excludes them from history and voice stats. Used for sensitive dictations the user doesn't want in their history.

**Schema:** `dictations.hidden` (BOOLEAN, NOT NULL, DEFAULT 0)

### F18: Voice Stats Word Count

> Status: **IMPLEMENTED**

**What:** Cached `wordCount` column on dictations for the voice stats dashboard, avoiding repeated O(n) text splitting. Backfilled on migration from existing transcripts.

**Schema:** `dictations.wordCount` (INTEGER, NOT NULL, DEFAULT 0)

### F19: Multi-Conversation Chat

> Status: **IMPLEMENTED**

**What:** Replaced the single `chatMessages` JSON field on `transcriptions` with a dedicated `chat_conversations` table. Each transcription can now have multiple named conversations with independent history.

**Migration:** Existing `chatMessages` data migrated to new table with auto-derived titles. Legacy column nulled out but kept for backward compat.

**Schema:** New `chat_conversations` table with FK → `transcriptions` (CASCADE delete). See `spec/01-data-model.md`.

### F20: YouTube Video Metadata

> Status: **IMPLEMENTED**

**What:** Store YouTube video metadata (thumbnail URL, channel name, description) on transcription records. Powers thumbnail cards in the library grid and richer display.

**Schema:** `transcriptions.thumbnailURL`, `transcriptions.channelName`, `transcriptions.videoDescription`

### F21: Transcription Favorites

> Status: **IMPLEMENTED**

**What:** User can mark transcriptions as favorites. Library view supports filtering by favorites.

**Schema:** `transcriptions.isFavorite` (BOOLEAN, NOT NULL, DEFAULT 0)

### F22: FTS5 Removal

> Status: **IMPLEMENTED**

**What:** Dropped the unused FTS5 virtual table and 3 sync triggers on `dictations`. These were created in v0.1 but never queried — search uses `LIKE` instead. Removing them eliminates write overhead on every dictation INSERT/UPDATE/DELETE.

### F23: Open-Source Release

> Status: **IMPLEMENTED**

**What:** Released MacParakeet as GPL-3.0 open source at github.com/moona3k/macparakeet. LemonSqueezy kept as $0 product. Community repo archived with redirect.

---

## v0.6 Features (Video Player & UI Revamp)

> Status: **IMPLEMENTED**

Embedded video/audio playback, split-pane detail view, synced transcript highlighting, and a library grid with thumbnails, filters, and search.

### F24: Video & Audio Playback

> Status: **IMPLEMENTED**

**What:** Embedded playback for YouTube videos (HLS streaming) and local audio/video files. Split-pane layout with video on the left and tabbed content on the right.

**Acceptance criteria:**
- [x] YouTube videos play via HLS streaming (yt-dlp URL extraction + AVPlayer)
- [x] Local video files play via AVPlayer
- [x] Audio-only files show a 44px horizontal scrubber bar instead of video
- [x] Playback mode auto-detected (video/audio/none)
- [x] MediaPlayerViewModel with play/pause, seek, 10Hz time sync
- [x] Video panel collapsible (full → hidden)

### F25: Synced Transcript & Timestamps

> Status: **IMPLEMENTED**

**What:** Transcript highlighting synced to playback position. Click any timestamp to seek.

**Acceptance criteria:**
- [x] Active word/segment highlighted during playback (binary search for current time)
- [x] Auto-scroll follows playback position
- [x] Clicking a timestamp in the transcript seeks the player to that position

### F26: Transcription Library

> Status: **IMPLEMENTED**

**What:** Grid view of all transcriptions with thumbnail cards, filters, search, and sorting.

**Acceptance criteria:**
- [x] Thumbnail grid layout with cards (YouTube thumbnails downloaded, local video frames extracted via FFmpeg)
- [x] Filter bar: All / YouTube / Local / Favorites
- [x] Search across transcription titles and content
- [x] Sort by date (newest/oldest)

### F27: Home Page Redesign

> Status: **IMPLEMENTED**

**What:** Two side-by-side input cards on the home page: YouTube URL input and local file drop zone.

**Acceptance criteria:**
- [x] YouTube input card with URL field and transcribe button
- [x] Local file card with drag-and-drop zone
- [x] Both cards equally prominent (co-equal modes)

---

## v0.5 — Processing Layer (Implemented)

Prompt library and multi-summary system. Users control how AI processes transcripts via reusable prompts. See [spec/12-processing-layer.md](12-processing-layer.md) and [ADR-013](adr/013-prompt-library-multi-summary.md).

### F28: Prompt Library

> Status: **IMPLEMENTED ON CURRENT BRANCH**

**What:** Reusable prompt templates stored in SQLite. Community prompts ship with the app and can be hidden but not edited or deleted. Users can create, edit, and delete custom prompts.

**Acceptance criteria:**
- [x] Built-in/community prompts available on first launch from built-in seed
- [x] Built-in/community prompts can be hidden but not edited or deleted
- [x] Prompt cards can be marked auto-run independently of sort order
- [x] Zero auto-run prompt cards is a supported configuration
- [x] Custom prompts can be created, edited, and deleted via management sheet
- [x] Prompt management accessible from the generation popover
- [x] Auto-run prompt cards stay visible while auto-run is enabled

### F29: Multi-Summary

> Status: **IMPLEMENTED ON CURRENT BRANCH**

**What:** Multiple summaries per transcript, each from a different prompt. Summaries are tab-based, with pending generations appearing immediately.

**Acceptance criteria:**
- [x] User can select a prompt from the generation popover
- [x] Generating a summary creates a new summary record (does not overwrite)
- [x] Multiple summaries displayed as tabs, pending generations appear immediately
- [x] User can add extra instructions layered on top of selected prompt
- [x] Queued summary pipeline (single-worker, sequential execution)
- [x] Auto-run after transcription uses every prompt card marked auto-run
- [x] If zero prompt cards are marked auto-run, transcription still completes normally and prompt tabs can be added manually
- [x] Existing transcriptions with summaries display migrated data correctly

---

## Future Features (Post-Launch)

### F30: iOS Companion App
Share transcripts between Mac and iPhone. Capture in-person conversations on iPhone.

### F31: Translation
Translate transcribed text to other languages. Implementation approach TBD (local model or API).

### F32: API / Shortcuts Integration
Expose transcription as a macOS Shortcut action. Enable automation: "When I receive a voice memo, transcribe it."

### F33: Team Vocabulary Sharing
Export/import custom word lists and snippet packs. Share domain-specific vocabulary with team members.

### F34: Vibe Coding Integrations
Deep integration with code editors:
- **Cursor / VS Code:** Dictate code with context-aware formatting
- **Xcode:** Swift-specific dictation mode
- **Terminal:** Voice commands for git, build, test

### F35: Context Awareness
Read surrounding text from the active app via macOS Accessibility APIs (AXUIElement) to produce better transcriptions. Knows "React" in a code editor, "react" in a therapy note. All processing local -- no screen content ever leaves device.

---

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Transcription speed | 155x realtime | Parakeet TDT on Apple Silicon (ANE via FluidAudio CoreML) |
| Dictation latency | <500ms end-to-end | From Fn release to text appearing |
| Clean pipeline | <1ms | Deterministic, pure string operations |
| Memory usage (idle) | <200MB | Menu bar + STT model standing by |
| Memory usage (active) | <300MB | During transcription with STT loaded |
| App size | <100MB | Plus ~6 GB STT model download on first run |
| Startup time | <2s | Cold start to menu bar ready |
| File transcription | 1 hour audio in <25s | On M1 or better (ANE via CoreML) |

---

## Privacy Requirements

MacParakeet's brand is privacy. These are non-negotiable.

| Requirement | Detail |
|-------------|--------|
| Core offline operation | Dictation and file transcription work fully offline after one-time model setup |
| Opt-out telemetry | Self-hosted usage analytics and crash reporting can be disabled in Settings |
| No accounts | No email, no login, no registration |
| No cloud STT | All speech recognition runs locally on Apple Silicon |
| User-controlled storage | Audio saved by default, user can disable or delete |
| Explicit network surfaces | Model download, update checks, optional LLM providers, optional telemetry/crash reporting, licensing flows, and YouTube download |

**What "supports a fully local setup" means:**
- Parakeet STT runs on Apple Silicon Neural Engine (ANE) via FluidAudio CoreML -- no cloud API
- Audio never leaves the device
- Transcripts stay local unless the user explicitly enables external AI features
- Users can remain fully local by sticking to offline/core features and local providers such as Ollama
- Network access is limited to explicit product surfaces such as updates, telemetry, licensing, and media download

---

## Feature Dependencies

```
v0.1 Core MVP:
────────────────────────────────────────────────────────────────────

                   ┌──────────────────┐
                   │  Parakeet STT    │ ← Foundation for everything
                   │  (FluidAudio)   │
                   └────────┬─────────┘
                            │
              ┌─────────────┼──────────────┐
              │             │              │
      ┌───────▼──────┐  ┌──▼───────┐  ┌──▼────────────┐
      │ F1: Dictation │  │ F2: File │  │ F3: Basic UI  │
      │ (Fn hotkey,   │  │ Transcr. │  │ (menu bar +   │
      │  overlay,     │  │ (drag &  │  │  main window) │
      │  auto-paste)  │  │  drop)   │  │               │
      └───────┬───────┘  └──┬───────┘  └──┬────────────┘
              │             │              │
              │     ┌───────┴──────┐       │
              ├────►│ F4: History  │◄──────┘
              │     │ (dictations  │
              │     │  + file      │
              │     │  results)    │
              │     └──────────────┘
              │
      ┌───────▼──────┐     ┌──────────────┐
      │ F5: Settings │     │ F6: Basic    │
      │ (hotkey, mode│     │ Export       │
      │  storage)    │     │ (.txt, copy) │
      └──────────────┘     └──────────────┘


v0.2 Text Processing:
────────────────────────────────────────────────────────────────────

      ┌──────────────────┐
      │ F7: Clean Text   │ ← Deterministic pipeline
      │ Pipeline         │
      └────────┬─────────┘
               │
               │  ┌──────────────────┐
               └──│ F9: Custom Words │
                  │ & Snippets UI    │
                  └──────────────────┘

         Integrates with F1 (dictation)
         and F2 (file transcription)


v0.3 YouTube & Export:
────────────────────────────────────────────────────────────────────

      ┌──────────────────┐
      │ F11: YouTube     │ ← Requires F2 (file transcription)
      │ Transcription    │   + yt-dlp
      └──────────────────┘

      ┌──────────────────┐
      │ F12: Full Export │ ← Requires F2 (word-level timestamps)
      │ (.srt, .pdf, etc)│
      └──────────────────┘


v0.4 Polish & Launch:
────────────────────────────────────────────────────────────────────

      ┌──────────────────┐
      │ F13: Diarization │ ← Extends F2 (file transcription)
      └──────────────────┘

      ┌──────────────────┐
      │ F14: Batch       │ ← Extends F2 (file transcription)
      │ Processing       │
      └──────────────────┘

      ┌──────────────────┐
      │ F16: Direct      │ ← Requires all v0.1-v0.3 features
      │ Distribution     │
      └──────────────────┘


Cross-cutting dependency:

      Parakeet STT ──► F1, F2, F11, F13, F14
      Accessibility ──► F1 (hotkey + paste)
      FFmpeg ──────────► F2, F11, F14
      yt-dlp ──────────► F11
      GRDB (SQLite) ──► F4, F7 (custom words, snippets)
```

**Critical path for MVP (v0.1):**
```
FluidAudio model download → Audio capture (AVAudioEngine)
    → Dictation service (Fn hotkey + overlay)
    → Text insertion (NSPasteboard + Cmd+V)
    → History (GRDB persistence)
    → Settings (UserDefaults)
```

---

## Non-Features (Explicit Exclusions)

| Feature | Why Excluded |
|---------|--------------|
| AI meeting notes / memory / CRM-style enrichment | That's Oatmeal, not MacParakeet |
| Calendar integration | Meeting app territory |
| Entity extraction / memory | Meeting app territory |
| Cloud processing | Privacy is the brand -- opt-in LLM providers only (ADR-011) |
| Windows / Linux | macOS-only simplifies everything, Apple Silicon required |
| Collaborative / multi-user | Single-user product |
| Subscription pricing | Free and open-source (GPL-3.0) — no monetization |
| Realtime streaming transcription | File-based and dictation-based only |
| ~~Video playback~~ | ~~We transcribe audio, not play video~~ (implemented in v0.6) |

---

## Licensing

> Status: **HISTORICAL** — MacParakeet is now free and open-source (GPL-3.0) as of v0.5.

The trial/Pro tier system (ADR-006) is no longer enforced. LemonSqueezy is kept as a $0 product for download tracking. License activation code remains in the codebase but all features are unlocked.

---

*See [03-architecture.md](./03-architecture.md) for how these features are implemented technically.*
