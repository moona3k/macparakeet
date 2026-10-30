#!/usr/bin/env python3
"""Exercise runner process ownership without requesting audio capture (Python 3)."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "run-process-tap-audio-only-probe.sh"
PROBE_SOURCE = RUNNER.parent / "process-tap-audio-only-probe.swift"
PROBE = r'''import Foundation
import Darwin
@main enum Fixture {
    static func main() throws {
        guard setpgid(0, 0) == 0 else { exit(2) }
        let args = CommandLine.arguments
        let output = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
        let env = ProcessInfo.processInfo.environment
        try String(getpid()).write(to: output.deletingLastPathComponent().appendingPathComponent("probe.pid"),
                                   atomically: true, encoding: .utf8)
        if args.contains("--observe-seconds") {
            precondition(!args.contains("--tone") && !args.contains("--cycles"))
            if env["FIXTURE_MODE"] == "hang" { Thread.sleep(forTimeInterval: 60) }
            let result: [String: Any] = ["schemaVersion": 3, "microphoneRequested": false,
                "screenPixelsRequested": false, "status": "OBSERVED", "mode": "external_audio_observation",
                "generatedPlayback": false, "teardownVerified": true, "capturedFrames": 100,
                "windows": [["channels": [["samples": 100, "exactZeroSamples": 100, "peak": 0]]]]]
            try JSONSerialization.data(withJSONObject: result).write(to: output)
            return
        }
        let tone = args[args.firstIndex(of: "--tone")! + 1]
        do {
            try playProbeTone(at: tone, executable: env["FIXTURE_PLAYER"]!)
        } catch { exit(1) }
        let cycle: [String: Any] = ["teardownVerified": true, "capturedFrames": 100,
                                   "rms": 0.1, "targetAmplitude": 0.1]
        let result: [String: Any] = ["schemaVersion": 2, "microphoneRequested": false,
            "screenPixelsRequested": false, "status": "PASS", "permissionOutcome": "process_tap_created",
            "requestedCycles": 1, "completedCycles": 1, "capturedFrames": 100,
            "minimumCycleRMS": 0.1, "minimumCycleTargetAmplitude": 0.1, "cycles": [cycle]]
        try JSONSerialization.data(withJSONObject: result).write(to: output)
    }
}
'''


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.player_temp = tempfile.TemporaryDirectory(prefix='process-tap-player-test-')
        cls.player = Path(cls.player_temp.name) / 'afplay'
        # A silent stand-in with the same process name and argv as afplay. This
        # reproduces filename-based cleanup without touching audio hardware.
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(cls.player)],
                       input='#include <unistd.h>\n#include <stdlib.h>\n#include <string.h>\n#include <stdio.h>\n'
                             'int main(void) { const char *p = getenv("FIXTURE_CHILD_PID"); '
                             'if (p) { FILE *f = fopen(p, "w"); if (!f) return 2; '
                             'fprintf(f, "%d\\n", getpid()); fclose(f); } '
                             'const char *m = getenv("FIXTURE_MODE"); '
                             'if (m && !strcmp(m, "pass")) usleep(300000); else sleep(60); return 0; }\n',
                       text=True, check=True)

        fixture_source = Path(cls.player_temp.name) / 'Fixture.swift'
        fixture_source.write_text(PROBE)
        cls.fixture = Path(cls.player_temp.name) / 'probe'
        subprocess.run(['swiftc', '-parse-as-library', '-D', 'PROCESS_TAP_PLAYER_TEST',
                        str(PROBE_SOURCE), str(fixture_source),
                        '-o', str(cls.fixture)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.player_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='process-tap-runner-test-')
        self.root = Path(self.temp.name)
        self.output = self.root / 'evidence'
        bindir = self.root / 'bin'
        bindir.mkdir()
        # Substitute only build/sign steps; execute the actual shell runner and
        # real process discovery, signals, waits, and result validation.
        for name, body in {
            'swiftc': '#!/bin/bash\nwhile [[ "$1" != -o ]]; do shift; done\ncp "$FIXTURE_PROBE" "$2"\n',
            'codesign': '#!/bin/bash\nexit 0\n',
            'swift': '#!/bin/bash\necho fixture\n',
        }.items():
            path = bindir / name
            path.write_text(body)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'],
                        FIXTURE_PROBE=str(self.fixture), FIXTURE_PLAYER=str(self.player), FIXTURE_MODE='pass',
                        FIXTURE_CHILD_PID=str(self.output / 'child.pid'))
        self.unrelated = subprocess.Popen(
            ['/usr/bin/afplay', str(self.output / 'generated-997hz.wav')], executable=str(self.player))
        self.runner = None

    def tearDown(self):
        if self.runner and self.runner.poll() is None:
            self.runner.terminate()
            self.runner.wait(timeout=15)
        self.unrelated.terminate()
        self.unrelated.wait()
        self.temp.cleanup()

    def launch(self, mode='pass', deadline='20', observe_seconds=None):
        self.env.update(FIXTURE_MODE=mode, MACPARAKEET_PROCESS_TAP_PROBE_DEADLINE_SECONDS=deadline)
        arguments = ['bash', str(RUNNER), str(self.output)]
        if observe_seconds is not None:
            arguments += ['--observe-seconds', str(observe_seconds)]
        self.runner = subprocess.Popen(arguments, env=self.env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def await_child(self):
        path = self.output / 'child.pid'
        for _ in range(100):
            if path.exists() and path.read_text().strip():
                return int(path.read_text())
            time.sleep(0.05)
        self.fail('fixture never launched child')

    def assert_cleanup(self, child):
        self.assertIsNone(self.unrelated.poll(), 'cleanup killed unrelated process')
        for _ in range(100):
            state = subprocess.run(['/bin/ps', '-p', str(child), '-o', 'stat='],
                                   capture_output=True, text=True).stdout.strip()
            if not state or state.startswith('Z'):
                return
            time.sleep(0.05)
        self.fail('probe child survived cleanup')

    def test_external_observation_does_not_launch_player_or_call_silence_pass(self):
        self.launch(observe_seconds=1)
        self.assertEqual(self.runner.wait(timeout=15), 0)
        result = json.loads((self.output / 'result.json').read_text())
        self.assertEqual(result['status'], 'OBSERVED')
        self.assertFalse(result['generatedPlayback'])
        self.assertFalse((self.output / 'child.pid').exists())
        self.assertFalse((self.output / 'generated-997hz.wav').exists())
        self.assertIsNone(self.unrelated.poll())

    def test_external_observation_deadline_cannot_leave_observed_result(self):
        self.launch(mode='hang', deadline='1', observe_seconds=60)
        self.assertEqual(self.runner.wait(timeout=15), 124)
        result = json.loads((self.output / 'result.json').read_text())
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['failureType'], 'deadline_exceeded')
        self.assertFalse((self.output / 'child.pid').exists())
        self.assertIsNone(self.unrelated.poll())

    def test_invalid_observation_duration_fails_before_building_or_capturing(self):
        for value in ('', '0', '301', 'nan', 'inf', '-1'):
            with self.subTest(value=value):
                self.launch(observe_seconds=value)
                self.assertEqual(self.runner.wait(timeout=10), 64)
                self.assertFalse(self.output.exists())

    def test_success(self):
        self.launch()
        child = self.await_child()
        self.assertEqual(self.runner.wait(timeout=15), 0)
        self.assertEqual(json.loads((self.output / 'result.json').read_text())['status'], 'PASS')
        self.assert_cleanup(child)

    def test_timeout(self):
        self.launch('wait', '1')
        child = self.await_child()
        self.assertEqual(self.runner.wait(timeout=15), 124)
        self.assertEqual(json.loads((self.output / 'result.json').read_text())['status'], 'FAIL')
        self.assert_cleanup(child)

    def test_signal(self):
        self.launch('wait')
        child = self.await_child()
        self.runner.send_signal(signal.SIGTERM)
        self.assertEqual(self.runner.wait(timeout=15), 143)
        self.assertEqual(json.loads((self.output / 'result.json').read_text())['status'], 'FAIL')
        self.assert_cleanup(child)

    def test_crashed_probe_orphan(self):
        self.launch('crash')
        child = self.await_child()
        os.kill(int((self.output / 'probe.pid').read_text()), signal.SIGKILL)
        self.assertNotEqual(self.runner.wait(timeout=15), 0)
        self.assert_cleanup(child)


if __name__ == '__main__':
    unittest.main()
