# CLI, data, and inference review for 0.8.0

Candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`, compared with `v0.7.3`.

This is an independent source/contract review. Root owns all builds, Swift tests, GUI interaction, audio, and end-to-end execution. No application state, preferences, databases, or GitHub objects were changed by this reviewer. This bounded review is complete; it is not exhaustive release certification.

## Isolation findings

- `AppPaths.swift` supports `MACPARAKEET_DEBUG_APP_STATE_DIR` only under `#if DEBUG`. It redirects application data, meeting artifacts, local logs, and FluidAudio model caches. Release builds ignore it.
- That override does **not** change the preference domain or credential stores. `AppPaths.preferencesSuiteName` is fixed to `com.macparakeet.MacParakeet`; CLI `config` writes that suite through `macParakeetAppDefaults()`. Do not run `config set` or model selection commands assuming the state directory isolates preferences.
- GUI settings predominantly use `.standard`. A copied DEBUG application bundle with a unique bundle identifier plus the state override can isolate those settings and data. No app/Core/ViewModel call site of `AppPaths.appDefaults` or `sharedAppDefaults` was found; those helpers are called by CLI commands. The GUI's retained entitlement store uses the bundle identifier as its Keychain service (`AppEnvironment.swift:210`). This is not complete whole-process isolation.
- `LLMConfigStore` defaults to Keychain service `com.macparakeet.llm`, independent of bundle identifier. Avoid saving/deleting provider keys from a QA bundle; use an inline CLI provider pointed at a synthetic loopback server for transport verification.
- CLI `--database` directs repository access to a throwaway SQLite file, but `makeDatabaseManager` still calls `AppPaths.ensureDirectories()`. Use the DEBUG state override as well for complete data-directory isolation.
- Set `MACPARAKEET_TELEMETRY=0` and `DO_NOT_TRACK=1` per QA process. Do not persistently change the user's telemetry setting.
- `LocalCLIExecutor.defaultWorkingDirectory()` resolves Foundation Application Support directly, bypassing the DEBUG state-root override (`LocalCLIExecutor.swift:336`). Inline local-shell provider probes can therefore create `MacParakeet/LocalCLI` outside that override. Prefer the loopback HTTP provider for this QA run.
- `CFFIXED_USER_HOME` has no repository references or product support contract. Its Foundation behavior must be established with root's small resolver probe, including named UserDefaults suites and `FileManager` directory URLs, before treating it as a Release-build isolation mechanism. It does not establish Keychain isolation.

## Findings to address

### P3: document the effective receipt on `llm summarize --json`

Location: `spec/contracts/cli-json-v1.md:103-108`.

The contract says other LLM commands omit `effectiveSettings`, but `LLMSummarizeCommand.swift:42` calls `summarizeDetailed`, which delegates to `generatePromptResultDetailed` (`LLMService.swift:152`, `475`). That method resolves the baseline even with no requested overrides (`LLMService.swift:505`). Adapters attach that receipt. For an OpenAI-compatible endpoint the baseline includes temperature 0.7, so `llm summarize --json` can emit `effectiveSettings` without loading any stored prompt.

Impact: automation implementing the written contract has an incorrect omission guarantee. This is an additive field, not a breaking API change, and does not justify changing runtime behavior. Narrow fix: name `llm summarize --json` alongside `prompts run --json`, clarify that summarize reports its baseline settings, and preserve the omission statement specifically for chat/transform commands. Confirm once with a synthetic loopback response. Confidence: 100 from the complete source call chain.

### P3: update the integration guide's CLI version

Location: `integrations/README.md:8`.

The development guide says CLI 3.2. The executable's `CLI.cliVersion` and latest released changelog section both say 3.3.0. Narrow fix: update the development-contract label to 3.3, preserving the warning to inspect the installed binary. Confidence: 100.

No P0, P1, or P2 release-blocking CLI/data contract regression was established in this bounded review.

## Source-supported results

These are source review results, not executed runtime passes.

| Area | Observation | Regression evidence available for root |
| --- | --- | --- |
| CLI compatibility | Existing commands, defaults, JSON keys and exit-code meanings are retained in the changed CLI files. New DAPT and audio-track options are additive. CLI 3.3.0 matches the changelog release header. | `CLIVersionTests`, `SpecCommandTests`, `LLMJSONOutputTests`, `TranscribeCommandTests`, `ExportCommandTests` |
| Migrations | New v0.29/v0.30/v0.31 migrations add nullable columns for selected audio stream, capture report and prompt settings/receipts. Earlier migration edits in this diff are formatting. The file-backed migration lock, foreign keys and five-second busy timeout remain. | `DatabaseManagerTests`, including `testPromptInferenceSettingsMigrationPreservesExistingRows` and missing-marker tolerance |
| Legacy records | New transcription fields decode optionally; malformed optional capture metadata falls back to unknown. Existing prompt/result settings are nil after migration. Ordinary record-opening commands can migrate/reconcile seeds; `health` uses a separate read-only opener. | `DatabaseManagerTests`, `ModelLifecycleCommandTests`, prompt repository tests |
| Prompt settings | Stored settings validate numeric ranges, normalize default/disabled thinking values, reject non-default settings on Transform prompts, and remain attached when CLI toggles visibility or auto-run. Effective receipts use provider-filtered options. | `PromptInferenceSettingsTests`, `PromptRepositoryTests`, `PromptResultRepositoryTests`, `LLMServiceTests`, `LLMHTTPAdapterTests` |
| Results and regeneration | CLI JSON, plain and stream prompt runs pass the saved prompt's settings. Successful runs retain the effective receipt. Stream runs require terminal metadata before persistence. Repository replacement saves and deletes in one transaction. | `PromptsCommandTests`, `PromptResultRepositoryTests`, `LLMHTTPAdapterTests.testOllamaStreamFailurePreservesPreviouslySavedResult`, root's GUI regeneration coverage |
| Provider boundaries | OpenAI/Ollama/Anthropic detailed streaming retains terminal metadata. Ollama error-only frames fail both streaming paths; lenient content-bearing EOF is deliberately retained for compatible servers. Sampling fields are filtered according to the model policy. | Golden request, cancellation, usage-overflow, stream-error, strict/lenient EOF tests in `LLMHTTPAdapterTests` and `LLMClientTests` |
| Provider configuration | Keychain operations complete before saved provider metadata changes. Local CLI configuration prepares encoding before selecting the provider. No stored API key is serialized into preferences. | `LLMConfigStoreTests`, `LLMSettingsViewModelTests`, `LocalCLIExecutorTests` |
| OpenCode | Session header is restricted to the named HTTPS origin and three allowlisted endpoints; unapproved redirects are rejected before forwarding the prompt body. Other provider endpoints do not receive the session header. | OpenCode header/redirect adapter tests; no live provider request performed here |
| Bulk vocabulary deletion | Explicit UUID sets delete in chunks of 500 within one asynchronous GRDB transaction. Empty sets are harmless; missing IDs are ignored; a later chunk's error rolls back earlier chunks. Existing CLI individual deletion remains. | `CustomWordRepositoryTests`, `CustomWordsViewModelTests`; root owns native UI checks |
| Rename/status writes | Meeting rename returns the committed row from the write transaction; conditional status transitions avoid publishing a stale state. | `TranscriptionRepositoryTests`, meeting workspace tests |
| DAPT and exports | Shared renderer emits an XML original transcript with aligned timing/speaker agents only when justified by word metadata. Edited text is untimed. XML controls are filtered and text/attributes escaped. Compound `.dapt.xml` extension reaches CLI and auto-save. TXT/Markdown paragraph behavior is deliberately documented. | `DAPTExportTests`, `AutoSaveServiceTests`, `TranscriptResultActionsTests`, CLI export/transcribe tests |
| Telemetry | CLI event parameters retain command/outcome categories without argument content. Network event encoding excludes free-form error details. Queue consent generations invalidate retries and waiting batches after opt-out. | `CLITelemetryTests`, `TelemetryServiceTests`, `TelemetryErrorClassifierTests`, `ObservabilityTests` |

## Safe commands for root's end-to-end run

The commands below are recommendations, **not commands executed by this reviewer**. Set `qa_cli_binary` to the candidate DEBUG CLI already built by root. Use a new owned directory; do not substitute a personal library database. Keep the state override on each invocation, since every new CLI process resolves its own paths.

```bash
qa_cli_binary='/absolute/path/to/candidate/debug/macparakeet-cli'
qa_state_dir='/tmp/macparakeet-080-qa/owned-cli-state'
qa_database="$qa_state_dir/macparakeet.db"
qa_cli() {
  env MACPARAKEET_DEBUG_APP_STATE_DIR="$qa_state_dir" \
    MACPARAKEET_TELEMETRY=0 DO_NOT_TRACK=1 \
    "$qa_cli_binary" "$@"
}

qa_cli --version
qa_cli spec --json
qa_cli health --json
qa_cli prompts list --database "$qa_database" --json
qa_cli vocab words add QAWidget --database "$qa_database"
qa_cli vocab words list --database "$qa_database" --json
qa_cli prompts add --name 'QA receipt' --content 'Return a short Markdown summary.' \
  --database "$qa_database"
```

For the first `health` invocation, leave `qa_state_dir` absent and verify it remains absent. Expected report is missing directories/database with exit 0: component health is not a single readiness verdict. `health` does not accept `--database`. It still reads the shared engine preferences, which is acceptable for this read-only check; it must not be called with repair flags for isolation verification.

Once root has created an owned synthetic WAV, exercise persistence with explicit recognition choices, then export that saved transcription. Use a known locally available model and preserve its exact identity in the evidence; `v3` below is an example of an explicit supported choice.

```bash
qa_cli transcribe "$qa_fixture_wav" --engine parakeet --parakeet-model v3 \
  --mode raw --speaker-detection off --format json --database "$qa_database"
qa_cli export "$qa_transcription_id" --format dapt --stdout --database "$qa_database"
qa_cli export "$qa_transcription_id" --format markdown \
  --output "$qa_state_dir/export.md" --database "$qa_database"
qa_cli export "$qa_transcription_id" --format srt \
  --output "$qa_state_dir/export.srt" --database "$qa_database"
```

For a synthetic two-track file, add `--audio-track 2` and require `audioTrackOrdinal == 1` in saved/exported JSON plus recognizer output from the second track. `--audio-track 0` must fail validation with exit 2. A nonexistent positive ordinal must fail without creating a successful transcript. Do not use downloaded URLs to test the local-only audio-track branch.

The existing `scripts/dev/release_demo_smoke.sh --cli ... --output-dir ...` covers version, health, synthesized speech, persistence and Markdown export. It does not fully pin recognition/text processing defaults and its health step reads the normal paths unless the parent environment supplies the DEBUG override. It is a useful supplemental smoke, not a replacement for the explicit matrix above.

## Synthetic provider verification

HTTP response injection is possible without code changes, app preferences, Keychain or paid provider requests: run an owned loopback HTTP server and pass an inline OpenAI-compatible endpoint. `LLMInlineOptions` accepts this combination with no API key and no insecure-HTTP override.

```bash
qa_cli llm summarize "$qa_text_fixture" --provider openaiCompatible \
  --base-url http://127.0.0.1:18780/v1 --model qa-model --json
qa_cli prompts run 'QA receipt' --transcription "$qa_transcription_id" \
  --provider openaiCompatible --base-url http://127.0.0.1:18780/v1 \
  --model qa-model --database "$qa_database" --json
qa_cli prompts run 'QA receipt' --transcription "$qa_transcription_id" \
  --provider openaiCompatible --base-url http://127.0.0.1:18780/v1 \
  --model qa-model --database "$qa_database" --stream
qa_cli prompts set 'QA receipt' --hidden --database "$qa_database" --json
qa_cli prompts show 'QA receipt' --database "$qa_database" --json
```

Root should configure the owned prompt's nondefault settings through the isolated GUI, then compare the HTTP request, result JSON and persisted receipt. `prompts add/set` intentionally do not provide settings flags. The hide/show round trip must preserve settings.

The loopback server should support `POST /v1/chat/completions`. A nonstream response needs `model` and `choices[0].message.content`; optional usage has `prompt_tokens` and `completion_tokens`. A stream can send `data: {"model":"qa-model","choices":[{"delta":{"content":"QA result"}}]}`, a finish/usage frame and `data: [DONE]`, separated by blank lines. Log only synthetic request content in the owned evidence directory.

Recommended response matrix:

1. Successful nonstream and stream Markdown; compare output and exact effective receipt.
2. HTTP 401 and 429; require nonzero exit plus JSON `errorType` `auth`/`rate_limit`, and no saved successful result.
3. Invalid JSON or empty stream; require a visible failure without replacing an existing result.
4. Content followed by a provider error; preserve the previous saved result despite visible partial output.
5. Delayed stream canceled by the user; require cancellation, no successful receipt and no replacement.
6. Native OpenAI (`--provider openai` with a throwaway dummy key to the loopback endpoint) requires `[DONE]`; compatible endpoints deliberately accept clean content-bearing EOF. Keep these expectations distinct.

Existing unit tests inject `URLProtocol` into `LLMClient`; a loopback server supplies stronger executable-boundary evidence without real external inference. Live provider availability, authentication, quality and current model compatibility remain untested by a synthetic server.

## Remaining verification limits

- No CLI binary, migration, transcription, provider request, export or GUI behavior was executed by this reviewer. Root must attach actual commands, exact candidate head, exit status and artifacts to the consolidated QA log.
- The v0.31 migration test reconstructs an older schema by dropping new columns and the migration marker. This is useful but is not a migration of a real v0.7.3-produced database. An owned synthetic legacy database would strengthen upgrade evidence without reading private content.
- The DAPT contract requires representative timed-speaker, timed-no-speaker and untimed documents checked against W3C DAPT XSD and BBC TTML Validator at release/review. Unit parsing alone does not establish external conformance.
- Synthetic models can validate request construction, streaming, receipts and errors; they cannot establish inference quality or real provider compatibility.
- The configured database path does not rewrite absolute meeting artifact paths already stored in rows. Use newly created fixtures only for materialization/deletion verification.
- No personal memory files were modified. Prior memory only guided telemetry/privacy and verification boundaries; current conclusions above were checked against candidate source.
