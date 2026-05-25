#!/usr/bin/env python3
"""
Generate voiceover audio via Higgs Audio V2 — the current SOTA open-weight TTS.

Use this when you need maximum quality — dramatic range, multi-speaker dialog,
or premium hero-cut renders. For most iteration, the Kokoro-js default in
`generate-voice.ts` is more than sufficient and dramatically simpler.

Why Higgs Audio V2:
  - #1 trending TTS on HuggingFace as of May 2026
  - Built on Llama 3.2 3B foundation; pretrained on 10M+ hours of audio
  - Naturalness 9.5/10; exceptional prosody and breathing simulation
  - Multi-speaker capable (distinct voices, turn-taking, emotional sync)
  - V2.5 update Jan 2026 refined intonation
  - Open weights, runs locally on Apple Silicon via PyTorch MPS

Setup (one-time, ~6-10 GB model downloads on first run):
    uv sync                                  # installs deps from pyproject.toml
    # or with pip:  pip install -e .

Apple Silicon notes:
    Uses PyTorch MPS backend. Expect ~10-30s generation per minute of audio
    on M2 Pro / M3 / M4. CPU fallback works but is much slower.

Usage:
    python scripts/generate-voice-hq.py                  # all scenes
    python scripts/generate-voice-hq.py master-demo      # one scene

Reads from a JSON dump of SCRIPT — run `npm run script:dump` first, or
the script will auto-invoke tsx to extract it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "public" / "audio"
SCRIPT_DUMP = ROOT / "src" / "content" / "script.json"

MODEL_NAME = os.environ.get(
    "HIGGS_MODEL",
    "bosonai/higgs-audio-v2-generation-3B-base",
)
DEVICE = os.environ.get("HIGGS_DEVICE", "mps")  # mps | cpu | cuda


def ensure_script_dump() -> dict:
    """Materialize SCRIPT as JSON so Python can read it without a TS runtime."""
    dumper = ROOT / "scripts" / "dump-script.ts"
    if not SCRIPT_DUMP.exists() or SCRIPT_DUMP.stat().st_mtime < dumper.stat().st_mtime:
        print("Dumping SCRIPT → script.json…")
        subprocess.run(
            ["npx", "tsx", str(dumper)],
            cwd=ROOT,
            check=True,
        )
    with SCRIPT_DUMP.open() as f:
        return json.load(f)


def build_jobs(script: dict) -> list[tuple[str, str]]:
    return [
        ("hook-opener", script["bridges"]["openingLine"]),
        ("mode-dictation", script["modes"]["dictation"]["vo"]),
        ("mode-transcription", script["modes"]["transcription"]["vo"]),
        ("mode-meeting", script["modes"]["meeting"]["vo"]),
        ("closing", script["bridges"]["closingLine"]),
        (
            "master-demo",
            " ".join(
                [
                    script["bridges"]["openingLine"],
                    script["modes"]["dictation"]["vo"],
                    script["modes"]["transcription"]["vo"],
                    script["modes"]["meeting"]["vo"],
                    script["bridges"]["closingLine"],
                ]
            ),
        ),
    ]


def main() -> int:
    try:
        import torch
        import torchaudio
        from boson_multimodal.serve.serve_engine import HiggsAudioServeEngine, HiggsAudioResponse
        from boson_multimodal.data_types import ChatMLSample, Message
    except ImportError as exc:
        print(
            f"Missing dependency ({exc.name}). Install with:\n"
            f"    cd {ROOT} && uv sync\n"
            f"    # or: pip install -e .",
            file=sys.stderr,
        )
        return 1

    script = ensure_script_dump()
    all_jobs = build_jobs(script)

    requested = sys.argv[1:]
    jobs = (
        [(n, t) for n, t in all_jobs if n in requested]
        if requested
        else all_jobs
    )

    if not jobs:
        print(
            f"No matching jobs. Available: {', '.join(n for n, _ in all_jobs)}",
            file=sys.stderr,
        )
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Loading Higgs Audio V2 ({MODEL_NAME}) on {DEVICE}…")
    engine = HiggsAudioServeEngine(model_name_or_path=MODEL_NAME, device=DEVICE)
    print("Engine ready.\n")

    # System prompt encoding the brand voice direction.
    system_prompt = (
        "You are a narrator with a calm, confident, minimal tone. "
        "Slight warmth. Professional. Quiet competence — measured pacing, "
        "no theatrical emphasis. Pause naturally at periods."
    )

    for name, text in jobs:
        messages = [
            Message(role="system", content=system_prompt),
            Message(role="user", content=text),
        ]
        sample = ChatMLSample(messages=messages)
        out_path = OUT_DIR / f"{name}.wav"

        import time

        start = time.time()
        response: HiggsAudioResponse = engine.generate(
            chat_ml_sample=sample,
            max_new_tokens=2048,
            temperature=0.3,
            top_p=0.95,
        )
        torchaudio.save(
            str(out_path),
            torch.tensor(response.audio).unsqueeze(0),
            response.sampling_rate,
        )
        elapsed = time.time() - start
        print(f"✓ {name.ljust(20)} → {out_path.relative_to(ROOT)} ({elapsed:.1f}s)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
