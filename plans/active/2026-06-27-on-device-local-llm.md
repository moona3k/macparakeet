# On-Device Local LLM — A Self-Optimized MLX Model for Transcript AI

**Status:** DIRECTION CONFIRMED (Daniel, 2026-07-04) — ship a local model as a dead-simple *option* while cloud/frontier stays the recommended default until local quality catches up (§1). Phase 0 spike + eval still gates what ships and at what scope (§8, §11).
**Created:** 2026-06-27
**Related issues:** #439 (integrated local cleanup/format — the core ask), #265 (custom/specialized cleanup model + full prompt control), #550 (global company context for cleanup), #460 (folder-scoped AI queries / cross-meeting QA), #563 (chat truncation from hardcoded context budgets), #408 (separate dictation/transform AI from meeting AI).
**Related plans:** [`2026-05-ai-setup-ux.md`](2026-05-ai-setup-ux.md) (where one-click setup lives), [`2026-06-19-meetings-workspace-productization.md`](2026-06-19-meetings-workspace-productization.md) (U6 local index / U7 cross-meeting Ask), [`2026-05-voice-command-agent-mode.md`](2026-05-voice-command-agent-mode.md) (tool-calling / agent mode).
**Canonical spec to update:** [`spec/11-llm-integration.md`](../../spec/11-llm-integration.md).

---

## 1. Goal & north star

Future direction: give MacParakeet a **first-party, on-device LLM** that powers transcript-based AI — **cleanup, summarization, QA, and eventually tool-calling** — with **no API key, no second app, and nothing leaving the Mac**, set up in **one click**.

**Positioning (decided 2026-07-04): option, not default.** The local model ships as a dead-simple choice alongside the existing providers; cloud/frontier models remain the recommended quality path for every AI surface until the local model demonstrably closes the gap on that surface. This splits the bar: to **offer** local, a surface must be trust-safe (fidelity gates) and clearly better than the deterministic pipeline; to **recommend or default to** local on a surface, it must reach cloud parity there. The option must stay effortless for non-technical users — one click, no key, no terminal — because that audience is exactly who cannot do BYO keys or Ollama.

**North star: output quality/accuracy of the final result.** We should not ship a local model just because it is local or easier for nontechnical users to set up. The feature is only worth adding if Phase 0 proves the model actually works well enough on real MacParakeet transcripts. A local model may be good enough first for one-transcript cleanup, summary, or Q&A; whole-library / cross-meeting analysis is a higher bar and current local LLMs are likely not sufficient without stronger retrieval, context handling, and model intelligence. We target performant Apple Silicon Macs, so model size (multi-GB download/RAM) is acceptable only when it buys reliably better output. Latency is a managed secondary concern.

**Strategy, if the gate passes: hyper-focus on one engine and one self-optimized model.** Rather than supporting every runtime and every model format, we would commit to **MLX** (Apple's on-device ML framework) and ship a **single model that we optimize specifically for Apple Silicon** — an open, permissively-licensed base that we convert, quantize, and (over time) fine-tune for MacParakeet's transcript tasks, with our own purpose-built model as the endgame. This is the opposite of a sprawling provider matrix: one engine, one tuned model, deeply optimized.

This is **not** "bundle a model into the app." The app stays small; the model is an **opt-in, verified download** the user enables with a single action, on top of the BYO flexibility we already have (Ollama / LM Studio / cloud keys / local CLI remain for power users).

### Why this matters now
Today every AI feature requires the user to bring a cloud API key **or** stand up Ollama/LM Studio themselves — a real setup cliff and an extra trust boundary for transcript text. Issue #439 captures it: people want a default local refiner that "just works" for "mama + grandma," while power users keep their options. The open question is whether current local LLMs are good enough to earn that default. If they are, the likely first win is local AI for one transcript at a time; broader cross-library intelligence remains a later capability gate.

---

## 2. Use cases (priority order)

| # | Task | What it needs | Where it plugs in today (provider-agnostic already) |
|---|------|---------------|------------------------------------------------------|
| A | **Transcript / dictation cleanup** (disfluency removal, light formatting, ITN, casing) | Strong instruction-following + faithfulness; low temperature; fast | `TextProcessing/AIFormatter.swift`, `TextProcessing/TranscriptFormatter.swift`; dictation `Services/Dictation/DictationService.swift`, file/URL/meeting `Services/TranscriptionService.swift` |
| B | **Summarization of long transcripts** (meetings, YouTube, files; 10k–50k+ tokens) | Long context (via chunking/map-reduce); capable model | `PromptResultsViewModel` → `LLMService.generatePromptResultStream`; prompt library |
| C | **QA over one transcript** (grounded answers; per-transcript first) | Long context + retrieval; faithfulness | `TranscriptChatViewModel` → `LLMService.chatStream`; live meeting `LiveAskPaneView` |
| D | **Cross-meeting / whole-library analysis** | Local index + retrieval + stronger context handling; likely beyond current small local LLMs until proven | `2026-06-19-meetings-workspace-productization.md` U6/U7; new retrieval layer |
| E | **Tool / function calling** (drive app actions, agent mode) | A tool-trained model + tool plumbing we don't have yet; structured-output reliability must be proven | New — enables `2026-05-voice-command-agent-mode.md` |

Cleanup, summary, Ask, and Transforms are **already provider-agnostic** (they route through `LLMService` → `RoutingLLMClient`). If Phase 0 passes, adding one local MLX provider makes the proven subset of A/B/C and selected-text Transforms available locally with **no call-site changes**. Cross-library analysis and tool-calling need separate gates and new plumbing (§6).

**Underweighted consumer — background/library intelligence jobs (added 2026-07-04):** the strongest structural fit for a local model is not replacing a user-initiated cloud call but the calls nobody makes because of cost/trust: auto-titling, entity/action-item extraction, tagging, and index enrichment for the context engine (see [`2026-07-04-context-engine-agent-tools.md`](2026-07-04-context-engine-agent-tools.md)). These are high-volume, low-entropy background tasks with a lower quality bar than user-facing prose, zero marginal cost locally, and no privacy exposure — where cloud can never compete on economics or trust. Design context-engine indexing jobs as local-model consumers from day one; they may justify the runtime even if only cleanup passes the user-facing gate.

---

## 3. Invariants / non-goals

- **One engine: MLX.** We do not build a multi-runtime hybrid. (Keep a thin `LocalLLMRuntime` protocol as cheap future insurance, but implement only MLX.)
- **One self-optimized model is the first-party path.** We pick/convert/quantize/fine-tune a single model for Apple Silicon and ship it as the default; depth of optimization over breadth of choice.
- **No product commitment before proof.** Do not add the runtime, downloader, or default setup path until Phase 0 proves the local model is useful enough for at least one clear user-facing job. "It runs locally" is not sufficient.
- **Apple Silicon only.** The MLX engine + our model require Apple Silicon (the app is already Apple-Silicon-only). The one-click local path must be hardware-gated/hidden so an unsupported Mac never surfaces a setup that cannot run.
- **On-device only for the local path.** No transcript text leaves the Mac when the local model is selected; indexing/retrieval for QA stays local.
- **Do not bundle a multi-GB model into the app binary.** Keep the DMG small; the model is a verified on-demand download into Application Support.
- **Preserve existing providers.** Cloud keys, Ollama, LM Studio, local CLI remain for power users. "BYO" for the in-process engine means **other MLX-format models**, not arbitrary formats.
- **Permissive licensing for anything we ship/fine-tune by default** — Apache-2.0 / MIT base only (see §5).
- **Accuracy beats latency.** When forced to choose for the default, pick the more accurate model/quant.
- **Structurally bounded memory (added 2026-07-04).** Long inputs are always chunked/map-reduced (small per-call windows) with quantized KV (`kvBits:4`), and the model unloads on idle. These are day-one design invariants, not tuning knobs: they make the in-process OOM scenario unreachable by construction instead of merely unlikely, which is what lets perf be instrumentation rather than a gate (§8).
- **Graceful fallback.** On model-missing / load failure / OOM, fall back to the deterministic pipeline (and offer raw transcript) — never block dictation, never insert an error string.

---

## 4. Runtime decision: MLX

We want an in-process runtime on Apple Silicon, optimizable for a single model, supporting streaming + (eventually) tool-calling + long context, with zero terminal/extra-app friction.

**Decision: MLX (mlx-swift / mlx-swift-lm), as the single in-process engine.** Rationale, given we optimize one model rather than support every model:
- **Best Apple Silicon performance** — fastest small-model decode; large prefill gains on M5+. The right engine when the goal is to make *one* model run as well as possible on this hardware.
- **Cleanest native integration** — first-party Apple SwiftPM packages; no C++/Metal framework to vendor and codesign. Lower long-term integration burden.
- **Full self-optimization control** — MLX quantization (including DWQ 4-bit ≈ 6–8-bit quality), and a clear path to convert/fine-tune our own model into MLX format. Conversion is a one-time, deliberate step we own, not a per-user chore.
- **Ships in notarized apps** today (Metal shaders built via Xcode, `.metallib` bundled). Large models on macOS need **no special memory entitlement** (the `com.apple.developer.kernel.increased-memory-limit` entitlement is iOS-only and does not apply on macOS) — fit is managed by RAM-gating model tiers and respecting the Metal wired-memory limit (see §9).

**Pinned facts (live-verified 2026-07-04, Codex web pass):** mlx-swift-lm latest is `3.31.4` — pin **exact** for the spike, plus a direct exact `mlx-swift 0.31.4` pin (the resolver otherwise picks `0.31.6`, which requires Swift tools 6.3). mlx-swift-lm itself requires Swift tools 6.1 (our package is 5.9 — see the build-gating decision in §6). Confirmed as cited: `ChatSession.respond`/`streamResponse`/`streamDetails`; `GenerateParameters` `kvBits`/`kvGroupSize`/`kvScheme`; `savePromptCache`/`loadPromptCache`; `RotatingKVCache.toQuantized()` still a `fatalError`; macOS 14.0 platform floor. Changed since research: `LLMModelFactory.loadContainer` in 3.x needs downloader/tokenizer adapters or the `MLXHuggingFace` macros — don't code against the old bare `loadContainer(configuration:)` shape.

**Runtimes we are NOT using (and why):** llama.cpp/GGUF — its main advantage is universal "load any GGUF" BYO, which we are explicitly *not* prioritizing; not worth the C++ vendoring when we optimize one MLX model. MLC-LLM / Core ML — per-model compile/convert, weaker momentum. Bundled Ollama — a hidden second process. **Apple Foundation Models** — Apple's fixed ~3B model with a ~4096-token window; we can't self-optimize it and it can't summarize long transcripts without heavy chunking. Demoted to an **optional zero-download fallback** for eligible users (the public `FoundationModels` API — `LanguageModelSession` + `@Generable` — on macOS 26+ with Apple Intelligence enabled), never the primary "our model" path.

### Two tradeoffs MLX carries — and our mitigations (own the model)
1. **No built-in grammar-constrained decoding** (no GBNF equivalent on MLX-Swift). Affects **tool-calling (D)** and strict JSON extraction. Mitigations, in order: (a) **fine-tune our model** to emit reliable tool/JSON output and validate-and-retry; (b) implement/port a **logits processor** for constrained decoding when needed; (c) for guaranteed-structured tasks on eligible OS, use Apple Foundation Models' typed `@Generable`. Validate in Phase 0 since tool-calling is a stated future goal.
2. **Long-context prefill** can be slow on MLX for very long inputs. Mitigations: **map-reduce chunking + retrieval** (needed for long meetings regardless), KV/prompt caching, and choosing/fine-tuning an architecture with good long-context behavior. Validate the long-transcript path in Phase 0.

---

## 5. Model: a self-optimized, permissively-licensed model

We ship **one** first-party model (with optional RAM-tiered variants), built from a permissively-licensed base so we can redistribute and fine-tune freely.

- **Base candidate / starting default: `Qwen3-4B-Instruct-2507`** — Apache-2.0, 262K native context, top sub-8B instruction-following, light KV cache, competent tool-calling. Exact MLX weights (verified 2026-07-04): `mlx-community/Qwen3-4B-Instruct-2507-DDWQ` **2.53 GB** (the distillation-recovered quant — note the repo is named DDWQ, not DWQ, and is slightly larger than plain 4-bit); plain 4-bit 2.26 GB; 6-bit 3.27 GB; 8-bit 4.27 GB and use the **non-thinking Instruct** checkpoint (cleanup wants determinism). This is the *base we optimize*, not necessarily the final shipped weights. Phase 0 bakes this off against Apache-licensed **Gemma-4-E4B** (community signal: the Gemma line leans terse/faithful for cleanup, Qwen stronger at summarizing/structuring — eval doc §8); the single-model invariant holds and the bake-off picks the one first-party default.
- **Self-optimization path:** (1) MLX convert + DWQ quantize and tune generation params; (2) fine-tune on transcript cleanup / summarization / QA style for higher faithfulness and our house formatting; (3) endgame = our own purpose-built MacParakeet model, published as MLX weights the one-click flow fetches.
- **Optional RAM tiers (same family for consistent prompts):** 16 GB → 4B; 32 GB → Qwen3-30B-A3B-Instruct (MoE, ~18.6 GB, ~3B-speed, near-flagship quality); 64 GB → 30B-A3B Q6/Q8. Start with the single 4B and add tiers only if the spike shows a clear quality gap. Note (2026-07-04 review): the user base skews pro hardware, so expect the 30B-A3B tier to be the difference between a tolerable option and a genuinely good one — the 4B is the 16 GB floor, not the pitch. Still Phase 2, not v1.
- **License rule:** base/fine-tune only from **Apache-2.0 / MIT** (Qwen3, Mistral Apache models, Phi-4/-mini, SmolLM, IBM Granite 4.0, OLMo 2). Avoid Gemma 2/3 (custom terms) and Llama (community license + EU multimodal carve-out) as a base. (Gemma 4 reportedly moved to Apache — re-check if wanted.)
- **Specialized cleanup model (#265):** don't maintain a second first-party model. Parakeet already emits punctuation/casing, so cleanup *beyond* punctuation (disfluency, ITN, light rewrite) is best done by our tuned general model under a strict source-faithful prompt. #265's "plug in a tiny specialized cleanup model + control the prompt" is satisfied by **BYO (another MLX model) + the editable prompt**.

**Freshness flags (verify in Phase 0):** small-model rankings move fast; advertised context windows overstate *reliable* comprehension; confirm the exact base + quant on real transcripts before locking.

---

## 6. Architecture & integration seam

Our LLM stack is already cleanly abstracted; the change is additive.

**Today (verified):**
- `Sources/MacParakeetCore/Models/LLMProvider.swift` — `LLMProviderID` enum + `LLMProviderDescriptor` (incl. `isLocal`) + `LLMProviderConfig`.
- `Sources/MacParakeetCore/Services/LLM/LLMClient.swift` — `LLMClientProtocol` (`chatCompletion`, `chatCompletionStream`, `testConnection`, `listModels`).
- `RoutingLLMClient.swift` — routes by `providerConfig.id`.
- `LLMService.swift` — `formatTranscript` / `generatePromptResult`(summary) / `chat` / `transform`; **provider-agnostic**. ⚠️ Context budgets hardcoded in **chars** (cloud 500k / local 80k / lmStudio 8k) with silent middle-truncation → root of **#563**.
- `LLMConfigStore.swift` — config in UserDefaults, keys in Keychain.
- Model-download prior art: FluidAudio `AsrModels.download(version:progressHandler:)` + `STTRuntime.deleteParakeetModel` — reuse for the MLX model files.
- Tool-calling: **absent** (`ChatMessage` has no tools).

**To add the in-process MLX provider:**
1. `LLMProviderID` += `.inProcessLocal` (and optionally `.appleIntelligence` for the FM fallback); add descriptors (`isLocal: true`, `supportsAPIKey: false`). **`baseURL` contract:** `LLMProviderConfig.baseURL` is non-optional today, so the in-process provider uses a sentinel URL (e.g. `inprocess://local`) that the in-process client ignores; only revisit making `baseURL` optional if more in-process providers appear.
2. New `Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift` implementing `LLMClientProtocol` over a thin `LocalLLMRuntime` protocol, with an **MLX implementation** (`MLXLLM` / `mlx-swift-lm`: `LLMModelFactory.loadContainer` → `ChatSession.respond`/streaming). Honor `Task.checkCancellation()`.
3. `RoutingLLMClient.client(for:)` += route `.inProcessLocal` → `InProcessLLMClient` (and `.appleIntelligence` → a `FoundationModelsLLMClient` if we add the fallback). Inject the new client through `RoutingLLMClient`'s initializer, mirroring how `cliClient` is provided today (eager injection). The **feature call sites and `LLMService`'s public API are unchanged** — only routing is extended. (The separate context-budget fix in step 6 *does* change `LLMService` internals — that is not a call-site change.)
4. New `InProcessModelDownloader` (reuse FluidAudio download/verify/delete pattern) + `InProcessModelManagerViewModel`. Models cached under `Application Support/MacParakeet/LLMModels/<id>/`. MLX models can also load via Hub download with progress.
5. Settings: add to provider order in `LLMSettingsView`/`LLMSettingsViewModel`; add the one-click card (§7).
6. **Fix context budgets (#563) — this changes `LLMService` internals** (the `cloud`/`local`/`lmStudio` char budgets + `truncateMiddle` live there): make budgets token-based and per-model (read the model's real context window) instead of hardcoded chars. Provider abstraction and call sites stay unchanged.
7. **Tool-calling (Phase 3):** extend `ChatMessage`/`ChatCompletionOptions`/`ChatCompletionResponse` with tool definitions + results; implement via a fine-tuned-for-tools model + validate/retry (and/or a logits processor / FM `@Generable`); wire allowlisted typed tools per `2026-05-voice-command-agent-mode.md`.

**Build gating (decided 2026-07-04, from live verification):** MLX **cannot** land as a plain dependency — command-line SwiftPM can't build the Metal shaders (xcodebuild required; Jan's app ships this way, copying `default.metallib`), and mlx-swift-lm needs Swift tools 6.1 vs our tools 5.9 and CI's Xcode 16.1. Therefore: `LocalLLMRuntime` protocol + `InProcessLLMClient` live in `MacParakeetCore` with **no MLX import**; the MLX implementation lives in a separate opt-in target/module wired only into app builds, gated the same way as the existing no-Whisper gate, so `swift build` / `swift test` / CI never resolve or compile MLX. App release builds (xcodebuild, Daniel's machine) turn the gate on.

**PR2 implementation note (2026-07-05):** the verified downloader, `InProcessModelManagerViewModel`, and one-click Settings card are allowed to exist behind the developer enable path while `AppFeatures.inProcessLocalLLMEnabled` remains `false`. This does not flip the public product surface: downloads are opt-in, RAM-gated at 16 GB, verified by size + SHA-256 manifest, and tested before `.inProcessLocal` is saved.

Build the **chunking / map-reduce / retrieval layer** for long transcripts regardless (summary/QA need it; mitigates MLX long-prefill).

---

## 7. One-click setup UX (hard requirement)

The local model is presented as an **option alongside the other providers** — recommendation copy keeps pointing at cloud/frontier for best quality until per-surface evidence flips it (§1) — but enabling it must be **a single obvious action**. Lives in the Settings → AI card + onboarding AI step (extends [`2026-05-ai-setup-ux.md`](2026-05-ai-setup-ux.md): `.setUpNeeded` / `.ready` / `.cannotConnect`).

- **Hardware gate (first):** only offer the local path on Apple Silicon (see §3); on unsupported hardware, hide it and fall back to BYO/cloud messaging — never surface a one-click setup that cannot run.
- **Primary: one "Enable local AI" button** that runs **download our optimized model → verify → select → test → "Ready"**, with a progress bar (reuse speech-model download UI) and recoverable error states (network/disk/corrupt → re-validate; mirror speech-model download hardening). RAM-aware: pick the right tier for the machine, respecting the macOS Metal wired-memory limit.
- **Optional zero-download path** where Apple Intelligence is available: "Use on-device AI (no download)" via Foundation Models for short tasks; clearly secondary to our model.
- **Manage models:** delete, switch tier, and **BYO an MLX model** (power users / #265).
- **Fallback messaging:** if no local model and no key, AI features show a compact empty state pointing at this one button; dictation/transcription always work without it.

---

## 8. Phasing

**Phase 0 — Spike + evaluation (decision gate).** Stand up a minimal in-process **MLX** path (mlx-swift-lm) with the base candidate (Qwen3-4B-Instruct-2507, DWQ). Evaluate on real MacParakeet transcripts: cleanup faithfulness, summary quality, one-transcript QA groundedness, and a tool-calling/JSON-reliability probe — **vs the deterministic pipeline and vs a cloud model**. Also run a deliberately hard cross-meeting / library-analysis probe to decide whether that scope is currently a no-go. Measure on-device latency (prewarm + prompt-cache) and RAM on 16/32/64 GB, and **explicitly validate the two MLX risks** (structured-output reliability, long-transcript prefill). Output: confirmed base model + quant, the chunking approach, which product surfaces are allowed, and accept/reject thresholds met. *Accuracy is the gating metric.* **Eval methodology — what to measure and how (metric stack, judge protocol, gold-set recipe, perf benchmarks, go/no-go) — is detailed in the companion [Phase 0 Eval Design](./2026-06-27-on-device-local-llm-phase0-eval.md).** Sequencing (revised 2026-07-04): **perf is instrumentation, not a gate.** 4B-class viability on M-series is community-settled, and the two real perf risks (long-context KV OOM, prefill stalls) are removed by construction via the §3 memory invariants (chunking + `kvBits:4` + unload-on-idle). Collect the §7 numbers incidentally from the spike build during dogfood — they tune the chunking threshold, they don't decide go/no-go. The gate is **quality only**: (1) Tier-1 deterministic fidelity gates on a ~50-item core plus side-by-side dogfood vs the cloud baseline on real meetings (including one adversarial session: summarize a long meeting on a 16 GB Mac while a recording is live); (2) the full 200-item gold set + judge calibration only if the decision is borderline. Don't let the eval become the project.

**Phase 1 — In-process MLX provider + one-click local *option* for proven tasks only.** Add `.inProcessLocal` + `InProcessLLMClient` (MLX) + downloader; ship the one-click card as an option (cloud stays the recommended default, §1) covering only the surfaces Phase 0 proves. Cleanup alone is a legitimate Phase 1 — do not stretch scope to summary/QA to justify the download if they read as mediocre; visible mediocrity is what killed ADR-008. Fix #563 (token budgets). Resolves the core of #439, and only part of #550.

**Phase 2 — Self-optimization + tiers + fallback.** Fine-tune the model for our tasks (cleanup/summary faithfulness, house style); add RAM tiers if warranted; add the optional Apple Intelligence zero-download fallback; ship the map-reduce/retrieval layer for long transcripts. BYO MLX model for power users (#265).

**Phase 3 — Tool-calling + cross-meeting QA, only if model capability catches up.** Add tool-calling (enables `2026-05-voice-command-agent-mode.md`) via a tools-tuned model + validation (and/or logits processor / FM); leverage the local model for cross-meeting/folder-scoped QA (#460), relaxing the "snippets-only to remote" constraint when inference is local (ties to meetings-workspace U6/U7). This phase should wait until local models demonstrate enough context, reasoning, and structured-output reliability to make whole-library analysis actually useful.

**Phase 4 (endgame) — Our own model.** A purpose-built MacParakeet cleanup/summary model, published as MLX weights the one-click flow fetches.

---

## 9. Risks & mitigations

- **Quality bar not met at tolerable size** → Phase 0 gate; accuracy is the metric; deterministic fallback retained.
- **Local model works only for narrow tasks** → ship only the proven subset; keep cloud/BYO providers as the recommendation for long-context or cross-library work.
- **MLX structured-output gap (tool-calling/JSON)** → fine-tune for tool output + validate/retry; optional logits processor; FM `@Generable` where available.
- **MLX long-context prefill** → map-reduce/retrieval + KV/prompt caching; validate in Phase 0.
- **RAM / macOS Metal wired-memory limit** (≈67% ≤36 GB, ≈75% >36 GB unified memory) → RAM-gate recommendations; cap context/KV; quantize KV for long transcripts; free idle models. (No memory entitlement on macOS — that is iOS-only.)
- **Apple Silicon requirement** → gate/hide the one-click local path on unsupported hardware (see §3) so it never offers a setup that cannot run.
- **MLX API churn** (mlx-swift-lm repo split / breaking 3.x) → isolate behind `LocalLLMRuntime`, pin exact versions, own upgrades.
- **First-run latency** (model load + shader compile) → prewarm on AI entry; stable-prompt-prefix prompt cache.
- **Long-transcript truncation (#563)** → token budgets + map-reduce, not silent middle-drop.
- **License contamination** → automated check that the base/fine-tune is Apache-2.0/MIT.
- **Build/CI** → CONFIRMED BLOCKING (2026-07-04): MLX Metal shaders need `xcodebuild`, and mlx-swift-lm needs Swift tools 6.1 (transitive `mlx-swift 0.31.6` even needs 6.3 — pin `0.31.4` directly). Mitigation is the §6 gating decision: CI and `swift build`/`swift test` never compile MLX; only gated app builds do.

## 10. Success criteria

- Fresh-install user enables capable local AI **in one action**, no key, no extra app; transcript text never leaves the device.
- Cleanup/summary/Ask quality on real single-transcript tasks **meets or beats** the deterministic baseline by Phase 0 thresholds, and is "good enough vs cloud" for everyday use.
- Summary/QA work on long meeting/YouTube/file transcripts without silent truncation.
- Cross-meeting / whole-library analysis is either proven useful with retrieval and explicit quality gates, or explicitly excluded from the first local-LLM release.
- The model is demonstrably **optimized for Apple Silicon** (latency/RAM acceptable on a 16 GB Mac), with a clear path to a fine-tuned MacParakeet model.

## 11. Decisions & open questions

**Decided (Daniel, 2026-07-04):**
- Ship the local model as a **dead-simple option, not the default**; cloud/frontier stays the recommended quality path per surface until local reaches parity there (§1).
- The go/no-go bar splits accordingly: fidelity-safe + clearly above the deterministic floor to *offer*; cloud parity to *recommend* (eval doc §9).
- v1 scope is whatever subset Phase 0 proves; cleanup alone is acceptable. Cross-library analysis and agentic/MCP-style tool-calling stay cloud-first until local capability is proven (closed-world app tools may qualify earlier than open-ended agents).

**Still open:**
1. **Confirm MLX as the single engine** (no llama.cpp/multi-runtime), with a thin `LocalLLMRuntime` seam as optional insurance?
2. **Base model:** Qwen3-4B-Instruct-2507 vs Gemma-4-E4B (both Apache) — Phase 0 bake-off picks the one first-party default; 30B-A3B tier expected in Phase 2 for 32 GB+ Macs.
3. **Self-optimization roadmap:** convert+quantize first (Phase 1), fine-tune next (Phase 2), our own model as endgame (Phase 4) — agree on this sequencing?
4. **Apple Intelligence:** include as an optional zero-download fallback, or skip entirely to stay single-model?

---

## References

Runtime/model research summarized inline (§4–§5); sources captured during research include Apple `mlx-swift` / `mlx-swift-lm`, Apple ML Research on MLX/M5 performance, MLX quantization (DWQ) analyses, Qwen3 / Mistral / Phi-4 / SmolLM / Granite license + benchmark pages, BFCL V4 (tool-calling), and NoLiMa long-context evals; FoundationModels `SystemLanguageModel` docs + TN3193 (4096-token window) for the fallback option. Re-verify specifics in Phase 0 (fast-moving area). Codebase seam references are file-pathed in §6.
