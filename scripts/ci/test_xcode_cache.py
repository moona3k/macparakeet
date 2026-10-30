"""Isolated cache identity and consumer-probe failure controls; no Xcode builds."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parent
spec = importlib.util.spec_from_file_location("xcode_probe", SCRIPTS / "qualify-xcode-cache.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class XcodeCacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for directory in ("scripts/ci", "scripts/dist", "bin", "Developer/usr/bin"):
            (self.root / directory).mkdir(parents=True)
        shutil.copyfile(SCRIPTS / "xcode-cache-key.sh", self.root / "scripts/ci/xcode-cache-key.sh")
        (self.root / "scripts/ci/swift-cache-key.sh").write_text("echo baseline\n")
        (self.root / "scripts/dist/build_app_bundle.sh").write_text("baseline\n")
        (self.root / "Developer/usr/bin/xcodebuild").touch()
        tool = self.root / "bin/xcrun"
        tool.write_text('#!/bin/sh\nprintf "%s\\n" "$FAKE_XCODE"\n')
        tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        FAKE_XCODE=str(self.root / "Developer/usr/bin/xcodebuild"),
                        XCODE_DERIVED_DATA=str(self.root / "derived"))

    def key(self, **environment):
        return subprocess.check_output(["bash", "scripts/ci/xcode-cache-key.sh"], cwd=self.root,
                                       env=dict(self.env, **environment), text=True,
                                       stderr=subprocess.PIPE).strip()

    def test_identity_changes_for_builder_paths_and_upstream_fingerprint(self):
        initial = self.key()
        self.assertRegex(initial, r"^[0-9a-f]{64}$")
        self.assertEqual(initial, self.key())
        self.assertNotEqual(initial, self.key(XCODE_DERIVED_DATA=str(self.root / "other")))
        other = self.root / "OtherDeveloper/usr/bin/xcodebuild"
        other.parent.mkdir(parents=True)
        other.touch()
        self.assertNotEqual(initial, self.key(FAKE_XCODE=str(other)))
        for name in ("scripts/dist/build_app_bundle.sh", "scripts/ci/swift-cache-key.sh"):
            path = self.root / name
            original = path.read_text()
            path.write_text(original + "\necho changed\n")
            self.assertNotEqual(initial, self.key())
            path.write_text(original)
        other_root = self.root / "checkout"
        shutil.copytree(self.root / "scripts", other_root / "scripts")
        result = subprocess.check_output(["bash", "scripts/ci/xcode-cache-key.sh"], cwd=other_root,
                                         env=self.env, text=True).strip()
        self.assertNotEqual(initial, result)

    def test_invalid_inputs_fail_closed(self):
        for overrides in ({"XCODE_DERIVED_DATA": "relative"}, {"FAKE_XCODE": "/missing/xcodebuild"}):
            with self.subTest(overrides=overrides), self.assertRaises(subprocess.CalledProcessError):
                self.key(**overrides)
        (self.root / "scripts/ci/swift-cache-key.sh").write_text("exit 7\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.key()
        (self.root / "scripts/ci/swift-cache-key.sh").write_text("echo baseline\n")
        (self.root / "bin/xcrun").write_text("#!/bin/sh\nexit 7\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.key()


class XcodeConsumerProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / probe.SOURCE
        self.resource = self.root / probe.RESOURCE
        self.source.parent.mkdir(parents=True)
        self.resource.parent.mkdir(parents=True)
        self.source.write_text("let message = " + probe.ORIGINAL + "\n")
        self.resource.write_text('{"items": [{"title": "original"}]}\n')
        self.originals = (self.source.read_bytes(), self.resource.read_bytes())
        self.env = {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(self.root),
                    "XCODE_DERIVED_DATA": str(self.root / "derived")}

    def build(self, root, env, stale=None):
        self.assertEqual(env["SKIP_BUILD"], "0")
        self.assertEqual(env["BUILD_SYSTEM"], "xcodebuild")
        marker = json.loads(self.resource.read_text())["items"][0]["title"]
        self.assertIn(marker, self.source.read_text())
        app = root / "dist/MacParakeet.app/Contents"
        binary = app / "MacOS/MacParakeet"
        resource = app / "Resources/MacParakeet_MacParakeet.bundle/Contents/Resources/discover-fallback.json"
        binary.parent.mkdir(parents=True, exist_ok=True)
        resource.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text("stale" if stale == "binary" else marker)
        resource.write_text(json.dumps({"items": [{"title": "stale" if stale == "resource" else marker}]}))

    def assert_restored(self):
        self.assertEqual(self.originals, (self.source.read_bytes(), self.resource.read_bytes()))

    def test_success_requires_both_packaged_consumers_and_restores(self):
        with patch.object(probe, "run_build", side_effect=self.build):
            probe.qualify(self.root, self.env)
        self.assert_restored()

    def test_stale_binary_or_resource_is_rejected_and_restored(self):
        for stale in ("binary", "resource"):
            with self.subTest(stale=stale), patch.object(
                probe, "run_build", side_effect=lambda root, env: self.build(root, env, stale)
            ), self.assertRaises(RuntimeError):
                probe.qualify(self.root, self.env)
            self.assert_restored()

    def test_build_failure_or_interruption_restores_inputs(self):
        for error in (RuntimeError("build failed"), KeyboardInterrupt()):
            with patch.object(probe, "run_build", side_effect=error), self.assertRaises(type(error)):
                probe.qualify(self.root, self.env)
            self.assert_restored()

    def test_guard_rejects_local_account_and_unowned_derived_data(self):
        for env in (dict(self.env, GITHUB_ACTIONS="false"), dict(self.env, XCODE_DERIVED_DATA="/outside")):
            with patch.object(probe, "run_build") as build, self.assertRaises(RuntimeError):
                probe.qualify(self.root, env)
            build.assert_not_called()
            self.assert_restored()


if __name__ == "__main__":
    unittest.main()
