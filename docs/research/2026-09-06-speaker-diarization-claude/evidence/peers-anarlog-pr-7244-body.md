<!-- CURSOR_AGENT_PR_BODY_BEGIN -->
## Summary

**Problem:** Free-plan users transcribe on device (whisper.cpp, Argmax, Apple Speech, Soniqo), and those paths return words with no speaker labels unless Soniqo happens to know an exact speaker count and the recording is under 10 minutes. Pro users get `precision-2` diarization from the cloud. `crates/pyannote-local` existed but its `cluster()` was a stub returning all zeros and nothing called it, so the free tier had no diarization at all, and the voiceprints we already store for contacts were never used to help diarize a meeting — only to name speakers after the fact.

**Fix:** `pyannote-local` is now a real diarizer modelled on the pyannote 3.1 recipe: sliding 10 s windows through the bundled segmentation-3.0 model (powerset → per-local-speaker activity), WeSpeaker embeddings masked to clean speech (reusing `crates/embedding`; the duplicate 28 MB model is removed), centroid-linkage agglomerative clustering with `num/min/max_speakers` constraints, majority-vote reconstruction across overlapping windows, and word assignment by overlap. After any local batch finishes, `listener2-core` runs it on each transcript channel that came back unlabeled and fills in `word.speaker`, so the existing `provider_speaker_index` → "Speaker N" → voiceprint naming flow works unchanged. Cloud providers are untouched, so the plan split is: local model → local diarizer, Pro cloud → `precision-2`.

The channel plan follows the *recording's* layout, not the transcript's: mono recordings are scored whole; a true stereo transcript scores the system-audio channel with the participant count shifted by one (mic = the user); a stereo recording that a progressive provider (Whisper/Argmax) downmixed into one transcript channel is scored on the average of both channel files with the full participant count. The transcript never leaves the async task — only word timings cross into the blocking diarizer, which returns labels — so a diarizer panic or error leaves the finished transcript intact.

The participant list becomes a prior: the transcription plugin loads confirmed voiceprint exemplars for the session's participants and passes them as `known_speakers`. The diarizer merges clusters whose best match is the same known voice (fragmentation of one voice is the most common local failure) and names clusters that match uniquely on both sides.

Also included for the tuning loop: a DER metric (collar, optimal mapping), a `diarization-eval` binary behind the `eval` feature that scores a directory of `wav`+`rttm`/pyannote-JSON pairs, `eval/fetch_datasets.py` for `diarizers-community/{ami,voxconverse,callhome,simsamu}`, and `eval/PROGRAM.md` describing the ratchet loop and which files it may edit.

Baseline on the two in-repo fixtures against `precision-2` output (after correcting a 2.3 s offset in `english_10/pyannote.json`): DER 1.8% on `english_1`, 4.7% on `english_10`, RTF ≈0.09 on a plain x86 CPU (CoreML on Apple Silicon should be much faster). Step 5 s gave 11.5%, so the default is 2 s; `min_cluster_size` is expressed in seconds so it stays meaningful across steps.

Not changed: the TypeScript gate that decides whether to re-run a batch after a live capture (`shouldRefineSpeakerDiarization`) still only triggers for cloud or Soniqo-batch. Batch-first flows and imports get diarized automatically; extending the live repass to whisper/Argmax batch is a follow-up.

## Verification

- `cargo test -p pyannote-local --features eval` (23 tests, including real-model runs on the `english_1` fixture and a known-speaker round trip)
- `cargo test -p listener2-core` (batch module: 61 tests, including end-to-end labelling from a mono recording, a stereo recording downmixed to one transcript channel built from `english_1` + its reference diarization, a failing diarization leaving the transcript untouched, and cloud output untouched)
- `cargo test -p voiceprint -p embedding`
- `cargo clippy -p pyannote-local --features eval --all-targets --no-deps` (clean), `cargo clippy -p listener2-core --all-targets --no-deps` (only pre-existing warnings in untouched tests)
- `cargo check --locked -p desktop`, `cargo check -p tauri-plugin-transcription --tests`
- `cargo fmt`, `pnpm exec dprint check` on changed paths
- `cargo run --release -p pyannote-local --features eval --bin diarization-eval -- /tmp/diar-eval` on the two fixtures (numbers above)
- Not run: HF dataset download (no network budget here), macOS CoreML path, `pnpm -F desktop typecheck` (no TS changes)

<!-- CURSOR_AGENT_PR_BODY_END -->

<div><a href="https://cursor.com/agents/bc-33616c17-2ec5-4de3-ac54-85b9e0e037ca?cursor_ref=pr_footer&cursor_cta=open_in_web"><picture><source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-web-dark.png"><source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-web-light.png"><img alt="Open in Web" width="114" height="28" src="https://cursor.com/assets/images/open-in-web-dark.png"></picture></a>&nbsp;<a href="https://cursor.com/background-agent?bcId=bc-33616c17-2ec5-4de3-ac54-85b9e0e037ca&cursor_ref=pr_footer&cursor_cta=open_in_cursor"><picture><source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-cursor-dark.png"><source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-cursor-light.png"><img alt="Open in Cursor" width="131" height="28" src="https://cursor.com/assets/images/open-in-cursor-dark.png"></picture></a>&nbsp;</div>


