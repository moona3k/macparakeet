# Evidence: AssemblyAI official docs and blog (observed 2026-09-06)

## Speaker diarization doc (https://www.assemblyai.com/docs/speech-to-text/speaker-diarization)

- `speaker_labels`: "Enable Speaker Diarization" (default false).
- `speakers_expected`: "Set the exact number of speakers". Warning: "Only set `speakers_expected` when you are certain of the exact speaker count."
- `speaker_options.min_speakers_expected`: "A hard lower limit on the number of speaker labels. The model won't return fewer speakers than this."
- `speaker_options.max_speakers_expected`: "A hard upper limit on the number of speaker labels. If more people speak than this, the additional speakers are merged into existing labels."
- Output: "a list of utterances, where each utterance represents an uninterrupted segment of speech from a single speaker"; labels are "sequential letters such as A, B, and C"; the `words` array carries per-word speaker.
- "Each speaker should have at least 30 seconds of continuous speech" for best results.
- "Overlapping speech between speakers can reduce diarization accuracy".
- "If speakers sound similar, the model may have difficulty distinguishing between them".

## FAQ: how speakers are identified (https://www.assemblyai.com/docs/faq/how-are-individual-speakers-identified-and-how-does-the-speaker-label-feature-work)

- "Word timings are used to cut the audio into separate chunks of words. Those chunks are fed into a model to build a 'speaker embedding', which is a representation of a speaker."
- "An algorithm is then used to cluster speaker embeddings that are similar to each other."
- Roughly 30 seconds of audio needed for a distinct speaker; minimal speakers' "words will be attributed to the speaker embedding the model feels is most similar."

## Multichannel doc (https://www.assemblyai.com/docs/pre-recorded-audio/multichannel-transcription)

- "If you have a multichannel audio file with multiple speakers, you can transcribe each of them separately." Response has `audio_channels` and `utterances`; channels numbered from 1; each word carries its channel.
- `speaker_labels` can be combined with `multichannel`: channels numbered 1,2,3, speakers lettered within channel, combined labels like "1A" or "2B".
- "When using `multichannel` with `speaker_labels`, the `speaker_options` parameters are applied per channel, not globally."
- "Multichannel audio increases the transcription time by approximately 40%."
- Note: an older search snippet (blog "Using multichannel and speaker diarization") said the two could not be combined; the current doc page says they can. Doc page wins.

## FAQ: speaker labels vs multichannel (https://www.assemblyai.com/docs/faq/should-i-use-speaker-labels-or-multi-channel)

- "Multichannel is more accurate since each speaker's audio is processed independently."
- "Multichannel audio will not automatically separate multiple speakers on the same channel. If you have multiple speakers on a single channel, speaker labels are required for speaker separation."

## Meeting notetaker best practices (https://www.assemblyai.com/docs/meeting-notetaker-best-practices)

- "Speaker diarization (1-10 speakers by default, expandable to any min/max)".
- On `max_speakers_expected`: "Set a bit higher than expected; too high can cause over-splitting".
- With per-participant platform recordings: "Multichannel=True" with diarization disabled gives "Perfect speaker separation — No diarization errors."
- Zoom: enable "Record a separate audio file for each participant". Teams and Google Meet "require third-party solutions like Recall.ai for multichannel capture".
- Keyterms: "Include participant names for better speaker recognition".
- Speaker Identification "uses AssemblyAI's Speech Understanding API to map generic speaker labels to actual names or roles that you provide." Preconditions: diarization enabled, enough audio per speaker, distinct voices.

## Speaker Identification doc (https://www.assemblyai.com/docs/speech-understanding/speaker-identification)

- "Replace generic 'Speaker A' and 'Speaker B' labels with real names or roles, no voice enrollment needed."
- "uses conversation content to infer who's speaking and applies the identifiers you provide"; can "infer roles from context clues, and can associate names when the names are present within the transcript."
- `speaker_type: "name"` or `"role"` with `known_values`.
- "Speaker Identification requires Speaker Diarization. You must set `speaker_labels: true`".
- "the accuracy of Speaker Diarization depends on the quality of the audio and the distinctiveness of each speaker's voice, which will have a downstream effect on the quality of Speaker Identification."

## Blog: context and speaker labeling (https://www.assemblyai.com/blog/ai-transcription-with-speaker-identification and https://www.assemblyai.com/blog/context-influence-automatic-speaker-labeling)

- Two signals: in-file context (e.g. "Hi, this is Jennifer") and the API-provided participant list.
- "AssemblyAI does not offer speaker enrollment"; mapping is per file.
- Cross-file identification is a cookbook pattern: diarize, then embed with a third-party speaker model (Nvidia Titanet named) and match against a vector database (https://www.assemblyai.com/docs/faq/do-you-offer-cross-file-speaker-identification).

## Accuracy claims

- Blog "New Speaker Tracking Model" (https://www.assemblyai.com/blog/speaker-diarization-update): "30% improvement in speaker tracking accuracy for noisy and far-field audio scenarios", DER 29.1% to 20.4%; table by condition and segment length (clean 250 ms 18.8 to 16.4; noisy 250 ms 46.8 to 26.4; reverberant 1.5 s 15.2 to 4.4; noise+reverb 500 ms 40.0 to 22.8). "205+ hours of audio including meeting recordings, call center conversations" and "AMI, DIPCO, and VoxConverse". Collar, overlap scoring, oracle count: not stated (unknown).
- Universal-3.5 Pro (July 2026, per search snippet of assemblyai.com blog): internal benchmark "average cpWER of 30.17" vs Deepgram Nova-3 EN 37.92, ElevenLabs Scribe v2 35.26, Gladia 36.87; "reliably identifies speakers from segments as short as 250 milliseconds". Internal benchmark; dataset composition unknown.
- Streaming upgrade blog (https://www.assemblyai.com/blog/streaming-diarization-major-upgrade): "Each word object inside a turn now carries its own speaker label, rather than inheriting a single label from the parent turn." No provisional-label semantics documented on that page.
