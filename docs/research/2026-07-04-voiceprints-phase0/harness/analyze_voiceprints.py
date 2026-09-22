#!/usr/bin/env python3
"""Analyze MacParakeet voiceprint phase-0 extraction JSON.

The script intentionally reads only harness JSON: session IDs, track names,
durations, speaker IDs, speech totals, and embeddings. It never reads audio or
transcript artifacts.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import statistics
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class SpeakerEmbedding:
    session_id: str
    track: str
    speaker_id: str
    embedding: list[float]
    total_speech_sec: float
    source: str
    half: str | None = None


def l2_normalized(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        return vector
    return [value / norm for value in vector]


def cosine_distance(lhs: list[float], rhs: list[float]) -> float:
    a = l2_normalized(lhs)
    b = l2_normalized(rhs)
    dot = sum(x * y for x, y in zip(a, b))
    dot = max(-1.0, min(1.0, dot))
    return 1.0 - dot


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * pct / 100.0
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    frac = pos - lo
    return ordered[lo] * (1 - frac) + ordered[hi] * frac


def stats(values: list[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "min": min(values) if values else None,
        "p5": percentile(values, 5),
        "p25": percentile(values, 25),
        "p50": percentile(values, 50),
        "p75": percentile(values, 75),
        "p95": percentile(values, 95),
        "max": max(values) if values else None,
        "mean": statistics.fmean(values) if values else None,
    }


def load_full(data_dir: Path) -> list[SpeakerEmbedding]:
    speakers: list[SpeakerEmbedding] = []
    for path in sorted(data_dir.glob("*-full.json")):
        payload = json.loads(path.read_text())
        for speaker in payload["speakers"]:
            speakers.append(
                SpeakerEmbedding(
                    session_id=payload["sessionID"],
                    track=payload["track"],
                    speaker_id=speaker["speakerId"],
                    embedding=speaker["embedding"],
                    total_speech_sec=speaker["totalSpeechSec"],
                    source=path.name,
                )
            )
    return speakers


def load_split(data_dir: Path) -> list[SpeakerEmbedding]:
    speakers: list[SpeakerEmbedding] = []
    for path in sorted(data_dir.glob("*-split.json")):
        payload = json.loads(path.read_text())
        for half in payload["halves"]:
            for speaker in half["speakers"]:
                speakers.append(
                    SpeakerEmbedding(
                        session_id=payload["sessionID"],
                        track=payload["track"],
                        speaker_id=speaker["speakerId"],
                        embedding=speaker["embedding"],
                        total_speech_sec=speaker["totalSpeechSec"],
                        source=path.name,
                        half=half["half"],
                    )
                )
    return speakers


def pair_record(
    label: str, lhs: SpeakerEmbedding, rhs: SpeakerEmbedding
) -> dict[str, object]:
    return {
        "population": label,
        "distance": cosine_distance(lhs.embedding, rhs.embedding),
        "lhs": {
            "sessionID": lhs.session_id,
            "track": lhs.track,
            "speakerId": lhs.speaker_id,
            "half": lhs.half,
            "source": lhs.source,
            "totalSpeechSec": lhs.total_speech_sec,
        },
        "rhs": {
            "sessionID": rhs.session_id,
            "track": rhs.track,
            "speakerId": rhs.speaker_id,
            "half": rhs.half,
            "source": rhs.source,
            "totalSpeechSec": rhs.total_speech_sec,
        },
    }


def greedy_nearest_pairs(
    first: list[SpeakerEmbedding], second: list[SpeakerEmbedding], label: str
) -> list[dict[str, object]]:
    candidates: list[tuple[float, int, int]] = []
    for i, lhs in enumerate(first):
        for j, rhs in enumerate(second):
            candidates.append((cosine_distance(lhs.embedding, rhs.embedding), i, j))
    candidates.sort(key=lambda item: item[0])

    used_first: set[int] = set()
    used_second: set[int] = set()
    pairs: list[dict[str, object]] = []
    for distance, i, j in candidates:
        if i in used_first or j in used_second:
            continue
        used_first.add(i)
        used_second.add(j)
        record = pair_record(label, first[i], second[j])
        record["distance"] = distance
        record["pairing"] = "greedy-nearest"
        pairs.append(record)
    return pairs


def build_pair_populations(
    full: list[SpeakerEmbedding], split: list[SpeakerEmbedding]
) -> dict[str, list[dict[str, object]]]:
    mic_full = [speaker for speaker in full if speaker.track == "microphone"]
    system_full = [speaker for speaker in full if speaker.track == "system"]

    populations: dict[str, list[dict[str, object]]] = {
        "a_same_user_mic_cross_recording": [],
        "b_same_split_microphone": [],
        "b_same_split_system_nearest": [],
        "c_different_system_same_meeting": [],
        "d_random_system_cross_meeting": [],
    }

    for lhs, rhs in itertools.combinations(mic_full, 2):
        if lhs.session_id != rhs.session_id:
            populations["a_same_user_mic_cross_recording"].append(
                pair_record("a_same_user_mic_cross_recording", lhs, rhs)
            )

    for lhs, rhs in itertools.combinations(system_full, 2):
        if lhs.session_id == rhs.session_id:
            populations["c_different_system_same_meeting"].append(
                pair_record("c_different_system_same_meeting", lhs, rhs)
            )
        else:
            populations["d_random_system_cross_meeting"].append(
                pair_record("d_random_system_cross_meeting", lhs, rhs)
            )

    for session_id in sorted({speaker.session_id for speaker in split}):
        for track in ["microphone", "system"]:
            first = [
                speaker
                for speaker in split
                if speaker.session_id == session_id
                and speaker.track == track
                and speaker.half == "first"
            ]
            second = [
                speaker
                for speaker in split
                if speaker.session_id == session_id
                and speaker.track == track
                and speaker.half == "second"
            ]
            if track == "microphone":
                # The microphone channel is the only cross-recording same-speaker
                # ground truth: all detected mic clusters are treated as the app
                # user's voice, even when the diarizer over-clusters.
                for lhs in first:
                    for rhs in second:
                        populations["b_same_split_microphone"].append(
                            pair_record("b_same_split_microphone", lhs, rhs)
                        )
            else:
                populations["b_same_split_system_nearest"].extend(
                    greedy_nearest_pairs(first, second, "b_same_split_system_nearest")
                )

    return populations


def population_stats(populations: dict[str, list[dict[str, object]]]) -> dict[str, object]:
    return {
        name: stats([float(record["distance"]) for record in records])
        for name, records in populations.items()
    }


def overlap(populations: dict[str, list[dict[str, object]]]) -> dict[str, object]:
    same = [float(record["distance"]) for record in populations["a_same_user_mic_cross_recording"]]
    result: dict[str, object] = {}
    for name in ["c_different_system_same_meeting", "d_random_system_cross_meeting"]:
        diff = [float(record["distance"]) for record in populations[name]]
        if not same or not diff:
            result[name] = None
            continue
        same_max = max(same)
        diff_min = min(diff)
        same_p95 = percentile(same, 95)
        diff_p5 = percentile(diff, 5)
        result[name] = {
            "sameMax": same_max,
            "diffMin": diff_min,
            "rangeOverlap": diff_min <= same_max,
            "sameAtOrAboveDiffP5Fraction": sum(1 for value in same if value >= diff_p5) / len(same),
            "diffAtOrBelowSameP95Fraction": sum(1 for value in diff if value <= same_p95) / len(diff),
            "p95SameMinusP5Diff": (same_p95 - diff_p5) if same_p95 is not None and diff_p5 is not None else None,
        }
    return result


def pairwise_sweep(
    populations: dict[str, list[dict[str, object]]], step: float = 0.05
) -> list[dict[str, object]]:
    positives = [float(record["distance"]) for record in populations["a_same_user_mic_cross_recording"]]
    neg_same_meeting = [
        float(record["distance"]) for record in populations["c_different_system_same_meeting"]
    ]
    neg_cross_meeting = [
        float(record["distance"]) for record in populations["d_random_system_cross_meeting"]
    ]

    rows: list[dict[str, object]] = []
    tau = 0.0
    while tau <= 1.000001:
        rows.append(
            {
                "tau": round(tau, 2),
                "margin": 0.10,
                "pairwiseTPR_sameMic": (
                    sum(1 for value in positives if value <= tau) / len(positives)
                    if positives
                    else None
                ),
                "pairwiseFPR_systemSameMeeting": (
                    sum(1 for value in neg_same_meeting if value <= tau) / len(neg_same_meeting)
                    if neg_same_meeting
                    else None
                ),
                "pairwiseFPR_systemCrossMeeting": (
                    sum(1 for value in neg_cross_meeting if value <= tau) / len(neg_cross_meeting)
                    if neg_cross_meeting
                    else None
                ),
            }
        )
        tau += step
    return rows


def margin_proxy_sweep(
    full: list[SpeakerEmbedding], step: float = 0.05, margin: float = 0.10
) -> list[dict[str, object]]:
    """A user-profile proxy sweep.

    Positives: microphone query embedding matches nearest microphone reference
    from other sessions and must beat the nearest system embedding by margin.
    Negatives: system query falsely matches nearest microphone reference and
    must beat the nearest other-system embedding by margin.
    """

    mic = [speaker for speaker in full if speaker.track == "microphone"]
    system = [speaker for speaker in full if speaker.track == "system"]

    positive_trials: list[dict[str, float | bool]] = []
    for query in mic:
        same_refs = [speaker for speaker in mic if speaker.session_id != query.session_id]
        imposter_refs = system
        if not same_refs or not imposter_refs:
            continue
        same_dist = min(cosine_distance(query.embedding, ref.embedding) for ref in same_refs)
        imposter_dist = min(cosine_distance(query.embedding, ref.embedding) for ref in imposter_refs)
        positive_trials.append(
            {
                "targetDistance": same_dist,
                "marginDelta": imposter_dist - same_dist,
                "top1IsTarget": same_dist < imposter_dist,
            }
        )

    negative_trials: list[dict[str, float | bool]] = []
    for query in system:
        user_refs = mic
        competing_system = [
            speaker
            for speaker in system
            if not (
                speaker.session_id == query.session_id
                and speaker.speaker_id == query.speaker_id
                and speaker.source == query.source
            )
        ]
        if not user_refs or not competing_system:
            continue
        user_dist = min(cosine_distance(query.embedding, ref.embedding) for ref in user_refs)
        competitor_dist = min(
            cosine_distance(query.embedding, ref.embedding) for ref in competing_system
        )
        negative_trials.append(
            {
                "targetDistance": user_dist,
                "marginDelta": competitor_dist - user_dist,
                "top1IsTarget": user_dist < competitor_dist,
            }
        )

    rows: list[dict[str, object]] = []
    tau = 0.0
    while tau <= 1.000001:
        pos_pass = [
            trial
            for trial in positive_trials
            if trial["top1IsTarget"]
            and float(trial["targetDistance"]) <= tau
            and float(trial["marginDelta"]) >= margin
        ]
        neg_pass = [
            trial
            for trial in negative_trials
            if trial["top1IsTarget"]
            and float(trial["targetDistance"]) <= tau
            and float(trial["marginDelta"]) >= margin
        ]
        rows.append(
            {
                "tau": round(tau, 2),
                "margin": margin,
                "positiveTrials": len(positive_trials),
                "negativeTrials": len(negative_trials),
                "proxyTPR": len(pos_pass) / len(positive_trials) if positive_trials else None,
                "proxyFPR": len(neg_pass) / len(negative_trials) if negative_trials else None,
                "proxyPositivePass": len(pos_pass),
                "proxyFalsePositivePass": len(neg_pass),
            }
        )
        tau += step
    return rows


def embedding_counts(full: list[SpeakerEmbedding], split: list[SpeakerEmbedding]) -> dict[str, object]:
    full_counts: dict[str, dict[str, int]] = {}
    for speaker in full:
        full_counts.setdefault(speaker.session_id, {}).setdefault(speaker.track, 0)
        full_counts[speaker.session_id][speaker.track] += 1

    split_counts: dict[str, dict[str, dict[str, int]]] = {}
    for speaker in split:
        split_counts.setdefault(speaker.session_id, {}).setdefault(speaker.track, {}).setdefault(
            speaker.half or "unknown", 0
        )
        split_counts[speaker.session_id][speaker.track][speaker.half or "unknown"] += 1

    return {"full": full_counts, "split": split_counts}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--include-population-pairs",
        action="store_true",
        help="Include linkable per-session/per-speaker pair records. Keep this local.",
    )
    args = parser.parse_args()

    full = load_full(args.data_dir)
    split = load_split(args.data_dir)
    populations = build_pair_populations(full, split)

    sample_path = args.data_dir / "sample-sessions.json"
    sample = json.loads(sample_path.read_text()) if sample_path.exists() else {}

    output = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "dataDir": str(args.data_dir),
        "sample": sample,
        "embeddingCounts": embedding_counts(full, split),
        "populationStats": population_stats(populations),
        "overlap": overlap(populations),
        "pairwiseTauSweep": pairwise_sweep(populations),
        "marginProxyTauSweep": margin_proxy_sweep(full),
        "notes": [
            "Microphone clusters are treated as same-speaker because the microphone channel is the app-user ground truth, despite diarizer over-clustering.",
            "System split-half same-speaker pairs use greedy nearest-neighbor matching across halves because no participant labels are available.",
            "Margin proxy sweep is a user-profile proxy, not a fully labeled multi-profile speaker-identification evaluation.",
            "Detailed populationPairs records are omitted by default because they are linkable "
            "biometric meeting metadata; pass --include-population-pairs only for local analysis.",
        ],
    }
    if args.include_population_pairs:
        output["populationPairs"] = {
            name: records for name, records in populations.items()
        }

    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(json.dumps({k: output[k] for k in ["generatedAt", "populationStats", "overlap"]}, indent=2))


if __name__ == "__main__":
    main()
