# Evidence: benchmark excerpts (observed 2026-09-06 unless stated)

All numbers are attributed reports. Conditions are recorded as stated by the source.

## pyannote community-1 model card (https://huggingface.co/pyannote/speaker-diarization-community-1)
Card last modified 2025-09-29 (HF API). License CC-BY-4.0. Conditions quoted: "fully automatic
processing, no forgiveness collar, nor skipping overlapping speech".

| Dataset | Legacy 3.1 | Community-1 | Precision-2 |
|---|---|---|---|
| AISHELL-4 | 12.2 | 11.7 | 11.4 |
| AliMeeting (ch. 1) | 24.5 | 20.3 | 15.2 |
| AMI (IHM) | 18.8 | 17.0 | 12.9 |
| AMI (SDM) | 22.7 | 19.9 | 15.6 |
| AVA-AVD | 49.7 | 44.6 | 37.1 |
| CALLHOME (pt. 2) | 28.5 | 26.7 | 16.6 |
| DIHARD 3 | 21.4 | 20.2 | 14.7 |
| Ego4D | 51.2 | 46.8 | 39.0 |
| MSDWild | 25.4 | 22.8 | 17.3 |
| RAMC | 22.2 | 20.8 | 10.5 |
| REPERE (ph. 2) | 7.9 | 8.9 | 7.4 |
| VoxConverse v0.3 | 11.2 | 11.2 | 8.5 |

pyannote HF org listing: no model newer than community-1 (2025-09-29) / precision-2 (2025-09-16).
pyannote.audio releases (GitHub API): 4.0.0 2025-09-29, 4.0.4 2026-02-07, 4.0.5 2026-06-22,
4.0.6 2026-06-29, 4.0.7 2026-06-30. CHANGELOG for 4.0.4-4.0.7 lists no new pretrained pipeline.

## Argmax OpenBench BENCHMARKS.md (https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md)
Systems: AWS Transcribe (run 2025-02-17), Deepgram nova-3 (2025-06-27), pyannote 3.1 on M2 Ultra
(2025-02-17), pyannoteAI precision-1 API (2025-02-17), Argmax SpeakerKit with pyannote/community-1 on
M2 Ultra (2025-09-29). DER as fractions. Collar/overlap not stated on the page; senko's evaluation
README says OpenBench defaults are collar=0.0 and skip_overlap=False.

| Dataset | AWS | Deepgram | pyannote 3.1 | pyannoteAI p-1 | Argmax c-1 |
|---|---|---|---|---|---|
| AISHELL-4 | 0.22 | 0.72 | 0.12 | 0.11 | 0.12 |
| AMI-IHM | 0.29 | 0.35 | 0.19 | 0.16 | 0.18 |
| AMI-SDM | 0.37 | 0.42 | 0.23 | 0.18 | 0.21 |
| AliMeeting | 0.42 | 0.81 | 0.25 | 0.19 | 0.23 |
| CALLHOME | 0.37 | 0.64 | 0.29 | 0.20 | 0.30 |
| DIHARD-III | 0.36 | 0.37 | 0.24 | 0.17 | 0.22 |
| VoxConverse | 0.13 | 0.36 | 0.11 | 0.10 | 0.11 |
| Earnings-21 | 0.18 | - | 0.10 | 0.09 | 0.10 |
| MSDWILD | 0.40 | 0.64 | 0.32 | 0.26 | 0.33 |
| AVA-AVD | 0.61 | 0.68 | 0.48 | 0.47 | 0.48 |
| EGO4D | 0.61 | 0.71 | 0.52 | 0.46 | 0.48 |
| ICSI | 0.46 | - | 0.34 | 0.31 | 0.35 |

Speaker Count Accuracy: AMI-SDM AWS 56%, Deepgram 88%, pyannote 3.1 6%, pyannoteAI 12%, Argmax 69%;
VoxConverse 46% / 39% / 42% / 38% / 45%.

## senko evaluation (https://github.com/narcotic-sh/senko/tree/main/evaluation)
OpenBench defaults "collar=0.0" and "skip_overlap=False". Apple M3 row (DER fraction, SF, SCA):
AISHELL-4 0.136 / 285x / 90%; AMI-IHM 0.275 / 270x / 50%; AMI-SDM 0.328 / 275x / 68.8%;
AVA-AVD 0.722; AliMeeting 0.304 / 282x / 80%; Earnings-21 0.211; ICSI 0.375; VoxConverse 0.139 / 393x / 44.8%.
README headline (different protocol, not stated): 13.5% VoxConverse, 13.3% AISHELL-4, 26.5% AMI-IHM;
"1 hour in 7.7 seconds" on M3. Pipeline: pyannote segmentation-3.0 or Silero VAD, CAM++ embeddings
(CoreML on Mac), spectral or UMAP+HDBSCAN clustering. MIT. Python.

## FluidAudio pinned 0.15.4 Documentation/Benchmarks.md (local checkout, doc dated pre-2026-06-16)
VoxConverse full (232 clips), "collar=0.25s, ignoreOverlap=True": stepRatio 0.2 / minSeg 1.0 (the
shipped defaults) average DER 15.07%, median 10.70%, RTFx 122; stepRatio 0.1 / minSeg 0 average DER
13.89%, RTFx 64.75. "baseline pytorch version is ~11% DER, we lost some precision dropping down to fp16".
AMI SDM 16-meeting test set, offline, average DER 10.6% (JER 17.4), 12/16 correct speaker counts,
RTFx ~70 (collar/overlap not stated in that table; run with --threshold 0.7 per main's note).
Main's Benchmarks.md (2026-08-19) adds: "The table above predates #801 and uses --threshold 0.7 under
the old (inverted) threshold semantics."
Sortformer (streaming v2.1 CoreML, NVIDIA high-latency config) AMI SDM average DER 31.7%, RTFx 126.7.
LS-EEND .ami variant, 500 ms step: AMI SDM average DER 20.7%, RTFx 74.5 (M4 Max).
CAM++ CoreML (beta, main): AISHELL-1 EER 0.48%; no diarization DER reported with CAM++.

## NVIDIA Sortformer cards
diar_streaming_sortformer_4spk-v2.1 (last modified 2025-12-31): NVIDIA Open Model License; max 4
speakers; "All evaluations include overlapping speech"; collar 0.25 s for CALLHOME-part2/CH109, 0 s for
DIHARD III, AliMeeting, AMI, NOTSOFAR1. Low-latency (1.04 s): DIHARD III <=4spk 15.09, CALLHOME 2spk 6.65,
AMI IHM 16.67. Very-high-latency config 30.4 s.
diar_sortformer_4spk-v1 (offline, 2024-09): license CC-BY-NC-4.0; DIHARD3-Eval <=4spk collar 0 14.76;
CALLHOME-part2 2spk 5.85, 3spk 8.46, 4spk 12.59 (collar 0.25); overlap included.
HF search for "sortformer" (2026-09-06): no NVIDIA model newer than v2.1 and none above 4 speakers,
other than the gated Nemotron-3-Diarization-preview (see frontier-nemotron3-hf-card.md).

## DiariZen (https://github.com/BUTSpeechFIT/DiariZen; HF BUT-FIT/diarizen-wavlm-large-s80-md-v2)
Code MIT; weights CC BY-NC 4.0. News: 2025-12-09 v2 benchmarks; 2026-01-31 multi-channel WavLM.
DER "without applying a collar" (overlap handling not stated on the page we read; the 2509.26177
benchmark scored DiariZen with overlap): Large-s80-v2 AMI-SDM 13.9, AISHELL-4 10.1, AliMeeting far
10.8, NOTSOFAR-1 16.7, MSDWild 15.8, DIHARD3 14.5, RAMC 11.0, VoxConverse 9.1. 63.3M params after 80%
structured pruning. No CoreML conversion found on HF; community ONNX and MLX repos exist.

## Benchmarking Diarization Models (arXiv 2509.26177, 2025-09-30)
"0.25 second collar and skip_overlap=False". Average over four datasets (AliMeeting, AMI, CALLHOME,
VoxConverse): PyannoteAI 11.2% DER, DiariZen 13.3% DER. RTF: DiariZen ~20x, Sortformer v2 ~214x.
"missed speech errors are the most common source of errors, with the exception of Sortformer, which
has a higher speaker confusion error."

## Argmax SpeakerKit (argmax-oss-swift, MIT; HF argmaxinc/speakerkit-coreml)
Releases: v0.17.0 2026-03-13 introduced SpeakerKit; v1.0.0 2026-05-01; v1.1.0 2026-08-06 exposes
speaker centroid embeddings. README: "runs Pyannote v4 (community-1) on Apple silicon"; macOS 13+.
HF repo (created 2026-03-11, modified 2026-05-07) has no license tag; files: speaker_clusterer/pyannote-v4
PldaProjector, speaker_embedder/pyannote-v3 SpeakerEmbedder (W16A16, W8A16). SDBench (arXiv 2507.16136,
Interspeech 2025): SpeakerKit "9.6x faster than Pyannote v3 while achieving comparable error rates".

## soniqo/speech-swift (Apache 2.0, macOS 15+)
docs/inference/speaker-diarization.md: Community-1 parity check on a fixed VoxConverse subset
(1,057.49 s, 0.25 s collar, overlap included): 4.66% DER / 21.43% JER vs the CoreML export's 4.65 /
21.42; "This is a small release parity check, not a dataset-wide quality claim". Models:
aufklarer/Pyannote-Community-1-CoreML (CC BY 4.0, FP32, ~32 MiB), aufklarer/Sortformer-Diarization-CoreML
(v2.1, CC-BY-4.0), aufklarer/Ultra-Sortformer-Diarization-CoreML (8-speaker fine-tune, Apache-2.0,
no published corpus numbers), MOSS Transcribe Diarize (CoreML/MLX).

## Joint ASR+diarization open weights
OpenMOSS-Team/MOSS-Transcribe-Diarize (0.9B, Apache-2.0, open-sourced 2026-07-09, HF modified
2026-09-02): up to 90 min, 50+ languages; reports CER/cpCER not DER: AISHELL-4 14.84/15.83, AliMeeting
24.86/22.17, Podcast 5.97/7.37, Movies 6.36/12.76; RTFx 294 (Open ASR leaderboard, GPU).
microsoft/VibeVoice-ASR (9B, MIT, 2026-01-21): up to 60 min; DER/cpWER/tcpWER: AISHELL-4 6.77/24.99/25.35,
AMI-IHM 11.92/20.41/20.82, AMI-SDM 13.43/28.82/29.80, AliMeeting 10.92/29.33/29.51; conditions not stated.
nvidia/multitalker-parakeet-streaming-0.6b-v1 (NVIDIA Open Model License): needs external diarization
(Streaming Sortformer v2/v2.1); cpWER AMI IHM 21.26, AMI SDM 37.44, CH109 15.81; .nemo only.
Voxtral Transcribe 2 (2026-02-04): diarization only in the API batch model; the open Realtime 4B has none.

## LLM post-correction
DiarizationLM (arXiv 2401.03506): fine-tuned PaLM 2-S; WDER rel. -55.5% Fisher, -44.9% Callhome.
google/DiarizationLM-8b-Fisher-v2 (Llama-3-8B, llama3 license): Fisher WDER 5.32 -> 3.28; Callhome
7.72 -> 6.66. SEAL (arXiv 2501.08421, 2025-01): acoustic-conditioned fine-tuned LLM with constrained
decoding, speaker error rate -24% to -43% (Fisher, Callhome, RT03-CTS). Efstathiadis et al. (arXiv
2406.04927, Speech Communication 2025): fine-tuned models are "constrained to transcripts produced using
the same ASR tool"; ensemble of three ASR-specific fine-tunes generalizes better. SpeakerLM (2508.06372)
reports zero-shot Qwen2.5-7B-Instruct and ChatGPT-4.5 "perform poorly ... even degrading overall
performance due to LLM hallucination"; fine-tuning fixes it.

## Apple SpeechAnalyzer
developer.apple.com SpeechTranscriber documentation JSON (macOS 26): no "speaker" attribute, option, or
result; a July 2026 third-party doc survey reaches the same conclusion.
