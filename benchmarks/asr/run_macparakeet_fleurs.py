#!/usr/bin/env python3
"""Drive macparakeet-cli over a FLEURS language subset and emit multilingual
scorer-ready JSONL ({id, ref, hyp, lang, engine}).

FLEURS layout (FluidInference/fleurs-full): <lang>/<lang>.trans.txt with
"<id> <text>" lines + <lang>/<id>.wav. We take the first N ids (sorted) to match
FluidAudio's cohere/sensevoice `--max-files N` (= first N per language), so the
multilingual numbers are comparable across engines.

Engines (`--engine` -> macparakeet-cli flags); --language hint set from the FLEURS code:
    whisper          -> --engine whisper --language <hint>
    nemotron-multi   -> --engine nemotron --nemotron-model multilingual-1120ms --language <hint>
    parakeet-v3      -> --engine parakeet --parakeet-model v3 --language <hint>   (EU+en; not CJK)

Score with score_multi.py (WER for en, CER for ko/ja/zh).
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

# FLEURS code -> macparakeet-cli --language hint
LANG_HINT = {"en_us": "en", "ko_kr": "ko", "ja_jp": "ja", "cmn_hans_cn": "zh",
             "fr_fr": "fr", "de_de": "de", "es_419": "es", "it_it": "it"}

ENGINES = {
    "whisper": lambda hint: ["--engine", "whisper", "--language", hint],
    "nemotron-multi": lambda hint: ["--engine", "nemotron", "--nemotron-model", "multilingual-1120ms", "--language", hint],
    "parakeet-v3": lambda hint: ["--engine", "parakeet", "--parakeet-model", "v3", "--language", hint],
}


def load_refs(trans: Path) -> dict[str, str]:
    refs = {}
    for line in trans.read_text(encoding="utf-8").splitlines():
        if line.strip():
            uid, _, text = line.partition(" ")
            refs[uid] = text
    return refs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", type=Path, required=True)
    ap.add_argument("--fleurs-dir", type=Path, required=True, help="dir containing <lang>/ subdirs")
    ap.add_argument("--lang", required=True, help="FLEURS code, e.g. ko_kr")
    ap.add_argument("--engine", required=True, choices=list(ENGINES))
    ap.add_argument("--limit", type=int, default=150)
    ap.add_argument("--records", type=Path, required=True)
    args = ap.parse_args()

    lang_dir = (args.fleurs_dir / args.lang).expanduser().resolve()
    trans = lang_dir / f"{args.lang}.trans.txt"
    refs = load_refs(trans)
    wavs = sorted(p for p in lang_dir.glob("*.wav") if p.stem in refs)[: args.limit]
    if not wavs:
        raise SystemExit(f"no wavs for {args.lang} under {lang_dir}")
    hint = LANG_HINT.get(args.lang, args.lang.split("_")[0])

    work = Path(tempfile.mkdtemp(prefix=f"fleurs-{args.engine}-{args.lang}-"))
    out_dir = work / "t"
    out_dir.mkdir(parents=True)
    cmd = [str(args.cli.expanduser().resolve()), "transcribe", *[str(p) for p in wavs],
           "--format", "transcript", "--output-dir", str(out_dir),
           *ENGINES[args.engine](hint), "--speaker-detection", "off", "--no-history"]
    print(f"engine={args.engine} lang={args.lang} hint={hint} files={len(wavs)}")
    t0 = time.monotonic()
    res = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    wall = time.monotonic() - t0
    (work / "stderr.log").write_text(res.stderr, encoding="utf-8")
    if res.returncode != 0:
        raise SystemExit(f"cli exit {res.returncode}; see {work}/stderr.log")

    args.records.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with args.records.open("w", encoding="utf-8") as fh:
        for p in wavs:
            tx = out_dir / f"{p.stem}.txt"
            if not tx.exists():
                continue
            rec = {"id": p.stem, "ref": refs[p.stem], "hyp": tx.read_text(encoding="utf-8").strip(),
                   "lang": args.lang, "engine": args.engine}
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
    print(f"records={args.records} written={n} wall={wall:.1f}s")
    shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
