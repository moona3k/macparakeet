#!/usr/bin/env python3
"""Exercise standalone archive layout without building Swift or downloading runtimes."""
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CLIArchiveTests(unittest.TestCase):
    def test_archive_preserves_ask_and_optional_verified_cohere_runtime(self):
        for native in (False, True):
            with self.subTest(native=native), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                dist = root / "scripts/dist"
                dist.mkdir(parents=True)
                builder = dist / "build_cli_archive.sh"
                shutil.copy2(ROOT / "scripts/dist/build_cli_archive.sh", builder)

                def script(path, body):
                    path.write_text("#!/bin/sh\nset -eu\n" + body)
                    path.chmod(0o755)

                script(root / "scripts/build_ask_helper.sh",
                       'mkdir -p "$1"; echo helper > "$1/ask-helper.cjs"\n')
                # Native package integrity has separate end-to-end fixture tests;
                # this verifier fixture checks packaging actually calls that gate.
                script(dist / "verify_transcribe_cpp_release.sh",
                       'test -n "${MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH:-}"\n'
                       'echo verified > "$VERIFY_RECEIPT"\n')
                cli = root / "cli"
                node = root / "node"
                script(cli, "echo cli\n")
                script(node, "echo node\n")
                environment = dict(os.environ)
                environment.pop("MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH", None)
                environment.update({
                    "CLI_BINARY": str(cli), "NODE_BINARY": str(node),
                    "OUT_DIR": str(root / "dist"), "ARCH": "arm64",
                    "VERSION": "1.2.3" if native else "ci",
                    "VERIFY_RECEIPT": str(root / "verified"),
                })
                if native:
                    package = root / "wrapper"
                    framework = package / "build-apple/TranscribeCpp.xcframework"
                    native_binary = framework / "macos-arm64/CTranscribe.framework/CTranscribe"
                    native_binary.parent.mkdir(parents=True)
                    native_binary.write_text("verified runtime bytes")
                    for notice in ("LICENSE", "LICENSE.ggml", "LICENSE.miniz"):
                        (framework / notice).write_text(notice)
                    (root / "LICENSES").mkdir()
                    for notice in ("LICENSE", "THIRD_PARTY_LICENSES.md", "LICENSES/Apache-2.0.txt"):
                        (root / notice).write_text(notice)
                    commands = root / "commands"
                    commands.mkdir()
                    script(commands / "otool",
                           'if [ "$1" = -L ]; then echo @rpath/CTranscribe.framework/Versions/A/CTranscribe; fi\n')
                    script(commands / "install_name_tool", 'echo "$*" >> "$RPATH_RECEIPT"\n')
                    # Portable byte copy; actual macOS ditto verification is covered
                    # by the native archive mismatch tests in benchmarks/asr.
                    script(commands / "ditto", 'cp -R "$1" "$2"\n')
                    environment.update({
                        "MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH": str(package),
                        "PATH": str(commands) + os.pathsep + environment["PATH"],
                        "RPATH_RECEIPT": str(root / "rpaths"),
                    })
                result = subprocess.run(["bash", str(builder)], env=environment,
                                        text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                archive = root / f'dist/macparakeet-cli-{environment["VERSION"]}-darwin-arm64.tar.gz'
                with tarfile.open(archive) as package_archive:
                    names = set(package_archive.getnames())
                    self.assertIn("macparakeet-cli", names)
                    self.assertIn("libexec/macparakeet-cli/node", names)
                    self.assertIn("libexec/macparakeet-cli/AskAgentHelper/ask-helper.cjs", names)
                    if native:
                        self.assertIn("Frameworks/CTranscribe.framework/CTranscribe", names)
                        self.assertIn("Legal/transcribe.cpp-LICENSE.ggml", names)
                        self.assertIn("Legal/transcribe.cpp-LICENSE.miniz", names)
                        with package_archive.extractfile("Frameworks/CTranscribe.framework/CTranscribe") as binary:
                            self.assertEqual(binary.read(), b"verified runtime bytes")
                    else:
                        self.assertNotIn("Frameworks", names)
                self.assertEqual((root / "verified").exists(), native)
                if native:
                    rpaths = (root / "rpaths").read_text()
                    self.assertIn("@executable_path/Frameworks", rpaths)
                    self.assertIn("@executable_path/../libexec/Frameworks", rpaths)
                else:
                    # A versioned release cannot silently ship a stub-only CLI.
                    environment["VERSION"] = "1.2.3"
                    failed = subprocess.run(["bash", str(builder)], env=environment,
                                            text=True, capture_output=True, timeout=20)
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertFalse((root / "dist/macparakeet-cli-1.2.3-darwin-arm64.tar.gz").exists())


if __name__ == "__main__":
    unittest.main()
