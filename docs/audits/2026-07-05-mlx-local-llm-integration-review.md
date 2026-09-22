# MLX Local LLM Integration Review

Date: 2026-07-05

Status: deep code review and focused verification of the dev-gated MLX local
LLM path. This is a handoff note for the next agent, not a product spec change.

**Resolution update (2026-07-05):** findings 1, 2, 5, 6, 7, 8, and 9 are
CLOSED on main — PR #749 (capability gating + generation smoke), PR #750
(disk preflight, remove-model action, removal/lease race fix), PR #746
(docs status alignment, MLX/model attribution, pin comment). Remaining open:
finding 3 (context-strategy seam — needs design note + dogfood data),
finding 4 (public setup UX), finding 10 (Phase 0 evaluation).

## Scope

The review focused on whether the in-process MLX path is functionally real and
how close it is to a nontechnical "download and click" setup experience.

Primary areas reviewed:

- Build gating and dependency resolution in `Package.swift`.
- Runtime injection in `Sources/MacParakeet/App/AppEnvironment.swift`.
- Feature visibility in `Sources/MacParakeetCore/AppFeatures.swift`.
- Provider selection in `Sources/MacParakeetCore/Models/LLMProvider.swift`.
- Settings setup UI in `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`.
- Setup state in `Sources/MacParakeetViewModels/InProcessModelManagerViewModel.swift`.
- Downloader hardening in `Sources/MacParakeetCore/Services/LLM/InProcessModelDownloader.swift`.
- Client/routing in `Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift`
  and `RoutingLLMClient.swift`.
- MLX implementation in `Sources/MacParakeetLocalLLM/MLXLocalLLMRuntime.swift`.
- Summary/chat context handling in `Sources/MacParakeetCore/Services/LLM/LLMService.swift`.
- Governing docs in `spec/11-llm-integration.md`,
  `spec/adr/011-llm-cloud-and-local-providers.md`, and
  `plans/active/2026-06-27-on-device-local-llm*.md`.

## Bottom Line

The MLX path is a credible dev-gated foundation. It is not vapor:

- Normal builds do not resolve MLX dependencies.
- Gated builds include `MacParakeetLocalLLM`.
- App runtime injection exists when the MLX compile flag is present.
- The default model manifest is pinned and verified.
- The Settings setup flow exists.
- Focused tests pass.
- The gated `MacParakeetLocalLLM` target compiles.

It is not ready for a public nontechnical "download and click" promise. The
remaining work is mostly productization and proof: capability gating, real
generation smoke testing, long-context behavior, setup preflight/recovery,
model removal, license/disclosure cleanup, and Phase 0 quality evidence on
target Macs.

Two distinct gates: capability gating and a generation smoke test block even
an internal dogfood flag-flip; everything else blocks only the public promise.
Dogfood should start as soon as the first two land — real usage data is the
input Phase 0 and the chunking design need.

## Positive Evidence

### Build and runtime seam

`Package.swift` keeps MLX dependencies behind `MACPARAKEET_ENABLE_MLX_LOCAL_LLM`.
Normal package description did not list MLX or Swift Transformers dependencies.
With the flag enabled, the package graph includes `MacParakeetLocalLLM`.

`AppEnvironment` injects:

- `RoutingLLMClient(inProcessClient: InProcessLLMClient(runtime: MLXLocalLLMRuntime()))`
  when `MACPARAKEET_HAS_MLX_LOCAL_LLM` is defined.
- `RoutingLLMClient()` otherwise, which uses `UnavailableLocalLLMRuntime`.

This is a reasonable compile-time seam for keeping public builds free of MLX
until the feature is intentionally enabled.

### Downloader quality

`InProcessModelDownloader` is stronger than a quick prototype:

- Default model is pinned to `mlx-community/Qwen3-4B-Instruct-2507-DDWQ`.
- Manifest pins revision `88033de44951ebedb96e0adb68cc037443aab93a`.
- Individual files have expected byte counts and SHA-256 hashes.
- Managed cache is considered valid only with a verification marker.
- Manifest paths are validated against traversal and symlink escape.
- Existing files are verified before reuse.
- Partial downloads are resumed when possible and removed when corrupt.
- Redirects are restricted to HTTPS `huggingface.co` / `hf.co`.
- Final file creation uses no-follow/exclusive creation patterns.

This is the right shape for a first-party model download path.

### Focused verification passed

Commands run:

```bash
swift test --filter InProcessModelDownloaderTests
swift test --filter InProcessModelManagerViewModelTests
swift test --filter InProcessLLMClientTests
swift test --filter LLMProviderDescriptorTests
MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1 MACPARAKEET_SKIP_WHISPERKIT=1 swift build --target MacParakeetLocalLLM
```

All passed. The gated build emitted a non-blocking warning that dependency
`mlx-swift` is not used by any target.

## Findings For Next Agent

Severity is tagged with the gate it blocks: findings 1-2 block even an
internal dogfood flag-flip; findings 3-7 block the public "download and
click" promise but not dogfood.

### 1. High (blocks dogfood): setup visibility is not tied to runtime linkability

The Settings setup card visibility is controlled by
`AppFeatures.isInProcessLocalLLMVisible(defaults:)`. That checks the product
flag, developer defaults key, or launch argument. It does not prove that the
MLX runtime is linked into the binary.

In normal builds, `AppEnvironment` still injects the default
`UnavailableLocalLLMRuntime`. If a dev override exposes the setup card in that
build, a user can be invited to download the model and only then fail when the
runtime cannot load.

Why it matters:

- This is acceptable for internal development only if everyone understands the
  build flag.
- It is not acceptable for nontechnical setup because it can waste a large
  download and fail after the user did what the app asked.

Recommended fix:

- Add a runtime availability/capability bit that is true only when the MLX
  target is linked.
- Gate the setup card and the provider picker on both product visibility and
  runtime capability.
- If a developer override is set in a non-MLX build, show a dev-only unavailable
  explanation before any download can start.

Key files:

- `Sources/MacParakeetCore/AppFeatures.swift`
- `Sources/MacParakeet/App/AppEnvironment.swift`
- `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
- `Sources/MacParakeetCore/Services/LLM/LocalLLMRuntime.swift`

### 2. High (blocks dogfood): "test local AI" only loads the model; it does not test generation

`InProcessModelManagerViewModel.enableLocalAI()` downloads and verifies the
model, then calls `llmClient.testConnection(config:)` before saving
`.inProcessLocal`.

For the in-process path, `InProcessLLMClient.testConnection` obtains a generation
lease and calls `loadRuntime`. It does not run a token-generation smoke.

Why it matters:

- Model load can succeed while tokenizer, chat template, prompt formatting,
  Metal execution, or streaming generation fails.
- For a one-click setup flow, saving the provider should require a real minimal
  generation proof.

Recommended fix:

- Add a short deterministic smoke, such as a one-token or small "OK" generation,
  after model load and before saving `.inProcessLocal`.
- Prefer putting this behind a runtime-level method such as
  `LocalLLMRuntime.smokeTest(modelDirectory:)` so the setup manager does not
  know MLX internals.
- Add an opt-in integration test that uses an already-downloaded model path so
  release/dogfood machines can verify real generation.

Key files:

- `Sources/MacParakeetViewModels/InProcessModelManagerViewModel.swift`
- `Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift`
- `Sources/MacParakeetLocalLLM/MLXLocalLLMRuntime.swift`

### 3. High (blocks public promise, not dogfood): long transcript summary/chat truncates before MLX chunking can help

`LLMService` applies local-provider context budgets before sending the prompt to
the selected client. Local providers currently receive an 80,000 character
budget and the service middle-truncates transcript/context for summary and chat
prompts.

`InProcessLLMClient` has map-reduce chunking, but it only receives the prompt
after `LLMService` has already truncated it. That means the MLX-specific
chunking path does not preserve full transcript content for the most important
initial use cases.

Why it matters:

- The likely first useful MLX scopes are single-transcript summarization and
  transcript Q&A.
- Real meetings and YouTube/media transcripts can exceed the local character
  budget.
- A user will perceive this as local AI being weak or inconsistent, even if the
  model itself is usable.

This is the one real design decision in this list, not a mechanical fix.
Today `LLMService` owns context policy uniformly for all providers; routing
full transcripts to an in-process chunk/reduce path makes context policy
provider-dependent. Where that seam lives — service or client — is a
hard-to-reverse contract choice and needs a short design review before an
executor implements it.

Recommended direction:

- Move the budget decision behind the client: the client advertises a context
  strategy (for example `.truncate(budget:)` vs `.chunked`) and `LLMService`
  asks instead of assuming. Keep cloud provider behavior unchanged.
- Write the seam decision up briefly and get design sign-off before coding.
- Do NOT block dogfood on this. Dogfood with truncation and let real usage
  show how often transcripts exceed the 80,000-character budget.
- Phase 0 must measure end-to-end chunked-summary latency on long meetings,
  not just tokens per second. A 4B model map-reducing a 2-hour meeting may be
  slow enough that chunking feels worse than truncation; that outcome should
  be allowed to change the design.

Key files:

- `Sources/MacParakeetCore/Services/LLM/LLMService.swift`
- `Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift`
- `plans/active/2026-06-27-on-device-local-llm.md`

### 4. Medium: setup UX is still developer-facing

The current Settings card is good for dogfood but not yet for nontechnical
users. It uses language like "Experimental" and "dev-enabled build", presents
Local MLX as another provider, and places it after the Local CLI option in the
provider list.

Why it matters:

- Nontechnical setup should feel like first-party model setup, not provider
  configuration.
- The user should not need to understand MLX, local CLI providers, API keys, or
  build flags.

Recommended fix:

- Keep the provider picker as the advanced configuration surface.
- Add or promote a primary "Download local AI" setup path when the feature is
  public-capable.
- The setup flow should include preflight, progress, resume/retry, delete/reset,
  and plain recovery messages.
- Avoid making local MLX the default or recommended provider until Phase 0
  quality evidence justifies it.

Key files:

- `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`
- `Sources/MacParakeetCore/Models/LLMProvider.swift`
- `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`

### 5. Medium: setup checks RAM but not disk space

`InProcessModelManagerViewModel` gates setup on 16GB physical RAM. The default
model download is about 2.53GB, but the setup path does not appear to preflight
available disk space before download.

Why it matters:

- Disk failure after a long download attempt is a poor first-run experience.
- The app already has onboarding-style preflight patterns elsewhere, so this
  would fit existing product behavior.

Recommended fix:

- Before starting download, check free space at the app support volume.
- Include room for partial files and extraction/cache overhead if any.
- Report required and available space in user-facing failure state.

Key files:

- `Sources/MacParakeetViewModels/InProcessModelManagerViewModel.swift`
- `Sources/MacParakeetCore/Services/LLM/InProcessModelDownloader.swift`
- `Sources/MacParakeetCore/Services/AppPaths.swift`

### 6. Medium: docs and plans have mixed status signals

The repo now has dev-gated MLX runtime/downloader/setup code. Some docs still
read as if runtime/downloader should not be added until Phase 0 proof exists,
while later plan sections allow a dev-gated foundation.

Correct current status:

- Dev-gated foundation code exists.
- Public one-click setup is still blocked by capability, UX, release, and
  quality evidence gates.
- First plausible scope is single-transcript cleanup/summarization/Q&A.
- Cross-meeting or whole-library analysis remains future-gated.

Recommended fix:

- Update `spec/11-llm-integration.md`, ADR-011, and the active plan so they use
  that exact distinction.
- Keep Phase 0 as the gate for product promise and default/recommendation, not
  as a denial that dev-gated foundation code exists.

Key files:

- `spec/11-llm-integration.md`
- `spec/adr/011-llm-cloud-and-local-providers.md`
- `plans/active/2026-06-27-on-device-local-llm.md`
- `plans/active/2026-06-27-on-device-local-llm-phase0-eval.md`

### 7. Medium: third-party/model attribution is incomplete for public release

`THIRD_PARTY_LICENSES.md` does not yet list the MLX dependencies or the Qwen3
model download. That may be fine while the path is dev-gated, but it must be
closed before any public one-click release.

Recommended fix:

- Add MLX package attribution if the package graph enters a release build.
- Add the default model attribution, source, license, and download disclosure.
- Ensure Settings or release notes clearly state that the model is downloaded
  from Hugging Face and runs locally after setup.

Key files:

- `THIRD_PARTY_LICENSES.md`
- `Sources/MacParakeetCore/Services/LLM/InProcessModelDownloader.swift`

### 8. Medium: no model removal/reclaim path

The setup flow can download a ~2.53GB model into Application Support, but
there is no first-class way for a user to remove it and reclaim the disk
space. A delete/reset control appears only as one bullet inside the setup-UX
finding above; for an artifact this large under the app's user-data posture,
it deserves its own line item and must exist before public release.

Recommended fix:

- Add an explicit "Remove downloaded model" action in the setup/settings
  surface that deletes the managed cache and returns the provider to its
  unconfigured state.
- Show the on-disk size next to the action.
- Removal must not touch anything outside the managed model cache directory.

Key files:

- `Sources/MacParakeetViewModels/InProcessModelManagerViewModel.swift`
- `Sources/MacParakeetCore/Services/LLM/InProcessModelDownloader.swift`
- `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`

### 9. Low: gated build warns about unused `mlx-swift`

The gated build succeeded, but SwiftPM warned that dependency `mlx-swift` is
not used by any target. This is almost certainly intentional version pinning
(`mlx-swift-lm` uses MLX transitively). Add a one-line comment in
`Package.swift` saying so and move on; it does not merit release-notes
documentation.

Key file:

- `Package.swift`

### 10. Residual risk: real model generation quality was not tested in this pass

This review compiled the gated target and ran focused unit tests. It did not
download the real Qwen model or run real generation locally.

Before public setup, Phase 0 should measure:

- First-run download time and failure modes.
- Model load time.
- Time to first token.
- Tokens per second.
- Peak memory on 16GB and 24GB Apple Silicon Macs.
- Quality for transcript cleanup, summary, and Q&A.
- End-to-end chunked-summary latency on long meetings (not just tokens/sec).
- Behavior on long transcripts after the chunking fix.
- Failure/retry behavior after offline, sleep, low disk, and corrupt partial
  download scenarios.

## Recommended Implementation Order

Dogfood gate (before internal flag-flip candidates):

1. Add runtime capability gating so impossible builds cannot show or start local
   AI setup, and add real generation smoke testing before saving
   `.inProcessLocal`. These are small and belong in one PR.
2. Add disk-space preflight and clearer setup failure recovery.

Public gate (during/after dogfood):

3. Write and review the short design note on the context-strategy seam
   (finding 3), then implement chunked context handling for in-process local.
4. Add a model removal/reclaim action.
5. Polish the public UX into a first-party "Download local AI" setup flow.
6. Update docs to distinguish dev-gated foundation from public capability, and
   add license/model attribution and release disclosure (findings 6-7 can ride
   along with the flag-flip PR).
7. Run Phase 0 quality/performance evaluation on real hardware and the pinned
   default model. Phase 0 is the go/no-go for any default or recommendation.

## Suggested Test Plan For Follow-Up PRs

For capability gating:

```bash
swift test --filter LLMProviderDescriptorTests
swift test --filter InProcessModelManagerViewModelTests
swift test --filter LLMSettingsViewModelTests
```

For downloader/preflight changes:

```bash
swift test --filter InProcessModelDownloaderTests
swift test --filter InProcessModelManagerViewModelTests
```

For real runtime changes:

```bash
MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1 MACPARAKEET_SKIP_WHISPERKIT=1 swift build --target MacParakeetLocalLLM
```

Add an opt-in integration test or script that only runs when a verified model
path is present, so normal CI does not download multi-GB assets.

For long-context changes:

```bash
swift test --filter InProcessLLMClientTests
swift test --filter LLMServiceTests
```

Use focused tests during iteration. Run the full `swift test` suite at most once
as the final gate if the follow-up branch changes shared LLM behavior.

## Source Map

- Build flags and target wiring: `Package.swift`
- Feature gate: `Sources/MacParakeetCore/AppFeatures.swift`
- Runtime injection: `Sources/MacParakeet/App/AppEnvironment.swift`
- Provider descriptor: `Sources/MacParakeetCore/Models/LLMProvider.swift`
- Settings card: `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`
- Settings view model: `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
- Setup manager: `Sources/MacParakeetViewModels/InProcessModelManagerViewModel.swift`
- Downloader: `Sources/MacParakeetCore/Services/LLM/InProcessModelDownloader.swift`
- Runtime protocol: `Sources/MacParakeetCore/Services/LLM/LocalLLMRuntime.swift`
- In-process client: `Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift`
- Routing client: `Sources/MacParakeetCore/Services/LLM/RoutingLLMClient.swift`
- MLX runtime: `Sources/MacParakeetLocalLLM/MLXLocalLLMRuntime.swift`
- Prompt/context policy: `Sources/MacParakeetCore/Services/LLM/LLMService.swift`
- Public LLM spec: `spec/11-llm-integration.md`
- LLM ADR: `spec/adr/011-llm-cloud-and-local-providers.md`
- Local LLM plan: `plans/active/2026-06-27-on-device-local-llm.md`
- Phase 0 eval plan: `plans/active/2026-06-27-on-device-local-llm-phase0-eval.md`
- Third-party notices: `THIRD_PARTY_LICENSES.md`
