## Summary

**Problem:** Follow-ups from #7244 after verifying the local diarizer on a real Mac.
1. Progressive local batches (whisper.cpp, Argmax) are torn down after 60 s without a streamed event. Diarization runs after the provider finishes and is silent, so any meeting longer than a few minutes lost its finished transcript to a `TimedOut` (Bugbot 0c6455ae).
2. On this machine every accelerated ONNX session was silently running on the CPU: a half-written compiled model in the shared temp cache made `MLModel` refuse to load, `crates/onnx` fell back to CPU, and nothing ever cleared the cache. Diarization ran at RTF 0.20 instead of 0.03; the voiceprint extractor in the installed app has the same problem.
3. A couple of places in the diarizer were more elaborate than they needed to be.

**Fix:**
1. The diarizer reports per-window progress; the batch layer streams it as `Progress` heartbeats from 0.95 to 1.0 (continuing where Soniqo's own progress stops), throttled to 5 s, starting before the resample. Progressive sessions stay alive and the UI shows work continuing instead of freezing at 100%.
2. `load_model_from_bytes_accelerated` clears the cache and retries once when the accelerated commit fails, then falls back to CPU as before. The cache is keyed by executable path so an installed build and a dev build stop compiling into each other's directory (the in-process compile lock never protected across processes).
3. The speaker-bound cut search is one `min_by_key` over (count gap, distance from threshold); speakers are built once with centroid and identity instead of being patched after reconstruction; `specta`/`tracing` are dropped from `pyannote-local`; the eval binary prints tracing warnings so accelerator fallbacks are visible.

Numbers on an M5 Max (`diarization-eval`, two fixtures vs `precision-2`): DER 4.4% unchanged; RTF 0.207 with the broken cache → 0.034 after the repair (6x). Reproduced the production failure by truncating `compiled_model.mlmodelc` and confirmed the rebuild path recovers at full speed.

## Verification

- `cargo test -p listener2-core batch::diarize` (14, incl. new heartbeat throttle test and an end-to-end test asserting progress is streamed within [0.95, 1.0])
- `cargo test -p pyannote-local --features eval` (24, incl. new progress callback test)
- `cargo test -p embedding --features coreml`, `cargo test -p onnx --features coreml`
- `cargo clippy` on `pyannote-local` (eval), `onnx` (coreml), `listener2-core`: clean
- `cargo check -p desktop`
- `cargo fmt`, `pnpm exec dprint check` on changed paths
- Manual: `diarization-eval --features eval,coreml` before/after corrupting the cache (see numbers above)
- Not run: the desktop UI end to end; the word→`provider_speaker_index`→"Speaker N" path is unchanged from cloud providers and covered by existing TS tests

<!-- CURSOR_SUMMARY -->
---

> [!NOTE]
> **Medium Risk**
> Changes batch session liveness, CoreML ONNX loading/caching used by diarization and embeddings, and diarizer clustering/reconstruction paths; behavior is covered by new tests but affects long-running local batch workflows on macOS.
> 
> **Overview**
> Fixes progressive local batches **timing out after transcription** when on-device diarization runs silently for long meetings. The batch layer now streams **`Progress` heartbeats from 0.95 to 1.0** (throttled to every 5s, including during resample and model load), driven by a new **`on_progress`** callback on the pyannote diarizer.
> 
> **ONNX CoreML acceleration** no longer stays stuck on CPU when a corrupted compiled cache fails to load: **`load_model_from_bytes_accelerated`** clears the cache and retries once, and the cache directory is **hashed per executable** so dev and installed builds do not share the same temp folder.
> 
> Minor **pyannote-local** refactors: simpler speaker-bound cluster cut selection, speaker metadata assembled before reconstruction, **`specta`/`tracing` dropped** from the crate, and **`diarization-eval`** initializes **`tracing-subscriber`** so accelerator fallbacks show up in stderr.
> 
> <sup>Reviewed by [Cursor Bugbot](https://cursor.com/bugbot) for commit 177f9f7ce13eb8b48f3e8f3c9082690bceb487e6. Bugbot is set up for automated code reviews on this repo. Configure [here](https://www.cursor.com/dashboard/bugbot).</sup>
<!-- /CURSOR_SUMMARY -->
