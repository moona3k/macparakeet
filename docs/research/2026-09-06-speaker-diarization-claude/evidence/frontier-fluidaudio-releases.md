### v0.15.6 (2026-08-19T06:24:27Z)

## What's Changed
* chore(download): remove migration-only characterization scaffolding (#781)  https://github.com/FluidInference/FluidAudio/pull/782
* fix(tts/kokoro-ane): smart-apostrophe contractions + hyphenated lexicon lookups (#774, #775)  https://github.com/FluidInference/FluidAudio/pull/783
* fix(tts): normalize decade and bare-year forms in English text (#776)  https://github.com/FluidInference/FluidAudio/pull/780a
* feat(tts): route English frontends through native NeMo TN when available  https://github.com/FluidInference/FluidAudio/pull/784
* Seam-gap repair pass for long-form chunk-merge content drops by @maboa in https://github.com/FluidInference/FluidAudio/pull/761
* feat(asr): add language hint to SlidingWindowAsrConfig by @patlux in https://github.com/FluidInference/FluidAudio/pull/786
* feat(tts/kokoro): byte-exact NeMo text normalization before G2P  https://github.com/FluidInference/FluidAudio/pull/790
* fix(download): preserve model cache on transient network errors by @dtopel in https://github.com/FluidInference/FluidAudio/pull/792
* feat(tts): LuxTTS backend 48 kHz zero-shot voice cloning (CoreML)  https://github.com/FluidInference/FluidAudio/pull/785
* fix(itn): protect natural-language ambiguous words from native normalization  https://github.com/FluidInference/FluidAudio/pull/796
* fix(tts/pocket-tts): enable voice cloning for 24-layer non-English packs (#793)  https://github.com/FluidInference/FluidAudio/pull/797
* OfflineDiarizerManager: split process() into prepare()/cluster() for cacheable segmentation+embeddings by @ComicBit in https://github.com/FluidInference/FluidAudio/pull/789
* Remove redundant audio decoding in CLI `transcribe` path by @hamzaq2000 in https://github.com/FluidInference/FluidAudio/pull/799
* fix(asr): end-align the final window at the last speech-bearing frame (#747)  https://github.com/FluidInference/FluidAudio/pull/800
* feat(asr): expose non-mutating vocabulary candidate evidence by @CiprianSpiridon in https://github.com/FluidInference/FluidAudio/pull/805
* fix(tts): make LuxTTS resources signable on iOS by @CiprianSpiridon in https://github.com/FluidInference/FluidAudio/pull/806
* fix(sortformer): streaming mel emits phantom frames, drifting all timestamps late by @predict-woo in https://github.com/FluidInference/FluidAudio/pull/807
* feat(download): stall watchdog + DownloadConfig plumbing (#810)  https://github.com/FluidInference/FluidAudio/pull/811
* feat(cli/process): add --compute-units flag for offline diarization  https://github.com/FluidInference/FluidAudio/pull/812
* Expose token timings from the Unified offline batch path by @NylonDiamond in https://github.com/FluidInference/FluidAudio/pull/814
* fix(tts/kokoro-ane): throw instead of trapping on non-finite PostAlbert durations  https://github.com/FluidInference/FluidAudio/pull/816
* fix(tts/kokoro-ane): warn on BNNS-crash-prone OS builds (26.4–26.5.x) + document both Apple bug classes  https://github.com/FluidInference/FluidAudio/pull/818
* fix(download): include CoreML bundle internals for subPath repos (StyleTTS2 corruptedModel)  https://github.com/FluidInference/FluidAudio/pull/821
* feat(tts/kokoro-ane): Japanese variant + MiniMax benchmark support (--phonemes)  https://github.com/FluidInference/FluidAudio/pull/820
* fix(asr): preserve merge token order at chunk seams (#825)  https://github.com/FluidInference/FluidAudio/pull/830
* fix(download): interrupted first download no longer bricks streaming ASR managers (#819); Unified int8 A16 compat docs (#828)  https://github.com/FluidInference/FluidAudio/pull/829
* fix(asr/eou): debounce on wall-clock silence, not consecutive EOU emissions  https://github.com/FluidInference/FluidAudio/pull/831
* fix(download): stop downloading never-loaded sibling bundles in subPath repos (#826)  https://github.com/FluidInference/FluidAudio/pull/832
* fix: prevent integer overflow in AudioSourceFactory frame count calculation by @jtjones1028 in https://github.com/FluidInference/FluidAudio/pull/813
* docs(asr): clarify vocabulary alias match semantics by @CiprianSpiridon in https://github.com/FluidInference/FluidAudio/pull/834
* fix(tts/kokoro-ane): route noise+tail to CPU by default on OS 27  https://github.com/FluidInference/FluidAudio/pull/849
* fix(tts/kokoro-ane): keep BNNS crash advisory active on iOS 26.6+  https://github.com/FluidInference/FluidAudio/pull/848
* fix(asr/streaming): temporally gate token dedup to stop prefix-collision loss (#787)  https://github.com/FluidInference/FluidAudio/pull/788
* fix(audio): tolerate the phantom tail of packetized formats in resampleAudioFile by @maboa in https://github.com/FluidInference/FluidAudio/pull/845
* fix(asr/tdt): scope applyEnglishBlocklist to French only  https://github.com/FluidInference/FluidAudio/pull/847
* feat(tts/kokoro-ane): expose predicted token durations by @Bbrizly in https://github.com/FluidInference/FluidAudio/pull/854
* Exclude Parakeet benchmark documentation from target by @aindaco1 in https://github.com/FluidInference/FluidAudio/pull/837
* feat(speaker): CAM++ speaker-embedding backend (CoreML) [beta]  https://github.com/FluidInference/FluidAudio/pull/652
* feat(vad): FSMN-VAD backend (CoreML) [beta]  https://github.com/FluidInference/FluidAudio/pull/653
* feat(asr/canary): Canary-1B-v2 AED engine + CTC-spotter custom vocab [beta]  https://github.com/FluidInference/FluidAudio/pull/709
* feat(tts): add NeuTTS-2E backend (emotional English TTS, Qwen3 + NeuCodec) [beta]  https://github.com/FluidInference/FluidAudio/pull/822
* perf: improve performance by @yanxxl in https://github.com/FluidInference/FluidAudio/pull/804
* feat(tts): Inflect v2 (Micro/Nano) CoreML backend [beta]  https://github.com/FluidInference/FluidAudio/pull/823
* fix(asr): post-#804 cleanup — format CI, pointer lifetimes, shared argmax, timestamp tail  https://github.com/FluidInference/FluidAudio/pull/857
* Add ModelRegistry.repoOverrides so mirrored repos can be resolved by @omachala in https://github.com/FluidInference/FluidAudio/pull/824
* style(tests): wrap over-long ModelRegistryTests lines from #824  https://github.com/FluidInference/FluidAudio/pull/859
* fix(offline-diarizer): pyannote-parity clustering — threshold semantics, constraint count, constrained assignment  https://github.com/FluidInference/FluidAudio/pull/802
* fix(tts): repair legacy Kokoro ANE caches on OS 27  https://github.com/FluidInference/FluidAudio/pull/858
* fix(asr/streaming): re-decode final window from frame 0 — stops #855 trailing-word loss  https://github.com/FluidInference/FluidAudio/pull/861
* perf(download): skip unused PocketTTS variants + concurrent subdirectory fetches  https://github.com/FluidInference/FluidAudio/pull/863
* feat(asr/unified): vocabulary boosting on the unified Parakeet path  https://github.com/FluidInference/FluidAudio/pull/862
* fix(download): latch pre-attach cancellation so cancelled downloads never start  https://github.com/FluidInference/FluidAudio/pull/864

## New Contributors
* @maboa made their first contribution in https://github.com/FluidInference/FluidAudio/pull/761
* @patlux made their first contribution in https://github.com/FluidInference/FluidAudio/pull/786
* @dtopel made their first contribution in https://github.com/FluidInference/FluidAudio/pull/792
* @ertra made their first contribution in https://github.com/FluidInference/FluidAudio/pull/795
* @drkpxl made their first contribution in https://github.com/FluidInference/FluidAudio/pull/798
* @CiprianSpiridon made their first contribution in https://github.com/FluidInference/FluidAudio/pull/805
* @predict-woo made their first contribution in https://github.com/FluidInference/FluidAudio/pull/807
* @NylonDiamond made their first contribution in https://github.com/FluidInference/FluidAudio/pull/814
* @shanforge made their first contribution in https://github.com/FluidInference/FluidAudio/pull/815
* @jtjones1028 made their first contribution in https://github.com/FluidInference/FluidAudio/pull/813
* @Bbrizly made their first contribution in https://github.com/FluidInference/FluidAudio/pull/854
* @aindaco1 made their first contribution in https://github.com/FluidInference/FluidAudio/pull/837
* @yanxxl made their first contribution in https://github.com/FluidInference/FluidAudio/pull/804
* @omachala made their first contribution in https://github.com/FluidInference/FluidAudio/pull/824

**Full Changelog**: https://github.com/FluidInference/FluidAudio/compare/v0.15.5...v0.15.6

### v0.15.5 (2026-07-07T22:55:46Z)

Highlights

- Download stack rebuilt (#765). The monolithic DownloadUtils is replaced by a composable ModelHub with resumable downloads (HTTP Range), byte-level progress, artifact validation before caching, and a shared retry policy that honors Retry-After. Breaking: DownloadUtils → ModelHub (#779).
- Parakeet unified ASR (#705). Native-Swift mel front-end, word-level timestamps, and lower-latency streaming tiers.
- Custom vocabulary controls (#647, #702, #724). Per-term CTC thresholds plus opt-in knobs to curb short-term over-firing and disable the acoustic spotter-rescue.

ASR
- Native-Swift mel front-end fixes iPadOS cold-start zero output (#744)
- Repair stale/corrupt Nemotron multilingual latin tokenizer on download (#690)
- Remove chunk-merge seam artifacts in offline transcription (#708), plus word-boundary-safe fallbacks for 3 residual seam-merge drop paths (#759)
- Fetch parakeet_vocab.json in AsrModels.download (#763)
- Feature Provider classes for unified Parakeet ASR (#713, @SGD2718)
- Fix type-checker timeout in NemotronMultilingualFleursBenchmark (#732, @kripskroll)

TTS

- Shared English text normalization (numbers/times) + initialism helpers (#715); adopted by StyleTTS2 (#720)
- Auto-chunk long text in KokoroAne high-level synthesize (#717)
- Fix KokoroAne strided MLMultiArray handling (#730, @XUJiahua)
- Supertonic: inter-chunk silence 0.3s → 0.05s + --silence flag (#737)

Diarization

- BNNS-fixed Sortformer v3 models, precision/compute-unit control + cancellation (#728)
- Deterministic, robust offline VBx re-clustering via K-Means n_init (#735, @testfields)
- Honor configuration.computeUnits in OfflineDiarizerModels.load (#743, @chadneal)
- Optional progressHandler on performCompleteDiarization (#753, @thatbin)
- Honor configuration.computeUnits in OfflineDiarizerModels.load (#743, @chadneal)
- Optional progressHandler on performCompleteDiarization (#753, @thatbin)
- Re-embed zero-vote spans instead of arbitrary cluster-0 tie-break (#751, @ComicBit)
- LS-EEND speaker pre-enrollment bugfixes (#729, @SGD2718)

Download infrastructure (#765)

- Wave 1: characterization tests + download smoke CI (#770)
- Wave 2: extract HFClient + RetryPolicy primitives (#771)
- Wave 3: one paginating HFTreeLister (#772)
- Wave 4: FileDownloader, ModelCache, ProgressReporter; DownloadUtils becomes a façade (#777)
- Wave 5: converge fetchHuggingFaceFile onto the shared policy (#778)
- Wave 6: ModelHub replaces DownloadUtils (#779) — breaking
- Resumable downloads (#768), byte-level progress (#764), byte-weighted subdirectory progress (#769, @JulianPscheid), artifact validation (#741), preserve cache on cancelled first load (#749, @ComicBit)

VAD

- Update Silero VAD CoreML artifact to v6.2.1 (#734, @LemonCANDY42)

Benchmarks & Docs

- Fail loudly on missing AMI annotations instead of scoring placeholder ground truth (#754)
- Fetch AMI corpus from HuggingFace mirror, Edinburgh fallback (#767)
- Add evoglyph to the Showcase (#755, @lucasmccomb)

New Contributors

@kripskroll, @testfields, @lucasmccomb, @thatbin, @chadneal, @holovchenko

Full Changelog: https://github.com/FluidInference/FluidAudio/compare/v0.15.4...v0.15.5

 

