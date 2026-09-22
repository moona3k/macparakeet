# Brief: MacParakeet speaker-attribution baseline audit

Own: docs/research/2026-09-06-speaker-diarization-claude/macparakeet-baseline.md and evidence/baseline-*.
Read briefs/shared.md first.

Goal: establish exactly what MacParakeet does today for speaker attribution and where the
quality is most likely lost, with source-line citations (use GitHub permalinks against the
current origin/main SHA from `git rev-parse origin/main`, or local path:line if the file is
only modified locally).

Trace:
- DiarizationService and SpeakerMerger: which FluidAudio API is called (OfflineDiarizerManager
  config: clustering threshold, min speakers, segmentation settings), how ASR words/segments
  are aligned to speaker segments (overlap rule, ties, short turns, words with no overlap),
  what happens with no-word-timing engines, and speaker relabeling/normalization.
- Meeting recordings: MeetingTranscriptFinalizer / MeetingTranscriptAssembler / retranscribe
  path. Is diarization run on the mixed track, the mic track, the system track, or both? Is
  the mic-vs-system split used as a "Me" prior? How does ADR-028 echo cancellation interact
  (does the processed mic still contain far-end bleed that gets clustered as a phantom speaker)?
- File/URL transcription path and the CLI retranscribe / transcribe commands' diarization flags.
- Speaker rename/correction UI and persistence (Transcription model, DatabaseManager,
  TranscriptSegmenter, export), and whether user edits survive re-run.
- FluidAudio 0.15.4 checkout: read its offline diarizer implementation and defaults (models
  used, VBx/clustering parameters, min segment length, embedding exclusion of overlap, any
  known issues documented in the repo). Check the FluidAudio CHANGELOG/releases in the checkout
  for what changed in diarization after 0.15.4 only if visible locally; the frontier agent owns
  the web side.
- Existing tests under Tests/ for diarization/merging and what they do and do not cover.
- Historical work: June frontier doc, June plan, July voiceprints phase 0 / 0b docs, ADR-010.
  Which claims are stale relative to current code?
- Is there any evaluation harness, corpus, or DER script in the repo or scripts/?

Deliver: a precise pipeline description, a ranked list of the most likely quality losses
(distinguish static-analysis suspicion from observed bug, and say which are checkable), the
smallest seams where a better diarizer or a post-processing pass could be inserted, and what
evaluation data would be needed to measure any change. No implementation.
