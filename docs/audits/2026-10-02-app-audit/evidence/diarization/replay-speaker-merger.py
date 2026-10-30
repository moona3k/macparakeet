#!/usr/bin/env python3
"""Execute the checked-out production merger with minimal value-type stubs.

This characterizes existing smoothing policy. It does not assert that removing
smoothing improves corpus quality. No SwiftPM build or model assets required.
"""
from pathlib import Path
import hashlib, json, subprocess, tempfile

repo = Path(__file__).resolve().parents[5]
source = repo / "Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift"
stubs = r"""
import Foundation
public struct WordTimestamp {
    public let word: String
    public let startMs: Int
    public let endMs: Int
    public var speakerId: String?
}
public struct SpeakerSegment {
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int
}
"""
probe = r"""
func run(_ name: String, _ words: [WordTimestamp], _ segments: [SpeakerSegment]) {
    let output = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
    let payload: [String: Any] = ["case": name, "labels": output.map { $0.speakerId ?? "unassigned" }]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
run("one-word-answer-with-two-second-own-activity", [
    .init(word: "Ready?", startMs: 0, endMs: 1000),
    .init(word: "No.", startMs: 5000, endMs: 7000),
    .init(word: "Okay.", startMs: 10000, endMs: 11000)
], [
    .init(speakerId: "A", startMs: 0, endMs: 1000),
    .init(speakerId: "B", startMs: 5000, endMs: 7000),
    .init(speakerId: "A", startMs: 10000, endMs: 11000)
])
run("unassigned-word-in-two-minute-gap", [
    .init(word: "start", startMs: 0, endMs: 1000),
    .init(word: "unknown", startMs: 60000, endMs: 61000),
    .init(word: "end", startMs: 120000, endMs: 121000)
], [
    .init(speakerId: "A", startMs: 0, endMs: 1000),
    .init(speakerId: "A", startMs: 120000, endMs: 121000)
])
run("meeting-fallback-word-with-no-overlap", [
    .init(word: "start", startMs: 0, endMs: 1000, speakerId: "system"),
    .init(word: "unknown", startMs: 60000, endMs: 61000, speakerId: "system"),
    .init(word: "end", startMs: 120000, endMs: 121000, speakerId: "system")
], [
    .init(speakerId: "system:A", startMs: 0, endMs: 1000),
    .init(speakerId: "system:A", startMs: 120000, endMs: 121000)
])
"""
with tempfile.TemporaryDirectory(prefix="macparakeet-merger-audit-") as temporary:
    path = Path(temporary) / "main.swift"
    path.write_text(stubs + source.read_text() + probe)
    result = subprocess.run(["swift", str(path)], text=True, capture_output=True, check=True)
print(json.dumps({"sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                  "source": str(source.relative_to(repo)),
                  "runs": [json.loads(line) for line in result.stdout.splitlines()]}, indent=2))
