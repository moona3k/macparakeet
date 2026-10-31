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
    words.json
```

`system.wav` is preferred when present; otherwise the harness uses `audio.wav`
or the first `.wav` in the fixture folder. `reference.rttm` is optional. When it
is present, the harness computes DER and coverage using the selected scoring
policy.

Each RTTM file must describe one recording. RTTM and word-timing annotations
must fit within `0...2147483647` milliseconds (about 24.8 days); nonfinite or
out-of-range times are rejected. DER and coverage are omitted when there is no reference or when
the scoring collar leaves no reference speech; an omitted score is not zero.

`words.json` is optional timing-only input for the experimental word assigner:

```json
[{"startMs": 0, "endMs": 150}, {"startMs": 200, "endMs": 350}]
```

These timings must belong to the selected WAV. They need no transcript text or
speaker names. The report counts direct overlap, nearest fallback, and
unassigned words; it does not emit the words or timings. Without this file,
assignment counts are zero and do not establish word-level coverage. The
fallback warning divides fallback words by direct + fallback + unassigned
words, excluding source-only words. Mixed-source meeting coverage warnings
are deferred until a source-aware report producer exists.

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

All supplied counts must be positive; minimum must not exceed maximum. The
JSON `requestedSpeakers` field is exact-only. `requestedSpeakerHint` preserves
exact/minimum/maximum semantics on both successful and failed runs.

The report uses `fixture-001`, `fixture-002`, etc. in sorted fixture-directory
order, and anonymous `S1`, `S2`, etc. speaker keys. It omits folder/audio paths,
transcript text, provider ids, RTTM labels, and raw error messages. A failed
model run has `error: "diarization_failed"`; cancellation stops evaluation.
Keep the local directory ordering alongside reports when comparing runs.

## Scope and evidence

This command supplies measurement infrastructure. It does not establish a
real-world accuracy gain without a representative labelled corpus. The
experimental `SpeakerWordAssigner` is used only here and in tests; production
transcription and meeting attribution keep their current policies, speaker
priors, and identity behavior. The earlier proposed
`transcribe --diarization-report PATH` integration and speaker-label provenance
changes are deferred. Existing `transcribe --speaker-count/min/max` remain
unchanged.

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
