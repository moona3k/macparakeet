# Ask workspace verification and open qualification issues

Status: **Implemented candidate; not runtime-qualified.** Recorded 2026-09-25.
The feature implementation is commit `991d1ed79`; the CLI catalog expectation
is corrected in `2b74a9e73`. Later review commits must retain these boundaries.

## Open blockers

1. During native QA, the user reported that the app froze their keyboard and
   computer, and quit the app. Local UI automation, model requests, and the
   synthetic server were stopped. The cause has not been established. The
   observed successful UI actions below do not qualify system-wide input
   stability. Do not reopen the app or resume intensive local QA without
   coordinating a controlled follow-up with the user.
2. Real local-model Ask investigation is not qualified. LM Studio exposed
   `qwen/qwen3-4b-2507` and returned HTTP 200 with a valid JSON tool decision to
   a small direct synthetic request. Through Ask, a three-meeting decision
   question failed after 31.56 seconds before activity/text, and a simpler
   question failed after 7.40 seconds after “Checking selected recordings.”
   Both stored a failed assistant message with no citations and a sanitized
   error. Availability and basic JSON output work; the cause of the Ask
   failures remains unresolved. No real-model answer-quality claim is made.

These issues block a merge-ready/runtime-qualified verdict even if CI passes.
No stable release, notarized distribution, or update publication was performed.

## Automated evidence

- The real pinned Pi helper passes 10 JavaScript behavior tests. Swift tests
  exercise the actual helper and official bundled Node runtime with a scripted
  model transport, including tool continuation and text before terminal output.
- After review fixes, the focused service/view-model/Pi run passed 34 tests,
  including delayed draft writes, external draft conflicts/deletion, history
  isolation, evidence freshness, and model/tool boundaries.
- The sole full local `swift test --jobs 6` run executed 7,587 XCTest cases,
  with 28 skips and one failure: the curated CLI root-command expectation
  omitted `ask`. All 30 Swift Testing cases also passed. The expectation was
  corrected and the affected `SpecCommandTests|AskCommandTests` run passed
  all 21 tests. The full local suite was not repeated, following AGENTS.md.
- Native Debug builds succeeded through `scripts/dev/run_app.sh`, including
  the final UI fixes. Bundle-local Pi/Node executed a complete synthetic run.
- Shell syntax, Homebrew scaffold Ruby syntax, subsystem README references,
  local documentation links, and `git diff --check` passed.
- Dev-launcher behavior tests and AppKit fixtures passed, including registered
  applications whose executable was unlinked. Unrelated app instances were
  preserved by the build launcher.
- Independent code reviews found and drove fixes for scoped citation handling,
  provider authority/consent, mutable summaries, source search fairness, draft
  races, Library navigation, evidence state, and CLI streaming.
- Local Greptile review was attempted against committed changes but could not
  authenticate: the installed CLI is signed out. This is not a review pass.

## Native observations

All recordings and questions were synthetic, in an isolated database and
separate app preference domain. No private meeting content was used.

Observed in the actual native app using macOS Accessibility and window captures:

- Ask sidebar destination, new conversation, source curator, searchable meeting
  titles, selection retained across filters, bulk selection, and Apply.
- Explicit provider consent, progress, text streaming, saved answer with three
  citation controls, passage inspection, and Open in Library selecting the
  matching synthetic transcript.
- Answer persistence after app restart; Stop settling to an explicitly
  incomplete/stopped answer.
- Narrow-window evidence sheet and wide-window evidence inspector. Light and
  dark appearances were inspected; final light-mode screenshots are below.
- Visual fixes removed a duplicated menu indicator, constrained long titles so
  Sources/New stay available, widened the source-type popup, and removed the
  empty-state suggestions once the first question starts.

The native tests used a **scripted loopback model fixture**. They establish
application flow and transport behavior, not model reasoning quality. The
subsequent user-reported freeze remains an open blocker.

![Native Ask workspace with synthetic answer](assets/ask-workspace-light.png)

![Native source curator with three synthetic meetings selected](assets/source-curator-light.png)

## Standalone CLI package

A generated arm64 CLI archive was extracted and run outside the checkout. It
included CLI 4.7.0, official Node v24.13.1, the bundled helper, and dependency
notices. With a copied synthetic database, `new`, `select`, `send`, `evidence`,
`draft`, `show`, and `list` worked across separate processes. Three source
citations resolved. Draft and history survived a source-section change.

In a timed stream, activity arrived at 0.864 seconds, text at 0.973 seconds,
and the final conversation at 4.416 seconds. The process was still running
when the early events arrived. Omitting remote consent rejected the same
OpenAI-compatible loopback endpoint and left the conversation revision intact.
This used the debug CLI build and scripted provider, not a notarized release.

## Remaining verification

- Diagnose the system-wide freeze in a coordinated, isolated native session.
- Capture a failing synthetic model exchange safely and distinguish transport,
  decision validation, and tool-continuation errors; then qualify the three
  research jobs with a real capable model.
- Complete the PR gate and hosted CI, recording their exact result separately.
- Qualify signed distribution/upgrade behavior before any release work.
