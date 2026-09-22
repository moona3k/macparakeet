# Follow-ups from the documentation audit

> Status: **PROPOSALS / REVIEW NOTES** — not accepted architecture, implemented
> fixes or automatic release gates. Source baseline: `c79d3f52` on 2026-09-07.
> These findings came from [the documentation alignment audit](../audits/2026-09-07-documentation-alignment.md),
> not new hardware, provider, model or production-service testing.

## 1. Resolve TXT stdout compatibility before the next CLI publication

**Observed:** `cli-v3.1.0` routes `export --stdout --format txt` through
`ExportService.formatForClipboard`, which returns preferred transcript text.
Current [ExportCommand](../../Sources/CLI/Commands/ExportCommand.swift) calls
`formatPlainText(projection:)`, adding the file export's metadata/timestamps/
speaker presentation. [The CLI changelog](../../Sources/CLI/CHANGELOG.md)
acknowledges this under Unreleased, while `CLI.cliVersion` in `MacParakeetCLI.swift` is `3.3.0`.
Its compatibility policy treats changed existing defaults as a major change.

**Why it matters:** a script consuming text from the same invocation receives
additional content. Documenting it does not settle the compatibility decision.

**Suggested next step:** decide whether to preserve the previous stdout default
and expose rich text explicitly, or publish the change with a deliberate major
version/migration story. Compare a synthetic transcript with and without timings
against the published CLI behavior. JSON transcript fields already provide an
alternative for consumers, but do not make the changed default compatible.
This audit does not change CLI behavior or select a release version.

**Resolution (PR #982, 2026-09-07):** the change shipped as a deliberate major
bump. `CLI.cliVersion` is `4.0.0`, the [CLI changelog](../../Sources/CLI/CHANGELOG.md)
records it under a `Breaking` heading, and
[cli-json-v1.md](../../spec/contracts/cli-json-v1.md) documents the JSON
fallback for callers that need bare stored text. JSON schema v1 is unchanged.

## 2. Reconsider automatic legacy-license validation in free builds

**Observed:** [AppEnvironmentConfigurer](../../Sources/MacParakeet/App/AppEnvironmentConfigurer.swift)
invokes `refreshValidationIfNeeded`; [EntitlementsService](../../Sources/MacParakeetCore/Licensing/EntitlementsService.swift)
can contact LemonSqueezy for a retained key/instance once cached validation is at
least a day old. CLI transcription can also request it with
`--enforce-entitlements`. The free build always returns unlocked. No Keychain
contents were inspected; this is a conditional code path, not a claim that the
current user's app makes the request.

**Suggested next step:** decide whether free builds should skip automatic
validation while retaining explicit activation and future-option plumbing.
Verify the chosen policy with mocked entitlement storage/API tests. Do not
remove licensing code or user credentials as cleanup. The docs now describe
the actual external-I/O boundary.

## 3. Use artifact hashes for release identity

**Observed:** [distribution guidance](../distribution.md) uses file-size equality
in multiple transfer/identity checks. Equal sizes cannot establish identical
signed bytes. That document is being edited by the parallel release work and
was deliberately not changed here.

**Suggested next step:** the release owner should pair app/CLI version and build
identity with SHA-256 of the accepted DMG, upload and downloaded artifact. Keep
notarization/stapling and runtime QA as separate evidence; none is replaced by
hash equality. This is a verification improvement, not evidence that a current
artifact was corrupted or mismatched.

## 4. Measure the pinned diarizer and supporting echo heuristic

**Observed:** [ADR-010](../../spec/adr/010-speaker-diarization.md) now pins
FluidAudio 0.15.6 and a high-accuracy preset. The cited older DER/throughput tables
predate clustering fixes; model download size is not process peak memory.
Separately, [MeetingTranscriptFinalizer](../../Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift)
still invokes `MeetingTranscriptSourceReconciler` after source transcription.
That heuristic removes sufficiently long, similar simultaneous speech; a
cleaned microphone artifact does not disable it.

**Suggested next step:** use a consented/synthetic corpus to compare the current
pin and presets, including short turns, speaker-count bounds, overlap and
system-only tracks. Separately compare raw/cleaned mic paths with and without
the reconciler on both acoustic echo and intentional repeated/choral speech.
Record accuracy, throughput and peak memory on the same build/machine. No new
regression or false-positive rate was measured here, so retain existing filters
until evidence justifies a change.

## 5. Add small mechanical guards against documentation drift

**Observed:** this pass found stale CLI/plan versions, dependency versions,
segmenter versions, a missing active table description and contradictory
copies of APIs. Existing CLI catalog tests do not validate all documentation
recipes or automatically enumerate every registered root command. The
architecture guide now links to owners instead of copying schemas/protocols.

**Suggested next step:** start with a cheap check for canonical local links and
anchors, feature flags, CLI version, migration identifiers and package
requirements. Add parse-only checks for selected integration recipes without
executing commands. Generate a compact schema/migration inventory from an
isolated database if needed; never introspect the user's database for docs CI.
Keep prose about guarantees and decisions reviewed by humans/agents rather
than trying to generate it from implementation.

When amendment-heavy ADRs next change, put a short current-decision summary near
the top. Preserve the older reasoning and name what supersedes it. Avoid adding
a second large hand-maintained feature catalog or more startup instructions.

## 6. Preserve the distinction between a saved edit and derived-artifact refresh

**Observed:** current speaker correction and notes paths persist canonical state
and refresh derived meeting files. Notes last-writer-wins behavior is explicit;
per-meeting GUI refresh ordering does not supply cross-process revision conflict
resolution. The [speaker editing plan](../../plans/active/2026-09-05-speaker-attribution-editing.md)
already leaves broader artifact-retry UX, remove-split UI and replay work open.

**Suggested next step:** finish the existing artifact-staleness/retry UX only
if observed failures justify it. If concurrent GUI/agent note editing becomes a
common workflow, add a deliberate conflict/recovery design and deterministic
interleaving tests. Do not silently claim shared-editor safety or start a
collaboration framework from this audit.

## Verification limits worth retaining

- The STT lifecycle watchdog reports an unhealthy runtime; it does not terminate
  inference that ignores cancellation. Diagnose actual hangs before adding
  speculative retries or a new global timeout.
- Import has no proven configurable four-hour cap. Decide and test any desired
  shared app/CLI duration limit explicitly rather than documenting one.
- Release-demo smoke records health and then transcribes; it is not a complete
  no-download/readiness preflight or a fully isolated GUI sandbox. Add explicit
  readiness checks only if that stronger smoke contract is wanted.
- Public in-process MLX, activity detection and app-aware formatter profiles
  remain gated. This audit does not supply their outstanding quality or runtime
  evidence, nor the parallel release's hardware/Sparkle upgrade checks.
