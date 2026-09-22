# Private Diarization Evaluation Fixtures

This folder documents the local-only fixture layout for
`macparakeet-cli diarization-eval`. Do not commit real meeting audio, public
dataset audio, or derived private annotations here. `fixtures/private/` is
gitignored on purpose.

## Layout

```text
fixtures/private/diarization/
  two-remote-speakers/
    system.wav
    expected.json
    reference.rttm
```

`system.wav` is preferred when present; otherwise the harness uses `audio.wav`
or the first `.wav` in the fixture folder. `reference.rttm` is optional. When it
is present, the harness computes DER and coverage using the selected scoring
policy.

`expected.json` is optional and intentionally coarse:

```json
{
  "expectedRemoteSpeakers": 2,
  "minimumRemoteSpeakers": 2,
  "maximumRemoteSpeakers": 3,
  "notes": "Two remote speakers, low overlap"
}
```

`expectedRemoteSpeakers` drives exact/min/max hint runs. It is a symptom check,
not benchmark truth.

## Scoring Policy

The default profile is strict internal regression scoring:

```bash
swift run macparakeet-cli diarization-eval fixtures/private/diarization --json
```

Use `--collar-ms` and `--ignore-overlap` only when comparing against a benchmark
recipe that uses those settings:

```bash
swift run macparakeet-cli diarization-eval fixtures/private/diarization \
  --collar-ms 250 \
  --ignore-overlap \
  --json
```

The JSON report records `collarMs` and `skipOverlap` because DER is not
comparable without those settings.

## Credible Fixture Sources

- Handwritten RTTM/UEM-style fixtures: best for CI and unit tests; no licensing
  or privacy risk.
- AMI Meeting Corpus: close to MacParakeet's meeting use case, but do not bundle
  it. AMI/OpenSLR redistribution terms are non-trivial and non-commercial.
- VoxConverse: useful in-the-wild diarization data, but original video/audio
  copyrights still matter; keep local.
- DIHARD III: strong stress benchmark, but LDC licensing makes it unsuitable for
  repo fixtures.
- LibriCSS: useful overlap/far-field stress data with lower privacy risk, but
  validate redistribution terms before sharing anything.

For public benchmarks, keep raw data outside the repo and copy only local,
generic fixture folders into `fixtures/private/diarization/`.
