# Evidence: Deepgram and Soniox official docs (observed 2026-09-06)

## Deepgram diarization (https://developers.deepgram.com/docs/diarization)

- Labels are per word: each word object includes `"speaker":0` and, for pre-recorded audio, `"speaker_confidence"`.
- "When using diarization for pre-recorded audio, both `speaker` and `speaker_confidence` values will be returned"; "When using diarization for live streaming audio, only the `speaker` value will be returned".
- Speakers numbered from 0.
- No speaker-count parameter documented.
- `diarize_model=latest|v1|v2`; "`diarize_model=v2` — not supported on streaming"; deprecated `diarize=true` routes to v1. "Whisper is not supported".
- Utterances can be grouped as `[Speaker:X]` via utterances plus a JSON processor.

## Deepgram multichannel (https://developers.deepgram.com/docs/multichannel)

- "When set to `true`, you will receive separate transcripts for each channel." Up to 20 channels. Pre-recorded results carry a `channels` array; streaming carries `channel_index`.

## Deepgram multichannel vs diarization (https://developers.deepgram.com/docs/multichannel-vs-diarization)

- Multichannel when "audio that has multiple separate audio channels, and the audio in each channel is distinct."
- Diarization when "Your audio may have two speakers on one audio channel, one speaker on one audio channel and one on another."
- "diarization focuses on giving information about different speakers, while multichannel focuses on identifying different audio channels."
- Combined: each channel gets its own transcript with speaker labels within that channel; numbering resets to `speaker: 0` per channel.
- "Combining Deepgram's Multichannel and Diarization features can provide very specific, useful information about the people speaking in multiple audio channels."

## Deepgram batch diarization v2 (changelog https://developers.deepgram.com/changelog/2026/5/13, blog https://deepgram.com/learn/introducing-batch-diarization-v2, discussion https://github.com/orgs/deepgram/discussions/1625)

- "In side-by-side human evaluation, v2 was preferred 3.3× over our current production diarizer (v1)"; "median CER reduced roughly 80%" with largest gains on contact-center audio.
- "We measure performance using Confusion Error Rate (CER), which represents the percentage of speech time attributed to the wrong speaker."
- "Across 158 human evaluation votes: 63.3% preferred V2, 19.0% preferred V1, 17.7% reported no preference."
- Architecture: "Expanded training data, A new speaker embedding model, Improved segmentation and clustering."
- Datasets, collar, overlap, oracle count: not stated (unknown). No DER published.

## Soniox speaker diarization (https://soniox.com/docs/stt/concepts/speaker-diarization)

- "When speaker diarization is enabled, each token includes a 'speaker' field" (token-level labels, e.g. `"speaker": "1"`).
- "Real-time speaker diarization is more challenging due to low-latency constraints."
- Real-time mode has "Higher speaker attribution errors compared to async mode" and "Temporary speaker switches that stabilize as more context is available."
- "Endpoint detection and manual finalization force tokens to finalize early, which reduces diarization accuracy."
- "Up to 15 different speakers are supported per transcription session."
- "Accuracy may decrease when many speakers have similar voice characteristics."
- "For the most accurate and reliable speaker separation, use asynchronous transcription — it provides significantly higher diarization accuracy because the model has access to the full audio context."
- Overlap handling: not discussed.

## Soniox speaker identification

- Searches on 2026-09-06 (site-wide and docs-scoped) found no Soniox documentation page for speaker identification, voice profiles, or enrollment. The URLs /docs/stt/concepts/speaker-identification and /docs/stt/speaker-identification returned 404. Treat Soniox speaker identification as not documented at observation time.
