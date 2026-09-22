# File audio runtime verification

Completed 2026-09-07. Track selection, invalid-track handling, and two-speaker runtime checks passed. All 29 schema, content-source, persistence, and integrity assertions passed. A speaker-boundary attribution mismatch remains visible in both diarization runs; this is not an accuracy certification or a release-ready verdict.

## Candidate and isolation

- Executable: the root-owned copied `macparakeet-cli-runtime`, SHA-256 `f8a62b79ece6045909d15ece2fd086eed7e10ca04ebc870d9fc50ed76774f095`, verified before and after execution.
- Compiled source provenance supplied by root: base `8548c099af5ee2ab0ed4dd9efe757d85c498cca0` plus recovery fix `c506d7ef7d4cf98f3986cfb5de84ced6b4ce701e`. GUI-only cache commit `df98cfbd41a150f8ee510dd1333bfa6db176e342` does not change this CLI's exercised paths.
- Stable comparison channel: `v0.7.3`; no stable-binary A/B inference was performed.
- `CFFIXED_USER_HOME=/tmp/macparakeet-080-qa/isolated-home` used the prepared public model cache. Every run set `MACPARAKEET_TELEMETRY=0`, `DO_NOT_TRACK=1`, an owned `TMPDIR`, and a separate owned `--database`.
- Every command explicitly selected raw processing, engine, model variant, and speaker-detection mode. No configuration or model-selection writes were made. Successful runs intentionally saved only public/generated content to their disposable database so persistence could be checked.
- Inference was sequential, with a 180-second process-group deadline per invocation. No case timed out. No desktop interaction, audio playback, microphone/system-audio capture, Swift build, or package test ran in this subtask.

Raw working directory: `/tmp/macparakeet-080-qa/file-audio-runtime`. Curated evidence links below resolve after its `sanitized-artifacts/` contents are copied to `evidence/file-audio-runtime/` beside this report. SQLite databases and temporary model/conversion files are excluded from that curated set.

## Observed matrix

| Case | Outcome | Exit | Wall time | Observed evidence |
|---|---|---:|---:|---|
| Embedded track 1, Nemotron multilingual, English hint | Passed | 0 | 1.456 s | Expected English passage; JSON and one completed database row both store audio ordinal `0` |
| Embedded track 2, Nemotron multilingual, Japanese hint | Passed | 0 | 34.277 s | Expected Japanese passage; JSON and one completed database row both store audio ordinal `1` |
| Invalid track 0 | Passed rejection | 2 | 0.030 s | Argument validation error; zero transcription rows |
| Missing positive track 3 | Passed rejection | 2 | 0.311 s | JSON `errorType: validation`; zero transcription rows; no silent fallback |
| Two public speakers, Parakeet v3, automatic speaker count | Runtime passed; boundary mismatch | 0 | 28.090 s | Two final speakers and two diarization turns; both source passages retained |
| Same fixture, exact speaker count 2 | Runtime passed; boundary mismatch | 0 | 1.155 s | Two final speakers and two turns; explicit constraint applied in runtime log |

These are single-run wall times, affected by cache warming. They are not comparable latency benchmarks. The first English attempt completed inference and persistence, but the harness failed while serializing SQLite's binary UUID. Its original JSON/log/database remain in the working directory. The runner was corrected to encode binary values as hex, and English was repeated under a new case name to retain reliable exit/time metadata. The table uses that verified repeat.

## Embedded audio selection

The existing `two-tracks.mkv` has synthetic color video at container stream `0`, English audio at stream `1`, and Japanese audio at stream `2`. Its SHA-256 is `7501a235b599d08d8cc449d8ea7d6e53177d2e508387582c0d5c4fb44b423bff`.

Decoded 16 kHz mono PCM bytes from each embedded audio track exactly matched its public FLEURS input. This verifies the fixture itself before evaluating the application's selection:

| CLI track | Persisted audio ordinal | Public reference | PCM samples | PCM SHA-256 |
|---|---:|---|---:|---|
| 1 | 0 | `en_us_0000.wav` | 168,960 | `3f4a596a69474e5e9336fc22f87bfa9a876b9f145da56f641bfd8b26d5f74029` |
| 2 | 1 | `ja_jp_0000.wav` | 167,040 | `7eafd8517298b7ad9d096362fd1931ff533081f1986a5af6061651a13fd0122c` |

Track 1 returned “However, due to the slow communication channels, styles in the West could lag behind by twenty five to thirty years.” Track 2 returned `インターネットで敵体的環境コースについて検索すると、おそらく現地企業の住所が出てくるでしょう.` The Japanese reference uses `敵対的`, so the hypothesis has a character substitution. These observations establish distinct intended content; neither transcript is presented as an exact accuracy pass.

Both successful JSON records report engine `nemotron`, variant `multilingual-1120ms`, the requested language, and the expected zero-based ordinal. A read-only SQLite query confirmed the same ordinal and transcript in exactly one completed row per case. The two invalid cases had no rows of any status. The missing-track error was `--audio-track 3 is unavailable for two-tracks.mkv (2 audio tracks).`

Evidence: [fixture stream probe](evidence/file-audio-runtime/two-tracks-probe.json), [PCM equality](evidence/file-audio-runtime/track-pcm-equivalence.json), [English result](evidence/file-audio-runtime/track-1-en-verified.json), [Japanese result](evidence/file-audio-runtime/track-2-ja.json), [missing-track error](evidence/file-audio-runtime/track-3-missing.json), [all execution and database observations](evidence/file-audio-runtime/results.json).

## Two-speaker fixture and actual turns

The derived WAV concatenates these two unmodified public LibriSpeech utterances with 1.5 seconds of generated silence between them. The corpus `SPEAKERS.TXT` confirms that IDs `1089` and `1188` identify different readers. No overlap was synthesized.

| Source | File interval in derived WAV | SHA-256 of source FLAC |
|---|---|---|
| `1089-134686-0000.flac` | 0–10.435 s | `30885601173f96b0d8ddd020dc959b055c6c1582b85a33e3fcab8c4b08ed94c2` |
| Generated silence | 10.435–11.935 s | Not a source recording |
| `1188-133604-0000.flac` | 11.935–22.660 s | `4a10149395cb5af8aa5d04ef3adb49b3980baa93114d0851046e6343744b26cb` |

Derived file: `two-public-speakers.wav`, mono 16 kHz signed 16-bit PCM, 22.660 seconds, SHA-256 `d38d2c43eab8b3924be380c635fa38633fe4fcc5bf48cc3dc966b69ac7871a39`. Source hashes were unchanged after the runs.

Both runs produced the same final turns:

| Output cluster | Start | End | Observed content |
|---|---:|---:|---|
| S1 / Speaker 1 | 0.000 s | 10.119 s | First reader's stew passage |
| S2 / Speaker 2 | 12.462 s | 22.122 s | Second reader's discussion of four painters |

The automatic run's intermediate clustering log reported three centroids; final reconstructed output contained two speakers. The exact-count run logged `numSpeakers=2, min=2, max=2` and explicitly re-clustered from three to two. The report uses final exposed speakers and turns, while preserving intermediate diagnostics.

### Boundary attribution mismatch

The second source starts “You will find me continually speaking…”. In both runs, `You` has timestamp 12,160–12,320 ms and no word-level `speakerId`. The assembled transcript segment appends it to the first speaker's passage and labels that whole segment S1. `will` and the following passage belong to S2. Thus two detected speakers do not mean every displayed word is attributed correctly.

This matches the existing `TranscriptSegmenter.segmentBoundaries` behavior that lets words without an assigned speaker inherit the current segment speaker. No production change was made here, and no stable-release A/B run established whether this is a regression. [Quality observation](evidence/file-audio-runtime/quality-observations.json) retains the exact word and containing segment for a future focused regression test.

The fixture intervals include each utterance's own silence. They are not manually annotated voice-activity boundaries. No DER score, overlap accuracy, general speaker recognition, live-meeting behavior, or broad ASR accuracy claim follows from this smoke check.

Evidence: [automatic output](evidence/file-audio-runtime/diarization-auto.json), [exact-count output](evidence/file-audio-runtime/diarization-exact-2.json), [speaker and transcript turns](evidence/file-audio-runtime/speaker-observations.json), [automatic diagnostics](evidence/file-audio-runtime/diarization-auto.stderr.log), [exact-count diagnostics](evidence/file-audio-runtime/diarization-exact-2.stderr.log).

## Reproduction and assertions

The working directory retains `run.py` and `assert-results.py`. The runner refuses to overwrite completed case outputs, validates the candidate hash, checks that diarization model bundles exist, creates only derived audio, executes each process sequentially, records sanitized stdout/stderr and exit/time metadata, and queries only its own database. Use a new output directory for a full replay; do not delete prior evidence to rerun it.

All inference commands share these explicit options:

```text
transcribe INPUT --database OWNED_CASE.sqlite --mode raw --format json
```

Track cases add:

```text
--engine nemotron --nemotron-model multilingual-1120ms --speaker-detection off
--language en|ja --audio-track 1|2|0|3
```

Diarization cases add:

```text
--engine parakeet --parakeet-model v3 --speaker-detection on
# Exact-count case additionally supplies: --speaker-count 2
```

The saved [29 assertions](evidence/file-audio-runtime/assertions.json) cover JSON structure, completed status, positive duration, retained transcript content, one completed row per successful case, engine/variant/language, JSON/database ordinals, reference-content anchors, different selected-track hypotheses, validation exit codes with zero rows, speaker IDs and turn ranges, exact count two, word-to-speaker referential integrity, original file preservation, and fixture PCM equality. The separate boundary mismatch is not hidden by those structural passes.

## Methodology notes for the next pass

- Worked: content-distinct tracks after a video stream caught audio-ordinal versus container-index confusion without relying on metadata alone. PCM equality made the fixture provenance deterministic.
- Worked: public corpus references, disposable per-case databases, explicit flags, and before/after hashes allowed real inference and persistence verification without touching personal recordings or devices.
- Worked: model and diarizer diagnostics showed actual preparation, inference, clustering, and explicit constraint handling. Cached directory presence alone was used only as preflight.
- Did not work initially: the harness assumed SQLite IDs were JSON-native values. Encoding UUID BLOBs before serialization fixed reporting; the repeat and original attempt are distinguished above.
- Did not establish: GUI track picking, microphone capture, system-audio capture, acoustic echo cancellation, hardware route changes, concurrent recordings, cancellation during inference, or packaged release behavior. Cohere was deliberately excluded; root owns its prior long-load evidence.
- Follow-up candidate: a deterministic boundary-word test for unassigned words immediately before a new speaker. Preserve the observed raw word and segment behavior when deciding whether to change attribution policy.
