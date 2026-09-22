# Evidence: Nemotron-3 Diarization (NVIDIA preview) and FluidInference CoreML port

Observed 2026-09-06. Both Hugging Face repos are gated ("gated: manual" in the HF API).
Raw file fetches returned "Access to model ... is restricted" (see the earlier version of this file
during the session). The rendered card pages were readable through the WebFetch tool; the
excerpts below are what the tool returned, not a verbatim copy of the gated files.

## HF API metadata (curl https://huggingface.co/api/models/...)

- nvidia/Nemotron-3-Diarization-preview: createdAt 2026-08-24, lastModified 2026-09-05, gated manual,
  license tag "other"; files include Nemotron-3-Diarization-preview.nemo, diarization_evaluation.md,
  overview.md, bias.md, explainability.md, privacy.md, safety.md.
- FluidInference/nemotron-3-diarization-coreml: createdAt 2026-08-30, lastModified 2026-08-30, gated
  manual, license "other"; files: BENCHMARKS.md, CONVERSION_NOTES.md, README.md, learnable_sil_emb.bin,
  monolithic/Nemotron3Diarizer_{fast,fast128,fast32,low,offline}.mlmodelc.

## nvidia/Nemotron-3-Diarization-preview rendered card (WebFetch summary)

- License name: "nvidia-software-and-model-evaluation-license".
- Restrictions reported: early access "for internal testing and evaluation" only; prohibited in
  production environments; requires NVIDIA GPUs; redistribution forbidden; outputs may not be used to
  develop other AI models without written consent.
- No release date, architecture, benchmark table, or general-release statement was visible in the
  unauthenticated render.

## FluidInference/nemotron-3-diarization-coreml rendered card (WebFetch summary)

- Source: nvidia/Nemotron-3-Diarization-preview. "31-layer RoPE Transformer, 10 ms output resolution",
  ~100M parameters, "8-speaker streaming Sortformer"; streaming and offline presets.
- License stated as NVIDIA Software and Model Evaluation License "(pending update at general release)".
- Reported AMI MHM test DER (card protocol; collar/overlap not visible in the render): offline 9.28
  (NVIDIA reference 9.30), low 9.90 (NVIDIA 10.35), fast32 9.94, fast128 9.59.
- Hardware: M5 Pro, fast preset "~11 ms ANE per chunk" at 1.04 s latency; fast128 "1004x wall real-time";
  split-graph W8A8 "100% ANE-resident".
- Integration: "Nemotron3Models.load()" with preset selection (FluidAudio PR #883, open, code-only).

## FluidAudio PR #883 (open, updated 2026-09-04) — see frontier-fluidaudio-pr883-nemotron3.md

"model weights are not included; they load from a local directory and move to HuggingFace auto-download
once NVIDIA's public release lands". "Benchmark figures are intentionally deferred to post-release
documentation per the model's early-access evaluation terms".
