# UI, view-model and tooling follow-up review

Baseline: `79cf1ca92`. The machine-readable [code inventory](code-inventory.json)
contains 1,274 tracked code files across app, Core, CLI, tests, helper,
integrations, scripts and benchmarks. All 658 Swift files under Sources were
parsed with Swift 6 syntax mode without dependency resolution. This provides
breadth and syntax evidence, not line-by-line behavioral review.

## Parent review coverage

| Area | Work performed | Limits |
|---|---|---|
| App views and 52 view models | Indexed asynchronous work, destructive paths, error handling and feature entry points. Traced Library loading/export/bulk operations, notes saving, whole/timed transcript editing, find/replace, result export, vocabulary backup, Discover cancellation and Settings cleanup. | Most visual components were inventoried and syntax-checked, not exercised in a native window. |
| Package/build architecture | Read target/dependency/gate definitions, normal versus MLX/Whisper configurations, CLI packaging and CI lanes. | No fresh dependency graph build locally; hosted CI validates the code PR. |
| CI and scripts | Reviewed workflow trigger/cache/test stages and local validation/release scripts. Ran `python3 -m unittest discover -s scripts/ci -p 'test_*.py'`: 46 tests passed. | No release, signing, notarization or production deployment attempted. Benchmark scripts are inventoried, not new acoustic evaluations. |
| Objective-C/C shims | Inspected crash-handler bounded buffers, first-report persistence, signal guard, no-follow opens and best-effort backtrace boundary. | No fatal signal induced; the documented non-signal-safe backtrace remains an acknowledged best-effort boundary. |
| Optional MLX target | Checked build gating and target isolation. | Runtime/model reliability and memory footprint not evaluated. |
| CLI/public interfaces | Rechecked corrected-output and capture/edit scope findings; installed catalog/help probe and regression-fix review. | Source-neutral editing/recovery remain separate feature work. |

## Findings and rejected hypotheses

- **Confirmed and fixed in the documentation branch:** TextProcessing README
  still called ADR-032 routing unimplemented and described specialist recipes.
  Current cleanup/analysis routes and cleanup-only Apple Intelligence are
  implemented; specialists are not shipped.
- **Confirmed runtime fix, separate PR:** history JSON bypasses effective
  corrections. The fix reuses the existing read service and preserves raw
  evidence and output shape; new tests use synthetic databases.
- **Rejected:** prompt-result export appeared to write Markdown bytes for every
  export extension. Actual menu callers permit only Markdown/text; PDF/DOCX
  transcript export dispatches to the appropriate renderer. No reachable bug
  established.
- **Rejected:** detached Library loads could republish stale search state.
  Publication checks task cancellation and load generation; export loading
  forwards cancellation to its detached fetch. No concrete regression found.
- **Rejected:** saved-note persistence could overwrite newer metadata.
  The repository writes only notes, and the view model uses the authoritative
  committed row or patches only notes after a fetch failure. Configuration and
  save tokens prevent old editors from publishing into a new selection.
- **Rejected:** hiding Discover leaves stale results able to reappear.
  Cancellation clears service/tasks and advances a generation checked before
  publication. This is stronger than merely hiding the sidebar item.
- **Follow-up requiring a deletion-policy design:** dictation deletion removes
  audio before database deletion, and Settings cleanup can continue after a
  database deletion error. A naive database-first reversal can instead orphan
  audio and weaken deletion privacy. The data review records the tradeoff;
  this is not folded into the transcript-output fix.

## Evidence boundary

The review maps the full first-party code tree and traces selected high-risk
paths across every major product layer. It does **not** claim every line was
read or that all bugs, native accessibility problems, hardware failures or
provider behaviors have been excluded. Dependencies, generated artifacts,
private diagnostics and historical archives were not treated as first-party
runtime code. Behavioral CI results belong to their exact PR head.
