# MacParakeet Architecture

> Status: **ACTIVE**

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        MacParakeet App                          │
│                         (SwiftUI)                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │   Main Window   │  │   Menu Bar      │  │   Dictation    │  │
│  │   (Drop Zone)   │  │   (Status)      │  │   Overlay      │  │
│  └────────┬────────┘  └────────┬────────┘  └───────┬────────┘  │
│           │                    │                    │           │
│           └────────────────────┴────────────────────┘           │
│                              │                                   │
│                    ┌─────────▼─────────┐                        │
│                    │  MacParakeetCore  │                        │
│                    │    (Library)      │                        │
│                    └─────────┬─────────┘                        │
│                              │                                   │
│         ┌────────────────────┼────────────────────┐             │
│         │                    │                    │             │
│  ┌──────▼──────┐  ┌─────────▼─────────┐  ┌──────▼──────┐      │
│  │   Audio     │  │   Transcription   │  │     AI      │      │
│  │   Capture   │  │     Service       │  │   Refine    │      │
│  └──────┬──────┘  └─────────┬─────────┘  └──────┬──────┘      │
│         │                   │                    │             │
└─────────┼───────────────────┼────────────────────┼─────────────┘
          │                   │                    │
          │         ┌─────────▼─────────┐          │
          │         │   Parakeet STT    │          │
          │         │  (Python Daemon)  │          │
          │         └───────────────────┘          │
          │                                        │
          │                              ┌─────────▼─────────┐
          │                              │   MLX-Swift LLM   │
          │                              │    (Qwen3-4B)     │
          │                              └───────────────────┘
          │
    ┌─────▼─────┐
    │ AVFoundation│
    │ Core Audio  │
    └─────────────┘
```

## Components

### 1. MacParakeet App (GUI)

SwiftUI-based macOS application.

**Views:**
- `MainWindow` - Drag-drop zone, transcript display
- `MenuBarView` - Status menu
- `DictationOverlay` - Recording indicator
- `SettingsView` - Preferences

**Responsibilities:**
- User interaction
- File selection
- Transcript display
- Export handling

### 2. MacParakeetCore (Library)

Shared Swift library with no UI dependencies.

**Services:**
| Service | Responsibility |
|---------|---------------|
| `TranscriptionService` | Orchestrate file → text |
| `DictationService` | Handle live recording → paste |
| `AudioProcessor` | Format conversion, resampling |
| `STTClient` | Communicate with Parakeet daemon |
| `AIService` | Text refinement via MLX |
| `ExportService` | Generate output formats |

### 3. Parakeet STT Daemon

Python process for speech-to-text.

**Communication:** JSON-RPC over stdin/stdout

**Protocol:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/tmp/recording.wav",
    "language": "en"
  },
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "text": "Hello world",
    "words": [
      {"word": "Hello", "start": 0.0, "end": 0.5, "confidence": 0.98},
      {"word": "world", "start": 0.6, "end": 1.0, "confidence": 0.97}
    ],
    "duration": 1.0
  },
  "id": 1
}
```

**Bootstrap:**
```
App Launch
    │
    ▼
Check ~/.macparakeet/python exists?
    │
    ├── No ──► Run bundled `uv` to create venv
    │          Install parakeet-mlx
    │
    ▼
Start Python daemon
    │
    ▼
Ready for transcription
```

### 4. MLX-Swift LLM

Local language model for text refinement.

**Model:** Qwen3-4B (4-bit quantized)
**Framework:** MLX-Swift

**Use Cases:**
- Clean up dictation (remove fillers)
- Grammar correction
- Format conversion (email, formal, etc.)

---

## Data Flow

### File Transcription

```
User drops file
       │
       ▼
┌──────────────────┐
│  AudioProcessor  │ ── Convert to 16kHz mono WAV
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│    STTClient     │ ── Send to Parakeet daemon
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Parakeet Daemon │ ── Transcribe with word timestamps
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   AIService      │ ── Optional: Refine text
└────────┬─────────┘
         │
         ▼
Display in UI
```

### Dictation Flow

```
User presses hotkey
       │
       ▼
┌──────────────────┐
│ DictationService │ ── Start recording via AVAudioEngine
└────────┬─────────┘
         │
       (recording...)
         │
User releases hotkey
         │
         ▼
┌──────────────────┐
│  AudioProcessor  │ ── Save buffer to temp WAV
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│    STTClient     │ ── Transcribe
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   AIService      │ ── Optional: Refine
└────────┬─────────┘
         │
         ▼
Paste to active app (NSPasteboard + CGEvent)
```

---

## File Locations

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Python venv | `~/.macparakeet/python/` |
| Settings | `~/Library/Preferences/com.macparakeet.plist` |
| Temp audio | `$TMPDIR/macparakeet/` |
| Logs | `~/Library/Logs/MacParakeet/` |
| Models | `~/.macparakeet/models/` |

---

## Security & Privacy

### Permissions Required

| Permission | Reason | When Requested |
|------------|--------|----------------|
| Microphone | Dictation recording | First dictation |
| Accessibility | Global hotkey, paste | First dictation |
| Screen Recording | System audio capture | Meeting recording |

### Privacy Guarantees

1. **No network by default** - App works fully offline
2. **Temp files deleted** - Audio removed after transcription
3. **No analytics** - Zero telemetry
4. **No accounts** - No login required

### Sandboxing (App Store)

For App Store distribution:
- Reduced permissions
- Hardened runtime
- May require entitlements for:
  - Audio input
  - Accessibility
  - Temporary files

---

## Dependencies

### Swift
| Package | Version | Purpose |
|---------|---------|---------|
| MLX-Swift | Latest | LLM inference |
| GRDB | 6.x | SQLite (history) |

### Python (Daemon)
| Package | Version | Purpose |
|---------|---------|---------|
| parakeet-mlx | Latest | STT engine |
| mlx | Latest | ML framework |

### Bundled
| Tool | Purpose |
|------|---------|
| uv | Python environment |
| FFmpeg | Audio conversion |

---

## Performance Considerations

### Memory
- Parakeet model: ~1.5GB
- LLM model: ~2.5GB
- Target total: <4GB at peak

### Startup
- Lazy-load Python daemon (on first transcription)
- Pre-warm in background after first use
- Target: <2s cold start

### Transcription Speed
- Parakeet: 100-300x realtime on M1+
- Target: 1 hour audio in <1 minute

---

## Testing Strategy

### Unit Tests
- `AudioProcessor` format handling
- `STTClient` protocol serialization
- Export format generation

### Integration Tests
- Full transcription pipeline
- Dictation → paste flow

### Manual Testing
- Various audio formats
- Different accent/languages
- Long recordings (2+ hours)

---

*Last updated: 2026-01-24*
