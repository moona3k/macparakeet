# On-device ASR landscape — verified survey (2026-07-03)

> Method: an initial broad landscape sweep (Gemini web research) was
> adversarially fact-checked by three independent web-verification passes
> (Codex, high reasoning, primary sources only) covering runtimes, models,
> and Apple platform ASR. Every claim below carries a verdict; several
> widely-repeated claims from the initial sweep were **refuted** and are
> listed at the end so they don't re-enter our planning. Input to
> [ADR-026](../../spec/adr/026-asr-engine-strategy.md).

## Runtimes on Apple Silicon

| Runtime | State (verified) | Verdict for MacParakeet |
|---------|------------------|-------------------------|
| **FluidAudio** (FluidInference) | v0.15.4 (2026-06-16), active. Documented ASR: Parakeet TDT v2, v3, TDT-CTC-110M, **Parakeet Japanese**, **Parakeet CTC keyword/custom-vocab builds**, Parakeet EOU streaming, Nemotron Speech Streaming 0.6B (EN + Multilingual), Cohere Transcribe, SenseVoiceSmall, Paraformer-large-zh. Plus Silero VAD and diarization via Sortformer, LS-EEND, and pyannote CoreML. Source: `github.com/FluidInference/FluidAudio` + `Documentation/Models.md`. | Center of gravity. Nearly every model we would plausibly want through 2027 ships here or will land here. |
| **WhisperKit** (Argmax) | Whisper-only; open-source SDK explicitly scoped to OpenAI Whisper. Diarization is a separate kit, **SpeakerKit** (pyannote). No Parakeet or non-Whisper ASR support found (claims of "Speakerbox"/Parakeet-in-WhisperKit: **refuted**). Source: `github.com/argmaxinc/argmax-oss-swift` (v1.0.0, 2026-05-01). | Legacy multilingual fallback. Maintained, not growing. |
| **MLX audio** | Active: `mlx-audio` (~7.5k stars, v0.4.4 2026-06-06; Whisper, Qwen3-ASR, VibeVoice-ASR, Parakeet), `parakeet-mlx` (0.5.2, 2026-06-05). Python-first; no production Swift ASR path. | Watch item — the only credible future third runtime, contingent on Swift-usable ports. |
| **sherpa-onnx** | Active (13.4k stars, docs through 2026): streaming Zipformer/Conformer transducers + CTC, broad model zoo. | No unique value over FluidAudio+WhisperKit for us. |
| **whisper.cpp** | Very active (v1.9.1), Whisper-only, no Parakeet support. | Same — nothing we need. |

## Models

| Model | Verified facts | Relevance |
|-------|----------------|-----------|
| **NVIDIA Nemotron-3.5 ASR streaming 0.6B** | Real: HF 2026-06-04, OpenMDW-1.1, cache-aware FastConformer-RNNT, 600M, chunk latencies 80–1120 ms, ~32 languages out of box (marketing says 40 locales; 8 need fine-tuning). | Successor to our Nemotron Beta line; multilingual streaming. Adopt when FluidAudio ships it. |
| **NVIDIA Parakeet TDT 0.6B v3** | 2025-08-14, CC-BY-4.0, 25 languages. Still the local speed/accuracy leader for EN+EU (our benchmark: 155× realtime class, WER 2.3–3.2 on LibriSpeech per ADR-001 amendment). | Our default; line keeps compounding (Japanese build, custom-vocab CTC builds already in FluidAudio). |
| **Whisper Large v3 Turbo** | No Whisper v4 exists; OpenAI has moved to API-only audio models. The open Whisper line is frozen. | Role shrinks over time; fallback only. |
| **Mistral Voxtral Realtime** | Real-ish: "Voxtral Mini Transcribe Realtime" v26.02 in Mistral docs; arXiv 2026-02 reports 4B Apache-2.0 natively-streaming ASR, 13 languages, Whisper-parity at ~480 ms. **No Apple Silicon port found.** | Watch list. Not actionable without a Swift/CoreML/MLX port. |
| **Moonshine v2** (Useful Sensors) | Real (2026-02-12): Tiny/Small/Medium 34M/123M/245M, avg WER 12.0/7.8/6.7, M3 latency 50–258 ms. Claim of Whisper-Large parity: **inflated** — paper says on-par with models ~6× larger, 43.7× faster than large-v3. | English-focused; our fast-English slot is already covered. Skip. |
| **Meta Omnilingual ASR** | Real (arXiv 2025-11, Apache-2.0): 1,600+ languages, CTC 300M–7B + LLM-ASR variants. Python/fairseq2 only; "speech-swift" framework: **does not exist**. | No Swift runtime → skip until one exists. |
| **Kyutai STT** | Real: `stt-2.6b-en` (CC-BY-4.0, 2.5 s delay), `stt-1b-en_fr` (0.5 s); MLX + `moshi-swift` ports exist (1B runs on iPhone). | EN/FR only; interesting engineering, no product gap it fills for us. |
| **Mamba/SSM ASR** | Research-stage only (Speech-Mamba 2024, Samba-ASR 2025-01). Claims of production Mamba ASR ("TransMamba", "Mamba-3"): **unverified/refuted**. | Ignore for planning. |

## Apple SpeechAnalyzer / SpeechTranscriber (macOS 26)

- Real, WWDC25; on-device; model assets live in system storage and its memory
  is **not charged to the app process** (Apple WWDC25 session 277).
- **Has custom-vocabulary support**: `AnalysisContext.contextualStrings` is in
  the macOS 26.4 SDK (the "no custom vocab" claim is **refuted**). Full custom
  LM hooks (à la `SFCustomLanguageModelData`) on SpeechTranscriber: unverified.
- **No third-party WER benchmark exists** (searched: MacStories, Argmax,
  named engineering blogs — nothing with numbers). Quality is unproven.
- Language coverage unverified; a live `SpeechTranscriber.supportedLocales`
  probe on a macOS 26.4 dev machine returned **0 locales** (assets likely
  not installed; needs a proper spike, not a one-off probe).
- Competitor adoption **not found**: Superwhisper's changelog shows no
  SpeechAnalyzer adoption (the "Fast mode uses it" story is refuted by their
  own changelog); VoiceInk mentions Apple Speech bug-fixes only; nothing from
  MacWhisper or Wispr Flow.

## Trend calls (grounded)

1. **Dedicated ASR is not being displaced by speech-LLMs on-device.**
   CTC/TDT/transducer models remain ~10–20× cheaper in compute/battery — the
   right physics for always-on dictation. Speech-LLMs (Voxtral, Qwen audio)
   matter for *understanding* tasks (meetings), and have no Swift runtime yet.
2. **ASR + diarization are converging**, and FluidAudio already ships three
   diarization families alongside ASR — the convergence favors our stack.
3. **The open Whisper line is done** (no v4). Multilingual momentum now lives
   with NVIDIA's open line (Nemotron-3.5, Canary) and CJK-focused models
   (SenseVoice, Paraformer).

## Hallucinations refuted during verification (do not re-plan on these)

- WhisperKit running Parakeet / "Speakerbox" diarization product.
- FluidAudio "Unified Inference" thermal-switching roadmap.
- Apple M5 "dedicated audio-path neural accelerators" (M5 neural accelerators
  are per-GPU-core, per Apple's own press release).
- Meta "speech-swift" framework; MMS/Omnilingual branding conflation.
- Production Mamba ASR ("TransMamba", "Mamba-3").
- SpeechTranscriber "~14% WER, Whisper-Small/Medium parity" (no benchmark
  exists); "30-min file in ~45 s on M4" (no measured source).
- Superwhisper shipping SpeechAnalyzer "Fast mode".
