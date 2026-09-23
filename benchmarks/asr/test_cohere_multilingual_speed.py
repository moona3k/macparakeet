#!/usr/bin/env python3
"""Focused tests for the pinned Cohere multilingual benchmark harness."""

from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path

import cohere_multilingual_speed as benchmark


ROOT = Path(__file__).resolve().parents[2]
RELEASE_MANIFEST = Path(__file__).with_name("cohere_transcribe_cpp_release.json")
RESULT = Path(__file__).parent / "results/cohere-transcribe-cpp-multilingual.json"
DIST_PINS = ROOT / "scripts/dist/transcribe_cpp_release_pins.sh"


class CohereMultilingualSpeedTests(unittest.TestCase):
    def test_release_manifest_matches_distribution_pins(self) -> None:
        manifest = benchmark.load_release_manifest(RELEASE_MANIFEST)
        pins = DIST_PINS.read_text(encoding="utf-8")

        def pin(name: str) -> str:
            match = re.search(rf'^{name}="([^"]+)"$', pins, re.MULTILINE)
            self.assertIsNotNone(match, name)
            return match.group(1)

        runtime = manifest["runtime"]
        model = manifest["model"]
        self.assertEqual(
            runtime["repository"],
            pin("TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY"),
        )
        self.assertEqual(runtime["commit"], pin("TRANSCRIBE_CPP_OWNED_FORK_COMMIT"))
        self.assertEqual(
            runtime["release_tag"],
            pin("TRANSCRIBE_CPP_OWNED_RELEASE_TAG"),
        )
        self.assertEqual(
            runtime["artifact_filename"],
            pin("TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME"),
        )
        self.assertEqual(
            runtime["artifact_sha256"],
            pin("TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256"),
        )
        self.assertEqual(
            model["repository"],
            pin("COHERE_TRANSCRIBE_MODEL_REPOSITORY"),
        )
        self.assertEqual(model["revision"], pin("COHERE_TRANSCRIBE_MODEL_REVISION"))
        self.assertEqual(model["filename"], pin("COHERE_TRANSCRIBE_MODEL_FILENAME"))
        self.assertEqual(
            model["size_bytes"],
            int(pin("COHERE_TRANSCRIBE_MODEL_SIZE_BYTES")),
        )
        self.assertEqual(model["sha256"], pin("COHERE_TRANSCRIBE_MODEL_SHA256"))

    def test_release_metadata_requires_matching_immutable_attestation(self) -> None:
        manifest = benchmark.load_release_manifest(RELEASE_MANIFEST)
        runtime = manifest["runtime"]
        release = {
            "isImmutable": True,
            "tagName": runtime["release_tag"],
            "targetCommitish": runtime["commit"],
            "url": runtime["release_url"],
            "assets": [
                {
                    "name": runtime["artifact_filename"],
                    "digest": f"sha256:{runtime['artifact_sha256']}",
                }
            ],
        }
        attestation = {
            "verificationResult": {
                "statement": {
                    "predicateType": runtime["attestation_predicate_type"],
                    "predicate": {
                        "repository": runtime["repository"],
                        "tag": runtime["release_tag"],
                    },
                    "subject": [
                        {
                            "uri": (
                                f"pkg:github/{runtime['repository']}"
                                f"@{runtime['release_tag']}"
                            ),
                            "digest": {
                                "sha1": runtime["commit"],
                            }
                        },
                        {
                            "name": runtime["artifact_filename"],
                            "digest": {
                                "sha256": runtime["artifact_sha256"],
                            },
                        },
                    ],
                }
            }
        }

        benchmark.validate_release_metadata(
            manifest,
            runtime["artifact_sha256"],
            release,
            attestation,
        )

        release["isImmutable"] = False
        with self.assertRaisesRegex(SystemExit, "not immutable"):
            benchmark.validate_release_metadata(
                manifest,
                runtime["artifact_sha256"],
                release,
                attestation,
            )

    def test_fixture_and_transcript_validation_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.wav"
            fixture.write_bytes(b"fixture")
            expected_text = "expected transcript"
            manifest = {
                "fixtures": {
                    "en": {
                        "id": "fixture/en.wav",
                        "sha256": benchmark.sha256_file(fixture),
                        "expected_transcript": expected_text,
                    }
                }
            }

            reference = benchmark.validate_fixture(manifest, "en", fixture)
            benchmark.validate_transcripts(
                "en",
                "cold",
                [expected_text],
                reference["expected_transcript"],
            )

            fixture.write_bytes(b"corrupt")
            with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                benchmark.validate_fixture(manifest, "en", fixture)
            with self.assertRaisesRegex(SystemExit, "did not match"):
                benchmark.validate_transcripts(
                    "en",
                    "warm",
                    ["different transcript"],
                    expected_text,
                )

    def test_committed_result_uses_stable_fixture_provenance(self) -> None:
        payload = json.loads(RESULT.read_text(encoding="utf-8"))
        for measurement in payload["measurements"]:
            self.assertNotIn("fixture", measurement)
            self.assertTrue(measurement["fixture_id"].startswith("transcribe.cpp/"))
            self.assertRegex(measurement["fixture_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(
                measurement["reference_transcript_sha256"],
                r"^[0-9a-f]{64}$",
            )


if __name__ == "__main__":
    unittest.main()
