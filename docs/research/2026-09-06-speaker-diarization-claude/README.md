# Speaker diarization research (Claude, 2026-09-06)

Question: MacParakeet's speaker separation on FluidAudio's built-in pipeline is "not the best".
How does Anarlog (fastrepl/anarlog, formerly Hyprnote) handle it, what do other apps and
current models do, and what is the highest recommendation for MacParakeet? Diarization runs as
post-transcription async processing, so speed is not a constraint.

Reading order:

1. [synthesis.md](synthesis.md): verdict and ordered recommendation.
2. [macparakeet-baseline.md](macparakeet-baseline.md): what ships today and where quality is lost.
3. [frontier.md](frontier.md): models, ports, benchmarks, and the FluidAudio 0.15.4 clustering defects.
4. [anarlog-and-peers.md](anarlog-and-peers.md): Anarlog end to end, plus Muesli, Meetily, Minutes, Vibe, OpenWhispr.
5. [production-practices.md](production-practices.md): pyannoteAI, AssemblyAI, Deepgram, Soniox, Granola, Otter, Teams, Zoom.

Method: four delegated research agents, each with a brief under [briefs/](briefs/), writing
only its own report and `evidence/` prefix; the orchestrator verified the central FluidAudio
defect claim in the pinned checkout and wrote the synthesis. Competitor sources were read from
the clones under `/Users/dmoon/code/research/macparakeet-oss-2026-09-06-astra/` (Anarlog at
e4379fb6). No models were downloaded or run, no benchmarks reproduced, no product code changed.
Benchmark figures are attributed reports with their protocol recorded where the source states it.

A parallel skeleton from an earlier Astra session lives in
`../2026-09-06-speaker-diarization-astra/` and was left untouched.
