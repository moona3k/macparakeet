# Evidence: pyannoteAI official docs (observed 2026-09-06)

All fetched via WebFetch on 2026-09-06. Quotes are verbatim where marked.

## Diarize API (https://docs.pyannote.ai/api-reference/diarize)

- `model`: `precision-2` (default) or `community-1`.
- `numSpeakers`: "Number of speakers. Only use if the number of speakers is known in advance...Setting this value results in better overall diarization performance".
- `minSpeakers` / `maxSpeakers`: bounds; "must be <= maxSpeakers if both are set".
- `exclusive` (bool): "Includes exclusive diarization values in the output in `exclusiveDiarization` key (equivalent to diarization but without overlapping speech)".
- `confidence` (bool): "Include confidence values in the output...Output includes a list of confidence scores with a resolution".
- `turnLevelConfidence` (bool): "Includes turn-level confidence values in the output".
- `transcription` (bool): "Enable speaker attributed transcription. Only available for the `precision-2` model".

## Models (https://docs.pyannote.ai/models)

- Models: Precision-2 (cloud), Live-1 (streaming), Community-1 (hosted and self-hosted via pyannote.audio 4.0).
- "Precision-2 is 28% more accurate, on average, than Community-1."
- Live-1: "Sub-300ms latency", "Processes audio in 100ms chunks over WebSocket", up to 8 speakers, 16 kHz mono.
- "Speaker identification and voiceprint features are not available for Community-1 models."
- Exclusive to Precision-2: voiceprint identification, exclusive diarization mode, minSpeakers/maxSpeakers/numSpeakers, confidence scores "for manual correction workflows".

## Feature overview (https://docs.pyannote.ai/features)

- Exclusive diarization: "Enable exclusive diarization mode, equivalent to diarization but without overlapping speech. Useful for easier reconciliation with STT/ASR results."
- Confidence: "Receive confidence scores for each speaker segment to assess reliability and perform human in the loop correction."
- Identification: "Identification answers 'who is speaking?' by recognizing specific known voices using voiceprints."
- Orchestrated transcription: hosted STT "with specialized STT + diarization reconciliation logic for speaker-attributed transcripts".

## Speaker configuration tutorial (https://docs.pyannote.ai/tutorials/speaker-configuration.md)

- "When you know the exact number of speakers, use `numSpeakers` for better results."
- "Setting `numSpeakers` typically results in better overall diarization performance since the model can optimize for a specific speaker count."
- "`numSpeakers` cannot be used together with `minSpeakers` or `maxSpeakers`".
- "When unsure about speaker count, begin with automatic detection (no parameters) to understand your audio content, then refine with constraints in subsequent processing."

## Confidence scores tutorial (https://docs.pyannote.ai/tutorials/confidence-scores.md)

- "Confidence scores provide a measure of the certainty of the model in its predictions. These scores range from 0 to 100, with higher values indicating greater confidence."
- "If the `resolution` is `0.02`, it means each confidence score represents a 20-millisecond interval in the audio."
- "Turn-level confidence scores provide confidence values for each diarization segment (turn), making it easier to assess the quality of specific speaker assignments."
- Recommended use: "Identify segments with confidence scores below your threshold (e.g., < 70) for manual review"; "Focus human review time on the most uncertain segments rather than reviewing entire transcripts".

## Diarization + ASR merge tutorial (https://docs.pyannote.ai/tutorials/diarization-asr-merge.md)

- Recommends "the segment-level adaptation of WhisperX's current `assign_word_speakers` logic".
- For each transcript segment, sum overlap with each diarization speaker; assign `max(speaker_overlap.items(), key=lambda x: x[1])[0]`.
- `fill_nearest` option "assign[s] the nearest speaker when there is no overlap" by closest midpoint; otherwise `"speaker": "UNKNOWN"`.
- "Set the `exclusive` parameter to `true`" because it "removes overlapping speech, ensuring each segment contains exactly one speaker, which makes it easier to align with STT/ASR results that don't normally work well with overlapping speech."

## Identification with voiceprints tutorial (https://docs.pyannote.ai/tutorials/identification-with-voiceprints.md) and Identify API (https://docs.pyannote.ai/api-reference/identify)

- Voiceprint creation: "Single speaker only: The recording must contain only the target speaker's voice with no overlapping speakers." "Audio samples must be at most 30 seconds long for creating voiceprints."
- Storage is the caller's job: "Job outputs, including voiceprints, are automatically deleted 24 hours after job completion." Callers must "retrieve and store them securely for future identification requests".
- `threshold`: "Minimum confidence score required for a match (0-100, default: 0). Set higher values (50-70) for more strict matching, lower values for more lenient matching."
- `exclusive` matching: "Prevent multiple speakers from matching the same voiceprint (default: true)."
- Unmatched speakers keep generic diarization labels; results show `"match": null`.
- Voiceprint list: `minItems: 1, maxItems: 50`. Labels "can't start with 'SPEAKER_'".
- "Identification output is deleted 24 hours after job completion. Include all voiceprints to match in each request. Voiceprints from previous jobs are not added automatically."
- No explicit consent guidance on these pages.

## Data retention (https://docs.pyannote.ai/data-retention.md)

- Uploaded audio "automatically deleted within 48 hours"; URL audio: "No copy of the audio file is retained after processing completes."
- "Job results are retained for 24 hours after the job completes."

## Benchmark page (https://www.pyannote.ai/benchmark)

- 10 domains (Broadcast Interview, Clinical, Courtroom, Conversational telephone speech, Map task, Meeting, Restaurant, Sociolinguistic field/lab, Web video); "259 recordings", "≈67 hours", "9.3% overlap speech".
- Uses "pyannote.metrics open source evaluation toolkit".
- Oracle speaker count: "We did not provide the number of speakers for any of them."
- Collar and overlap-scoring settings not stated on the page as fetched: unknown.

## Precision-2 blog (https://www.pyannote.ai/blog/precision-2)

- "Precision-2 is 14% more accurate than Precision-1 and 28% more accurate than pyannote.audio OSS 3.1".
- "Precision-2 predicts the correct number of speakers on 70% of our most difficult internal benchmark" ("250+ files with 2 to 10 speakers"); Precision-1 "barely reached 50%"; "relative reduction of 37% on the speaker confusion rate" (from search snippet of the same post).
- `exclusive` flag: "return speaker diarization where only one single speaker (the most likely to be transcribed) is active at a time."

## Evaluation blog (https://www.pyannote.ai/blog/how-to-evaluate-speaker-diarization-performance)

- DER components: missed speech, false alarm, confusion. "Confusion ... is often the most damaging error type for user experience, as it makes transcripts misleading rather than merely incomplete."
- "A tolerance collar (commonly 0.25 seconds) is often applied around speaker boundaries".
- "Overlapped speech handling varies by protocol: some DER implementations ignore overlaps, while others count them strictly. Always check protocol details."

## WhisperX assign_word_speakers (https://raw.githubusercontent.com/m-bain/whisperX/main/whisperx/diarize.py, fetched 2026-09-06, main branch, no SHA pinned)

- Interval tree query; intersection = `min(segment_end, query_end) - max(segment_start, query_start)`; per-speaker sums; dominant speaker wins; `fill_nearest` picks the segment with the closest midpoint; same logic applied per word when the word has timing.
