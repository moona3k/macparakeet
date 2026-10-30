#!/usr/bin/env python3
"""Focused tests for the pinned Cohere multilingual benchmark harness."""

from __future__ import annotations

import json
import os
import sys
import time
import subprocess
import shutil
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_archive_mismatch_fails_before_network_or_execution(self) -> None:
        manifest = benchmark.load_release_manifest(RELEASE_MANIFEST)
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / manifest["runtime"]["artifact_filename"]
            artifact.write_bytes(b"different runtime archive")
            with patch.object(benchmark, "command_json") as network:
                with self.assertRaisesRegex(SystemExit, "checksum does not match"):
                    benchmark.verify_release_provenance(manifest, artifact)
                network.assert_not_called()

    def test_timeout_kills_the_transcription_child_too(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "child-survived"
            ready = Path(temporary) / "child-started"
            child = "import time; from pathlib import Path; time.sleep(1.5); Path(%r).touch()" % str(marker)
            parent = (
                "import subprocess, sys, time; from pathlib import Path; "
                "subprocess.Popen([sys.executable, '-c', %r]); Path(%r).touch(); time.sleep(10)"
                % (child, str(ready))
            )
            started = time.monotonic()
            with self.assertRaisesRegex(SystemExit, "transcription timed out"):
                benchmark.run_process([sys.executable, "-c", parent], "transcription", timeout=1)
            self.assertLess(time.monotonic() - started, 3)
            self.assertTrue(ready.exists(), "wrapper never started its child")
            time.sleep(1.6)
            self.assertFalse(marker.exists(), "timed-out wrapper left its child alive")

    def test_timeout_requires_finite_positive_seconds(self) -> None:
        for value in ("0", "-1", "nan", "inf"):
            with self.subTest(value=value), self.assertRaises(benchmark.argparse.ArgumentTypeError):
                benchmark.positive_seconds(value)
        self.assertEqual(benchmark.positive_seconds("1.5"), 1.5)

    def test_fresh_build_receipt_and_post_measurement_integrity(self) -> None:
        for mutate in (False, True):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                package = Path(temporary) / "package"
                artifact = Path(temporary) / "native.zip"
                built = {}

                def build_command(command, description, **options):
                    if description == "verified CLI build":
                        scratch = Path(command[command.index("--scratch-path") + 1])
                        cli = scratch / "release/macparakeet-cli"
                        cli.parent.mkdir()
                        cli.write_bytes(b"freshly built executable")
                        cli.chmod(0o755)
                        built["cli"] = cli
                        self.assertEqual(options["env"]["MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH"], str(package))
                        self.assertNotIn("DYLD_LIBRARY_PATH", options["env"])
                        return ""
                    if description == "verified CLI build path":
                        return str(built["cli"].parent)
                    if description == "Cohere CLI linkage":
                        return "@rpath/CTranscribe.framework/Versions/A/CTranscribe"
                    self.fail(description)

                with patch.object(benchmark, "checked_output", side_effect=build_command), \
                     patch.object(benchmark, "adapter_commit", return_value="adapter-commit"), \
                     patch.object(benchmark, "verify_native_package") as verify, \
                     patch.dict(os.environ, {"DYLD_LIBRARY_PATH": "/unverified"}):
                    def measure():
                        with benchmark.build_verified_cli(package, artifact, 10) as (cli, receipt, environment):
                            self.assertEqual(receipt["cli_sha256"], benchmark.sha256_file(cli))
                            self.assertEqual(receipt["adapter_commit"], "adapter-commit")
                            self.assertEqual(environment["MACPARAKEET_TELEMETRY"], "0")
                            if mutate:
                                cli.write_bytes(b"stale replacement")
                    if mutate:
                        with self.assertRaisesRegex(SystemExit, "measured CLI.*changed"):
                            measure()
                    else:
                        measure()
                        self.assertEqual(verify.call_count, 3)
                self.assertFalse(built["cli"].exists(), "scratch build was not removed")

    def test_fresh_build_rejects_an_independent_cli_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            stale = Path(temporary) / "macparakeet-cli"
            stale.write_bytes(b"stale")
            stale.chmod(0o755)
            def output(command, description, **options):
                return temporary if description == "verified CLI build path" else ""
            with patch.object(benchmark, "checked_output", side_effect=output), \
                 patch.object(benchmark, "adapter_commit", return_value="adapter"), \
                 patch.object(benchmark, "verify_native_package"):
                with self.assertRaisesRegex(SystemExit, "fresh scratch tree"):
                    with benchmark.build_verified_cli(Path(temporary), Path(temporary), 10):
                        self.fail("independently supplied CLI was accepted")

    @unittest.skipUnless(sys.platform == "darwin", "native artifact verifier uses ditto")
    def test_native_package_rejects_modified_wrapper_and_different_framework(self) -> None:
        # Exercise the distribution verifier with a tiny Git/package/archive
        # fixture. Only lipo is stubbed: no model, compiler, or downloads.
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "app"
            package_root = base / "native"
            package = package_root / "bindings/swift"
            package.mkdir(parents=True)
            wrapper = package / "Sources/TranscribeCpp/TranscribeCpp.swift"
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text('public static let compiledVersion = "0.1.3"\n')
            (package / "Package.swift").write_text("// fixture manifest\n")
            (package_root / ".gitignore").write_text("build-apple/\n")
            for path in ("ggml/UPSTREAM", "src/third_party/miniz/UPSTREAM"):
                target = package_root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("sha: fixture-commit\n")
            def git(*args):
                return subprocess.run(["git", "-C", str(package_root), *args], check=True,
                                      text=True, capture_output=True, timeout=10).stdout.strip()
            git("init", "-q")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false",
                "commit", "-qm", "fixture", "--no-verify")
            framework = package / "build-apple/TranscribeCpp.xcframework"
            binary = framework / "macos-arm64/CTranscribe.framework/Versions/A/CTranscribe"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"verified-native-bytes")
            for notice in ("LICENSE", "LICENSE.ggml", "LICENSE.miniz"):
                (framework / notice).write_text(notice)
            artifact = base / "native.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(framework), str(artifact)],
                           check=True, timeout=10)
            dist = root / "scripts/dist"
            dist.mkdir(parents=True)
            verifier = dist / "verify_transcribe_cpp_release.sh"
            shutil.copy2(ROOT / "scripts/dist/verify_transcribe_cpp_release.sh", verifier)
            pins = {
                "TRANSCRIBE_CPP_OWNED_FORK_COMMIT": git("rev-parse", "HEAD"),
                "TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256": benchmark.sha256_file(artifact),
                "TRANSCRIBE_CPP_OWNED_RELEASE_TAG": "fixture-tag",
                "TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME": artifact.name,
                "TRANSCRIBE_CPP_OWNED_ARTIFACT_URL": "https://example.invalid/native.zip",
                "TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY": "fixture/native",
                "TRANSCRIBE_CPP_WRAPPER_VERSION": "0.1.3",
                "TRANSCRIBE_CPP_GGML_UPSTREAM_COMMIT": "fixture-commit",
                "TRANSCRIBE_CPP_MINIZ_UPSTREAM_COMMIT": "fixture-commit",
            }
            (dist / "transcribe_cpp_release_pins.sh").write_text(
                "".join(f'{key}="{value}"\n' for key, value in pins.items()))
            swift_pins = root / "Sources/MacParakeetCore/STT/CohereTranscribeModel.swift"
            swift_pins.parent.mkdir(parents=True)
            swift_pins.write_text(
                f'static let ownedForkRepository = "{pins["TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY"]}"\n'
                f'static let ownedForkCommit = "{pins["TRANSCRIBE_CPP_OWNED_FORK_COMMIT"]}"\n'
                f'static let ownedReleaseTag = "{pins["TRANSCRIBE_CPP_OWNED_RELEASE_TAG"]}"\n'
                + "\n".join(f'"{pins[key]}"' for key in (
                    "TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME", "TRANSCRIBE_CPP_OWNED_ARTIFACT_URL",
                    "TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256")))
            (root / "LICENSES").mkdir()
            for notice, retained in (("LICENSE", "transcribe.cpp-MIT.txt"),
                                     ("LICENSE.ggml", "transcribe.cpp-ggml-MIT.txt"),
                                     ("LICENSE.miniz", "transcribe.cpp-miniz-MIT.txt")):
                shutil.copy2(framework / notice, root / "LICENSES" / retained)
            fake_bin = base / "bin"
            fake_bin.mkdir()
            lipo = fake_bin / "lipo"
            lipo.write_text("#!/bin/sh\necho arm64\n")
            lipo.chmod(0o755)
            environment = benchmark.native_environment(package, artifact)
            environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
            def verify():
                return benchmark.checked_output([str(verifier)], "fixture native verification",
                                                env=environment, timeout=10)
            self.assertIn("Verified owned transcribe.cpp artifact", verify())
            binary.write_bytes(b"different linked runtime")
            with self.assertRaisesRegex(SystemExit, "differs from the checksum-verified archive"):
                verify()
            binary.write_bytes(b"verified-native-bytes")
            wrapper.write_text(wrapper.read_text() + "// modified wrapper\n")
            with self.assertRaisesRegex(SystemExit, "modified tracked files"):
                verify()

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
