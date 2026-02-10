# 06 - STT Engine

> Status: **ACTIVE** - Authoritative, current

MacParakeet uses Parakeet TDT 0.6B-v3 via parakeet-mlx for all speech-to-text, running locally on Apple Silicon.

---

## Model

| Property | Value |
|----------|-------|
| Model | Parakeet TDT 0.6B-v3 |
| HuggingFace ID | `mlx-community/parakeet-tdt-0.6b-v3` |
| Runtime | parakeet-mlx (Python, MLX backend) |
| Word Error Rate | ~6.3% |
| Speed | 300x+ realtime on Apple Silicon |
| Output | Word-level timestamps with confidence scores |
| Model Size | ~1.5GB download on first use |
| Input Format | Any audio format (FFmpeg converts to 16kHz mono) |
| Languages | English-primary; Parakeet v3 supports 25 European languages |
| Chunking | Automatic for long audio (30s chunks, 5s overlap) |
| Decoding | Greedy (default) or beam search (beam_size=5) |

---

## Python Daemon

### Architecture

The STT engine runs as a Python daemon process, communicating with the Swift app via JSON-RPC over stdin/stdout.

```
MacParakeet (Swift) ←→ stdin/stdout (JSON-RPC) ←→ Python Daemon (parakeet-mlx)
```

### Lifecycle

- **Lazy start**: daemon is not started at app launch; it starts on first transcription request
- **Keep alive**: once started, the daemon stays running for subsequent requests
- **Restart on crash**: if the daemon process exits unexpectedly, it is restarted on the next transcription request
- **Graceful shutdown**: daemon is terminated when the app quits

### Environment

- **uv** bootstraps the Python environment on first run
- A bundled `uv` binary creates an isolated venv with parakeet-mlx and its dependencies
- The venv is stored in the app's Application Support directory
- No system Python dependency — fully self-contained

---

## Protocol

### JSON-RPC 2.0

All communication uses JSON-RPC 2.0 over stdin/stdout. One request at a time (no batching).

### Transcribe Request

```json
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/tmp/recording.wav",
    "chunk_duration": 30.0,
    "overlap_duration": 5.0
  },
  "id": 1
}
```

**Parameters:**
- `audio_path` (required): Path to audio file (any format FFmpeg supports)
- `chunk_duration` (default: 30.0): Seconds per chunk for long audio. 30s balances context vs memory. Set 0 to disable chunking.
- `overlap_duration` (default: 5.0): Overlap between chunks (chunk/6 per HuggingFace best practice)

### Transcribe Response

```json
{
  "jsonrpc": "2.0",
  "result": {
    "text": "Hello world",
    "words": [
      {
        "word": "Hello",
        "start_ms": 0,
        "end_ms": 500,
        "confidence": 0.98
      },
      {
        "word": "world",
        "start_ms": 520,
        "end_ms": 1000,
        "confidence": 0.95
      }
    ]
  },
  "id": 1
}
```

**Note:** Word timestamps are in milliseconds (matching Oatmeal's convention). The daemon extracts these from parakeet-mlx's `AlignedResult.sentences[].tokens[]` objects, aggregating BPE tokens into words at space boundaries.

### Error Response

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "Transcription failed",
    "data": {
      "reason": "Audio file not found"
    }
  },
  "id": 1
}
```

### Error Codes

| Code | Meaning |
|------|---------|
| -32700 | Parse error (invalid JSON) |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32000 | Transcription failed |
| -32001 | Model not loaded |
| -32002 | Out of memory |

---

## Bootstrap Flow

```
App Launch
    → Check if Python venv exists
    → If not: create venv via bundled uv
        → Install parakeet-mlx + dependencies
        → Download model (~1.5GB) if not cached
    → If yes: verify venv integrity
    → (Daemon not started yet — lazy start)

First Transcription Request
    → Start Python daemon process
    → Wait for "ready" signal
    → Send transcribe request
    → Return result
```

### First-Run Experience

On first use, the bootstrap process:

1. Creates an isolated Python environment using the bundled `uv` binary
2. Installs `parakeet-mlx` and its dependencies into the venv
3. Downloads the Parakeet TDT 0.6B-v3 model (~1.5GB)
4. Reports progress to the UI (download percentage, install status)

This is a one-time cost. Subsequent launches skip directly to daemon start.

---

## Error Handling

### Model Download

- Show download progress bar in the UI
- Support retry on network failure
- Resume partial downloads where possible
- Verify model integrity after download (checksum)

### Daemon Crash Recovery

- Detect daemon exit via process monitoring
- Log crash reason (stderr capture)
- Auto-restart on next transcription request
- After 3 consecutive crashes, show error to user and stop retrying until manually triggered

### Timeout Handling

- Transcription requests have a timeout proportional to audio duration
- Short dictations: 30-second timeout
- Long files: duration x 0.5 timeout (since model runs at 300x+ realtime, this is generous)
- On timeout: kill daemon, report error, auto-restart on next request

### Out of Memory

- Parakeet-mlx runs on Apple Silicon unified memory
- If the system is memory-constrained, the daemon may be killed by the OS
- Detect OOM via exit code and report to user
- Suggest closing other apps or restarting

---

## Performance

| Scenario | Latency |
|----------|---------|
| Cold start (model loading) | ~5 seconds |
| Warm (model in memory) | <500ms for short dictations |
| Long file transcription | ~12 seconds per hour of audio |

### Optimization Notes

- The daemon keeps the model loaded in memory after first use (warm mode)
- Apple Silicon's unified memory means no GPU↔CPU transfer overhead
- For dictation, latency is the primary concern — aim for <500ms end-to-end after warm-up
- For file transcription, throughput matters more — progress reporting keeps the UI responsive
