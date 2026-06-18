# Plan: Establish a formatting/lint safety net (swift-format + .editorconfig + dev scripts + informational CI)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 16e3f865f..HEAD -- .editorconfig .gitattributes .github/workflows/ci.yml scripts/`
> If any of those paths changed since this plan was written, compare the
> "Current state" excerpts against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `16e3f865f`, 2026-06-15

## Why this matters

The repo has **no formatter, linter, `.editorconfig`, or pre-commit hook** for
first-party Swift. Style is enforced only by reviewer attention, and the
documented "mixed line endings flip whole files on edit" pitfall (see
`CLAUDE.md` → "Mixed line endings flip whole files on edit") has no
editor-level guard — `.gitattributes` enforces LF for `*.swift` at the git
layer, but editors get no hint and non-Swift files (`.yml`, `.json`, `.sh`,
`.md`) are uncovered. This plan adds a low-risk baseline: an `.editorconfig`,
a discoverable `swift-format` config, two dev scripts (a one-command formatter
and a fast inner-loop build check), and an **informational, non-blocking** CI
lint step. It deliberately does **not** reformat the existing tree or make
lint blocking — that is a separate decision for the maintainer (see
Maintenance notes).

## Current state

- `.gitattributes` (exists, 1 line): `*.swift text eol=lf` — keep it; this plan
  complements it, does not replace it.
- `.git-blame-ignore-revs` exists (from a prior LF renormalization).
- `.editorconfig` — **absent**.
- `swift-format` is available from the Xcode 16.1 / Swift 6 toolchain used by CI
  and locally via `xcrun swift-format` (verified:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format`).
  There is no `.swift-format` config file yet, so `swift-format` would use its
  built-in defaults.
- `scripts/` layout: `scripts/check-readme-references.sh` (a doc-drift checker,
  use as the shell-style exemplar), `scripts/dev/` (contains `run_app.sh`,
  `ci_local.sh`, etc.), `scripts/dist/`.
- `.github/workflows/ci.yml` — single job `swift-test` on `macos-14`, Xcode
  16.1. Each step follows this exact pattern:
  ```yaml
      - name: <Name>
        timeout-minutes: <n>
        run: |
          mkdir -p .ci-logs
          set -o pipefail
          <command> 2>&1 | tee .ci-logs/<slug>.log
  ```
  The first real step after checkout/toolchain is "Check Subsystem README
  References" (line ~39). CI ignores `**/*.md`, `docs/**`, `spec/**` via
  `paths-ignore`.

Repo script convention (from `scripts/check-readme-references.sh`): `#!/usr/bin/env bash`,
`set -euo pipefail`, a short header comment, plain `echo` progress, non-zero
exit on failure.

## Commands you will need

| Purpose            | Command                                                       | Expected on success |
|--------------------|--------------------------------------------------------------|---------------------|
| swift-format avail | `xcrun swift-format --version`                               | prints a version    |
| Lint (report only) | `xcrun swift-format lint --recursive Sources Tests`         | runs; may print warnings (non-fatal for this plan) |
| Format in place    | `xcrun swift-format format --in-place --recursive Sources Tests` | exit 0 (do NOT commit the reformat in this plan) |
| Fast debug build   | `swift build`                                                | exit 0              |
| Full tests         | `swift test`                                                 | all pass            |

## Scope

**In scope** (the only files you should create/modify):
- `.editorconfig` (create)
- `.swift-format` (create — JSON config)
- `scripts/dev/format.sh` (create)
- `scripts/dev/check.sh` (create)
- `.github/workflows/ci.yml` (add ONE informational step)
- `AGENTS.md` (add a short "Inner loop" note pointing at `scripts/dev/check.sh`)
- `plans/README.md` (status row update)

**Out of scope** (do NOT touch):
- Any `Sources/**` or `Tests/**` source file. **Do not run the in-place
  formatter against the committed tree** — reformatting 121K lines is a
  separate, maintainer-approved mechanical commit, not part of this plan.
- `.gitattributes` — leave the existing LF rule as-is.
- Making the CI lint step blocking (`continue-on-error: false`) — explicitly
  deferred.

## Git workflow

- Branch: `advisor/dx-format-lint-baseline` off `origin/main`
  (`git fetch origin && git worktree add -b advisor/dx-format-lint-baseline ../macparakeet-worktrees/dx-format-lint-baseline origin/main`).
- Commit message style: this repo uses rich messages for significant changes
  (`docs/commit-guidelines.md`), but a tooling-only change may use a concise
  subject + 2–3 bullet body. Example subject: `DX: add swift-format config, .editorconfig, and dev inner-loop scripts`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add `.editorconfig`

Create `.editorconfig` at the repo root:

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.swift]
indent_style = space
indent_size = 4

[*.{yml,yaml,json}]
indent_style = space
indent_size = 2

[*.md]
trim_trailing_whitespace = false
```

**Verify**: `test -f .editorconfig && head -1 .editorconfig` → prints `root = true`

### Step 2: Add a `.swift-format` config tuned to the existing style

Create `.swift-format` at the repo root. Keep it permissive so it documents the
house style without implying a giant reformat. The existing code uses 4-space
indent and ~100–120 col lines:

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false,
  "indentConditionalCompilationBlocks": false,
  "rules": {
    "AllPublicDeclarationsHaveDocumentation": false,
    "AlwaysUseLowerCamelCase": false,
    "NoBlockComments": false,
    "OrderedImports": false,
    "UseLetInEveryBoundCaseVariable": false
  }
}
```

**Verify**: `xcrun swift-format lint --configuration .swift-format Sources/MacParakeetCore/AppNotifications.swift`
→ runs and exits (warnings about that file are acceptable; the point is the
config parses and the tool runs).

### Step 3: Add `scripts/dev/format.sh`

Create `scripts/dev/format.sh` (mode `+x`):

```bash
#!/usr/bin/env bash
# Format first-party Swift in place with the repo's swift-format config.
# Manual / opt-in — NOT run by CI. Review the diff before committing.
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "Formatting Sources/ and Tests/ with swift-format…"
xcrun swift-format format --in-place --recursive --configuration .swift-format Sources Tests
echo "Done. Review with: git diff --stat"
```

`chmod +x scripts/dev/format.sh`.

**Verify**: `bash -n scripts/dev/format.sh && test -x scripts/dev/format.sh && echo ok` → `ok`
(Do **not** run the script itself in this plan — see Out of scope.)

### Step 4: Add `scripts/dev/check.sh` (fast inner loop for agents)

Create `scripts/dev/check.sh` (mode `+x`):

```bash
#!/usr/bin/env bash
# Fast inner-loop check for agents: debug build (no release, no clean) plus an
# optional filtered test run. Much faster than scripts/dev/ci_local.sh.
# Usage: scripts/dev/check.sh [test-filter]
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "==> swift build (debug)"
swift build
if [[ "${1:-}" != "" ]]; then
  echo "==> swift test --filter $1"
  swift test --filter "$1"
fi
echo "==> swift-format lint (report only)"
xcrun swift-format lint --recursive --configuration .swift-format Sources Tests || true
echo "check.sh complete"
```

`chmod +x scripts/dev/check.sh`.

**Verify**: `bash -n scripts/dev/check.sh && test -x scripts/dev/check.sh && echo ok` → `ok`

### Step 5: Add an informational (non-blocking) lint step to CI

In `.github/workflows/ci.yml`, insert a new step **immediately after** the
"Check Subsystem README References" step (around line 45, before "Cache SwiftPM
Dependencies"). It must be non-blocking via `continue-on-error: true`:

```yaml
      - name: Swift Format Lint (informational)
        continue-on-error: true
        timeout-minutes: 3
        run: |
          mkdir -p .ci-logs
          set -o pipefail
          xcrun swift-format lint --recursive --configuration .swift-format Sources Tests 2>&1 | tee .ci-logs/swift-format-lint.log
```

Do not change any other step. Do not remove `continue-on-error`.

**Verify**:
- `grep -n "Swift Format Lint" .github/workflows/ci.yml` → one match.
- `grep -n "continue-on-error: true" .github/workflows/ci.yml` → at least one match (the new step).
- YAML still parses: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"` → `yaml ok`

### Step 6: Document the inner loop in AGENTS.md

Add a short note to `AGENTS.md` (find the build/test section) pointing agents at
the new fast loop, e.g.:

> **Inner loop:** `scripts/dev/check.sh [TestFilter]` runs a debug build +
> optional filtered tests + report-only `swift-format` lint. Use it for fast
> iteration; `scripts/dev/ci_local.sh` remains the full pre-merge check.
> Run `scripts/dev/format.sh` to auto-format before committing.

**Verify**: `grep -n "scripts/dev/check.sh" AGENTS.md` → at least one match.

### Step 7: Confirm the build is unaffected

**Verify**: `swift build` → exit 0. (No source changed, so this must still pass.)

## Test plan

This plan adds tooling/config only — no new XCTest cases are required. The
verification gates above are the test plan. Do **not** run `swift test` changes;
just confirm `swift build` exits 0 (Step 7) to prove nothing in the toolchain
config breaks compilation.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `.editorconfig` and `.swift-format` exist at repo root; `head -1 .editorconfig` is `root = true`.
- [ ] `scripts/dev/format.sh` and `scripts/dev/check.sh` exist and are executable (`test -x`).
- [ ] `xcrun swift-format --version` succeeds and `.swift-format` parses (Step 2 verify).
- [ ] `.github/workflows/ci.yml` has exactly one new `Swift Format Lint (informational)` step with `continue-on-error: true`, and the file still parses as YAML.
- [ ] `swift build` exits 0.
- [ ] No file under `Sources/**` or `Tests/**` is modified (`git status --porcelain Sources Tests` is empty).
- [ ] `AGENTS.md` references `scripts/dev/check.sh`.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- `xcrun swift-format --version` fails (the CI/local toolchain does not bundle
  swift-format) — report so the maintainer can pin a swift-format SPM plugin
  instead.
- Adding the config would require touching any `Sources/**`/`Tests/**` file to
  keep `swift build` green.
- The CI YAML fails to parse after your edit and you cannot resolve it in one
  attempt.
- You discover an existing `.swift-format`, `.swiftlint.yml`, or lint CI step
  not mentioned in "Current state" (the repo drifted).

## Maintenance notes

- **Deferred follow-up (maintainer decision):** flipping the CI lint from
  informational to blocking requires first running `scripts/dev/format.sh` once
  to reformat the whole tree in a single mechanical commit, then adding that
  commit's SHA to `.git-blame-ignore-revs` (the repo already uses this file).
  Do that as its own PR so review noise is contained — it is intentionally NOT
  part of this plan.
- A reviewer should confirm the lint step is non-blocking (a red lint must not
  fail CI yet) and that no source files were reformatted in this PR.
- If `swift-format`'s default rules prove too noisy in the informational logs,
  tighten the `rules` map in `.swift-format` rather than disabling the step.
