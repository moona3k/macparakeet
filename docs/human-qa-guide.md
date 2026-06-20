# Human QA Guide

> Status: **ACTIVE** — how to manually verify a change before trusting it in a build.

## What "QA" means here

QA (quality assurance) is **you, as a user, confirming a change actually does what it
should** — by running the real app, not by reading the code. The automated suite
(`swift test`) already proves the logic in isolation; QA covers what tests can't:

- real UX and visual correctness (does the control look and behave right?)
- real integrations (an actual LLM provider, a real microphone, real ScreenCaptureKit
  system audio, real macOS permissions)
- the "feel" — latency, surprises, and edge cases a fixture won't hit

QA is **not** a re-run of the unit tests. Assume the logic works; you are checking that
it works **for a human, on a real Mac, end to end.**

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

Builds, signs, and launches the dev build. It uses a **separate bundle id
(`com.macparakeet.dev`)** with its **own settings and database**, so it never touches
your real MacParakeet install or history.

To QA a specific PR branch, run that script from inside **that branch's checkout or
worktree** — SwiftPM pins build paths per worktree, so build from where the branch
actually lives.

**Or** QA the Sparkle release candidate DMG — closest to what users receive. Use this
for release-gating checks (signing, notarization, first-run onboarding, auto-update).

## First-run gotchas for the dev build

- The dev build is a **separate app** to macOS, so it requests its **own permissions** —
  Microphone, Accessibility, and (for system-audio meeting modes) Screen & System
  Audio Recording. Grant them when prompted.
- If permissions act stuck after a re-sign, reset them:
  `tccutil reset All com.macparakeet.dev`.
- Its history and settings are independent — a clean slate is expected, not a bug.

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
