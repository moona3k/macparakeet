"""JSON-RPC 2.0 server for Parakeet TDT speech-to-text.

Communicates with the Swift app via stdin/stdout.
Protocol: one JSON-RPC request per line, one response per line.
"""

import json
import os
import sys
import traceback


def _ensure_ffmpeg_on_path():
    """Add FFmpeg to PATH so parakeet_mlx can find it.

    parakeet_mlx uses shutil.which("ffmpeg") to locate FFmpeg. In a macOS
    .app bundle the PATH is minimal (/usr/bin:/bin) and won't include
    Homebrew or the imageio-ffmpeg bundled binary. Fix that here before
    any audio loading happens.
    """
    try:
        import imageio_ffmpeg
        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        ffmpeg_dir = os.path.dirname(ffmpeg_exe)
        if ffmpeg_dir not in os.environ.get("PATH", ""):
            os.environ["PATH"] = ffmpeg_dir + os.pathsep + os.environ.get("PATH", "")
    except ImportError:
        pass

    # Also add common system locations as fallback
    for extra in ["/opt/homebrew/bin", "/usr/local/bin"]:
        if extra not in os.environ.get("PATH", ""):
            os.environ["PATH"] = os.environ.get("PATH", "") + os.pathsep + extra


_ensure_ffmpeg_on_path()

# Lazy-loaded model reference
_model = None

_HF_REPO = "mlx-community/parakeet-tdt-0.6b-v3"


def _load_model():
    """Load Parakeet TDT model on first use.

    Delegates to _load_model_with_progress() so the first transcribe call
    also gets progress-aware loading if the model hasn't been warmed up yet.
    """
    global _model
    if _model is not None:
        return _model
    return _load_model_with_progress()


class _StderrProgress:
    """tqdm-compatible progress class that writes SETUP_PROGRESS: lines to stderr."""

    def __init__(self, *args, **kwargs):
        self.total = kwargs.get("total", None)
        self.n = 0
        self.desc = kwargs.get("desc", "")

    def update(self, n=1):
        self.n += n
        if self.total and self.total > 0:
            sys.stderr.write(f"SETUP_PROGRESS:downloading_model:{self.n}:{self.total}\n")
            sys.stderr.flush()

    def close(self):
        pass

    def set_description(self, *args, **kwargs): pass
    def set_postfix(self, *args, **kwargs): pass
    def set_postfix_str(self, *args, **kwargs): pass
    def refresh(self, *args, **kwargs): pass
    def reset(self, *args, **kwargs): pass
    def display(self, *args, **kwargs): pass
    def clear(self, *args, **kwargs): pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _load_model_with_progress():
    """Load model with progress reporting to stderr.

    Inlines the logic from parakeet_mlx.from_pretrained() but passes our
    tqdm_class to hf_hub_download for the model weights download.
    """
    global _model
    if _model is not None:
        return _model

    try:
        import json as _json
        from pathlib import Path

        import mlx.core as mx
        from huggingface_hub import hf_hub_download
        from mlx.utils import tree_flatten, tree_unflatten
        from parakeet_mlx.utils import from_config

        # Download config (small, no progress needed)
        sys.stderr.write("SETUP_PROGRESS:downloading_config:0:0\n")
        sys.stderr.flush()
        config_path = hf_hub_download(_HF_REPO, "config.json")
        with open(config_path, "r") as f:
            config = _json.load(f)

        # Download model weights with progress
        sys.stderr.write("SETUP_PROGRESS:downloading_model:0:0\n")
        sys.stderr.flush()
        weight_path = hf_hub_download(
            _HF_REPO, "model.safetensors", tqdm_class=_StderrProgress
        )

        # Load into memory
        sys.stderr.write("SETUP_PROGRESS:loading_model:0:0\n")
        sys.stderr.flush()
        model = from_config(config)
        model.load_weights(weight_path)

        # Cast to bfloat16
        curr_weights = dict(tree_flatten(model.parameters()))
        curr_weights = [(k, v.astype(mx.bfloat16)) for k, v in curr_weights.items()]
        model.update(tree_unflatten(curr_weights))

        _model = model

        sys.stderr.write("SETUP_PROGRESS:ready:0:0\n")
        sys.stderr.flush()
        return _model
    except ImportError as e:
        raise RuntimeError(f"Failed to import parakeet_mlx: {e}")


def _make_response(result, request_id):
    return {"jsonrpc": "2.0", "result": result, "id": request_id}


def _make_error(code, message, request_id, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "error": error, "id": request_id}


def handle_ping(params, request_id):
    return _make_response("pong", request_id)

def handle_warm_up(params, request_id):
    """Preload the model so first real transcription is fast.

    This may download model weights on first run. Emits SETUP_PROGRESS: lines
    to stderr so the Swift app can show granular progress.
    """
    try:
        _load_model_with_progress()
        return _make_response({"status": "ok"}, request_id)
    except RuntimeError as e:
        return _make_error(-32001, str(e), request_id)
    except MemoryError:
        return _make_error(-32002, "Out of memory", request_id)
    except Exception as e:
        return _make_error(
            -32000,
            "Warm up failed",
            request_id,
            {"reason": str(e)},
        )


def handle_transcribe(params, request_id):
    audio_path = params.get("audio_path")
    if not audio_path:
        return _make_error(-32600, "Missing audio_path parameter", request_id)

    import os
    if not os.path.exists(audio_path):
        return _make_error(
            -32000,
            "Transcription failed",
            request_id,
            {"reason": f"Audio file not found: {audio_path}"},
        )

    try:
        model = _load_model()
    except RuntimeError as e:
        return _make_error(-32001, str(e), request_id)

    try:
        # Use chunking for long audio to avoid Metal OOM errors.
        # chunk_duration=300 (5 min chunks), overlap_duration=15s for context.
        # parakeet-mlx handles splitting, per-chunk inference, and merging.
        chunk_duration = params.get("chunk_duration", 300.0)
        overlap_duration = params.get("overlap_duration", 15.0)

        def _chunk_progress(current_pos, total_pos):
            sys.stderr.write(f"PROGRESS:{current_pos}/{total_pos}\n")
            sys.stderr.flush()

        result = model.transcribe(
            audio_path,
            chunk_duration=chunk_duration,
            overlap_duration=overlap_duration,
            chunk_callback=_chunk_progress,
        )

        # Extract text and word-level timestamps from AlignedResult.
        # Parakeet TDT returns sub-word tokens (SentencePiece). Tokens with a
        # leading space start a new word; others are continuations. Merge them
        # into full words so the UI displays proper text.
        text = result.text if hasattr(result, "text") else str(result)
        words = []
        current_word = None

        if hasattr(result, "sentences"):
            for sentence in result.sentences:
                if not hasattr(sentence, "tokens"):
                    continue
                first_in_sentence = True
                for token in sentence.tokens:
                    tok_text = token.text if hasattr(token, "text") else str(token)
                    if not tok_text:
                        continue

                    starts_new = first_in_sentence or tok_text[0] == " "
                    first_in_sentence = False

                    if starts_new:
                        if current_word is not None:
                            words.append(current_word)
                        current_word = {
                            "word": tok_text.strip(),
                            "start_ms": int(token.start * 1000) if hasattr(token, "start") else 0,
                            "end_ms": int(token.end * 1000) if hasattr(token, "end") else 0,
                            "confidence": getattr(token, "confidence", 1.0),
                        }
                    else:
                        # Continuation — append text, extend end time, take min confidence
                        current_word["word"] += tok_text
                        current_word["end_ms"] = int(token.end * 1000) if hasattr(token, "end") else current_word["end_ms"]
                        current_word["confidence"] = min(
                            current_word["confidence"],
                            getattr(token, "confidence", 1.0),
                        )

        if current_word is not None:
            words.append(current_word)

        # Filter out empty words
        words = [w for w in words if w["word"]]

        return _make_response(
            {"text": text, "words": words},
            request_id,
        )
    except MemoryError:
        return _make_error(-32002, "Out of memory", request_id)
    except Exception as e:
        return _make_error(
            -32000,
            "Transcription failed",
            request_id,
            {"reason": str(e)},
        )


METHODS = {
    "ping": handle_ping,
    "warm_up": handle_warm_up,
    "transcribe": handle_transcribe,
}


def process_request(line):
    """Parse and handle a single JSON-RPC request."""
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        return _make_error(-32700, "Parse error", None)

    jsonrpc = request.get("jsonrpc")
    if jsonrpc != "2.0":
        return _make_error(-32600, "Invalid Request: missing jsonrpc 2.0", request.get("id"))

    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params", {})

    if not method:
        return _make_error(-32600, "Invalid Request: missing method", request_id)

    if method not in METHODS:
        return _make_error(-32601, f"Method not found: {method}", request_id)

    return METHODS[method](params, request_id)


def main():
    """Main loop: read JSON-RPC requests from stdin, write responses to stdout."""
    # Signal readiness to the Swift app
    sys.stdout.write("ready\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            response = process_request(line)
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
        except Exception:
            error_response = _make_error(
                -32000,
                "Internal error",
                None,
                {"reason": traceback.format_exc()},
            )
            sys.stdout.write(json.dumps(error_response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
