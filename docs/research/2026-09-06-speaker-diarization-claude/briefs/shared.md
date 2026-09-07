# Shared brief: speaker attribution research for MacParakeet (2026-09-06)

Question from the product owner: MacParakeet's speaker separation runs on FluidAudio's built-in
pipeline and "the results are not the best". How does Anarlog handle speaker separation, what do
other meeting apps and current diarization models/tools do, and what is the single highest
recommendation for MacParakeet?

Settled product constraints:
- Diarization is NOT needed for the live transcript. It runs as post-transcription async
  processing on retained audio. It may be slow (real-time factor near 1x is acceptable), may use
  larger models, and may run in several passes.
- MacParakeet is native Swift / CoreML, local-first. Core audio and transcripts stay on device.
  A cloud route could only ever be an explicit opt-in surface, not the default.
- Meeting recordings retain separate microphone and system-audio sources (see ADR-028 for echo
  cancellation). "Me" vs "others" channel identity is real evidence and should not be thrown away.
- Research and documentation only. No product code changes, no builds or tests, no model
  downloads or runs, no commits, no external messages, no memory updates. Do not modify any
  file outside your assigned report path and evidence prefix. Preserve every other file.

Local sources you may read (read-only):
- Working tree: /Users/dmoon/code/macparakeet (current branch has unrelated uncommitted edits;
  do not touch them). Key paths: Sources/MacParakeetCore/Services/Diarization/,
  Sources/MacParakeetCore/Services/MeetingRecording/, Sources/MacParakeetCore/STT/,
  spec/adr/010-speaker-diarization.md, spec/adr/028-meeting-echo-cancellation.md,
  spec/adr/027-product-north-star.md, docs/research/speaker-diarization-frontier-2026-06.md,
  docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md,
  docs/research/2026-07-04-voiceprints-phase0*, docs/research/2026-07-03-speaker-voiceprints,
  docs/research/2026-09-06-oss-review-astra/ (earlier peer review incl. anarlog-hyprnote-char.md).
- Competitor source clones (read-only, do NOT run their scripts):
  /Users/dmoon/code/research/macparakeet-oss-2026-09-06-astra/{anarlog,muesli,meetily,minutes,vibe,handy,voiceink,openwhispr}
  Anarlog is at e4379fb6ec48c1094374054faa97912de6b714a4 (github.com/fastrepl/anarlog).
- FluidAudio pinned at 0.15.4 (revision b9d43724cbdb5a980e441fd54180964e94d470f7); checkout
  is under /Users/dmoon/code/macparakeet/.build/checkouts/FluidAudio if present.

Evidence standards:
- Cite primary sources: source files with commit SHA and line ranges (GitHub permalink form),
  official model cards, papers, official docs. Record the date you observed each web source.
- Benchmark numbers are attributed reports. Always record dataset, collar, whether overlap was
  scored, whether the speaker count was oracle, and hardware/latency definition when reported.
  Missing details are "unknown", not assumed. Never convert DER into a "percent accurate" claim.
- Separate: diarization error rate, word-level speaker attribution error, WER, speaker
  verification false accept/reject, and user correction burden.
- Separate what is implemented and shipped from what is documented, marketed, or in a paper.
- Distinguish deployable weights (and any CoreML / ONNX / MLX port for Apple Silicon) from
  paper-only results.
- Be skeptical. Trace the causal path of each recommendation.

Deliverable: a self-contained Markdown report at your assigned path with sections:
1. Verdict (short), 2. Findings (bounded, cited), 3. Implications for MacParakeet,
4. Failure scenarios and uncertainty, 5. Sources (all URLs / permalinks, with observed dates).
Save an outline early, then fill it in. Write concise, complete sentences. No emojis.
Return to the orchestrator: top findings, consequential uncertainties, and the report path.
Do not spawn further agents.
