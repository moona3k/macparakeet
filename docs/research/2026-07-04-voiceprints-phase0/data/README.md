# Phase 0 data

Aggregate artifacts only (`inventory.json`, `model-check.json`,
`sample-sessions.json`).

Per-session embedding JSONs (`<sessionID>-<track>-{full,split}.json`) are
deliberately NOT committed: a 256-d speaker embedding is biometric data (see
`docs/research/2026-07-03-speaker-voiceprints/report-privacy-biometrics.md`),
and this corpus includes meeting participants who never consented to
publication. Regenerate locally with the harness in `../harness/`.

`analysis-summary.json` is also NOT committed: its `populationPairs` records
form a linkable per-speaker graph (session UUIDs x speaker IDs x speaking
times x pairwise voice distances) of private meetings. The report carries
aggregate percentile tables and illustrative excerpts only; regenerate the
full analysis locally with `../harness/analyze_voiceprints.py`.
