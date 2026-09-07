# Brief: current diarization models and Apple Silicon tooling (web research)

Own: docs/research/2026-09-06-speaker-diarization-claude/frontier.md and evidence/frontier-*.
Read briefs/shared.md first. Web browsing is required (WebSearch/WebFetch). Observation date 2026-09-06.

Goal: identify the strongest currently evidenced offline (non-streaming) diarization options and
which of them are realistically deployable inside a native macOS Swift app, given that
processing is async and may be slow.

Cover, bounded to the strongest ~8 families:
1. pyannote: community-1 (open) vs precision-2 (commercial API); any newer pyannote releases
   (check pyannote.audio GitHub releases and HF model cards for versions after community-1,
   e.g. 4.x, and whether new open weights exist).
2. FluidAudio: latest release vs pinned 0.15.4. What changed in diarization (models, VBx,
   Sortformer, streaming, new offline pipeline, benchmarks they report, open issues about
   diarization quality). Check GitHub releases, CHANGELOG, README benchmark tables, issues.
3. NVIDIA NeMo: Sortformer (offline 4-speaker, streaming variant), any newer version lifting
   the 4-speaker limit, and NeMo's clustering diarizer / MSDD. Deployability to CoreML/ONNX.
4. DiariZen / WavLM-based segmentation and any newer self-supervised pipelines.
5. sherpa-onnx speaker diarization (pyannote segmentation + 3D-Speaker/WeSpeaker ONNX) and
   any Swift/macOS bindings; also senko (if it exists) or other Apple-Silicon-targeted
   diarization projects; MLX-based diarization ports; WhisperKit / Argmax diarization
   ("SpeakerKit" if it exists); Apple's SpeechAnalyzer in macOS 26 (does it expose speaker
   labels at all?).
6. Joint ASR+diarization: whisper-based word-level attribution (WhisperX style), NeMo
   Parakeet + diarization recipes, Canary / Sortformer joint models, any "speaker-attributed
   ASR" models with open weights.
7. Text/LLM post-correction: DiarizationLM (Google) and follow-ups; whether a small local LLM
   fixing speaker-change boundaries from text is evidenced to help.
8. Overlap-aware approaches and two-channel priors: using a known "self" channel (mic) vs
   far-end channel to constrain diarization; target-speaker VAD; anything evidenced.

For each: exact model/version, release date, license as declared, open weights?, Apple Silicon
port (CoreML/ONNX/MLX) exists?, reported DER with conditions (dataset, collar, overlap scored,
oracle count), speed/hardware if reported. Build one comparable benchmark table and clearly
mark non-comparable cells.

Identify which of ADR-010's and the June frontier doc's claims are now stale. Finish with a
ranked shortlist of 3 candidates for MacParakeet's async post-processing path with the causal
argument for why each would beat the current FluidAudio 0.15.4 offline pipeline, and what
a minimal A/B evaluation would look like.
