#!/usr/bin/env python3
"""Run frozen baseline and candidate binaries sequentially on the same WAVs.

Acquisition is separate. Every output has a matching log; failures stop the run.
Existing results are never silently reused or overwritten.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from score_diarization import load_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline-models", type=Path, required=True)
    parser.add_argument("--candidate-models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-offline", action="store_true")
    args = parser.parse_args()
    records = load_manifest(args.manifest)
    backends = ["community1-0.15.7", "nemotron"]
    if args.include_offline:
        backends.append("nemotron-offline")
    for row in records:
        audio = args.audio_root / (row["id"] + ".wav")
        if not audio.is_file():
            raise FileNotFoundError(audio)
        for backend in backends:
            output = args.output / backend / (row["id"] + ".json")
            if output.exists():
                raise FileExistsError(output)
    for index, row in enumerate(records):
        audio = args.audio_root / (row["id"] + ".wav")
        with audio.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        # Alternate who runs first. Only one inference process runs at a time.
        order = backends[index % len(backends):] + backends[:index % len(backends)]
        for backend in order:
            output = args.output / backend / (row["id"] + ".json")
            output.parent.mkdir(parents=True, exist_ok=True)
            baseline = backend == "community1-0.15.7"
            command = [str((args.baseline if baseline else args.candidate).resolve()), str(audio.resolve()),
                       "--output", str(output.resolve()), "--models-directory",
                       str((args.baseline_models if baseline else args.candidate_models).resolve())]
            if not baseline:
                command += ["--backend", backend]
            print(f"{index + 1}/{len(records)} {row['id']} {backend}", flush=True)
            with output.with_suffix(".log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            result = json.loads(output.read_text())
            if result["audioSHA256"] != digest or result["backend"] != backend:
                raise ValueError(f"Unexpected input/backend provenance: {output}")
            print(f"  {result['speakerCount']} speakers, {result['runtimeSeconds']:.3f}s", flush=True)


if __name__ == "__main__":
    main()
