# Issue 1046 baseline freeze — VoxConverse Auto over-split

Frozen 2026-09-15. This is the source of truth for the [#1046](https://github.com/moona3k/macparakeet/issues/1046) A/B. Do not retune thresholds on these files.

## Claims under test

1. Unconstrained Auto (`--speaker-detection on`, no `--speaker-count` / min / max) over-splits some recordings. A cluster-consolidation post-pass must move those rosters toward the RTTM speaker count without collapsing files that are already correct.
2. Neighbor-agreement smoothing can remove isolated word-level speaker artifacts without changing the underlying roster.

This is **not** a DER harness. It is **not** the Exact / max-cap path from [#1023](https://github.com/moona3k/macparakeet/issues/1023). Exact-1 and max-2 JSON in the same results directory are constraint tests; they must not be scored as Auto quality.

## Oracle

[VoxConverse v0.3](https://github.com/joonson/voxconverse) test split, CC BY 4.0. Unique speaker count = unique `SPEAKER` column 8 in the copied RTTM under `benchmarks/diarization/rttm/`. That count matches `selected_files.tsv` `rttm_speakers` for every file below (verified 2026-09-15).

Do **not** use MacParakeet library folders as labels.

## Audio

16 kHz mono 16-bit WAV at `$HOME/asr-bench/voxconverse/wav/test/<id>.wav` (same layout as `selected_files.tsv` `wav_relpath`). Not in git. Download: `python3 benchmarks/diarization/scripts/download_selected_wavs.py`.

| File | RTTM speakers | RTTM speech s | WAV duration s | WAV bytes | SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| `wibky` | 1 | 239.48 | 302.91 | 9693262 | `ccb07166a2faa29f21c399da6b6b7e51179b6846c30a339f01ceed0212a2bf00` |
| `sfdvy` | 1 | 321.54 | 336.58 | 10770510 | `86c03232e9e7e16a86cb76c102617df323cca58638d77d57fb5c295af0a0cdfa` |
| `bxcfq` | 2 | 201.38 | 196.48 | 6287438 | `9b928831c6f37e22dc055b7c732a75511c610a59ec0c275193f14d9f9842a8c1` |
| `gylzn` | 2 | 350.72 | 363.65 | 11636814 | `9018d9c65f8cd594b95e2cd843531866d154d8f8313916e576d971c58262434d` |
| `ouvtt` | 2 | 708.66 | 727.62 | 23283790 | `be6f9b14149c0f92e4d2d928edf60e19d19671f93b27cb3409e8b3cb96f924fe` |
| `fyqoe` | 3 | 356.85 | 311.10 | 9955406 | `fdd01a3087a247a46aa3495c51f4aa39f3c49875a786853f833b7fd4fd119bc2` |
| `ledhe` | 3 | 397.87 | 402.75 | 12888142 | `44943e09dc9ee1537339b7ac16c79d3aaff98cd0c997ce0983b123e09040c029` |

RTTM SHA-256 (in git):

| File | SHA-256 |
| --- | --- |
| `wibky.rttm` | `177bb9c623dc019b83c40afb8741615e5e4e0f2f021ed72006b8a0fc16bd2a70` |
| `sfdvy.rttm` | `a4d0f7e1ed369c9a6d48d1ec5590e32993a0e54db759e2371f55eee99e0d0937` |
| `bxcfq.rttm` | `1b1d0809df792475e5ef67b11c5c6f8e08bdb7acbcd72a4e831fc1218b85a9fd` |
| `gylzn.rttm` | `c18d171b16e0457cd55892a7a5b92655bd9cc77eb7f90bafa25bfae84382dcb9` |
| `ouvtt.rttm` | `a9e6b9745027fbef9fc423a41cc4eb0bcf5714e81a767808601478c5123f4039` |
| `fyqoe.rttm` | `d622d5f66df5dfc9d23353a002eef1a802af86dbe9f6018fa01adda49ecc60fc` |
| `ledhe.rttm` | `35bd38eb21c50ed0ea00f5d0d23e69ac869ea860c5eba4c171cd1ccb47389445` |

## Frozen Auto baseline

CLI JSON from the 2026-09-13 FluidAudio 0.15.7 pin A/B, **candidate** arm (0.15.7, unconstrained). 0.15.6 unconstrained rosters were identical; this is current Auto on the pinned pipeline.

Path: `$HOME/asr-bench/fluidaudio-0.15.7-ab/results/candidate/<id>.unconstrained.json`.

CLI JSON has speakers, word timestamps, and diarization segments. It does **not** include centroids. Consolidation cannot be replayed from JSON; a candidate must re-run `macparakeet-cli transcribe`.

| File | Auto roster | Word-ID count | Isolated one-word flip (same neighbors) | Nil words | JSON SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| `wibky` | **2** | 889 | 0 | 7 | `8e1d4760bba39567b1009f2fa04c2e0f5481bf7aadf26bfd25d7b0863894905c` |
| `sfdvy` | 1 | 1004 | 0 | 4 | `f6c0e9f28889d8ce63f31f65065bfa1af1ebe51f067abd94766b8f563fdb478d` |
| `bxcfq` | **3** | 697 | 0 | 27 | `aefc29498ef2b28506e0930c9cbb500effb38189c40b437a33f14034e4d0dcec` |
| `gylzn` | 2 | 1187 | 0 | 20 | `c6505cc77baf0d94a568b9db74f3316e62fed6b67e0cedeaadeee9ce9f0ebe5b` |
| `ouvtt` | **4** | 2081 | 4 | 27 | `e23608f02414a16252bccbfdc5a18e4b9020261da8ba6c63624b8077ae9f3069` |
| `fyqoe` | **4** | 1094 | 2 | 22 | `97c22af15469be5331c7685c7a376a900fcc85a08043851a9a694a9661995d40` |
| `ledhe` | 3 | 1193 | 0 | 8 | `8cd9b527ba6374eece639fdddc455b9b9ba4f5f57688000bf771e86099701aef` |

Roster = `len(speakers)` and matched unique `wordTimestamps[].speakerId` / `diarizationSegments[].speakerId` on this baseline.

Isolated one-word flips are rare here. Smoothing is specified by unit tests. The A/B gate is **roster vs RTTM**.

## Recorded A/B result

Command: `benchmarks/diarization/scripts/run_issue_1046_unconstrained_ab.sh`, debug build, Parakeet ASR, speaker detection on, no history. Baseline and candidate word text/timestamps aligned exactly on every file.

`Bounded nil` means unlabeled words in a run whose immediate non-nil neighbors have the same speaker. It is the only nil case the smoothing rule fills.

| File | RTTM | Baseline roster | Candidate roster | Isolated flips | Bounded nil words | All nil words |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `wibky` | 1 | 2 | 2 | 0 → 0 | 7 → 0 | 7 → 0 |
| `sfdvy` | 1 | 1 | 1 | 0 → 0 | 4 → 0 | 4 → 0 |
| `bxcfq` | 2 | 3 | 3 | 0 → 0 | 27 → 0 | 27 → 0 |
| `gylzn` | 2 | 2 | 2 | 0 → 0 | 18 → 0 | 20 → 2 |
| `ouvtt` | 2 | 4 | 4 | 4 → 0 | 27 → 0 | 27 → 0 |
| `fyqoe` | 3 | 4 | 4 | 2 → 0 | 21 → 0 | 22 → 1 |
| `ledhe` | 3 | 3 | 3 | 0 → 0 | 8 → 0 | 8 → 0 |
| **Total** | — | — | — | **6 → 0** | **112 → 0** | **115 → 3** |

Result:

- **Smoothing passes its bounded claim.** It changed 118 word assignments, removed all six isolated flips and all 112 same-speaker-bounded nil words, and preserved all seven rosters. The three remaining nil words are at a boundary or between different speakers.
- **Centroid consolidation fails its claim.** It changed zero rosters. The implementation and synthetic tests were removed from the shipping change.

### Why consolidation was rejected

All over-split fixtures had complete centroid coverage, but no pair was within the independently frozen tau 0.25:

| File | Closest centroid pair | Cosine distance | Assigned speech s |
| --- | --- | ---: | --- |
| `wibky` | S1 / S2 | 0.474 | 227.5 / 19.7 |
| `bxcfq` | S2 / S3 | 0.926 | 144.8 / 1.6 |
| `ouvtt` | S1 / S2 | 0.569 | 138.1 / 507.2 |
| `fyqoe` | S1 / S3 | 0.433 | 60.5 / 170.4 |

`wibky` is one actual speaker, but merging its pair would require tau ≥ 0.474. Phase 0b measured different-speaker clean-sample distances beginning at 0.47. Raising tau to make this frozen case pass would therefore fit the benchmark inside known different-speaker territory. No threshold change was made.

## Original consolidation gate (failed)

Score unconstrained only, same engine, `--no-history`, `--format json`.

| File | Must |
| --- | --- |
| `wibky` | roster 2 → 1 |
| `sfdvy` | stay 1 |
| `bxcfq` | 3 → closer to 2; must not go to 1 |
| `gylzn` | stay 2 |
| `ouvtt` | 4 → closer to 2; must not go to 1 |
| `fyqoe` | 4 → closer to 3; must not go to 1 or 2 |
| `ledhe` | stay 3 |

The candidate preserved `ledhe` and `gylzn`, but none of the four over-split rosters improved. This gate rejected centroid consolidation; it is not a merge gate for the narrower smoothing-only change.

Tau is frozen from Phase 0b / `SpeakerMatchPolicy.v1` (`tau 0.25`), not fitted on this slice. Long-long merges do not use voiceprint runner-up margin.

## What this slice cannot decide

- Meeting 1:1 `MeetingSpeakerPrior` (`max = n + 1`). These files are not dual-track meetings.
- Overlap / two-talker confusion (no DER).
- Private meeting dogfood. Useful later; not a merge gate.
- Historical DER quotes from ADR-010 (pre-0.15.6 clustering port).
