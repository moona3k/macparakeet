#!/usr/bin/env python3
"""Exercise actual Swift signal measurement without opening an audio device."""

from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "process-tap-audio-only-probe.swift"
FIXTURE = r'''
import AVFoundation
import Foundation

@main enum Fixture {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 4,
                                       channels: 2, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48)!
            buffer.frameLength = scenario == "overflow" ? 48 : 9
            let metrics = ProcessTapSignalWindows(sampleRate: 4, channels: 2, seconds: 1)
            for frame in 0..<Int(buffer.frameLength) {
                let left: Float = scenario == "inverse" ? -0.25 : 0
                let right: Float = scenario == "silence" ? 0 : 0.25
                buffer.floatChannelData![0][frame * buffer.stride] = left
                buffer.floatChannelData![interleaved ? 0 : 1][frame * buffer.stride + (interleaved ? 1 : 0)] = right
            }
            var asbd = format.streamDescription.pointee
            if scenario == "invalid" { asbd.mBitsPerChannel = 16 }
            if scenario == "nonfinite" { buffer.floatChannelData![0][0] = .nan }
            metrics.ingest(buffer.audioBufferList, format: asbd)
            if scenario == "invalid" {
                precondition(metrics.invalidBuffers == 1 && metrics.frames == 0 && !metrics.isValid)
            } else if scenario == "nonfinite" {
                precondition(metrics.nonfiniteSamples == 1 && !metrics.isValid)
                // Invalid samples never become NaN in the scalar artifact.
                _ = try JSONSerialization.data(withJSONObject: metrics.windows)
            } else if scenario == "overflow" {
                precondition(metrics.overflowFrames == 4 && !metrics.isValid)
            } else {
                precondition(metrics.isValid && metrics.frames == 9 && metrics.windows.count == 3)
                precondition(metrics.callbacks == 1 && metrics.firstCallbackUptimeSeconds != nil)
                let first = metrics.windows[0]["channels"] as! [[String: Any]]
                let last = metrics.windows[2]["channels"] as! [[String: Any]]
                precondition(first[0]["samples"] as! Int == 4 && last[0]["samples"] as! Int == 1)
                precondition(first[0]["exactZeroSamples"] as! Int == (scenario == "inverse" ? 0 : 4))
                precondition(first[1]["exactZeroSamples"] as! Int == (scenario == "silence" ? 4 : 0))
                precondition(first[1]["rms"] as! Double == (scenario == "silence" ? 0 : 0.25))
                // A second callback continues the partial window instead of resetting it.
                buffer.frameLength = 3
                metrics.ingest(buffer.audioBufferList, format: asbd)
                precondition(metrics.frames == 12 && metrics.windows.count == 3)
                let tail = metrics.windows[2]["channels"] as! [[String: Any]]
                precondition(tail[1]["samples"] as! Int == 4)
            }
        }
    }
}
'''


class ObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="process-tap-observation-test-")
        root = Path(cls.temp.name)
        fixture = root / "Fixture.swift"
        fixture.write_text(FIXTURE)
        cls.binary = root / "fixture"
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "6", "-D", "PROCESS_TAP_PLAYER_TEST",
            str(SOURCE), str(fixture), "-o", str(cls.binary),
        ], check=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_both_layouts_channels_window_rollover_and_invalid_data(self):
        for scenario in ("right-only", "inverse", "silence", "invalid", "nonfinite", "overflow"):
            with self.subTest(scenario=scenario):
                subprocess.run([str(self.binary), scenario], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
