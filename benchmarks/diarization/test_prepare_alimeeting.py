#!/usr/bin/env python3
"""Small real tar/ffmpeg/TextGrid test of the bounded official-data importer."""
from __future__ import annotations

import array
import importlib.util
import io
import shutil
import sys
import tarfile
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from prepare_alimeeting import mix_headsets, prepare


def wav_bytes(channels: int, values: tuple[int, ...]) -> bytes:
    result = io.BytesIO()
    with wave.open(result, "wb") as target:
        target.setnchannels(channels)
        target.setsampwidth(2)
        target.setframerate(16000)
        target.writeframes(array.array("h", values * 16000).tobytes())
    return result.getvalue()


GRID = '''File type = "ooTextFile"
Object class = "TextGrid"

xmin = 0
xmax = 1
tiers? <exists>
size = 1
item []:
    item [1]:
        class = "IntervalTier"
        name = "SPK1"
        xmin = 0
        xmax = 1
        intervals: size = 2
        intervals [1]:
            xmin = 0
            xmax = 0.5
            text = "speech"
        intervals [2]:
            xmin = 0.5
            xmax = 1
            text = ""
'''.encode()


@unittest.skipUnless(shutil.which("ffmpeg") and importlib.util.find_spec("textgrid"), "Requires ffmpeg and textgrid==1.6.1")
class StreamingAcquisitionTests(unittest.TestCase):
    def fixture(self, omit_last=False):
        sid = "R8002_M8002"
        far = f"Test_Ali/Test_Ali_far/audio_dir/{sid}_MS802.wav"
        near = [f"Test_Ali/Test_Ali_near/audio_dir/{sid}_N_SPK{i}.wav" for i in (1, 2)]
        records = [{"id": f"ali_{sid}_{condition}", "meetingId": sid, "referenceId": sid,
                    "condition": condition, "channelSelection": condition,
                    "audioMembers": [far] if condition == "far" else near} for condition in ("far", "near")]
        members = [(far, wav_bytes(2, (100, 300))), (near[0], wav_bytes(1, (200,)))]
        if not omit_last:
            members.append((near[1], wav_bytes(1, (400,))))
        members.append((f"Test_Ali/Test_Ali_far/textgrid_dir/{sid}.TextGrid", GRID))
        for member in near:
            name = Path(member).stem
            members.append((f"Test_Ali/Test_Ali_near/textgrid_dir/{name}.TextGrid", GRID.replace(b'SPK1', b'c1')))
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as target:
            for name, content in members:
                header = tarfile.TarInfo(name)
                header.size = len(content)
                target.addfile(header, io.BytesIO(content))
        archive.seek(0)
        return archive, records

    def test_channel_one_headset_mix_and_full_duration_uem(self):
        archive, records = self.fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = prepare(archive, records, root)
            self.assertEqual(evidence["archiveBytes"], len(archive.getvalue()))
            for condition, value in (("far", 100), ("near", 300)):
                recording_id = f"ali_R8002_M8002_{condition}"
                with wave.open(str(root / "audio" / (recording_id + ".wav"))) as audio:
                    samples = array.array("h", audio.readframes(16000))
                self.assertTrue(all(sample == value for sample in samples))
                # Last reference speech ends0.5sec, but scoring retains1sec.
                self.assertEqual((root / "references" / (recording_id + ".uem")).read_text(), "R8002_M8002 1 0.000000 1.000000\n")
                self.assertEqual(len(evidence["recordings"][recording_id]["annotations"]), 1 if condition == "far" else 2)
                speakers = {line.split()[7] for line in (root / "references" / (recording_id + ".rttm")).read_text().splitlines()}
                self.assertEqual(speakers, {"SPK1"} if condition == "far" else {"N_SPK1", "N_SPK2"})
            self.assertEqual(list((root / "headset-scratch").glob("*.wav")), [])

    def test_missing_participant_is_not_silently_evaluated_as_near_meeting(self):
        archive, records = self.fixture(omit_last=True)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "missing expected audio"):
                prepare(archive, records, Path(temporary))

    def test_headsets_with_different_end_times_keep_full_duration_and_fixed_gain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second, mixed = [root / name for name in ("first.wav", "second.wav", "mixed.wav")]
            first.write_bytes(wav_bytes(1, (200,)))
            with wave.open(str(second), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(array.array("h", [400] * 32000).tobytes())
            mix_headsets([first, second], mixed)
            with wave.open(str(mixed)) as audio:
                self.assertEqual(audio.getnframes(), 32000)
                samples = array.array("h", audio.readframes(32000))
            self.assertTrue(all(value == 300 for value in samples[:16000]))
            self.assertTrue(all(value == 200 for value in samples[16000:]))


if __name__ == "__main__":
    unittest.main()
