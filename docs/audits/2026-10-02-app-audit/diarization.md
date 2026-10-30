# Speaker diarization audit — 2026-10-02

Audited baseline: `f43f4bed2ba7d4afdb005369759afc3d6cc44d34` (use the full recorded head in the [run receipt](evidence/diarization/run-receipt.json) as authority). Scope: anonymous acoustic speakers, file/meeting word attribution, timing, backend routing, loading/cancellation, corrections, voice profiles, diagnostics and evaluation. This report distinguishes current execution from older repository evidence and recommendations. No production diarization policy was changed during this audit.

## Verdict

The model adapter and source-separated meeting architecture are substantially stronger than the user-facing assurance around them. Nemotron is a defensible default, and the new executions below reproduce a meaningful improvement over the retained Community-1 backend on two regression cases. They also reproduce a remaining extra speaker. The next highest-value work is to measure the final **words attributed to people**, preserve uncertainty and expose failures. Another blanket backend replacement or threshold adjustment is not justified by this audit.

The microphone is deliberately one source labeled **Me**; only the system track is diarized in captured meetings. A room full of people around one Mac microphone therefore remains one source. This is an accepted scope boundary, not a regression. Imported file transcription can diarize all audible speakers. Neither an anonymous cluster nor a calendar attendee is evidence of a person's identity.

## Current execution: four matched acoustic runs

Runs used the current Debug `diarization-benchmark`, public cached VoxConverse WAVs, and cloned app model assets. `sandbox-exec` denied all network access during inference. Thirty source/copy model files were SHA-256 compared before and after; all remained unchanged. The input files and personal app state were not modified. The scorer was fetched at the existing pinned dscore revision and its expected SHA-256 verified before running.

| Fixture | Reference people | Backend | Predicted people | DER | Missed speech | False alarm | Confusion |
|---|---:|---|---:|---:|---:|---:|---:|
| wibky, 302.91 s | 1 | Nemotron fast128 | 1 | 1.92% | 0.54% | 1.38% | 0.00% |
| wibky | 1 | Community-1 | 2 | 10.73% | 0.53% | 3.78% | 6.42% |
| ouvtt, 727.62 s | 2 | Nemotron fast128 | 3 | 10.83% | 4.56% | 5.77% | 0.49% |
| ouvtt | 2 | Community-1 | 4 | 25.78% | 12.37% | 4.48% | 8.92% |

Protocol: NIST `md-eval-22.pl` from dscore `e02f949ac6592279300a2c33d03daf9e0c12fd27`, zero collar, overlap included, repository VoxConverse v0.3 RTTM references, explicit UEM from zero to the full decoded WAV duration. The regression slice contains no official UEM; this generated scoring region is part of the result definition. All four runs used identical bytes within each fixture. Both backends were unconstrained. This is an acoustic test, not ASR or GUI capture.

These cases are **regression evidence**, not held-out generalization: NVIDIA's freshly retrieved [pinned model card](https://huggingface.co/nvidia/Nemotron-3-Diarization/blob/f667ed73aee57d40cc39428eb768b4fd87a0a29e/README.md) explicitly includes VoxConverse development and test in training. No inference claim depends on a vendor headline accuracy figure.

Debug processing times were 2.82/3.59 seconds for Nemotron and 2.52/6.74 seconds for Community-1, respectively. First Nemotron preparation took 7.00 seconds; later preparation took 0.23 seconds. Peak resident memory ranged from 204 to 473 MiB for Nemotron and 352 to 399 MiB for Community-1. These are single process runs on a shared Mac with concurrent audit compilation, different cache warmth and Debug code. They establish bounded local execution on these inputs, not optimized latency superiority or total accelerator memory.

Receipts: [scores and protocol](evidence/diarization/matched-regression-scores.json), [run provenance](evidence/diarization/run-receipt.json), [model hashes](evidence/diarization/model-hashes.json). Complete predictions and scorer inputs/outputs remain in `.build/audit-evidence/diarization/`; they contain only public corpus material.

## Current execution: real product integration and word projection

The existing `NemotronDiarizationE2ETests` passed against the first 180 seconds of public `ouvtt` and LibriSpeech `1089-134686-0000.flac`. It ran from the freshly built Debug XCTest bundle with network access denied, isolated app state, a temporary database and cloned models. All 23 original and copied Parakeet asset hashes remained unchanged. A first SwiftPM wrapper attempt failed before running tests because macOS rejects its nested sandbox; the successful run invoked the same prebuilt XCTest bundle directly under the network-deny sandbox.

Observed: 28 microphone words retained **Me**; 552 system words survived, 551 assigned to two remote identities and one retaining **Others**. The 500 ms source offset, chronological ordering, saved/reopened database, meeting JSON/Markdown artifacts and file transcription assertions passed. Reusing the model on silence returned zero speakers. File transcription retained two speakers. The meeting roster contained four entries because it counts the source-only **Others** fallback alongside **Me** and the two detected identities; see DIAR-06.

The single test passed in 33.58 seconds (33.70 seconds process wall time). Meeting finalization took 25.85 seconds, file transcription 2.25 seconds. Peak process RSS was **706.89 MiB**; macOS reported a 775.42 MiB peak memory footprint and zero swaps. This process includes fixture encoding, ASR, both diarizers, persistence and tests. It is not an isolated diarizer memory estimate or evidence of memory behavior during Teams, Bluetooth capture, long meetings or on an 8 GiB Mac. There was no physical microphone/ScreenCaptureKit or native GUI capture in this lane.

Using the exact 552 recognized words/timestamps from that file run, both backends were projected through the existing merger. NIST's one-to-one acoustic speaker mapping was held fixed before/after smoothing; only word midpoints with exactly one reference RTTM speaker were scored.

| Fixed-ASR diagnostic | Community-1 | Nemotron fast128 |
|---|---:|---:|
| Acoustic identities on the crop | 3 | 2 |
| Eligible word midpoints | 491 | 491 |
| Agreement before → after smoothing | 467 → 467 | 487 → 486 |
| Non-nil singleton assignments rewritten | 0 | 2 |
| Eligible correct → wrong / wrong → correct | 0 / 0 | 1 / 0 |
| Unassigned words before → after | 1 → 0 | 5 → 1 |

Twenty-seven no-reference-activity and 34 overlapping-speaker midpoints were excluded. This demonstrates a real correct acoustic assignment lost to smoothing in the tested crop. It does **not** establish a globally superior replacement policy. It is recognized-word midpoint agreement, not cpWER, reference-word alignment or corpus speaker-aware word accuracy; ASR omissions/substitutions and overlap are not evaluated by it. The crop remains training-exposed.

The [sanitized product receipt](evidence/diarization/product-e2e-summary.json) records source/model/report hashes, counts, timing, peak memory, speaker mapping and exclusions; [Parakeet model hashes](evidence/diarization/parakeet-model-hashes.json) record asset identity. Raw public transcript output remains outside the report in `.build/audit-evidence/diarization/product-e2e-raw.json`.

## Highest-value findings

### [DIAR-01] Qualify attribution policy on real short turns before changing it

- **Evidence:** `Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift:63` and `:85` rewrite any one-word A–B–A run to A, regardless of word duration, gap or strength of acoustic assignment. They also fill arbitrarily long unlabeled runs bracketed by the same speaker. `Tests/MacParakeetTests/Services/Diarization/SpeakerMergerTests.swift:191` explicitly requires the singleton rewrite. `SpeakerAttributionResolver.swift:954` separately carries prior speaker identity across automatic nil words.
- **Trigger:** A real one-word reply between two turns by someone else; an ASR word outside detected activity between distant turns; a source-only meeting word between two same-speaker turns.
- **Observed:** An executable replay of the checked-out Swift merger changed a two-second B reply with exact exclusive activity to A. It filled an unknown word in a two-minute gap and relabeled a meeting `system` fallback word with zero acoustic overlap. See [replay results](evidence/diarization/speaker-merger-replay.json) and [reproducer](evidence/diarization/replay-speaker-merger.py). The real fixed-ASR projection above additionally changed one eligible correct Nemotron assignment to an incorrect one; this confirms the failure mode without establishing its population frequency.
- **Impact:** A correct acoustic result can become an incorrect final transcript; a real participant represented only by a brief answer can disappear from the meeting roster because the roster filters to final word IDs (`MeetingTranscriptFinalizer.swift:124`). Coverage can look better while actual attribution gets worse.
- **Effort:** M for characterization, policy design and held-out projection evaluation; larger if adding confidence metadata.
- **Risk:** MED. Existing smoothing repairs model fragmentation; deleting it blindly can recreate speaker bubbles and worsen useful accuracy.
- **Confidence:** HIGH for the demonstrated behavior; MED for its frequency on user meetings.
- **Fix sketch:** Treat this as known policy debt, not an accidental implementation bug. Freeze a short-turn/unknown-gap fixture suite, retain overlap coverage and assignment provenance, and compare conservative time-bounded/uncertainty-preserving variants against the current policy. Require no degradation on genuine short turns before adopting a change. Keep explicit user corrections authoritative.

### [DIAR-02] Persist and surface the result of speaker detection

- **Evidence:** `Sources/MacParakeetCore/Services/TranscriptionService.swift:1816` and `:1998` preserve the ASR transcript after diarization errors but retain only logging/telemetry. the nonfatal-failure section of `spec/adr/010-speaker-diarization.md` promises a nonblocking unavailable notice. No durable per-run disabled/unsupported/no-speech/failed outcome exists in `MacParakeetDiarizationResult` or `Transcription`.
- **Trigger:** Missing/offline/corrupt speaker model or inference failure after successful ASR; a file with no word timings; a meeting without an isolated system track.
- **Impact:** Users see a completed transcript without enough information to distinguish successful anonymous speech, source labels, unsupported attribution, disabled detection and a recoverable model failure. Agents consuming CLI JSON face the same ambiguity. This is a source-proven contract gap; no native warning screenshot was collected in this sub-audit.
- **Effort:** M, including additive persistence/CLI contract, UI warning and focused failure tests.
- **Risk:** MED because old rows, retranscription and exports need backward-compatible semantics.
- **Confidence:** HIGH for the missing outcome through the inspected service/model path.
- **Fix sketch:** Add a small typed outcome with a safe reason code and requested/applied route. Keep ASR successful, show a nonblocking explanation and actionable retry only for recoverable cases, and expose the same outcome in CLI JSON. Unknown legacy state must remain unknown, not retroactively failed.

### [DIAR-03] Record the backend that actually ran and any fallback

- **Evidence:** `NemotronDiarizationService.swift:113` can return Community-1 for an advisory calendar bound, or preserve Nemotron when that fallback fails. `TranscriptionService.swift:1769` emits count, duration and requested prior. `TelemetryEvent.swift:715` / `:1355` has no backend/model/fallback outcome for the diarization event. `DiarizationServiceFactory` routes explicit constraints and developer voice-profile builds to Community-1 at `DiarizationService.swift:122`.
- **Trigger:** A calendar-bound Auto run exceeds its bound; explicit Exact/Range; a developer enables voice profiles.
- **Impact:** The same source/prior/count telemetry can describe different algorithms and costs. A recorded `bounds_1_2` can accompany a successful three-speaker Nemotron result when constrained fallback fails. Production reports cannot reliably separate regression by backend, model or applied policy.
- **Effort:** M for result provenance, privacy allowlist updates and both fallback tests.
- **Risk:** LOW/MED. Keep fields bounded and content-free; do not add speaker names, transcript text, paths or voice vectors.
- **Confidence:** HIGH from call/result/event contracts.
- **Fix sketch:** Return actual backend, immutable model/pipeline revision, requested policy, applied policy and fallback result from the service. Split preparation, queue, inference and projection timings where meaningful; correlate them with the existing transcription operation. Report no quality score without reference labels.

### [DIAR-04] Gate changes on final speaker-attributed words, not only DER and count

- **Evidence:** `benchmarks/diarization/2026-09-25-nemotron-evaluation.md:185` describes one 180-second product projection; the report expressly says it is not cpWER or corpus speaker-aware accuracy. `NemotronDiarizationE2ETests.swift:23` skips the real model integration without four environment variables. The acoustic runner preserves raw intervals; normal CI does not score a representative speech corpus.
- **Trigger:** A model update, ASR timestamp shift, smoothing change, meeting clock correction or source reconciliation change can pass isolated model tests while attributing the final words incorrectly.
- **Impact:** Good DER or an exact roster does not prove who said a particular sentence. Overlap, brief interjections, long pauses, speaker re-entry and source leakage are the practical high-risk cases.
- **Effort:** M for a small licensed fixture gate; L for a meaningful held-out speaker-aware word benchmark and physical capture matrix.
- **Risk:** LOW if tests remain opt-in/scheduled initially and use public/consented fixtures. Avoid adding expensive full-model runs to every edit loop.
- **Confidence:** HIGH for the current verification gap.
- **Fix sketch:** Add a small replay suite in regular CI and a model-backed release/nightly lane. Report DER components, count, short-turn preservation, reference-word speaker accuracy or a properly defined cpWER, unassigned coverage, final ASR WER, persistence/export parity, runtime and peak memory. Store hashes and per-case failures; empty predictions must score as misses. Keep held-out meetings separate from vendor-training-exposed regressions.

### [DIAR-05] Preserve acoustic activity separately from word-derived turns

- **Evidence:** `MeetingTranscriptFinalizer.swift:87` rebuilds `diarizationSegments` from final words at `:144`, filtering out acoustic speakers with no recognized words. File transcription instead persists raw acoustic segments at `TranscriptionService.swift:1988`. After manual assignment, `SpeakerAttributionResolver.swift:182` can derive segments from words. The separate acoustic-timeline contract already exists at `spec/contracts/audio-speaker-timeline-v1.md`.
- **Trigger:** Speech with no ASR words, simultaneous speech, untimed engines, or manual reassignment.
- **Impact:** A field with the same name has different semantics across capture paths and correction state. Speaking-time analytics cannot consistently mean measured acoustic speech time. Better overlap detection alone does not survive into a complete meeting timeline.
- **Effort:** L for deliberate schema/CLI/UI implementation of the existing contract.
- **Risk:** MED. Preserve old representations and correction overlays; do not infer words for untimed paragraphs.
- **Confidence:** HIGH for representation differences; this is an architectural limitation with an existing design, not a newly discovered regression.
- **Fix sketch:** Implement the independent acoustic timeline contract, retaining original source/clock and raw intervals separately from effective text turns. Label analytics according to the quantity measured and keep a one-speaker-per-word view for readable transcripts without discarding overlap evidence.

### [DIAR-06] Stop describing fallback source buckets as additional people

- **Evidence:** The fresh real-model product run retained two remote acoustic identities plus one unassigned remote word. `MeetingTranscriptFinalizer.swift:124` includes both the `system` source fallback and identified `system:S*` labels; `TranscriptionService.swift:1519` derives `speakerCount` from that array. `TranscriptResultView.swift:1637` uses the full array count for its speaker badge and `:1646` subtracts only the microphone for the remote count.
- **Trigger:** Any meeting that has detected remote identities and at least one word outside their acoustic intervals.
- **Observed:** File count was 2; meeting `speakerCount` was 4: Me, Others, Others 1, Others 2. The unknown source bucket contributes an extra count. The native count display is source-inspected, not visually exercised in this sub-audit.
- **Impact:** Metadata and UI can imply an extra person merely because one word was left unassigned. This can send users toward Exact-count retranscription to fix what is actually a presentation/provenance problem.
- **Effort:** M for a shared count/display policy, CLI compatibility decision and focused meeting regression.
- **Risk:** MED. The fallback is essential evidence and must not be removed or forcibly assigned; existing consumers may interpret `speakerCount` as roster-entry count.
- **Confidence:** HIGH, from fresh model-backed output and the count implementation.
- **Fix sketch:** Keep source-only labels available for unknown words, but display detected identities and unassigned audio separately. Specify whether the public count means identity clusters or roster entries and migrate/add fields deliberately. Test mixed identified/unassigned system words, source-only meetings and microphone-only recordings.

## Architecture and controls worth preserving

- **Routing is deliberate.** Auto uses Nemotron fast128, up to eight channels. Exact/Range use Community-1; calendar bounds are advisory, silence stays empty, and fallback failure retains successful Auto output. `DiarizationService.swift:118`, `NemotronDiarizationService.swift:99`, `MeetingSpeakerPrior.swift:31`.
- **Input provenance is sound.** Meeting diarization uses the isolated system WAV and adds the same saved source offset used for system words. The mic stays separate; it is not another cluster in the mixed playback track. `TranscriptionService.swift:1741`, `:1788`, `MeetingTranscriptFinalizer.swift:104`.
- **Loading and cancellation have thoughtful boundaries.** Shared, retryable loading stays outside the macOS 14 inference gate. Nemotron serializes its mutable runner, hops synchronous inference to a detached task, forwards cancellation, checks between one-second feeds and resets stream state per recording. Audio is staged through a disk-backed source. `NemotronDiarizationService.swift:130`, `:155`, `:244`; `DiarizationService.swift:349`, `:399`. This does not prove prompt cancellation inside a single CoreML call or while initially decoding a long file.
- **Corrections preserve canonical evidence.** The correction service and read projection retain the automatic transcript, use fingerprint/revision checks and replay effective attribution. This is preferable to overwriting hundreds of word IDs during a rename. `SpeakerAttributionReadService.swift:31`, `SpeakerAttributionResolver.swift:140`; contract `spec/contracts/speaker-correction-view-model.md`.
- **Voice profiles remain a separate experimental identity layer.** `AppFeatures.swift:48` keeps the compiled feature disabled. Matching has normalized compatible embeddings, duration gates, mutual best match, two-sided margins, exact-tie rejection and explicit confirmation. `SpeakerVoiceprintMatcher.swift:88`, `:189`; service consent gates and deletion paths were inspected. The 3/15-second gates measure cluster duration, not clean isolated speech; the contract says so. A mixed cluster still cannot reliably identify a person. Do not enable the feature broadly based on clean-audio calibration or the present anonymous-diarization results.

## Existing evidence and work, kept separate from today's runs

The committed [September 25 evaluation](../../../benchmarks/diarization/2026-09-25-nemotron-evaluation.md) is unusually explicit about limitations: 36 meetings / 72 microphone signals, improved forced-alignment AMI and weighted AliMeeting, but worse manual AMI DER and 11/20 AliMeeting far-mic regressions. Those are prior measurements, not rerun in this audit. They support the present default while arguing against a universal accuracy claim. Different reference conventions can reverse the headline comparison; do not mix them.

[PR #1201](https://github.com/moona3k/macparakeet/pull/1201) was OPEN when checked. It owns the exact-zero digital-silence dither fix for Community-1; its reported AMI experiment should receive an independent review, including clean-audio cost and profile-identity implications. This audit did not duplicate its source change or claim its author-reported benchmark as locally reproduced. [PR #537](https://github.com/moona3k/macparakeet/pull/537) was also OPEN and overlaps quality controls, diagnostics, provenance and eval tooling; it is an older broad branch. Reconcile current contracts and extract useful parts before stacking new parallel implementations.

## Verification plan and stopping rules

1. Keep the fresh two-case acoustic regression above as the smallest repeatable check. Explicit count checks should additionally assert requested caps; deliberately wrong counts are contract tests, not accuracy comparisons.
2. The isolated real-ASR/meeting-persistence/file/silence E2E passed on the public two-speaker crop above. Preserve this repeatable lane and add a held-out meeting crop. This lane still does not exercise ScreenCaptureKit, a physical mic, Bluetooth or GUI interaction.
3. Before changing smoothing, build a reference-word attribution suite spanning one-word replies, unknown intervals, overlap and re-entry. Fix ASR evidence across policy comparisons. No policy change should ship from synthetic correctness examples alone.
4. Before broad voice-profile availability, use held-out people and meetings, unknown speakers, channel changes and contaminated clusters. Report precision and useful coverage separately; validate consent, correction and forgetting in the actual app.
5. Qualify the supported capture matrix separately: system audio + headset, speaker playback/echo, Bluetooth transitions, pause/resume, long meetings, mic-only rooms and macOS 14 hardware. Source tests and fresh public-file inference do not close those gates.

Coverage: direct inspection of both diarization adapters, model store, routing/prior, merger, meeting finalization and offset mapping, error/telemetry paths, attribution resolver/read projection, voice embeddings/matcher/service boundaries, focused tests, benchmark runner/scorer/acquisition docs and both overlapping open PRs. Voice-profile persistence/concurrency received boundary review, not a fresh end-to-end identity qualification. No claim is made that every line, every device or every language has been tested.
