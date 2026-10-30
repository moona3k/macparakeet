"""Test native CI preparation with local Git/archive fixtures, never models."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "preparation uses macOS ditto")
class PrepareCohereRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "app"
        self.native = self.base / "native-source"
        self.native.mkdir()
        self.git("init", "-q")
        wrapper = self.native / "bindings/swift/Package.swift"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text("// fixture package\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture", "--no-verify")
        self.archive = self.base / "native.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("TranscribeCpp.xcframework/receipt", b"pinned native bytes")
        dist, ci = self.root / "scripts/dist", self.root / "scripts/ci"
        dist.mkdir(parents=True)
        ci.mkdir()
        shutil.copyfile(ROOT / "scripts/ci/prepare_cohere_runtime.sh", ci / "prepare_cohere_runtime.sh")
        pins = {
            "TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY": "fixture/native",
            "TRANSCRIBE_CPP_OWNED_FORK_COMMIT": self.git("rev-parse", "HEAD"),
            "TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME": "native.zip",
            "TRANSCRIBE_CPP_OWNED_ARTIFACT_URL": "https://example.invalid/native.zip",
            "TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
        }
        (dist / "transcribe_cpp_release_pins.sh").write_text("".join(f'{key}="{value}"\n' for key, value in pins.items()))
        self.script(dist / "verify_transcribe_cpp_release.sh", '''
test "${FAIL_VERIFICATION:-0}" != 1
test "$(cat "$TRANSCRIBE_XCFRAMEWORK_PATH/receipt")" = "pinned native bytes"
test "$TRANSCRIBE_XCFRAMEWORK_PATH" = "$MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH/build-apple/TranscribeCpp.xcframework"
test -f "$MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP"
echo verified > "$VERIFY_RECEIPT"
''')
        commands = self.base / "commands"
        commands.mkdir()
        # Replace network endpoints only; real Git fetches and checks out the pin.
        self.script(commands / "git", '''
args=()
for argument in "$@"; do
  if [[ "$argument" == https://github.com/fixture/native.git ]]; then argument="$NATIVE_FIXTURE"; fi
  args+=("$argument")
done
exec /usr/bin/git "${args[@]}"
''')
        self.script(commands / "curl", 'cp "$ARCHIVE_FIXTURE" "${@: -1}"\n')
        self.script(commands / "uname", 'echo arm64\n')
        self.runner = self.base / "runner"
        self.runner.mkdir()
        self.exports = self.base / "environment"
        self.exports.touch()
        self.env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                        RUNNER_TEMP=str(self.runner), GITHUB_ENV=str(self.exports),
                        NATIVE_FIXTURE=str(self.native), ARCHIVE_FIXTURE=str(self.archive),
                        VERIFY_RECEIPT=str(self.base / "verified"))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.native), *args], text=True).strip()

    def script(self, path, body):
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def prepare(self, **environment):
        return subprocess.run(["bash", "scripts/ci/prepare_cohere_runtime.sh"], cwd=self.root,
                              env=dict(self.env, **environment), text=True, capture_output=True, timeout=20)

    def test_verified_checkout_and_artifact_export_only_after_verification(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.exports.read_text().splitlines()
        self.assertEqual(len(lines), 3)
        values = dict(line.split("=", 1) for line in lines)
        package = Path(values["MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH"])
        actual = subprocess.check_output(["git", "-C", str(package), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(actual, self.git("rev-parse", "HEAD"))
        self.assertTrue((self.base / "verified").exists())
        self.assertEqual(Path(values["TRANSCRIBE_XCFRAMEWORK_PATH"]).joinpath("receipt").read_bytes(), b"pinned native bytes")

    def test_existing_checkout_is_preserved_and_rejected(self):
        existing = self.runner / "macparakeet-cohere-native"
        existing.mkdir()
        sentinel = existing / "unrelated"
        sentinel.write_text("preserve me")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve me")
        self.assertEqual(self.exports.read_text(), "")

    def test_bad_archive_never_exports_or_reaches_verifier(self):
        self.archive.write_bytes(b"wrong artifact")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(self.exports.read_text(), "")
        self.assertFalse((self.base / "verified").exists())

    def test_failed_native_verification_never_exports_build_environment(self):
        result = self.prepare(FAIL_VERIFICATION="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.exports.read_text(), "")


if __name__ == "__main__":
    unittest.main()
