# Evidence: MacParakeet speaker-attribution call trace at origin/main 57e3391a

All paths are relative to the repository root at 57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf.
Read with `git show origin/main:<path>`; the working tree has unrelated uncommitted edits but none
of the files below differ from origin/main except where noted.

## DiarizationService (Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift)

- 73-91: public inits. Default `config: OfflineDiarizerConfig = .default`; the constraint init
  calls `offlineConfig(speakerConstraint:)` (202-214) which only sets numSpeakers or min/max.
- 101-158: `diarize(audioURL:)` -> `manager.process(audioURL:)` under `ANEInferenceGate`
  (112-114); `noSpeechDetected` becomes an empty result (115-117); segments sorted by start,
  FluidAudio IDs remapped to "S1", "S2" in chronological first-appearance order (124-137); ms
  rounding (139-144); labels "Speaker N" (146-151).
- Nothing else from `DiarizationResult` (speakerDatabase, chunkEmbeddings, qualityScore,
  timings) is consumed.
- App wiring: Sources/MacParakeet/App/AppEnvironment.swift:234 `DiarizationService()` (default config).
- CLI wiring: Sources/CLI/Commands/TranscribeCommand.swift:441-449 `makeDiarizationService` (default
  config unless a count constraint is given).

## SpeakerMerger (Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift)

- 9-61: for each word, scan segments that overlap [startMs, endMs); the segment with the largest
  overlap wins; equal overlap keeps the earlier segment (46-50); zero overlap leaves speakerId nil
  (55-57). No smoothing, no boundary snapping, no confidence use.

## File / URL path (Sources/MacParakeetCore/Services/TranscriptionService.swift)

- 1644: `diarizationRequested = diarizationService != nil && shouldDiarize()`.
- 1647-1650: `audioProcessor.convert` to WAV.
- 1664-1678: STT, words from `result.words`.
- 1690: diarization runs only when `!words.isEmpty` (engines without word timings skip it; test
  at Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift:540-600).
- 1696-1709: `diarize(audioURL: wavURL)` on the same WAV; merge; `speakerCount`, `speakers`,
  `diarizationSegments` set from the diarizer output.
- 1716-1726: failure is non-fatal; telemetry `diarizationFailed`.
- 1932-1940: `KnowledgeSegmenter.materializeFileTranscriptSegments(words:speakers:)`.

## Meeting path (same file)

- 1264: `diarizationRequested = diarizationService != nil && shouldDiarizeMeetings() && recording.sourceAlignment.system != nil`.
- 1426-1488 `transcribeMeetingSources`: for each active source, pick the file via
  `meetingAudioURL` (1570-1584): microphone -> cleaned mic when the ADR-028 readiness decision
  says so, else raw mic; system -> `recording.systemAudioURL` (raw system capture). Each is
  converted to WAV and transcribed separately with `.meetingFinalize`.
- 1490-1549 `diarizeMeetingSystemIfNeeded`: diarizes ONLY `sourceWavURLs[.system]` (1499, 1506).
  Segments are shifted by `systemTrack.startOffsetMs` (1526-1532). IDs become
  "system:S1" with labels "Others 1", "Others 2" (1516-1521). Empty diarization -> nil (1514).
- 1304-1307: `MeetingTranscriptFinalizer.finalize(sourceTranscripts:systemDiarization:)`.
- 1320-1348: vocabulary corrections, then `transcription.speakers/speakerCount/diarizationSegments`
  from the finalizer, `TranscriptSegmenter.materializeSegments`.
- 1236-1252 `makeMeetingTranscriptionStub`: a fresh `Transcription` per run; `calendarEventSnapshot`
  is stored (1250) but not used as a speaker-count prior.

## MeetingTranscriptFinalizer (Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift)

- 34-43 `shiftedWords`: every word gets `speakerId = source.rawValue` ("microphone" / "system")
  (87-101).
- 45-50: `MeetingTranscriptSourceReconciler.reconcile(microphoneWords:systemWords:)` drops mic
  words that duplicate system words (echo).
- 51-59: `SpeakerMerger` over system words only; system words without an overlapping diarization
  segment keep "system" ("Others").
- 61-68: merge and sort; ties by source order.
- 103-125 `activeSpeakers`: "microphone"/"Me" first, then "system"/"Others" if any word kept it,
  then diarized "system:S<n>" speakers that have at least one word.
- 127-160 `buildDiarizationSegments`: derived from words with a 1.5 s same-speaker gap merge, not
  from the diarizer's own segments.

## MeetingTranscriptSourceReconciler (Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptSourceReconciler.swift)

- 154-163 constants: run gap 1.2 s, timing tolerance 0.6 s, low-confidence duplicate <= 0.65 avg
  (or <= 0.80 for 1-2 words), exact simultaneous echo >= 3 words, fuzzy simultaneous echo >= 5
  words with 0.8 similarity.
- 165-195: only microphone words are ever removed; system words are never removed.

## MeetingTranscriptAssembler (Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptAssembler.swift)

- Live preview only (used by MeetingRecordingService.swift:300). Speakers are source labels
  "Me"/"Others" (221-227); no diarization during recording.

## TranscriptSegmenter (Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift)

- 171-203: a segment flushes on speaker change (173-182), sentence punctuation after >= 3 words,
  a gap > 1.5 s, or 40 words. Words with nil speakerId inherit the current speaker (185-188).
- 208-221: label fallback: roster label, else `AudioSource.displayLabel`, else the raw id;
  nil -> "Unknown Speaker".

## Rename and persistence

- Sources/MacParakeetViewModels/TranscriptionViewModel.swift:1608-1680 `renameSpeaker`: edits the
  `speakers` roster label and re-labels `transcriptSegments`; persists via
  `TranscriptionRepository.updateSpeakers` (Sources/MacParakeetCore/Database/TranscriptionRepository.swift:534-545);
  refreshes meeting artifacts.
- Retranscription: `retranscribeMeeting` (TranscriptionService.swift:142-148, 179-203) calls
  `transcribeMeeting`, which builds a new record; the GUI copies id/createdAt back
  (TranscriptionViewModel.swift:908-911) and the CLI `preserveOriginalTranscriptionMetadata`
  (Sources/CLI/Commands/RetranscribeCommand.swift:632-652) copies identity, notes, and chat, but
  neither copies `speakers`. Renamed labels are lost on re-run; IDs are also not stable across
  runs because "S1" is assigned by first appearance.
- CLI meeting retranscribe falls back to the mixed playback file when the archived dual-track
  recording is unavailable (RetranscribeCommand.swift:492-507), which runs the file path
  (blind diarization, no "Me").

## Export

- Sources/MacParakeetCore/Services/MeetingRecording/MeetingMarkdownRenderer.swift:227-280:
  speaker paragraphs only when `hasSpeakerLabeledWords` and the transcript is not user-edited;
  label falls back to the raw id.
- Sources/CLI/Commands/TranscribeCommand.swift:1047-1078, 1135-1168: text output prints labels at
  turn changes; JSON output carries all speaker fields.

## Preferences and flags

- Sources/MacParakeetCore/AppRuntimePreferences.swift:514-517: `speakerDiarization` and
  `meetingSpeakerDiarization` keys, both default true.
- Sources/CLI/Commands/TranscribeCommand.swift:131-144, 349-439: `--speaker-detection
  app-default|on|off`, `--speaker-count`, `--speaker-min`, `--speaker-max`, `--no-diarize`.
- Sources/CLI/Commands/RetranscribeCommand.swift:156-169, 342-348: same options for saved
  transcriptions and meetings; rejected for dictations.

## Audio capture facts relevant to diarization input

- Sources/MacParakeetCore/Audio/SystemAudioStream.swift:76, 368: ScreenCaptureKit system audio at
  2 channels; it is the full system output mix, not a per-process tap.
- spec/adr/028-meeting-echo-cancellation.md:27-84: cleaned mic is derived offline with LocalVQE
  echo-only; fallback to raw mic is observable via reason codes.
