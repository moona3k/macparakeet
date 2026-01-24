# MacParakeet Features

> Status: **ACTIVE**

## Feature Overview

| Version | Theme | Status |
|---------|-------|--------|
| v0.1 | Core Transcription | 🚧 In Progress |
| v0.2 | AI Refinement | Planned |
| v0.3 | Import & Export | Planned |
| v0.4 | Polish & Launch | Planned |

---

## v0.1: Core Transcription (MVP)

### 1.1 File Transcription

**User Story:** As a user, I want to transcribe audio/video files by dragging them onto the app.

**Acceptance Criteria:**
- [ ] Drag-and-drop file onto app window or menu bar icon
- [ ] Progress indicator during transcription
- [ ] Display result in scrollable text view
- [ ] Copy to clipboard button
- [ ] Word-level timestamps available

**Supported Formats:**
| Type | Formats |
|------|---------|
| Audio | MP3, WAV, M4A, FLAC, OGG, OPUS |
| Video | MP4, MOV, MKV, WebM, AVI |

**Technical Notes:**
- Use FFmpeg (bundled) for format conversion
- Parakeet expects 16kHz mono WAV
- Max file size: 4 hours (configurable)

### 1.2 System-Wide Dictation

**User Story:** As a user, I want to dictate text anywhere on my Mac using a hotkey.

**Acceptance Criteria:**
- [ ] Global hotkey (default: `⌥⌥` double-tap Option)
- [ ] Visual overlay shows recording state
- [ ] Automatic paste into active text field on release
- [ ] Push-to-talk or toggle mode options
- [ ] Cancel with Escape key

**Technical Notes:**
- Use CGEventTap for global hotkey
- Clipboard paste via NSPasteboard
- Record via AVAudioEngine

### 1.3 Basic UI

**User Story:** As a user, I want a simple, native Mac interface.

**Interface:**
```
┌─────────────────────────────────────────────┐
│  MacParakeet                          ─ □ ✕ │
├─────────────────────────────────────────────┤
│                                             │
│     Drag audio or video file here           │
│           or click to browse                │
│                                             │
│           [Browse Files]                    │
│                                             │
├─────────────────────────────────────────────┤
│  Recent:                                    │
│  • interview.mp3 - 2 min ago               │
│  • podcast-ep42.m4a - Yesterday            │
└─────────────────────────────────────────────┘
```

**Menu Bar:**
```
┌────────────────────────┐
│ 🦜 MacParakeet         │
├────────────────────────┤
│ Start Dictation   ⌥⌥   │
│ Open Window       ⌘O   │
├────────────────────────┤
│ Recent Files      ►    │
├────────────────────────┤
│ Settings...       ⌘,   │
│ Quit             ⌘Q    │
└────────────────────────┘
```

### 1.4 Settings

**User Story:** As a user, I want to configure basic preferences.

**Settings:**
| Setting | Options | Default |
|---------|---------|---------|
| Dictation hotkey | Configurable | `⌥⌥` |
| Model | Parakeet 0.6B-v3 | Parakeet 0.6B-v3 |
| Output language | Auto, English, ... | Auto |
| Launch at login | On/Off | Off |
| Menu bar only | On/Off | Off |
| Dictation mode | Push-to-talk / Toggle | Push-to-talk |

### 1.5 Basic Export

**User Story:** As a user, I want to export transcripts in common formats.

**Export Formats (v0.1):**
- Plain text (.txt)
- Copy to clipboard

---

## v0.2: AI Refinement

### 2.1 Text Cleanup

**User Story:** As a user, I want AI to clean up my dictated text automatically.

**Features:**
- [ ] Remove filler words ("um", "uh", "like")
- [ ] Fix punctuation and capitalization
- [ ] Grammar correction
- [ ] Optional: Summarize long transcripts

**Technical Notes:**
- Use Qwen3-4B via MLX-Swift
- Configurable refinement level (none, light, full)

### 2.2 Context Modes

**User Story:** As a user, I want different refinement styles for different contexts.

**Modes:**
| Mode | Behavior |
|------|----------|
| Raw | No processing, exact transcription |
| Clean | Remove fillers, fix punctuation |
| Formal | Professional tone, grammar fixes |
| Email | Format as email |
| Code | Technical dictation, preserve syntax |

---

## v0.3: Import & Export

### 3.1 YouTube Transcription

**User Story:** As a user, I want to transcribe YouTube videos by pasting a URL.

**Flow:**
1. Paste YouTube URL
2. App downloads audio (yt-dlp)
3. Transcribe with Parakeet
4. Display result

**Limitations:**
- Age-restricted videos may fail
- Live streams not supported
- Download for personal use only

### 3.2 Full Export Options

**Export Formats:**
| Format | Extension | Use Case |
|--------|-----------|----------|
| Plain Text | .txt | General |
| Subtitles | .srt, .vtt | Video editing |
| Word | .docx | Documents |
| PDF | .pdf | Sharing |
| JSON | .json | Development |

### 3.3 Batch Processing

**User Story:** As a user, I want to transcribe multiple files at once.

**Features:**
- [ ] Multi-file drag and drop
- [ ] Queue view with progress
- [ ] Batch export

---

## v0.4: Polish & Launch

### 4.1 Speaker Diarization

**User Story:** As a user, I want to identify different speakers in recordings.

**Features:**
- [ ] Automatic speaker detection
- [ ] Label speakers (Speaker 1, Speaker 2, ...)
- [ ] Manual speaker naming
- [ ] Export with speaker labels

**Technical Notes:**
- Parakeet TDT includes diarization
- May require post-processing for accuracy

### 4.2 Meeting Auto-Detection

**User Story:** As a user, I want MacParakeet to automatically offer to transcribe when I join a meeting.

**Supported Apps:**
- Zoom
- Google Meet (via browser)
- Microsoft Teams
- Discord

**Technical Notes:**
- Detect app launch via NSWorkspace
- Prompt user to start recording
- Record system audio (requires Screen Recording permission)

### 4.3 App Store Submission

**Checklist:**
- [ ] App Store guidelines compliance
- [ ] Privacy policy
- [ ] Screenshots and preview video
- [ ] Sandboxing adjustments
- [ ] Notarization

---

## Future Ideas (Post-Launch)

| Feature | Priority | Notes |
|---------|----------|-------|
| iOS companion app | Medium | Share transcripts |
| Custom vocabulary | Medium | Technical terms |
| Whisper model fallback | Low | For comparison |
| Translation | Low | Via LLM |
| API/Shortcuts | Low | Automation |

---

## Technical Constraints

### Performance Targets

| Metric | Target |
|--------|--------|
| Transcription speed | 100x+ realtime |
| Dictation latency | <500ms |
| Memory usage | <2GB |
| App size | <500MB |
| Startup time | <2s |

### Privacy Requirements

- No network calls except:
  - YouTube download (user-initiated)
  - App Store license check (if sandboxed)
- No analytics, no telemetry
- No accounts required
- Audio deleted after transcription (unless saved by user)

---

*Last updated: 2026-01-24*
