"""Exercise the executable cache identity contract with isolated toolchains."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("swift-cache-key.sh")


class SwiftCacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("uname", "sw_vers", "xcodebuild", "swift", "xcrun"):
            path = self.bin / name
            path.write_text(f'#!/bin/sh\nprintf "%s\\n" "${{FAKE_{name.upper()}:-baseline}}"\n')
            path.chmod(0o755)
        for name in ("Package.swift", "Package.resolved", ".github/workflows/ci.yml"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("baseline\n")
        target = self.root / "scripts/ci/swift-cache-key.sh"
        target.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, target)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")

    def key(self, **environment):
        return subprocess.check_output(
            ["bash", "scripts/ci/swift-cache-key.sh"], cwd=self.root,
            env=dict(self.env, **environment), text=True,
        ).strip()

    def test_stable_identity_and_source_changes_allow_incremental_build(self):
        before = self.key()
        self.assertRegex(before, r"^[0-9a-f]{64}$")
        self.assertEqual(before, self.key())
        source = self.root / "Source.swift"
        source.write_text("changed application source")
        self.assertEqual(before, self.key())
        source.unlink()
        self.assertEqual(before, self.key())

    def test_each_toolchain_dimension_invalidates_build_state(self):
        before = self.key()
        for tool in ("UNAME", "SW_VERS", "XCODEBUILD", "SWIFT", "XCRUN"):
            with self.subTest(tool=tool):
                self.assertNotEqual(before, self.key(**{f"FAKE_{tool}": "different"}))

    def test_dependency_graph_workflow_and_key_policy_invalidate(self):
        before = self.key()
        for name in ("Package.swift", "Package.resolved", ".github/workflows/ci.yml",
                     "scripts/ci/swift-cache-key.sh"):
            with self.subTest(file=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original + "\n# changed\n")
                self.assertNotEqual(before, self.key())
                path.write_text(original)

    def test_missing_lockfile_fails_instead_of_using_partial_identity(self):
        (self.root / "Package.resolved").unlink()
        result = subprocess.run(
            ["bash", "scripts/ci/swift-cache-key.sh"], cwd=self.root,
            env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_failed_toolchain_probe_fails_instead_of_using_partial_identity(self):
        (self.bin / "swift").write_text("#!/bin/sh\nexit 7\n")
        result = subprocess.run(
            ["bash", "scripts/ci/swift-cache-key.sh"], cwd=self.root,
            env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
