# PR & Review Workflow

> Status: **ACTIVE**

How a change earns its way onto `main`. The goal is not "a bot said LGTM" —
it is **convergence**: independent reviewers, automated and agentic, stop
finding things that matter. This doc is the loop that gets there, and the
judgment that keeps it from becoming theater.

Companion docs: `docs/commit-guidelines.md` (the commit/PR *message* format)
and `spec/10-ai-coding-method.md` (spec precedence + the context zone). This
doc is the *process* that wraps them.

## The spirit

> A change is merge-ready when an honest adversary — given the diff, the
> tests, and time — would stop finding things worth changing. Reviews
> converging to trivial style nits is the signal, not a green checkmark.

Two failure modes this guards against, equally:

- **Under-review** — shipping a plausible-but-wrong change because the happy
  path passed.
- **Over-process** — gold-plating a one-line fix, or churning code to satisfy
  a reviewer that is bikeshedding (or simply wrong). *Clean, minimal code is
  the deliverable; the review loop serves that, not the reverse.*

## Scale to the change

Match the ceremony to the risk. Most changes are not "substantial."

| Tier | Examples | Treatment |
|------|----------|-----------|
| **Trivial** | Typos, doc edits, copy tweaks, a single obvious line | Commit direct to `main`. No PR, no agents. |
| **Small** | A contained bug fix with a test, a self-evident refactor | Branch + PR optional; focused verification. A fresh-eye pass is useful when the failure mode is subtle. |
| **Substantial** | New feature, new abstraction, auth/payments/data/migrations, public surface (CLI, telemetry, API), >~50 changed lines, anything user-visible | Full loop below. |

When unsure, choose the lightest tier that still protects correctness and user
trust.

## The full loop (substantial changes)

1. **Branch first.** Create the branch *before* writing code, base it on
   `origin/main` (not local `main`, which often lags; see `AGENTS.md`
   Worktrees). Open a real PR so "merge" actually merges. **Do not** push to
   `main` and then retrofit a review gate
   — that forces force-pushes, throwaway base branches, and close-instead-of-
   merge. (We learned this the awkward way.)
2. **Define the context zone** before coding: in-scope behavior, must-not-
   change invariants, out-of-scope. (`spec/10-ai-coding-method.md`.)
3. **Open the PR with an audience-friendly description** (see below). CI runs;
   the GitHub review bots (**Greptile**, **Gemini Code Assist**, **Copilot**)
   review on push. They re-review on new commits; if one goes quiet, re-trigger
   it (`/gemini review`, or re-request the reviewer) — and watch for it landing
   rather than assuming silence means approval.
4. **Run fresh-eye agent review in parallel** on the exact diff — independent
   of the bots. Pick lenses by what the diff touches (see "Agent review").
5. **Drive to LGTM** — address every *valid* finding (with judgment, next
   section), re-push, let reviewers re-review. Greptile's confidence score is
   the headline bar (target **5/5**); treat all the bots' inline comments —
   Greptile, Gemini, Copilot — as input, not orders.
6. **Converge.** Loop until findings are trivial/duplicative (the readiness
   signal). Reviewers contradicting each other or themselves = you're done
   deciding, not them.
7. **Merge** into `main` with a clean message. Delete the branch.

## Addressing review comments: judgment, not obedience

Every comment gets one of three outcomes. The reviewer being a model (or a
human) does not change that you owe each comment a *decision*.

- **Valid → fix it.** Real bug, real gap, real improvement. Implement, add a
  test if it was a logic bug, reply linking the commit.
- **Wrong → say so, with evidence.** Reviewers hallucinate. (Real example: a
  bot insisted `LocalizedStringKey` "won't compile" as an `.animation(value:)`
  argument — it does; the build proved it. We adopted its *suggested* fix
  anyway because keying on the enum was genuinely better, and said exactly
  that.) Never silently comply with a false premise.
- **Lateral / style preference → weigh it, then decide and own it.** When two
  valid patterns trade off, pick the more robust one and explain. (Real
  example: a bot proposed replacing a foolproof centralized invariant with a
  must-remember-to-call helper; we kept the robustness and routed *every* call
  site so the encapsulation was real, not a regression.) Do not churn toward a
  *worse* design to make a comment go away.

Replying "addressed in `<sha>`" or "declining because X" **is** addressing the
comment. Silence is not.

## Agent review (fresh eyes)

Spawn independent review agents on the diff range (`git diff <base>..<head>`),
in parallel, each with a distinct lens. Choose by what the diff touches:

- **Always:** correctness (logic, edge cases, state lifecycle), maintainability.
- **Conditional:** privacy/security (telemetry, auth, user input, public
  endpoints), performance (queries, loops, I/O), data integrity (migrations),
  API contract (public surfaces), the relevant `ce-*` persona.

Give each agent the diff, the intent, and the *specific* invariants to attack
(e.g. "prove the raw URL cannot reach telemetry"). Their job is to *break* the
change, not bless it. Convergence between independent agents + the PR bots is
the strongest readiness signal we have.

## What makes a good PR description

Reader-friendly first. The reviewer (and the future archaeologist) should
understand the change without reading the diff. Mirror the rich-commit
sections (`docs/commit-guidelines.md`):

- **What changed** — in plain language, grouped by concern, not a file list.
- **Why / root intent** — the problem, and why *this* shape solves it.
- **Risk + scope** — what's deliberately out of scope; what to watch.
- **Tests** — what's covered, especially the failure modes.
- **Privacy/ADR notes** — when relevant (telemetry, data, locked decisions).

Write it for a smart reader who wasn't in the room.

## Merge-ready checklist

- [ ] Branch off `origin/main`; real PR open
- [ ] `swift test` green; build clean (Swift 6 language mode)
- [ ] Tests cover the new behavior *and* its failure modes
- [ ] Automated review at LGTM (Greptile target 5/5); every inline comment
      resolved or explicitly declined with reasoning
- [ ] Fresh-eye agent pass(es) done; findings converged to trivial
- [ ] No overengineering — simplest design that holds; dead code deleted
- [ ] Docs updated if behavior changed: governing spec/ADR, README or CLI
      changelog when public-facing, and AGENTS.md/CLAUDE.md only when agent
      workflow guidance changes
- [ ] PR description is audience-friendly and complete
- [ ] Merged into `main`; branch deleted

## Anti-patterns

- **Ship-then-review.** Pushing to `main` first and retrofitting a review PR.
  Branch first.
- **Bot obedience.** Implementing every suggestion to chase a score, including
  wrong or robustness-reducing ones.
- **Bikeshedding past convergence.** Once findings are trivial, stop — re-
  running reviewers hoping for a cleaner verdict is wasted motion.
- **Ceremony on trivia.** A multi-agent gauntlet for a typo fix.
- **Vague PRs.** "Various fixes." The diff is not the description.
