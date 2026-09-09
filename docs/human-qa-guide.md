# Human QA Guide

> Status: **ACTIVE** — how to manually verify a change before trusting it in a build.

## What "QA" means here

QA (quality assurance) is **you, as a user, confirming a change actually does what it
should** — by running the real app, not by reading the code. Automated tests
provide evidence for the paths and assertions they exercise; QA adds checks
that isolated tests cannot establish:

- real UX and visual correctness (does the control look and behave right?)
- real integrations (an actual LLM provider, a real microphone, real ScreenCaptureKit
  system audio, real macOS permissions)
- the "feel" — latency, surprises, and edge cases a fixture won't hit

QA checks whether the feature works **for a human, on a real Mac, end to end.**
A passing automated suite does not rule out integration or logic defects found
during that exercise.

## The workflow

Every feature PR carries a **"Human QA checklist"** in its description (preconditions,
happy path, guardrails, and screenshots to attach). The loop:

1. Get a testable build (below).
2. Open the PR and walk its **Human QA checklist** top to bottom.
3. Tick the boxes that pass; comment on anything that doesn't.
4. Capture the requested screenshots and drag them into the PR.
5. All green → the PR is human-verified.

Because PRs merge to `main` (the dev channel) before a tagged release, you can QA
**before merging** (pull the branch) or **after merging** (QA `main` as a batch before
the next release). Either is fine — the checklist is the same. This is the
"merge the stack now, QA the batch later" flow.

## Getting a testable build

**Dev app (recommended for most QA):**

```
scripts/dev/run_app.sh
```

Builds, signs, and launches the dev build. Its separate bundle identifier
(`com.macparakeet.dev`) separates standard GUI preferences and macOS permissions.
It also uses `~/Library/Application Support/MacParakeet-Dev` for its database,
artifacts, model caches, and logs, keeping stable app data untouched.

Destructive QA requires verified throwaway data. Set
`MACPARAKEET_DEBUG_APP_STATE_DIR` to an absolute temporary directory to replace
the default Dev state root for app data, artifacts, model caches, and logs. The
launcher forwards that override in both Debug and optimized Release configurations.
Verify the resolved path before testing deletion or recovery.

The data override does not isolate preferences or Keychain. CLI configuration
commands still use `com.macparakeet.MacParakeet` preferences, and GUI LLM credentials
use the shared `com.macparakeet.llm` Keychain service. Keep provider credential
changes out of a shared-account QA run; use a disposable macOS account when full
user-state isolation is needed. See the
[integration isolation rules](../integrations/README.md#safe-automation-and-isolation).

To QA a specific PR branch, run that script from inside **that branch's checkout or
worktree** — SwiftPM pins build paths per worktree, so build from where the branch
actually lives.

The script intentionally passes `-skipMacroValidation` to `xcodebuild` because
the canonical `SwiftStreamingMarkdown` renderer includes the approved
`EquatableMacros` plugin transitively. If a hand-written Xcode command fails
with `Macro “EquatableMacros” ... must be enabled before it can be used`, do
not install or substitute a renderer: rerun `scripts/dev/run_app.sh`, or keep
that flag in the equivalent Xcode invocation.

The script also requests ordinary quit for this worktree’s replaced dev executables **before** rebuilding
or re-signing the Dev bundle. Never reorder that shutdown after bundle wrapping:
modifying a signed executable while macOS is running it can terminate the app
later with `SIGKILL (Code Signature Invalid)`, often when the next menu or sheet
loads code from the changed page. Shutdown requests a normal macOS app quit,
including the existing meeting confirmation and pending-note save flow, and
waits up to ten seconds for exit. Cancelled quit, ongoing finalization, failed
process inspection, or a raw executable without a normal app-quit interface
abort the build before modifying the bundle. Quit the app normally and rerun
the script when ready; it never sends a termination signal or force-kills it.
Process matching uses actual executable paths, so checkout punctuation and
unrelated command-line arguments cannot select the wrong process.

**Or** QA the Sparkle release candidate DMG — closest to what users receive. Use this
for release-gating checks (signing, notarization, first-run onboarding, auto-update).

## First-run gotchas for the dev build

- The dev build is a **separate app** to macOS, so it requests its **own permissions** —
  Microphone, Accessibility, and (for system-audio meeting modes) Screen & System
  Audio Recording. Grant them when prompted.
- If permissions act stuck after a re-sign, inspect the affected permission in
  System Settings → Privacy & Security and confirm it belongs to the running dev app.
- GUI settings can start fresh while history remains shared. Confirm the resolved
  data paths before treating the dev build as a clean slate.

## Markdown regression checks

- Select text directly inside table headers and cells. The pinned compatibility
  fork uses the same native selectable text view as ordinary paragraphs on macOS.
  Table Copy and Download actions are always visible; verify VoiceOver announces
  “Copy table” and “Download table” and can activate both. The automated native
  selection regression passes, but the XCTest host does not expose the SwiftUI
  accessibility tree, so the VoiceOver check must run in the app.
- While a result, saved chat response, or live Ask response is streaming, leave
  its pane and return. Existing text must remain visible and later chunks must
  continue to render. Repeat after
  a completed result starts streaming again. Also switch quickly between saved
  results of different lengths; the selected result must not revert to stale text.
- In a rendered table, select text in a header and a body cell, then copy it.
  Selection must remain usable without a table-wide click action consuming it.
- Navigate the table actions with VoiceOver. Both **Copy table** and **Download
  table** must be named and reachable before clicking the table; downloading must
  open the save dialog and export normalized Markdown for that table. Cancel
  the dialog to confirm no file is written. If the destination becomes
  unwritable, the app must show **Export Failed** instead of silently closing.

## Writing a QA checklist (for PR authors / agents)

Put this in the PR description so the human can self-serve. Keep items concrete and
user-facing — name a **user action** and an **observable result**
("record a 30s meeting → the Library row shows a topic title, not a timestamp"),
never "the code path runs."

```
> Preconditions: <what must be set up first>

Happy path
- [ ] <the main thing the feature promises: user action + expected result>

Guardrails / edge cases
- [ ] <the "don't break / don't overwrite / degrade gracefully" cases>

Regression
- [ ] <nearby behavior that must still work>

CLI (if applicable)
- [ ] <exact command → expected output>

Screenshots to attach
- [ ] <the 1–2 visuals worth capturing>
```

## When something fails QA

Comment on the PR with: what you did, what you expected, what actually happened, and a
screenshot if it's visual. That is enough to reopen the loop — you do not need to
diagnose the code yourself.
