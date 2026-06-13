# Plan: Wire the cross-repo telemetry allowlist guard into CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update this plan's row in
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Drift check (run first)**:
> `git diff --stat 3f9361005..HEAD -- Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift .github/workflows/ci.yml`
> If either changed since `3f9361005`, compare the "Current state" excerpts
> below against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2 (closes a recurring silent-data-loss class; not a live bug today)
- **Effort**: S
- **Risk**: LOW (adds a new CI step + a new script; touches no product code)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `3f9361005`, 2026-06-12
- **Re-verified**: 2026-06-13 at HEAD `eb123cc35` — source branch `chore/improve-audit-fixes` + script present; sibling `../macparakeet-website` checkout present; repos **in sync** (97 Swift `TelemetryEventName` cases, 0 missing from `ALLOWED_EVENTS`). Drift baseline unchanged (`3f9361005..HEAD` touches neither in-scope file). Executor-ready.

## Why this matters

Every `TelemetryEventName` case the app can emit must also appear in
`ALLOWED_EVENTS` in the **separate** `macparakeet-website` repo
(`functions/api/telemetry.ts`). The Cloudflare Worker rejects an **entire
telemetry batch** if it contains any event not on the allowlist — so a single
missing entry silently destroys *all* co-batched events from every affected
user until someone notices and redeploys the website. This exact failure has
occurred **three times** (the third, AUDIT-073, was a live data-loss window
from 2026-05-23 to 2026-06-09 for `snippet_edited`). It is invisible until
someone manually diffs the two repos.

The two repos are currently in sync (97 Swift events, all allowlisted —
verified 2026-06-12), so this is not a bug fix. It is a **guard that makes the
4th occurrence impossible**: a CI step that diffs the Swift enum against the
website allowlist and fails the build when the app would emit an
un-allowlisted event. A ready-made script for this already exists on an
unmerged branch (`chore/improve-audit-fixes`); this plan recovers it to
`main`, applies one hardening fix, and wires it into CI.

## Current state

- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — declares
  `public enum TelemetryEventName` (the enum starts at line ~3 and closes at
  the first column-0 `}` around line ~132). Every case has an explicit raw
  value, e.g. `case snippetEdited = "snippet_edited"`. There are **97** cases
  today.
- `.github/workflows/ci.yml` — one job, `swift-test`, on `macos-14`. It
  already contains a non-build "lint"-style step that shells out to a repo
  script — **use it as the structural exemplar**:
  ```yaml
      - name: Check Subsystem README References
        timeout-minutes: 1
        run: |
          mkdir -p .ci-logs
          set -o pipefail
          ./scripts/check-readme-references.sh 2>&1 | tee .ci-logs/check-readme-references.log
  ```
  The workflow has `paths-ignore: ["docs/**", "spec/**", "**/*.md"]`, so a
  change to the Swift enum (a `.swift` file) always triggers CI. Note: CI runs
  in the **app** repo only — it cannot observe website-side edits, which is
  correct: the guard's job is to block an *app* change that adds an event the
  website doesn't yet allow.
- `scripts/ci/` — **does not exist on `main`**. The script below lives on the
  branch `chore/improve-audit-fixes` at `scripts/ci/check-telemetry-allowlist.sh`
  and must be recovered.
- A sibling checkout of the website repo exists at `../macparakeet-website`
  (relative to this repo root), so the script resolves the allowlist locally
  without network/auth — this is what makes Step 3's verification work.
- Repo convention: shell scripts under `scripts/` are `#!/usr/bin/env bash`
  with `set -euo pipefail`; CI steps `mkdir -p .ci-logs` and `tee` their
  output into `.ci-logs/<step>.log` (see every step in `ci.yml`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Recover script | `git show chore/improve-audit-fixes:scripts/ci/check-telemetry-allowlist.sh` | prints the script |
| Make executable | `chmod +x scripts/ci/check-telemetry-allowlist.sh` | exit 0 |
| Run the guard locally | `./scripts/ci/check-telemetry-allowlist.sh` | exit 0, ends with `OK: every Swift telemetry event is allowlisted.` |
| Lint the workflow (optional) | `command -v actionlint && actionlint .github/workflows/ci.yml` | exit 0 (skip if actionlint absent) |

## Scope

**In scope** (the only files you should create/modify):
- `scripts/ci/check-telemetry-allowlist.sh` (create)
- `.github/workflows/ci.yml` (add one step)

**Out of scope** (do NOT touch):
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — do not
  add/rename/remove events. The guard is read-only over this file.
- The `macparakeet-website` repo — this plan does not modify the website. (If
  the guard ever *fails*, the fix is a website-side allowlist add + deploy,
  which is a separate, human-driven action.)
- Any other CI step or job.

## Git workflow

- Branch from `main`: `dx/telemetry-allowlist-ci-guard`.
- Commit message: short imperative subject, e.g.
  `Add CI guard for the cross-repo telemetry allowlist`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Recover the script onto main

Create `scripts/ci/check-telemetry-allowlist.sh` with the **exact** contents
from the source branch:

```
git show chore/improve-audit-fixes:scripts/ci/check-telemetry-allowlist.sh > scripts/ci/check-telemetry-allowlist.sh
chmod +x scripts/ci/check-telemetry-allowlist.sh
```

(If `mkdir -p scripts/ci` is needed first, do that.) Do not rewrite the
script from scratch — recover it verbatim, then apply only the Step 2 edit.

**Verify**: `head -1 scripts/ci/check-telemetry-allowlist.sh` →
`#!/usr/bin/env bash`, and `test -x scripts/ci/check-telemetry-allowlist.sh && echo OK` → `OK`.

### Step 2: Harden the ALLOWED_EVENTS block extraction (fail-loud on a missing terminator)

The script parses the website allowlist with an `awk` block that stops at the
first `])`. If a future website refactor removes that terminator, the original
`awk` silently runs to EOF and sweeps up unrelated string literals as
"allowed" — which could mask a genuinely-missing event. Make it fail loudly
instead.

Find this block in the script (the website-side parse, after the allowlist is
resolved into `$allowlist_ts`):

```bash
allowed_events="$(awk '/const ALLOWED_EVENTS/{found=1} found{print} found && /\]\)/{exit}' <<<"$allowlist_ts" \
    | grep -oE '"[^"]+"' | tr -d '"' | sort -u)"
if [[ -z "$allowed_events" ]]; then
    echo "ERROR: found $WEBSITE_FILE_PATH (via $source_used) but could not parse ALLOWED_EVENTS from it" >&2
    exit 1
fi
```

Replace it with (split the `awk` out of the pipe so `set -euo pipefail` can
catch a non-zero awk exit, and add a `closed` sentinel):

```bash
# Extract the ALLOWED_EVENTS block, failing loudly if it is never terminated
# by `])` (a refactor that drops the terminator must not silently parse to EOF
# and over-include unrelated string literals).
allowlist_block="$(awk '
    /const ALLOWED_EVENTS/ { found = 1 }
    found { print }
    found && /\]\)/ { closed = 1; exit }
    END { if (found && !closed) exit 9 }
' <<<"$allowlist_ts")" || {
    echo "ERROR: ALLOWED_EVENTS block in $WEBSITE_FILE_PATH (via $source_used) was never closed by '])' — refusing to parse to EOF" >&2
    exit 1
}
allowed_events="$(grep -oE '"[^"]+"' <<<"$allowlist_block" | tr -d '"' | sort -u)"
if [[ -z "$allowed_events" ]]; then
    echo "ERROR: found $WEBSITE_FILE_PATH (via $source_used) but could not parse ALLOWED_EVENTS from it" >&2
    exit 1
fi
```

Leave the rest of the script (Swift-enum extraction, source resolution,
`comm` comparison, output) unchanged.

**Verify**: `bash -n scripts/ci/check-telemetry-allowlist.sh` → exit 0 (syntax
OK), and `grep -c 'exit 9' scripts/ci/check-telemetry-allowlist.sh` → `1`.

### Step 3: Run the guard locally (proves it works against the real allowlist)

```
./scripts/ci/check-telemetry-allowlist.sh
```

It should resolve the allowlist via the sibling checkout `../macparakeet-website`
and print a summary plus `OK: every Swift telemetry event is allowlisted.`

**Verify**: command exits 0 and the final line is
`OK: every Swift telemetry event is allowlisted.`

If instead it prints `WARNING: telemetry allowlist check SKIPPED`, the sibling
checkout was not found — see STOP conditions.

### Step 4: Prove the guard actually catches a missing event (mutation check)

Temporarily comment out one entry in the **sibling** website allowlist (this
edit is throwaway and must be reverted; it is the only time you touch the
website file):

```
# pick any allowlisted event, e.g. snippet_edited, and comment it out.
# NOTE: BSD/macOS sed needs -E + [[:space:]]; the GNU `\s` class silently
# no-ops on macOS and would make this mutation check pass vacuously.
sed -E -i.bak 's/^([[:space:]]*)"snippet_edited",/\1\/\/ "snippet_edited",/' ../macparakeet-website/functions/api/telemetry.ts
# Guard against a no-op sed: confirm the edit actually applied before trusting the result.
grep -q '// "snippet_edited"' ../macparakeet-website/functions/api/telemetry.ts \
    || echo "WARN: sed did not match — fix the pattern; do NOT trust this step's result"
./scripts/ci/check-telemetry-allowlist.sh ; echo "exit=$?"
# restore:
mv ../macparakeet-website/functions/api/telemetry.ts.bak ../macparakeet-website/functions/api/telemetry.ts
```

**Verify**: the `grep -q` guard prints nothing (the comment-out applied), then
the guard prints a `FAIL:` block listing `snippet_edited` and `exit=1`; after
restore, re-running the guard prints `OK` and exits 0. Confirm
`git -C ../macparakeet-website status` is clean (no leftover edit/.bak). If the
`WARN:` line appears, the `sed` did not match — fix it before relying on Step 4.

### Step 5: Wire the guard into CI

In `.github/workflows/ci.yml`, add a new step **immediately after** the
existing "Check Subsystem README References" step, matching its shape:

```yaml
      - name: Check Telemetry Allowlist
        timeout-minutes: 2
        env:
          # PAT with read access to the private macparakeet-website repo, so
          # the script's `gh api` fallback can fetch the allowlist in CI. If
          # this secret is unset the script SKIPS (exit 0) rather than failing
          # — see the maintenance note about enabling enforcement.
          GH_TOKEN: ${{ secrets.WEBSITE_REPO_TOKEN }}
        run: |
          mkdir -p .ci-logs
          set -o pipefail
          ./scripts/ci/check-telemetry-allowlist.sh 2>&1 | tee .ci-logs/check-telemetry-allowlist.log
```

Do not change any other step, the `concurrency` block, or `paths-ignore`.

**Verify**: `grep -n "Check Telemetry Allowlist" .github/workflows/ci.yml` →
one match; the step appears after "Check Subsystem README References" and
before "Cache SwiftPM Dependencies". If `actionlint` is installed,
`actionlint .github/workflows/ci.yml` → exit 0.

## Test plan

This change has no unit tests (it is a shell script + a CI step). Its
verification is behavioral and covered by Steps 3–4:
- Step 3 = happy path (in-sync repos → exit 0, `OK`).
- Step 4 = the regression this guard exists for (a missing allowlist entry →
  `FAIL` + exit 1), plus proof the throwaway edit was reverted.

## Done criteria

ALL must hold:

- [ ] `scripts/ci/check-telemetry-allowlist.sh` exists on this branch and is executable
- [ ] `bash -n scripts/ci/check-telemetry-allowlist.sh` exits 0 and the file contains exactly one `exit 9`
- [ ] `./scripts/ci/check-telemetry-allowlist.sh` exits 0, final line `OK: every Swift telemetry event is allowlisted.`
- [ ] Mutation check (Step 4) produced a `FAIL` + exit 1, and the website file is restored clean (`git -C ../macparakeet-website status` clean)
- [ ] `.github/workflows/ci.yml` has the "Check Telemetry Allowlist" step in the right place
- [ ] `git status` shows only `scripts/ci/check-telemetry-allowlist.sh` and `.github/workflows/ci.yml` modified in this repo
- [ ] Status row updated in `plans/active/2026-06-12-advisor-index.md`

## STOP conditions

Stop and report (do not improvise) if:

- The source branch `chore/improve-audit-fixes` no longer exists or no longer
  contains `scripts/ci/check-telemetry-allowlist.sh` (recover from this plan's
  excerpts is not possible — the full script is not inlined here). Report so
  the advisor can re-supply it.
- Step 3 prints `SKIPPED` because `../macparakeet-website` is not checked out.
  Do **not** hardcode a path or disable the skip — report; the guard is
  designed to skip-not-fail when the allowlist is unreachable, and that is
  correct behavior.
- The local run prints a real `FAIL` (a genuinely missing event) **before**
  you make any edit — that means the two repos have drifted since 2026-06-12
  and there is a live data-loss bug. STOP and report it; the fix is a
  website-side allowlist add + deploy, which is out of this plan's scope.
- `TelemetryEventName` has a case without an explicit raw value (the script
  exits with an error saying so) — the extraction needs teaching; report.

## Maintenance notes

For the human/agent who owns this after it lands:

- **Enforcement in CI requires a secret.** The step is wired but will **SKIP**
  (non-blocking, exit 0) until a repo secret `WEBSITE_REPO_TOKEN` is added — a
  GitHub PAT with read access to `moona3k/macparakeet-website`. Until then the
  guard only truly runs for contributors who have the website checked out as a
  sibling and run it locally. **Adding that secret is the one step a coding
  agent cannot do — it is a maintainer action.** Consider it the follow-up
  that turns this from "documented" into "enforced".
- The deeper fix for this class is a *single source of truth*: generate the
  website `ALLOWED_EVENTS` from `TelemetryEventName` (codegen) so drift is
  structurally impossible. This guard is the cheap insurance; revisit codegen
  if the class bites a 4th time despite the guard.
- Extra allowlist entries on the website side are intentional (stale events
  retained so old shipped builds keep batching — AUDIT-081); the guard treats
  them as informational, not failures. Do not "clean them up" to satisfy the
  guard.
