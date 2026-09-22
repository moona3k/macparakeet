# MacParakeet speaker-attribution baseline audit (2026-09-06)

Audited tree: origin/main at `57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf` (read via `git show
origin/main:<path>`; the cited files are identical in the working tree). FluidAudio 0.15.4 at
`b9d43724cbdb5a980e441fd54180964e94d470f7` (local checkout under `.build/checkouts/FluidAudio`, tag
date 2026-06-16). Static reading only. Nothing was built, run, downloaded, or queried.

Permalink bases used below:
`MP = https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/`
`FA = https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/`

Evidence files: `evidence/baseline-pipeline-trace.md` (full call trace with line ranges),
`evidence/baseline-fluidaudio-0.15.4-offline-defaults.md` (config defaults, pipeline order,
history), `evidence/baseline-tests-and-eval-inventory.md` (tests and harnesses).

## 1. Verdict

MacParakeet ships one diarizer configuration and no post-processing. Every speaker label the user
sees comes from FluidAudio's `OfflineDiarizerConfig.default` (pyannote community-1 powerset
segmentation, WeSpeaker embeddings, AHC at threshold 0.6, VBx merge-only refinement, exclusive
segments, 1.0 s minimum segment) followed by a single max-overlap word assignment. The meeting
pipeline is architecturally sound: it never diarizes the mixed track, keeps the microphone as
"Me", and diarizes only the raw system track, so echo bleed cannot create a phantom diarized
speaker. Where quality is most likely lost is downstream of that decision:

1. Short turns are structurally invisible. Any speaker turn under 1.0 s of clean speech (after
   overlap exclusion and a 20 percent-of-window activity floor) gets no embedding and no segment,
   so backchannels and quick replies are attributed to the neighbouring speaker in files, and to
   a separate generic "Others" bucket in meetings. This is static analysis, not an observed bug,
   but it is directly checkable with one fixture.
2. Speaker count is decided by a single cosine cut (0.6) with no cluster-size floor and no use of
   available priors (calendar attendee count, CLI constraints are opt-in only). VBx can merge but
   never split, so the AHC cut dominates. Over-segmentation into "Others 3, 4, 5" and merging of
   similar voices are both plausible; neither is measured.
3. Word attribution is a raw overlap vote with no smoothing, no boundary snapping, and no use of
   the diarizer's quality scores or confidence. One-word flips create new transcript segments.
4. Corrections do not survive re-runs, and speaker IDs are not stable across runs, so user
   effort is discarded.
5. There is no accuracy harness of any kind. Telemetry records only the detected speaker count.

The smallest seam for a better diarizer or a post-processing pass is
`DiarizationServiceProtocol.diarize(audioURL:)` returning `MacParakeetDiarizationResult`; the
smallest seam for alignment fixes is `SpeakerMerger`; the smallest seam for using "Me"/"Others"
and calendar priors is `MeetingTranscriptFinalizer.finalize` together with
`diarizeMeetingSystemIfNeeded`, which already has both source WAVs in hand.

## 2. Findings

### 2.1 Pipeline as implemented

**Service wrapper.** `DiarizationService` wraps `OfflineDiarizerManager` behind an
`OfflineDiarizerManaging` protocol. The app constructs it with no arguments, so the FluidAudio
default config is used ([MP Sources/MacParakeet/App/AppEnvironment.swift#L234](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeet/App/AppEnvironment.swift#L234);
[MP DiarizationService.swift#L73-L91](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L73-L91)).
The only config surface MacParakeet touches is `withSpeakers(exactly:)` / `withSpeakers(min:max:)`
for CLI count constraints ([L202-L214](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L202-L214)).
`diarize(audioURL:)` runs `process(url)` under the ANE gate, maps `noSpeechDetected` to an
empty result, sorts segments by start, and renames FluidAudio's `S<n>` IDs to `S1, S2, ...` in
chronological first-appearance order with labels `Speaker N`
([L101-L158](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L101-L158)).
`speakerDatabase`, `chunkEmbeddings`, per-segment `qualityScore`, and `timings` from FluidAudio
are discarded.

**File and URL path.** Convert to WAV, transcribe, and only if the engine produced word timings
run diarization on the same WAV, then `SpeakerMerger`
([MP TranscriptionService.swift#L1644-L1729](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1644-L1729)).
Cohere has `providesWordTimestamps: false`
([MP SpeechEngineCapabilities.swift#L353-L360](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/STT/SpeechEngineCapabilities.swift#L353-L360)),
so Cohere transcripts never get speakers; the test at
[TranscriptionServiceTests.swift#L540-L600](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift#L540-L600)
pins that. Parakeet, Nemotron, and Whisper word timings come from token timings via
`STTWordTimingBuilder`, which starts a word at the first SentencePiece boundary token and ends it
at the last sub-token
([MP STTWordTimingBuilder.swift#L5-L67](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/STT/STTWordTimingBuilder.swift#L5-L67)).
Diarization failure is non-fatal and reported to telemetry.

**Meeting path.** Diarization is requested only when a system track exists and the meeting
preference is on ([L1264](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1264)).
The microphone and system tracks are converted and transcribed separately; the microphone file is
the ADR-028 cleaned mic when the readiness decision allows it, else the raw mic; the system file is
always the raw system capture
([L1426-L1488](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1426-L1488),
[L1570-L1584](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1570-L1584)).
`diarizeMeetingSystemIfNeeded` diarizes only the system WAV, shifts segments by the system
track's start offset, and renames speakers to `system:S<n>` with labels `Others N`
([L1490-L1549](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1490-L1549)).
`MeetingTranscriptFinalizer.finalize` tags every word with its source (`microphone` or `system`),
removes microphone words that the reconciler judges to be echo of system words, applies
`SpeakerMerger` to system words only, and leaves system words with no overlapping segment tagged
`system` ("Others")
([MP MeetingTranscriptFinalizer.swift#L23-L125](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift#L23-L125)).
The persisted `diarizationSegments` for meetings are rebuilt from words with a 1.5 s gap merge,
not taken from the diarizer
([L127-L160](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift#L127-L160)).
Live preview during recording uses `MeetingTranscriptAssembler`, which labels only by source and
never diarizes ([MP MeetingTranscriptAssembler.swift#L221-L227](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptAssembler.swift#L221-L227)).

**Rendering.** `TranscriptSegmenter` flushes a segment on speaker change, on sentence punctuation
after three words, on a gap over 1.5 s, or at 40 words; words with a nil speaker inherit the
current speaker ([MP TranscriptSegmenter.swift#L171-L203](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift#L171-L203)).

### 2.2 FluidAudio 0.15.4 offline diarizer internals and defaults

Defaults, with line references, are tabulated in the evidence file. The load-bearing facts:

- Segmentation: 10 s windows, 2 s hop (stepRatio 0.2, comment: "~1.4% worse DER but 2x the
  speed"), three local speaker slots, binary per-frame activations from powerset argmax
  ([FA OfflineDiarizerTypes.swift#L46-L55](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift#L46-L55),
  [FA OfflineSegmentationProcessor.swift#L393-L399](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Segmentation/OfflineSegmentationProcessor.swift#L393-L399)).
- Embedding: one embedding per (window, local speaker). Overlap frames are zeroed
  (`excludeOverlap: true`). A mask with fewer than 20 percent of the window's frames active after
  overlap removal yields no embedding at all (hard-coded `minActiveRatio`); a mask under the 1.0 s
  `minSegmentDuration` falls back to the overlap-inclusive mask
  ([FA OfflineEmbeddingExtractor.swift#L441-L464](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Extraction/OfflineEmbeddingExtractor.swift#L441-L464)).
- Clustering: AHC (fastcluster centroid linkage) at threshold 0.6, converted from cosine
  similarity to Euclidean distance sqrt(2 - 2 x 0.6) = 0.894
  ([FA AHCClustering.swift#L108-L115](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Clustering/AHCClustering.swift#L108-L115)).
  VBx is warm-started with exactly the AHC cluster count and can only collapse clusters (a speaker
  survives if its mixture weight exceeds 1e-7)
  ([FA VBxClustering.swift#L78](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift#L78),
  [FA OfflineDiarizerManager.swift#L530-L536](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift#L530-L536)).
  Every embedding is then re-assigned to the nearest centroid by cosine
  ([L687-L710](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift#L687-L710)).
  Count constraints trigger K-Means to the target count
  ([FA VBxClustering.swift#L685-L723](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift#L685-L723)).
- Reconstruction: per global frame the expected speaker count is the rounded mean activation sum
  across overlapping windows; the top-k clusters by activation are active; same-speaker gaps
  under 0.1 s merge; segments shorter than 1.0 s are dropped; with `exclusiveSegments: true` a
  later segment's start is trimmed to the previous segment's end and the remainder must still be
  at least 1.0 s ([FA OfflineReconstruction.swift#L139-L168](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift#L139-L168),
  [L281-L320](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift#L281-L320),
  [L403-L418](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift#L403-L418)).
- Known fix already inside 0.15.4: commit 30599f9c (2026-04-21, PR #523) fixed a transposed mask
  bug, added the 20 percent activity filter, and switched to binary masks, citing "97% F1 vs
  PyTorch pyannote" on one 467 s three-speaker file (attributed claim, single file, no dataset).
  No offline-diarizer changes after the tag are visible locally; the frontier report owns what
  changed upstream afterwards.
- Documentation drift inside the checkout: `BenchmarkAMISubset.md` says the default clustering
  threshold is 0.7 and reports AMI SDM subset DER 12.0 percent (collar 0.25 s, overlap ignored,
  speaker count not oracle, one of four meetings found 2 of 4 speakers) and full 16-meeting
  10.62 percent; `CLAUDE.md` in the same checkout still says 17.7 percent. The code default is
  0.6. Whether the reported numbers predate fix #523 is not stated.

### 2.3 Word-to-speaker alignment (SpeakerMerger)

`mergeWordTimestampsWithSpeakers` picks, per word, the segment with the largest time overlap;
equal overlap keeps the earlier segment; zero overlap leaves `speakerId` nil
([MP SpeakerMerger.swift#L9-L61](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift#L9-L61)).
Consequences:

- Because FluidAudio output is exclusive, a word straddling a speaker change is decided by which
  side the trimmed boundary lands on. The word-timing end lag of token-based timings (end time is
  the last sub-token's end) biases boundary words toward the earlier speaker.
- A word that lands in a dropped short segment or a gap gets nil. In the file path the segmenter
  then folds it into the current speaker; in the meeting path it keeps the source label
  `system` ("Others"), which renders as a third, unnamed participant next to "Others 1" and
  "Others 2" (pinned by [TranscriptionServiceTests.swift#L2649-L2711](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift#L2649-L2711)).
- Nothing suppresses isolated single-word speaker flips, and a flip forces a new transcript
  segment ([TranscriptSegmenter.swift#L173-L182](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift#L173-L182)).
- The diarizer's per-segment `qualityScore` and ASR word confidence are not consulted.

### 2.4 Meeting recordings: which track is diarized, and the Me/others prior

- Diarized: the raw system track only. Not diarized: the microphone (raw or cleaned) and the
  mixed playback file. The mic-vs-system split is used as a hard prior: every microphone word is
  "Me", every system word is "Others" or "Others N".
- Echo interaction (ADR-028): the cleaned mic is a LocalVQE echo-only render that replaces samples
  only on the microphone side; the system track is the reference and is untouched
  ([MP spec/adr/028-meeting-echo-cancellation.md#L27-L48](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/spec/adr/028-meeting-echo-cancellation.md#L27-L48)).
  Since the microphone is never clustered, residual far-end bleed cannot become a phantom
  diarized speaker. It surfaces instead as false "Me" words whenever the cleaned mic is not used
  (`rawTimeout`, `rawRenderFailed`, and the other reason codes) or when suppression leaves a
  residual. The text-level reconciler then removes microphone runs that duplicate system runs,
  but only under confidence and length rules (average confidence at or below 0.65, or exact
  sequences of three or more words, or fuzzy matches of five or more words with 0.8 similarity)
  ([MP MeetingTranscriptSourceReconciler.swift#L154-L163](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptSourceReconciler.swift#L154-L163)).
  High-confidence short bleed survives as "Me".
- The system track is the full ScreenCaptureKit system output mix, two channels downmixed for
  STT, not a per-application tap ([MP SystemAudioStream.swift#L76](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Audio/SystemAudioStream.swift#L76), [L368](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Audio/SystemAudioStream.swift#L368)).
  Notification sounds, music, or a second app's audio enter the diarizer with no VAD or gating
  in front of it; the pyannote segmentation model is the only speech filter.
- In-room second speakers (a colleague at the desk, a conference room) are always "Me" because
  the microphone is never clustered. This is the documented product rule
  ([docs/plans/2026-06-14-002 L523-L524](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md#L523-L524)),
  and it is a deliberate trade, not a bug.
- `calendarEventSnapshot` is stored on the transcription
  ([TranscriptionService.swift#L1250](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1250))
  but no attendee count reaches the diarizer as a min/max prior.

### 2.5 File/URL and CLI paths

- `macparakeet-cli transcribe`: `--speaker-detection app-default|on|off`, `--speaker-count`,
  `--speaker-min`, `--speaker-max`, `--no-diarize`; a constraint implies detection on
  ([MP TranscribeCommand.swift#L131-L144](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/CLI/Commands/TranscribeCommand.swift#L131-L144),
  [L349-L449](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/CLI/Commands/TranscribeCommand.swift#L349-L449)).
  These constraints are the only tuning surface in the product, and the GUI exposes none.
- `macparakeet-cli retranscribe --kind meeting` uses the dual-track path when the archived
  recording loads, otherwise it falls back to the mixed playback file and runs the file path,
  which is blind diarization with no "Me"
  ([MP RetranscribeCommand.swift#L492-L507](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/CLI/Commands/RetranscribeCommand.swift#L492-L507)).
  Speaker options are rejected for dictations ([L342-L348](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/CLI/Commands/RetranscribeCommand.swift#L342-L348)).
- Preferences: `speakerDiarization` and `meetingSpeakerDiarization`, both default on
  ([MP AppRuntimePreferences.swift#L514-L517](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/AppRuntimePreferences.swift#L514-L517)).

### 2.6 Speaker labels, rename, persistence, export

- Data model: `WordTimestamp.speakerId` holds stable IDs; `Transcription.speakers` maps IDs to
  labels; `diarizationSegments` and `transcriptSegments` (with cached `speakerLabel`) are stored
  ([MP Transcription.swift#L31-L35](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Models/Transcription.swift#L31-L35),
  [L184-L193](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Models/Transcription.swift#L184-L193)).
- Rename: label-only; `renameSpeaker` updates the roster and re-labels segments, persists through
  `TranscriptionRepository.updateSpeakers`, and refreshes meeting artifacts
  ([MP TranscriptionViewModel.swift#L1608-L1680](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetViewModels/TranscriptionViewModel.swift#L1608-L1680),
  [MP TranscriptionRepository.swift#L534-L545](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Database/TranscriptionRepository.swift#L534-L545)).
  There is no merge, split, or per-turn reassignment.
- Re-run: `retranscribeMeeting` and `retranscribe` build a fresh record; the GUI restores id and
  createdAt ([TranscriptionViewModel.swift#L908-L911](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetViewModels/TranscriptionViewModel.swift#L908-L911))
  and the CLI restores identity, notes, and chat
  ([RetranscribeCommand.swift#L632-L652](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/CLI/Commands/RetranscribeCommand.swift#L632-L652)),
  but neither carries `speakers` forward. User renames are lost, and even if they were kept the
  chronological `S1` numbering would not line up with the new run.
- Export: meeting Markdown emits bold speaker paragraphs only when words carry speaker IDs and
  the transcript is not user-edited ([MP MeetingMarkdownRenderer.swift#L227-L250](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingMarkdownRenderer.swift#L227-L250));
  CLI text prints labels at turn changes and JSON carries all fields.
- Settings copy is now hedged ("when audio is clear") and the timed-transcript banner says labels
  "may be approximate" ([MP SettingsView.swift#L1281-L1286](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeet/Views/Settings/SettingsView.swift#L1281-L1286),
  [MP TranscriptResultView.swift#L256-L262](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift#L256-L262)).

### 2.7 Tests: what they cover and do not

The inventory is in `evidence/baseline-tests-and-eval-inventory.md`. In short: every test uses a
mock or fake diarizer; the real FluidAudio pipeline is exercised only by the env-gated
`LongMeetingPipelineBenchmarkTests`, which measures elapsed time and RSS, not accuracy
([MP LongMeetingPipelineBenchmarkTests.swift#L118-L119](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Tests/MacParakeetTests/Benchmarks/LongMeetingPipelineBenchmarkTests.swift#L118-L119)).
`SpeakerMergerTests` cover the overlap rule with clean synthetic times only; there is no test for
short dropped segments, for exclusive-trim boundaries against realistic word timings, or for
one-word flips. No test asserts rename survival across a re-run.

### 2.8 Historical documents vs current code

| Claim | Where | Status now |
|---|---|---|
| "~85% accurate" toggle copy | ADR-010 L124 | Copy replaced; ADR text stale |
| Offline DER "~15% VoxConverse, ~17.7% AMI" | ADR-010 L26, spec/06 L208 | FluidAudio docs at 0.15.4 report 10.62% full AMI SDM and 15.07% VoxConverse (attributed); ADR numbers predate fix #523 |
| Overlap words "may get speakerId = nil" | ADR-010 L240, spec/02 L1416 | With exclusive trimming the word is assigned to the surviving segment; nil arises only from gaps and dropped short segments |
| "Current code defaults speaker detection off" | June plan L150-L154 | Superseded by the 2026-07-03 amendment; both keys default on |
| "There is no trust benchmark" | June plan L156-L167 | Still true |
| Artifact names `microphone.m4a` / `system.m4a` | Frontier doc L87 | Current names are `microphone-raw.m4a` / `system-raw.m4a` with legacy aliases |
| Phase 0 corpus: 3 usable sessions, pre-AEC | Phase 0 calibration | Stale by design; Phase 0b GO gated on a post-AEC corpus that has not been assembled |
| Default clustering threshold 0.7 | FluidAudio BenchmarkAMISubset.md L22 | Code default 0.6 |

### 2.9 Evaluation harness and corpus

None for attribution accuracy. What exists: the voiceprint Phase 0 harness (a separate SwiftPM
package that runs the offline diarizer and dumps embeddings), FluidAudio's own
`diarization-benchmark` CLI against AMI SDM and VoxConverse with auto-download, and the public
`DiarizationDER.compute(ref:hyp:frameStep:collar:)` utility inside the FluidAudio library
([FA DiarizationDER.swift#L26-L57](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Sources/FluidAudio/Diarizer/DiarizationDER.swift#L26-L57)).
Telemetry carries `diarizationCompleted(speakerCount:durationSeconds:)` and nothing about
corrections.

## 3. Implications for MacParakeet

### 3.1 Ranked likely quality losses

Each item states whether it is a static-analysis suspicion or an observed bug, and how to check it.
None was observed at runtime in this audit.

1. **Short turns vanish (static, checkable).** The 1.0 s minimum after overlap exclusion, the
   20 percent activity floor per 10 s window, and the 1.0 s post-trim floor together remove
   backchannels ("yeah", "right", "okay"), quick answers, and interruptions. In files those words
   fold into the neighbouring speaker; in meetings they render as a separate "Others" participant
   beside "Others 1" and "Others 2", which reads as a wrong speaker count. Check: a two-voice
   fixture with sub-second replies; count words with nil or `system` IDs versus reference.
2. **Speaker count is a single unguarded cut (static, checkable).** AHC at cosine 0.6 sets the
   count; VBx only merges; there is no minimum cluster mass, so a few embeddings from laughter, a
   ringtone, a phone-quality participant, or a voice change under load can spawn "Others 3".
   Similar voices under codec compression can merge. Check: distribution of `speakerCount` in
   telemetry versus calendar attendee counts on the same records; and a fixture sweep over
   thresholds 0.5 to 0.75 with DER and count error.
3. **Alignment is a raw vote (static, checkable).** No smoothing of one-word flips, no snapping
   of word boundaries to segment boundaries, no use of quality scores, and a late-ending word
   timing bias at speaker changes. Check: count of one-word `transcriptSegments` with a different
   speaker than both neighbours in existing library records; a boundary-perturbation test in
   `SpeakerMergerTests`.
4. **Corrections do not persist across re-runs and IDs are not stable (static, observed by code
   reading).** Any rename is discarded by both GUI and CLI re-run paths. Check: rename, re-run,
   observe `speakers` reset to "Others N".
5. **Bleed becomes "Me", not a phantom (static).** When the cleaned mic is not used, short
   high-confidence far-end phrases survive the reconciler as "Me" words. Check: `meeting_cleaned_mic_source`
   diagnostics reason codes in retained sessions, and mic-only word runs that co-occur with
   system words.
6. **System audio is an unfiltered system mix (static).** Non-meeting audio can seed clusters.
   Check: a fixture with a notification chime and background music.
7. **Meeting speaking-time stats come from words, not the diarizer (static, minor).** Silence
   inside a turn is counted up to 1.5 s and the diarizer's own timeline is not stored for
   meetings. Affects analytics, not attribution.
8. **CLI mixed-file fallback (static, minor).** When the archived dual-track recording is
   missing, re-run diarizes the mixed file and loses "Me".
9. **Engine gaps (static, minor).** Cohere never gets speakers; meetings transcribed with an engine
   that yields no word timings get no roster.

Not a quality loss but a knob: `exclusiveSegments: true` discards overlap. Turning it off would
require `SpeakerMerger` to handle genuinely overlapping segments, which today resolves by "most
overlap, earlier wins" and would silently favour the earlier speaker.

### 3.2 Smallest insertion seams

- **Swap or wrap the diarizer:** `DiarizationServiceProtocol.diarize(audioURL:) ->
  MacParakeetDiarizationResult` ([DiarizationService.swift#L33-L38](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L33-L38)).
  A different model, a multi-pass pipeline, or a re-clustering step that consumes FluidAudio's
  `chunkEmbeddings` (enable `exposeChunkEmbeddings`) fits behind this without touching callers.
  The `OfflineDiarizerManaging` init seam ([L50-L63](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L50-L63), [L93-L99](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift#L93-L99)) already lets tests inject a fake.
- **Tune without new code shape:** `DiarizationService(config:)` accepts any
  `OfflineDiarizerConfig` (threshold, `minSegmentDuration`, `exclusiveSegments`, `stepRatio`,
  count bounds). The app passes nothing today.
- **Post-processing pass:** `SpeakerMerger.mergeWordTimestampsWithSpeakers` is a pure, tested
  function; smoothing, boundary snapping, and minimum-run rules belong here or in a sibling
  applied by both call sites ([TranscriptionService.swift#L1699](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/TranscriptionService.swift#L1699), [MeetingTranscriptFinalizer.swift#L53](https://github.com/moona3k/macparakeet/blob/57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf/Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift#L53)).
- **Priors for meetings:** `diarizeMeetingSystemIfNeeded` receives `recording` (with
  `calendarEventSnapshot`) and `sourceWavURLs` for both tracks; `withSpeakers(min:max:)` is one
  line away. `MeetingTranscriptFinalizer.finalize(sourceTranscripts:systemDiarization:)` is where
  the "Others" fallback bucket could be re-attributed to the nearest diarized speaker.
- **Correction persistence:** `preserveOriginalTranscriptionMetadata` (CLI) and the GUI block at
  `TranscriptionViewModel.swift#L908-L911` are the two places a label carry-over (by centroid
  match using `speakerDatabase`, or by time overlap with the previous run) would live.
- **Measurement:** `DiarizationDER.compute` from FluidAudio plus the existing env-gated benchmark
  scaffold give a Swift-only DER path with no Python.

### 3.3 Evaluation data needed

To measure any change you need, at minimum:

- In-domain meeting fixtures: retained dual-track sessions (raw mic, raw system, cleaned mic,
  metadata) with a reference RTTM for the system track and a word-level speaker reference for the
  merged transcript. The Phase 0 inventory found 457 sessions with both files but only 12 readable
  pairs at the time; a fresh post-AEC dogfood set with known participant counts is required and
  was already the Phase 0b gate.
- A short-turn fixture: two to four voices with sub-second backchannels and interruptions, to
  score turn recall separately from DER.
- A noise fixture: system mix with a chime, music bed, and one phone-quality participant.
- Public anchors for regression only: AMI SDM subset and VoxConverse through FluidAudio's CLI,
  scored the same way its docs do (collar 0.25 s, overlap ignored) and, separately, with overlap
  scored and collar 0.
- Metrics to keep apart: DER with its miss, false alarm, and confusion components; speaker-count
  error; word-level speaker attribution error on the merged transcript; short-turn recall; and a
  correction-burden count (renames, and, once they exist, reassignments per meeting).

## 4. Failure scenarios and uncertainty

- **The audit is static.** No fixture was run; the rankings above are ordered by how directly the
  code guarantees the loss, not by measured frequency. Item 1 and item 4 are certain from code;
  items 2, 3, 5, and 6 are probable and unmeasured.
- **Threshold semantics.** FluidAudio's config comment calls the threshold a Euclidean distance,
  but AHC converts it as a cosine similarity to 0.894 Euclidean. Whether 0.6 matches the pyannote
  community-1 reference for this embedding and PLDA space is not established locally; the frontier
  report should confirm the reference value and units. If the reference differs, the entire
  speaker-count behaviour shifts.
- **Reported numbers are not comparable to product audio.** FluidAudio's AMI SDM and VoxConverse
  figures are far-field or in-the-wild recordings; the product diarizes conferencing app output,
  which is codec-compressed, gain-controlled, and already mixed. No local number exists for that
  domain.
- **Word-timing quality is engine-specific.** Parakeet and Nemotron token timings drive alignment;
  their boundary accuracy at speaker changes was not measured here. Whisper timings via WhisperKit
  are a separate path with different error characteristics.
- **Fix #523 and the benchmark tables.** The checkout's benchmark doc does not say whether its DER
  tables were produced after the April 2026 single-speaker fix; treat them as attributed and
  possibly stale in either direction.
- **The "Others" fallback bucket is the most visible symptom.** If dogfood shows many meetings
  with "Others" plus "Others N", the short-turn floor (item 1) is the first suspect and can be
  tested by lowering `minSegmentDuration` alone before any model change.
- **Not audited:** live diarization (none shipped), the knowledge layer's use of speaker IDs, and
  whether Sparkle-shipped builds pin the same FluidAudio revision as `Package.resolved`.

## 5. Sources

Local sources, observed 2026-09-06, all read-only:

- MacParakeet origin/main `57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf`
  (`https://github.com/moona3k/macparakeet`): files cited inline with line ranges; full trace in
  `evidence/baseline-pipeline-trace.md`.
- FluidAudio `b9d43724cbdb5a980e441fd54180964e94d470f7` (tag v0.15.4, 2026-06-16)
  (`https://github.com/FluidInference/FluidAudio`): `Sources/FluidAudio/Diarizer/Offline/**`,
  `Sources/FluidAudio/Diarizer/DiarizationDER.swift`, `Documentation/Diarization/GettingStarted.md`,
  `Documentation/Diarization/BenchmarkAMISubset.md`, `Documentation/Diarization/InvestigationReport.md`,
  `CLAUDE.md`, and `git log -- Sources/FluidAudio/Diarizer/Offline` (commit 30599f9c, PR #523).
- MacParakeet specs and research: `spec/adr/010-speaker-diarization.md`,
  `spec/adr/028-meeting-echo-cancellation.md`, `spec/02-features.md` (F13),
  `spec/06-stt-engine.md`, `docs/research/speaker-diarization-frontier-2026-06.md`,
  `docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md`,
  `docs/research/2026-07-04-voiceprints-phase0-calibration.md`,
  `docs/research/2026-07-04-voiceprints-phase0b-clean-corpus.md`,
  `docs/research/2026-09-06-oss-review-astra/macparakeet-baseline.md`.
- No web sources were consulted for this report; benchmark figures quoted from FluidAudio's
  checked-in documentation are attributed reports, not verified results.
