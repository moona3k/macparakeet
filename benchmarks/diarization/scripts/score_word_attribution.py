#!/usr/bin/env python3
"""Word-level speaker attribution of saved diarization runs, on the app's ASR words.

Reference turns are the RTTM intervals with touching or overlapping intervals of
the same speaker merged. Each ASR word belongs to the turn that holds its
midpoint, and a turn's length is the number of ASR words it holds. A word is
scored when it lies inside the UEM, its midpoint falls in a reference turn, and
that turn's speaker is the only reference speaker it touches; other words are
skipped. Word text is never compared with the reference, so ASR recognition
errors stay in.

Predicted segments are assigned to words by a copy of the app's SpeakerMerger,
under three policies: `raw` (no smoothing), `app` (the merger as shipped: fill
gaps and merge one-word flips) and `keep` (fill gaps only, to measure what the
one-word merge costs). Predicted speakers map one-to-one to reference speakers
by maximum agreement on the scored words of the `raw` assignment, and that one
mapping scores every policy, so policies differ only by the words they change.
A nil or unmapped word counts as wrong.
Accuracy is reported by reference turn length, because one-word turns are the
replies that smoothing can erase (#1046). Spurious switches count consecutive
scored words of one reference turn that received different predicted speakers.

This is not DER or cpWER. No audio, inference, downloads, or third-party Python
packages are needed.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import json
from dataclasses import dataclass
from pathlib import Path

POLICIES = ("raw", "app", "keep")
BUCKETS = ("1", "2", "3-5", "6+", "all")


@dataclass(frozen=True)
class Turn:
    start: int
    end: int
    speaker: str


@dataclass(frozen=True)
class Label:
    """A scored word: its reference speaker, turn index and turn length in ASR words."""
    speaker: str
    turn: int
    turn_words: int


def read_rttm(path: Path) -> list[Turn]:
    turns = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == "SPEAKER":
            start = round(float(fields[3]) * 1000)
            turns.append(Turn(start, start + round(float(fields[4]) * 1000), fields[7]))
    return merge_turns(turns)


def merge_turns(turns: list[Turn]) -> list[Turn]:
    """Merges touching or overlapping intervals of the same speaker."""
    by_speaker = collections.defaultdict(list)
    for turn in turns:
        by_speaker[turn.speaker].append(turn)
    merged = []
    for speaker, own in by_speaker.items():
        own.sort(key=lambda t: t.start)
        current = own[0]
        for turn in own[1:]:
            if turn.start <= current.end:
                current = Turn(current.start, max(current.end, turn.end), speaker)
            else:
                merged.append(current)
                current = turn
        merged.append(current)
    return sorted(merged, key=lambda t: (t.start, t.speaker))


def read_uem(path: Path) -> list[tuple[int, int]]:
    regions = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 4:
            regions.append((round(float(fields[2]) * 1000), round(float(fields[3]) * 1000)))
    return regions


def label_words(words: list[dict], turns: list[Turn], uem: list[tuple[int, int]]) -> list[Label | None]:
    """Reference label of each word, or None when it is not scored."""
    starts = [turn.start for turn in turns]
    longest = max((turn.end - turn.start for turn in turns), default=0)

    def nearby(start: float, end: float) -> range:
        return range(bisect.bisect_left(starts, start - longest), bisect.bisect_right(starts, end))

    holder = []
    for word in words:
        mid = (word["startMs"] + word["endMs"]) / 2
        holder.append(next((i for i in nearby(mid, mid) if turns[i].start <= mid < turns[i].end), None))
    turn_words = collections.Counter(index for index in holder if index is not None)

    labels = []
    for word, index in zip(words, holder, strict=True):
        start, end = word["startMs"], word["endMs"]
        inside = any(lo <= start and end <= hi for lo, hi in uem)
        speakers = {turns[i].speaker for i in nearby(start, end) if turns[i].start < end and start < turns[i].end}
        if inside and index is not None and speakers == {turns[index].speaker}:
            labels.append(Label(turns[index].speaker, index, turn_words[index]))
        else:
            labels.append(None)
    return labels


def merge(words: list[dict], segments: list[dict], policy: str) -> list[str | None]:
    """Mirror of SpeakerMerger.mergeWordTimestampsWithSpeakers."""
    if not words or not segments:
        return [word.get("speakerId") for word in words]
    ordered = sorted(segments, key=lambda s: s["startMs"])
    assigned, index = [], 0
    for word in words:
        while index < len(ordered) and ordered[index]["endMs"] <= word["startMs"]:
            index += 1
        best, best_overlap, cursor = None, 0, index
        while cursor < len(ordered) and ordered[cursor]["startMs"] < word["endMs"]:
            overlap = min(word["endMs"], ordered[cursor]["endMs"]) - max(word["startMs"], ordered[cursor]["startMs"])
            if overlap > best_overlap:
                best, best_overlap = ordered[cursor]["speakerId"], overlap
            cursor += 1
        assigned.append(best if best_overlap > 0 else word.get("speakerId"))
    if policy == "raw" or len(assigned) < 3:
        return assigned
    smoothed, start = list(assigned), 0
    while start < len(assigned):
        end = start + 1
        while end < len(assigned) and assigned[end] == assigned[start]:
            end += 1
        previous = assigned[start - 1] if start > 0 else None
        following = assigned[end] if end < len(assigned) else None
        if previous is not None and previous == following:
            run = assigned[start]
            if run is None or (policy == "app" and end - start == 1 and run != previous):
                smoothed[start:end] = [previous] * (end - start)
        start = end
    return smoothed


def best_mapping(agreement: dict[tuple[str, str], int]) -> dict[str, str]:
    """One-to-one predicted -> reference mapping that maximizes total agreement (Hungarian)."""
    predicted = sorted({pred for pred, _ in agreement})
    reference = sorted({ref for _, ref in agreement})
    size = max(len(predicted), len(reference))
    if size == 0:
        return {}
    top = max(agreement.values())
    cost = [[top - agreement.get((predicted[r], reference[c]), 0)
             if r < len(predicted) and c < len(reference) else top
             for c in range(size)] for r in range(size)]
    u, v, match, way = [0] * (size + 1), [0] * (size + 1), [0] * (size + 1), [0] * (size + 1)
    for row in range(1, size + 1):
        match[0], column = row, 0
        least, used = [float("inf")] * (size + 1), [False] * (size + 1)
        while True:
            used[column] = True
            current, delta, nxt = match[column], float("inf"), 0
            for c in range(1, size + 1):
                if not used[c]:
                    reduced = cost[current - 1][c - 1] - u[current] - v[c]
                    if reduced < least[c]:
                        least[c], way[c] = reduced, column
                    if least[c] < delta:
                        delta, nxt = least[c], c
            for c in range(size + 1):
                if used[c]:
                    u[match[c]] += delta
                    v[c] -= delta
                else:
                    least[c] -= delta
            column = nxt
            if match[column] == 0:
                break
        while column:
            previous = way[column]
            match[column], column = match[previous], previous
    return {
        predicted[match[c] - 1]: reference[c - 1]
        for c in range(1, size + 1)
        if match[c] - 1 < len(predicted) and c - 1 < len(reference)
        and agreement.get((predicted[match[c] - 1], reference[c - 1]), 0) > 0
    }


def bucket(length: int) -> str:
    return "1" if length == 1 else "2" if length == 2 else "3-5" if length <= 5 else "6+"


def speaker_mapping(labels: list[Label | None], predicted: list[str | None]) -> dict[str, str]:
    return best_mapping(collections.Counter(
        (pred, label.speaker) for label, pred in zip(labels, predicted, strict=True) if label and pred is not None
    ))


def score(labels: list[Label | None], predicted: list[str | None], mapping: dict[str, str] | None = None) -> dict:
    """Scores `predicted`; `mapping` defaults to the best one for `predicted` itself."""
    scored = [(i, label, pred) for i, (label, pred) in enumerate(zip(labels, predicted, strict=True)) if label]
    if mapping is None:
        mapping = speaker_mapping(labels, predicted)
    totals, correct = collections.Counter(), collections.Counter()
    for _, label, pred in scored:
        hit = mapping.get(pred) == label.speaker
        for name in (bucket(label.turn_words), "all"):
            totals[name] += 1
            correct[name] += hit
    spurious = sum(
        1 for (i, a, pa), (j, b, pb) in zip(scored, scored[1:])
        if j == i + 1 and a.turn == b.turn and pa is not None and pb is not None and pa != pb
    )
    return {"words": totals, "correct": correct, "nil": sum(pred is None for _, _, pred in scored), "spurious": spurious}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--condition", default="mhm")
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--asr-root", type=Path, required=True,
                        help="macparakeet-cli JSON per recording id, with wordTimestamps")
    parser.add_argument("--predictions", action="append", required=True, metavar="BACKEND=DIRECTORY")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    records = [r for r in json.loads(args.manifest.read_text())["recordings"] if r["condition"] == args.condition]
    if not records:
        parser.error(f"no {args.condition} recordings in {args.manifest}")
    report = {}
    print(f"{'backend':24} {'policy':6} " + " ".join(f"{name:>7}" for name in BUCKETS) + f" {'nil%':>6} {'spur/1k':>8}")
    for value in args.predictions:
        name, directory = value.split("=", 1)
        sums = {policy: collections.Counter() for policy in POLICIES}
        for record in records:
            rid = record["id"]
            words = sorted(
                (w for w in json.loads((args.asr_root / f"{rid}.json").read_text())["wordTimestamps"]
                 if w["endMs"] > w["startMs"]),
                key=lambda w: w["startMs"])
            labels = label_words(words, read_rttm(args.reference_root / f"{rid}.rttm"),
                                 read_uem(args.reference_root / f"{rid}.uem"))
            segments = json.loads((Path(directory) / f"{rid}.json").read_text())["segments"]
            mapping = speaker_mapping(labels, merge(words, segments, "raw"))
            for policy in POLICIES:
                result = score(labels, merge(words, segments, policy), mapping)
                sums[policy].update({f"words:{k}": v for k, v in result["words"].items()})
                sums[policy].update({f"correct:{k}": v for k, v in result["correct"].items()})
                sums[policy].update(nil=result["nil"], spurious=result["spurious"])
        report[name] = {}
        for policy in POLICIES:
            total = sums[policy]
            words = total["words:all"]
            if not words:
                report[name][policy] = {"scoredWords": 0}
                print(f"{name:24} {policy:6} no scored words")
                continue
            accuracy = {b: 100 * total[f"correct:{b}"] / total[f"words:{b}"] for b in BUCKETS if total[f"words:{b}"]}
            report[name][policy] = {
                "scoredWords": words,
                "accuracyPercentByReferenceTurnWords": accuracy,
                "wordsByReferenceTurnWords": {b: total[f"words:{b}"] for b in BUCKETS},
                "nilPercent": 100 * total["nil"] / words,
                "spuriousSwitchesPer1000Words": 1000 * total["spurious"] / words,
            }
            print(f"{name:24} {policy:6} " + " ".join(f"{accuracy.get(b, 0):7.1f}" for b in BUCKETS)
                  + f" {100 * total['nil'] / words:6.2f} {1000 * total['spurious'] / words:8.2f}")
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
