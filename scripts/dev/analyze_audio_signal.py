#!/usr/bin/env python3
"""Measure decoded local audio without transcription, downmixing, or playback."""

import argparse
import array
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


def dbfs(value):
    return 20 * math.log10(value) if value > 0 else None


def analyze(path, timeout_seconds=300):
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("timeout must be a positive, finite number of seconds")
    path = Path(path).resolve(strict=True)
    if not path.is_file():
        raise ValueError("input must be a local regular file")
    metadata = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
        "-select_streams", "a:0", "-show_entries",
        "stream=codec_name,sample_rate,channels,duration", "-of", "json", str(path),
    ], stderr=subprocess.DEVNULL, timeout=min(30, timeout_seconds)))
    if not metadata.get("streams"):
        raise ValueError("input has no audio stream")
    stream = metadata["streams"][0]
    sample_rate = int(stream["sample_rate"])
    channels = int(stream["channels"])
    if sample_rate <= 0 or channels <= 0:
        raise ValueError("invalid audio format")

    frames = zero_frames = longest_zero_run = zero_run = 0
    sum_squares = peak = 0.0
    windows = []
    window_frames = window_zero_frames = 0
    window_sum_squares = window_peak = 0.0

    def finish_window():
        nonlocal window_frames, window_zero_frames, window_sum_squares, window_peak
        if not window_frames:
            return
        windows.append({
            "start_seconds": (frames - window_frames) / sample_rate,
            "frames": window_frames,
            "exact_zero_frames": window_zero_frames,
            "rms_dbfs": dbfs(math.sqrt(window_sum_squares / (window_frames * channels))),
            "peak_dbfs": dbfs(window_peak),
        })
        window_frames = window_zero_frames = 0
        window_sum_squares = window_peak = 0.0

    # PCM stays in bounded blocks. The result retains only one scalar summary
    # per second. All channels contribute; inverse stereo must not cancel.
    with tempfile.TemporaryFile() as errors:
        with subprocess.Popen([
            "ffmpeg", "-nostdin", "-v", "error", "-xerror",
            "-protocol_whitelist", "file,pipe", "-i", str(path),
            "-map", "0:a:0", "-f", "f32le", "-acodec", "pcm_f32le", "-",
        ], stdout=subprocess.PIPE, stderr=errors) as decoder:
            deadline_expired = threading.Event()

            def expire():
                deadline_expired.set()
                decoder.kill()

            # Killing the child closes its pipe even when read() is blocked.
            # A timeout on wait() alone cannot bound that read.
            deadline = threading.Timer(timeout_seconds, expire)
            deadline.daemon = True
            deadline.start()
            try:
                while block := decoder.stdout.read(4096 * channels * 4):
                    if len(block) % (channels * 4):
                        raise ValueError("decoder returned an incomplete PCM frame")
                    samples = array.array("f")
                    samples.frombytes(block)
                    if sys.byteorder != "little":
                        samples.byteswap()
                    for offset in range(0, len(samples), channels):
                        frame_peak = frame_power = 0.0
                        for channel in range(channels):
                            sample = samples[offset + channel]
                            if not math.isfinite(sample):
                                raise ValueError("decoded audio contains non-finite samples")
                            frame_peak = max(frame_peak, abs(sample))
                            frame_power += sample * sample
                        frames += 1
                        window_frames += 1
                        sum_squares += frame_power
                        window_sum_squares += frame_power
                        peak = max(peak, frame_peak)
                        window_peak = max(window_peak, frame_peak)
                        if frame_peak == 0:
                            zero_frames += 1
                            window_zero_frames += 1
                            zero_run += 1
                            longest_zero_run = max(longest_zero_run, zero_run)
                        else:
                            zero_run = 0
                        if window_frames == sample_rate:
                            finish_window()
                returncode = decoder.wait()
            except BaseException:
                decoder.kill()
                decoder.wait()
                raise
            finally:
                deadline.cancel()
                deadline.join()
            if deadline_expired.is_set():
                raise ValueError("audio decoding deadline exceeded; no measurements accepted")
            if returncode != 0:
                raise ValueError("audio decoding failed; no measurements accepted")
    if not frames:
        raise ValueError("decoder produced no audio frames")
    finish_window()
    return {
        "schema_version": 1,
        "measurement": "decoded_pcm_not_capture_health",
        "codec": stream["codec_name"],
        "sample_rate_hz": sample_rate,
        "channels": channels,
        "decoded_frames": frames,
        "decoded_duration_seconds": frames / sample_rate,
        "exact_zero_frames": zero_frames,
        "longest_exact_zero_run_seconds": longest_zero_run / sample_rate,
        "rms_dbfs": dbfs(math.sqrt(sum_squares / (frames * channels))),
        "peak_dbfs": dbfs(peak),
        "windows": windows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio_file", type=Path)
    parser.add_argument(
        "--timeout-seconds", type=float, default=300,
        help="decoder deadline (default: 300); probing is limited to at most 30 seconds",
    )
    args = parser.parse_args()
    try:
        result = analyze(args.audio_file, timeout_seconds=args.timeout_seconds)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Audio analysis failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
