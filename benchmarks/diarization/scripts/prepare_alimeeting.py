#!/usr/bin/env python3
"""Stream the official 8.90GiB AliMeeting Test archive without storing it.

Requires ffmpeg and textgrid==1.6.1. Extracts channel 1 from the far array and
mixes ALL participant headsets at their common recording origin for near speech; individual headset WAVs
exist only temporarily. Writes original TextGrids, complete-duration UEMs, and
provenance hashes. No tar paths are extracted directly. Expect ~2.4GB final
mono PCM, plus <=300MB temporary headset audio; network transfer is still9GB.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import shutil
import subprocess
import tarfile
import urllib.request
import wave
from pathlib import Path, PurePosixPath

from prepare_ami import sha256
from score_diarization import json_to_rttm, load_manifest

DEFAULT_MANIFEST = Path(__file__).resolve().parent.parent / "manifests" / "alimeeting-test.json"


class HashingReader:
    def __init__(self, source):
        self.source = source
        self.digest = hashlib.sha256()
        self.count = 0

    def read(self, size=-1):
        data = self.source.read(size)
        self.digest.update(data)
        self.count += len(data)
        return data


def duration(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getframerate() != 16000 or source.getsampwidth() != 2:
            raise ValueError(f"Expected 16kHz mono PCM16: {path}")
        return source.getnframes() / source.getframerate()


def convert_stream(source, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".part.wav")
    command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", "pipe:0",
               "-af", "pan=mono|c0=c0", "-ar", "16000", "-c:a", "pcm_s16le", str(temporary)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        try:
            shutil.copyfileobj(source, process.stdin, length=1024 * 1024)
        finally:
            process.stdin.close()
        error = process.stderr.read().decode()
        if process.wait() != 0:
            raise RuntimeError(f"ffmpeg failed: {error}")
        duration(temporary)
        temporary.replace(destination)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stderr.close()
        temporary.unlink(missing_ok=True)


def mix_headsets(paths: list[Path], destination: Path) -> None:
    if len(paths) < 2:
        raise ValueError("Near meeting mix must contain every participant, not a single headset")
    # Official Test headsets can stop at different times (M8023 differs by
    # 158ms). Preserve the longest recording, padding ended channels with
    # silence and retaining the fixed 1/N gain instead of renormalizing.
    for path in paths:
        duration(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".part.wav")
    command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
    for path in paths:
        command.extend(["-i", str(path)])
    command.extend(["-filter_complex", f"amix=inputs={len(paths)}:duration=longest:normalize=0,volume={1/len(paths):.17g}",
                    "-ar", "16000", "-c:a", "pcm_s16le", str(temporary)])
    try:
        subprocess.run(command, check=True, capture_output=True)
        duration(temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def textgrid_segments(path: Path, speaker_id: str | None = None) -> list[dict]:
    # Use the same established parser as Alibaba's preparation recipe, rather
    # than silently dropping multiline or escaped TextGrid intervals.
    import textgrid
    grid = textgrid.TextGrid.fromFile(str(path))
    if speaker_id is not None and len(grid) != 1:
        raise ValueError(f"Expected one participant tier in headset annotation: {path}")
    result = []
    for tier in grid:
        if not isinstance(tier, textgrid.IntervalTier):
            raise ValueError(f"Unexpected non-interval tier in {path}: {tier.name}")
        for interval in tier:
            if interval.mark.strip():
                result.append({"speakerId": speaker_id or tier.name, "startMs": interval.minTime * 1000,
                               "endMs": interval.maxTime * 1000})
    if not result:
        raise ValueError(f"Empty reference speech in {path}")
    return result


def prepare(source, records: list[dict], root: Path) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    expected = {member: row for row in records for member in row["audioMembers"]}
    seen_audio, seen_annotations = set(), {}
    metadata = {row["id"]: {"id": row["id"], "channelSelection": row["channelSelection"], "inputs": []}
                for row in records}
    reader = HashingReader(source)
    with tarfile.open(fileobj=reader, mode="r|gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            path = PurePosixPath(member.name)
            name = str(path)
            if name in expected:
                if name in seen_audio:
                    raise ValueError(f"Duplicate archive member: {name}")
                seen_audio.add(name)
                row = expected[name]
                recording_id = row["id"]
                source_file = archive.extractfile(member)
                destination = (root / "audio" / (recording_id + ".wav") if row["condition"] == "far"
                               else root / "headset-scratch" / path.name)
                hashed_audio = HashingReader(source_file)
                convert_stream(hashed_audio, destination)
                metadata[recording_id]["inputs"].append({"member": name, "sha256": hashed_audio.digest.hexdigest(),
                                                        "bytes": hashed_audio.count,
                                                        "durationSeconds": duration(destination)})
                if row["condition"] == "near" and all(item in seen_audio for item in row["audioMembers"]):
                    inputs = [root / "headset-scratch" / PurePosixPath(item).name for item in row["audioMembers"]]
                    destination = root / "audio" / (recording_id + ".wav")
                    mix_headsets(inputs, destination)
                    for item in inputs:
                        item.unlink()  # Only temporary files created by this acquisition.
                if destination.parent.name == "audio":
                    metadata[recording_id].update({"sha256": sha256(destination), "bytes": destination.stat().st_size,
                                                   "durationSeconds": duration(destination)})
                    meta_path = root / "audio-metadata" / (recording_id + ".json")
                    meta_path.parent.mkdir(parents=True, exist_ok=True)
                    meta_path.write_text(json.dumps(metadata[recording_id], indent=2) + "\n")
                    print(f"ready {recording_id}: {destination}", flush=True)
            elif "textgrid_dir" in path.parts and path.suffix.lower() == ".textgrid":
                condition = "far" if "Test_Ali_far" in path.parts else "near" if "Test_Ali_near" in path.parts else None
                if condition is None:
                    raise ValueError(f"Unexpected annotation condition: {name}")
                meeting_id = path.stem[:11]
                recording_id = f"ali_{meeting_id}_{condition}"
                if recording_id not in metadata:
                    raise ValueError(f"Unexpected Test annotation: {name}")
                annotation = root / "annotations" / condition / path.name
                annotation.parent.mkdir(parents=True, exist_ok=True)
                annotation.write_bytes(archive.extractfile(member).read())
                seen_annotations.setdefault(recording_id, []).append(annotation)
            elif path.suffix.lower() == ".wav":
                raise ValueError(f"Unexpected Test audio absent from frozen manifest: {name}")
    # Consume gzip footer / any remaining response bytes so the archive hash
    # describes the whole transfer, not only bytes requested by tar iteration.
    while reader.read(1024 * 1024):
        pass
    if seen_audio != set(expected):
        raise ValueError(f"Archive missing expected audio: {sorted(set(expected) - seen_audio)}")
    for row in records:
        recording_id = row["id"]
        annotations = seen_annotations.get(recording_id, [])
        if not annotations:
            raise ValueError(f"No original TextGrid references for {recording_id}")
        segments = reference_segments(row, annotations)
        reference_root = root / "references"
        reference_root.mkdir(parents=True, exist_ok=True)
        reference = reference_root / (recording_id + ".rttm")
        reference.write_text(json_to_rttm({"segments": segments}, row["referenceId"]))
        end = metadata[recording_id]["durationSeconds"]
        if max(segment["endMs"] for segment in segments) / 1000 > end + 0.02:
            raise ValueError(f"Reference speech extends beyond audio for {recording_id}")
        (reference_root / (recording_id + ".uem")).write_text(f"{row['referenceId']} 1 0.000000 {end:.6f}\n")
        metadata[recording_id]["annotations"] = [{"file": str(path.relative_to(root)), "sha256": sha256(path)} for path in annotations]
        metadata[recording_id]["referenceSHA256"] = sha256(reference)
    return {"archiveSHA256": reader.digest.hexdigest(), "archiveBytes": reader.count, "recordings": metadata}


def reference_segments(row: dict, annotations: list[Path]) -> list[dict]:
    segments = []
    expected_headsets = {PurePosixPath(member).stem for member in row["audioMembers"]}
    for annotation in annotations:
        speaker_id = None
        if row["condition"] == "near":
            # Each headset TextGrid calls its only tier "c1". Identity comes
            # from that participant's filename; retaining c1 would merge all
            # near-reference speakers into one and invalidate the comparison.
            if annotation.stem not in expected_headsets:
                raise ValueError(f"Unmapped headset annotation: {annotation}")
            speaker_id = annotation.stem.removeprefix(row["meetingId"] + "_")
        segments.extend(textgrid_segments(annotation, speaker_id=speaker_id))
    if row["condition"] == "near" and {path.stem for path in annotations} != expected_headsets:
        raise ValueError(f"Missing participant annotation for {row['id']}")
    return segments


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--archive", type=Path, help="Use an already-owned local Test_Ali.tar.gz instead of HTTP")
    args = parser.parse_args()
    try:
        import textgrid  # noqa: F401
    except ImportError:
        parser.error("Install textgrid==1.6.1 in an isolated venv before acquisition")
    if importlib.metadata.version("TextGrid") != "1.6.1":
        parser.error("Use the pinned textgrid==1.6.1 reference parser")
    manifest = json.loads(args.manifest.read_text())
    records = load_manifest(args.manifest)
    # Never overwrite a previous run's audio or partial extraction silently.
    if args.root.exists() and any(args.root.iterdir()):
        parser.error("--root must be empty; use a fresh scratch directory for reproducible acquisition")
    source_info = manifest["archive"]
    ffmpeg_version = subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0]
    if args.archive:
        with args.archive.open("rb") as source:
            evidence = prepare(source, records, args.root)
    else:
        with urllib.request.urlopen(source_info["url"], timeout=120) as source:
            if int(source.headers["Content-Length"]) != source_info["bytes"] or source.headers.get("ETag", "").strip('"') != source_info["etag"]:
                raise ValueError("Official archive metadata changed; inspect and update the frozen manifest before downloading")
            evidence = prepare(source, records, args.root)
    if evidence["archiveBytes"] != source_info["bytes"]:
        raise ValueError("Incomplete official archive transfer")
    evidence.update({"source": source_info, "manifestSHA256": sha256(args.manifest), "ffmpegVersion": ffmpeg_version,
                     "textgridVersion": "1.6.1"})
    (args.root / "acquisition.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(args.root / "acquisition.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
