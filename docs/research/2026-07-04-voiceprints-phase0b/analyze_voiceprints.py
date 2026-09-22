#!/usr/bin/env python3
import itertools
import json
import math
from pathlib import Path


DATA_DIR = Path("data")
OUT_JSON = Path("analysis_results.json")
OUT_MD = Path("analysis_results.md")
MARGIN = 0.10


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    weight = pos - lo
    return ordered[lo] * (1.0 - weight) + ordered[hi] * weight


def cosine_distance(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0 or norm_b == 0:
        raise ValueError("zero-length embedding")
    return 1.0 - (dot / (norm_a * norm_b))


def load_records():
    records = []
    for path in sorted(DATA_DIR.glob("*.json")):
        channel, stem_json = path.name.split("__", 1)
        stem = stem_json.removesuffix(".json")
        payload = json.loads(path.read_text())
        speakers = payload.get("speakers", [])
        if not speakers:
            raise ValueError(f"{path} has no speakers")
        total_speech = sum(float(s["totalSpeechSec"]) for s in speakers)
        dominant = max(speakers, key=lambda s: float(s["totalSpeechSec"]))
        dominant_sec = float(dominant["totalSpeechSec"])
        dominant_ratio = dominant_sec / total_speech if total_speech else 0.0
        records.append(
            {
                "id": f"{channel}/{stem}",
                "channel": channel,
                "file": payload["sourceFile"],
                "json": str(path),
                "audioDurationSec": payload.get("audioDurationSec"),
                "segmentCount": payload["segmentCount"],
                "speakerCount": len(speakers),
                "totalSpeechSec": total_speech,
                "dominantSpeakerId": dominant["speakerId"],
                "dominantSpeechSec": dominant_sec,
                "dominantRatio": dominant_ratio,
                "flagDominantUnder70": dominant_ratio < 0.70,
                "embedding": dominant["embedding"],
            }
        )
    return records


def population_stats(values):
    return {
        "count": len(values),
        "p5": percentile(values, 5),
        "p25": percentile(values, 25),
        "p50": percentile(values, 50),
        "p75": percentile(values, 75),
        "p95": percentile(values, 95),
        "min": min(values) if values else None,
        "max": max(values) if values else None,
    }


def make_pairs(records):
    pairs = []
    for left, right in itertools.combinations(records, 2):
        same = left["channel"] == right["channel"]
        pairs.append(
            {
                "population": "P" if same else "N",
                "left": left["id"],
                "right": right["id"],
                "leftChannel": left["channel"],
                "rightChannel": right["channel"],
                "distance": cosine_distance(left["embedding"], right["embedding"]),
            }
        )
    return sorted(pairs, key=lambda p: (p["population"], p["distance"], p["left"], p["right"]))


def tau_sweep(positive, negative):
    rows = []
    for i in range(0, 31):
        tau = round(i * 0.05, 2)
        upper = tau + MARGIN
        p_accept = sum(1 for d in positive if d <= tau)
        n_accept = sum(1 for d in negative if d <= tau)
        p_gray = sum(1 for d in positive if tau < d < upper)
        n_gray = sum(1 for d in negative if tau < d < upper)
        rows.append(
            {
                "tau": tau,
                "marginUpper": round(upper, 2),
                "TPR": p_accept / len(positive) if positive else 0.0,
                "FPR": n_accept / len(negative) if negative else 0.0,
                "positiveAccepted": p_accept,
                "negativeAccepted": n_accept,
                "positiveGray": p_gray,
                "negativeGray": n_gray,
            }
        )
    return rows


def fmt(value):
    return f"{value:.4f}" if isinstance(value, float) else str(value)


def write_markdown(records, pairs, stats, sweep):
    positives = [p for p in pairs if p["population"] == "P"]
    negatives = [p for p in pairs if p["population"] == "N"]
    overlap = {
        "positiveMin": min(p["distance"] for p in positives),
        "positiveMax": max(p["distance"] for p in positives),
        "negativeMin": min(p["distance"] for p in negatives),
        "negativeMax": max(p["distance"] for p in negatives),
    }
    lines = []
    lines.append("# Analysis Results")
    lines.append("")
    lines.append("## Dominant Clusters")
    lines.append("")
    lines.append("| file | clusters | segments | total speech sec | dominant | dominant sec | dominant share | flag |")
    lines.append("|---|---:|---:|---:|---|---:|---:|---|")
    for r in records:
        flag = "DOM<70%" if r["flagDominantUnder70"] else ""
        lines.append(
            f"| {r['id']} | {r['speakerCount']} | {r['segmentCount']} | {r['totalSpeechSec']:.1f} | "
            f"{r['dominantSpeakerId']} | {r['dominantSpeechSec']:.1f} | {r['dominantRatio']:.3f} | {flag} |"
        )
    lines.append("")
    lines.append("## Population Stats")
    lines.append("")
    lines.append("| population | count | p5 | p25 | p50 | p75 | p95 | min | max |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for name in ("P", "N"):
        s = stats[name]
        lines.append(
            f"| {name} | {s['count']} | {s['p5']:.4f} | {s['p25']:.4f} | {s['p50']:.4f} | "
            f"{s['p75']:.4f} | {s['p95']:.4f} | {s['min']:.4f} | {s['max']:.4f} |"
        )
    lines.append("")
    lines.append(
        f"Overlap: P range {overlap['positiveMin']:.4f}-{overlap['positiveMax']:.4f}; "
        f"N range {overlap['negativeMin']:.4f}-{overlap['negativeMax']:.4f}."
    )
    lines.append("")
    lines.append("## Tau Sweep")
    lines.append("")
    lines.append(
        f"Margin interpretation: accept same-speaker when distance <= tau; "
        f"treat tau < distance < tau+{MARGIN:.2f} as gray/no-decision; FPR is negatives accepted at <= tau."
    )
    lines.append("")
    lines.append("| tau | gray upper | TPR | FPR | P accepted | N accepted | P gray | N gray |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in sweep:
        lines.append(
            f"| {row['tau']:.2f} | {row['marginUpper']:.2f} | {row['TPR']:.3f} | {row['FPR']:.3f} | "
            f"{row['positiveAccepted']} | {row['negativeAccepted']} | {row['positiveGray']} | {row['negativeGray']} |"
        )
    lines.append("")
    lines.append("## Same-Channel Pairs")
    lines.append("")
    lines.append("| distance | left | right |")
    lines.append("|---:|---|---|")
    for p in positives:
        lines.append(f"| {p['distance']:.4f} | {p['left']} | {p['right']} |")
    lines.append("")
    lines.append("## Cross-Channel Pairs")
    lines.append("")
    lines.append("| distance | left | right |")
    lines.append("|---:|---|---|")
    for p in negatives:
        lines.append(f"| {p['distance']:.4f} | {p['left']} | {p['right']} |")
    OUT_MD.write_text("\n".join(lines) + "\n")


def main():
    records = load_records()
    if len(records) != 15:
        raise SystemExit(f"expected 15 JSON files, found {len(records)}")
    pairs = make_pairs(records)
    positive_distances = [p["distance"] for p in pairs if p["population"] == "P"]
    negative_distances = [p["distance"] for p in pairs if p["population"] == "N"]
    stats = {
        "P": population_stats(positive_distances),
        "N": population_stats(negative_distances),
    }
    sweep = tau_sweep(positive_distances, negative_distances)
    result = {
        "recordCount": len(records),
        "records": [{k: v for k, v in r.items() if k != "embedding"} for r in records],
        "pairCount": len(pairs),
        "positivePairCount": len(positive_distances),
        "negativePairCount": len(negative_distances),
        "populationStats": stats,
        "pairs": pairs,
        "tauSweep": sweep,
    }
    OUT_JSON.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    write_markdown(records, pairs, stats, sweep)
    print(f"records={len(records)} P={len(positive_distances)} N={len(negative_distances)}")
    print(
        "P p50={:.4f} range={:.4f}-{:.4f}".format(
            stats["P"]["p50"], stats["P"]["min"], stats["P"]["max"]
        )
    )
    print(
        "N p50={:.4f} range={:.4f}-{:.4f}".format(
            stats["N"]["p50"], stats["N"]["min"], stats["N"]["max"]
        )
    )


if __name__ == "__main__":
    main()
