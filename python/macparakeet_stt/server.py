"""JSON-RPC 2.0 server for Parakeet TDT speech-to-text.

Communicates with the Swift app via stdin/stdout.
Protocol: one JSON-RPC request per line, one response per line.
"""

import json
import sys
import traceback

# Lazy-loaded model reference
_model = None


def _load_model():
    """Load Parakeet TDT model on first use via parakeet_mlx.from_pretrained().

    Downloads the model on first run (~600MB) and caches it in HuggingFace cache.
    """
    global _model
    if _model is not None:
        return _model
    try:
        import parakeet_mlx

        _model = parakeet_mlx.from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
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

    This may download model weights on first run.
    """
    try:
        _load_model()
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

        # Extract text and word-level timestamps from AlignedResult
        text = result.text if hasattr(result, "text") else str(result)
        words = []

        if hasattr(result, "sentences"):
            for sentence in result.sentences:
                if hasattr(sentence, "tokens"):
                    for token in sentence.tokens:
                        words.append({
                            "word": token.text.strip() if hasattr(token, "text") else str(token),
                            "start_ms": int(token.start * 1000) if hasattr(token, "start") else 0,
                            "end_ms": int(token.end * 1000) if hasattr(token, "end") else 0,
                            "confidence": getattr(token, "confidence", 1.0),
                        })

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
