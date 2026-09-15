# Issue 1046: automatic speaker detection / segmentation

Reviewed September 15, 2026. Local decision note after [#1044](https://github.com/moona3k/macparakeet/pull/1044) landed.

Source: [#1046](https://github.com/moona3k/macparakeet/issues/1046) (k1n0b0n, 2026-09-15). Related shipped work: [#972](https://github.com/moona3k/macparakeet/issues/972), [#1023](https://github.com/moona3k/macparakeet/issues/1023), [#542](https://github.com/moona3k/macparakeet/issues/542). Related still-open quality hole: Auto 1:1 over-split described in [#944](https://github.com/moona3k/macparakeet/issues/944) (closed without Auto getting cleaner).

Implementation plan: [`plans/active/2026-09-15-issue-1046-speaker-over-split.md`](../../plans/active/2026-09-15-issue-1046-speaker-over-split.md). Frozen A/B assets: [`benchmarks/diarization/2026-09-15-issue-1046-baseline.md`](../../benchmarks/diarization/2026-09-15-issue-1046-baseline.md).

## Verdict

Keep **one** GitHub issue. The two symptoms are the same clustering and word-assignment system failing in opposite directions, then looking like a segmentation bug in the transcript UI.

This is a real, default-on quality hole, not a voice-profile feature request. Automatic speaker detection is on where supported. Experimental voices ([#662](https://github.com/moona3k/macparakeet/issues/662), [#1044](https://github.com/moona3k/macparakeet/pull/1044)) only name clusters after clustering, and only behind `AppFeatures.voiceProfilesEnabled = false`. A one-word flip into a new speaker ID is what users see, and it would also poison later enrollment.

**Ship the bounded presentation fix; keep the clustering problem open.** Isolated word-level artifacts are testable and shippable with harnesses already in the repo. The attempted centroid consolidation did not improve any roster and is not shipping. Do not auto-tune the clustering threshold. Do not let voices steer clustering. Do not promise overlap / two-talker perfection without a DER gate we do not have.

## What the report is

Max hit this while working on remembering speakers across meetings. Observed:

1. Single words labeled as different speakers when they are the same person (screenshot: many speaker labels, one actual person).
2. Two people landing on the same speaker, but only on those short segments.
3. Offer of a testbench and a self-adjusting embed-distance setting.
4. Question: one issue or two.

They are linked. Raising the clustering cut merges more (helps 1, hurts 2). Lowering it splits more (hurts 1, helps 2). A live auto-threshold will chase whichever error the last meeting punished.

## Two layers in the screenshot

**Clustering.** FluidAudio's offline community-1 + VBx path over-splits one person into `S1` / `S3` / `S7`, or parks a noisy short embedding in the wrong cluster. The app currently runs `DiarizationService.highAccuracyConfig`: `stepRatio 0.1`, `embedding.minSegmentDurationSeconds = 0`, zero-vote re-embed on, library-default `clustering.threshold`. Short turns keep their own embedding on purpose (ADR-010 2026-09-06 amendment, [#972](https://github.com/moona3k/macparakeet/issues/972)). That is a DER win on long turns and a source of one-word speaker IDs.

**Presentation.** `TranscriptSegmenter.segmentBoundaries` starts a new bubble on every speaker-ID change (`Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift`). Isolated one-word ID flips therefore look like "cluttered transcription segmentation" even when ASR chunking is fine. Consecutive same-ID words already group into one turn; collapsing bogus IDs is what cleans the UI, not a new Markdown renderer.

`SpeakerMerger.mergeWordTimestampsWithSpeakers` first assigns by maximum direct overlap, then applies the neighbor-agreement smoothing added by this change. A no-overlap run remains nil unless both surrounding speaker runs agree. There is no nearest-turn fallback at transcript edges or between different speakers (`Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift`).

## What already shipped (do not redo)

| Work | What it did | What it did not do |
| --- | --- | --- |
| [#972](https://github.com/moona3k/macparakeet/issues/972) / ADR-010 2026-09-06 | FluidAudio 0.15.6, high-accuracy async config, calendar prior as a **cap** | Embedding consolidation; `SpeakerMerger` smoothing |
| [#1023](https://github.com/moona3k/macparakeet/issues/1023) / ADR-010 2026-09-13 | Pin 0.15.7 so Exact / `maxSpeakers` bind on both cluster censuses | Unconstrained Auto over-split. Eval: `benchmarks/diarization/2026-09-13-fluidaudio-0.15.7-eval.md` |
| `MeetingSpeakerPrior` | System-track bounds `min = 1`, `max = n + 1` for 1–8 countable remote attendees | A 1:1 invite still legally yields two remote labels (`Others` + `Others 1`). That is the [#944](https://github.com/moona3k/macparakeet/issues/944) hole. A wrong `minSpeakers` would K-Means-split real people, which is why min stays 1 (`Sources/MacParakeetCore/Services/Diarization/MeetingSpeakerPrior.swift`) |
| [#542](https://github.com/moona3k/macparakeet/issues/542) / #960 | Edit speakers: rename, merge, remove, split, undo | Manual merge is the escape hatch, not the automatic fix |
| [#1044](https://github.com/moona3k/macparakeet/pull/1044) | Meeting voice profiles behind a disabled gate | Must not rewrite automatic speaker IDs |

ADR-010 already named the remainder: embedding-based consolidation of over-split clusters, and `SpeakerMerger` smoothing / nearest-turn fallback for sub-second words. The 2026-09-06 synthesis listed the same post-passes after the FluidAudio upgrade: `docs/research/2026-09-06-speaker-diarization-claude/synthesis.md`.

The May quality plan (`plans/active/2026-05-speaker-diarization-quality.md`) still describes FluidAudio 0.14.5 and `OfflineDiarizerConfig.default`. Treat it as historical for the hint plumbing; this note is the current #1046 call.

## Inventory (2026-09-15)

Verified on disk before implementation. Details and SHA-256s are in the freeze file.

- Seven VoxConverse test WAVs at `$HOME/asr-bench/voxconverse/wav/test/`, 16 kHz mono, SHA-256 match recorded.
- RTTM unique speaker counts match `selected_files.tsv` for every file.
- Frozen Auto JSON from the 0.15.7 candidate arm still present; unconstrained rosters: `wibky` 2, `sfdvy` 1, `bxcfq` 3, `gylzn` 2, `ouvtt` 4, `fyqoe` 4, `ledhe` 3.
- CLI JSON has no embeddings — candidate A/B must re-run diarization.
- Isolated one-word flips are rare on this slice (0 on five files, 2 on `fyqoe`, 4 on `ouvtt`). Roster is the A/B gate; smoothing is unit-tested.
- Not present: labeled 1:1 meeting audio, DER harness, private-meeting CI.

## Recorded result

The unconstrained candidate produced the same speaker roster as the frozen baseline on all seven files: `2, 1, 3, 2, 4, 4, 3`. This proves the word-level smoothing does not create, merge, or drop speaker clusters, but it fails the proposed centroid-consolidation gate: none of the four over-split rosters moved toward RTTM truth.

Diagnostics ruled out missing embeddings. On `wibky` (one actual speaker, two detected clusters), both centroids were present, but their cosine distance was 0.474 with 227.5 s and 19.7 s of assigned speech. The independently frozen tau was 0.25. Raising tau enough to make this case pass would enter Phase 0b's measured different-speaker range (0.47–0.84), so that would be an unsafe fit to the gate.

Decision: ship only neighbor-agreement smoothing and the reproducible benchmark infrastructure. Remove centroid consolidation from the product path and document it as a rejected attempt. Auto roster over-splitting remains open in #1046.

## Can we test it, and can we do it

**Yes, for fewer isolated word-level artifacts without changing the roster.** That is a measured PR, not a new model. The available data is also enough to reject the tested centroid-only approach, but not to claim fewer Auto clusters.

Already in repo:

- VoxConverse v0.3 slice and CLI A/B: `benchmarks/diarization/`. Audio is not in git; recipe downloads WAVs. JSON already exposes `speakers`, `wordTimestamps[].speakerId`, `diarizationSegments`. Roster scoring is `scripts/score_speaker_count.py`. Singleton-word flips are a cheap extra scorer on the same JSON.
- Unconstrained over-splits already measured on this pin (identical on 0.15.6 and 0.15.7):

  | File | RTTM speakers | Unconstrained roster |
  | --- | ---: | ---: |
  | `wibky` | 1 | **2** |
  | `sfdvy` | 1 | 1 |
  | `bxcfq` | 2 | **3** |
  | `gylzn` | 2 | 2 |
  | `ouvtt` | 2 | **4** |
  | `fyqoe` | 3 | **4** |
  | `ledhe` | 3 | 3 |

  `ledhe` and `gylzn` are the "do not merge real people" regressions. `wibky` / `ouvtt` / `bxcfq` / `fyqoe` are the over-split targets.
- Per-cluster WeSpeaker centroids already come back from `DiarizationService`. Voiceprint Phase 0b showed same-narrator cosine distance 0.05–0.23 vs different-narrator 0.47–0.84 on clean public audio (`docs/research/2026-07-04-voiceprints-phase0b-clean-corpus.md`). That is the consolidation signal, used **after** clustering, not as a live clustering thermostat.
- `SpeakerMerger` and `MeetingSpeakerPrior` are pure functions with existing tests.

**Only weakly, for two people on one short word.** That needs overlap-aware scoring (DER / word-attribution on overlap). FluidAudio's `diarization-benchmark` CLI exists; this repo has never used it as a ship gate. The 0.15.7 eval explicitly does not claim DER. Max's private meetings are useful dogfood on his machine; they are not CI. The last local 1:1 library rows used in the 0.15.7 eval had no recoverable audio.

**No, for a self-adjusting embed distance.** Unstable, untestable as a frozen gate, and the wrong tool for two opposite errors.

## Decision after the A/B

Keep automatic IDs as evidence; user corrections stay the overlay (ADR-010 2026-09-05). Do not retune `clustering.threshold` as the product fix.

1. **Ship smoothing.** An isolated one-word ID flip inherits the neighboring speaker only when both sides agree. An unlabeled run gets the same treatment. A gap between different speakers, transcript edges, and multi-word speaker runs stay unchanged. Unit tests define these boundaries.

2. **Defer centroid consolidation.** Existing VBx centroids at frozen tau 0.25 changed 0/7 rosters. Do not ship inactive product code and do not raise tau toward known different-speaker distances. A future attempt needs a safer signal and a held-out gate.

3. **Tighter 1:1 cap only if (2) is not enough.** `max = n + 1` is why a calendar 1:1 can still show two remote speakers. Changing 1:1 to `max = 1` (or skipping clustering on the system track) is a one-line prior plus `MeetingSpeakerPriorTests`, and a real product tradeoff if a third person joins an invite that said 1:1. Do not raise `minSpeakers` above 1.

Contributor testbench: welcome if it scores unique IDs vs truth, singleton-word speaker changes, and short-turn confusion on **frozen** public or locally held audio, with no transcript text, names, or file names in the GitHub thread. It is not a live tuner and not a Settings slider.

## Must not

- Auto-adjust `clustering.threshold` or tau from production meetings.
- Feed voice-profile matches back into clustering or silently merge labels because a profile scored close (wrong-person learning is worse than a missed suggestion; see `spec/contracts/speaker-voiceprints.md`).
- Replace FluidAudio with another diarizer as the first move. ADR-010 and the 2026-09-06 synthesis: the model is not the remaining problem.
- Close #1046 (or #662) because Edit speakers can merge by hand.
- Use MacParakeet library folders as labeled ground truth.
- Quote historical DER (~15%, 13.89%) as a measurement of the pinned 0.15.7 high-accuracy path. Those figures predate the clustering-port fixes and were not re-run on this pin.

## Priority

More user-visible than experimental voices: detection is default-on. Voices stay gated. If Max wants a next PR after #1044, this is the right problem, with the sequence above. Do not start it as a drive-by in the same week unless fixtures are already on disk (`$HOME/asr-bench/voxconverse` from the 0.15.7 eval).

A GitHub reply, if one is posted later, should say: keep one issue; yes the symptoms are linked; testbench yes if it scores frozen audio; no auto-threshold; neighbor-agreement smoothing is ready, while safe roster consolidation still needs a better signal.
