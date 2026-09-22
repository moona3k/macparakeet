---
title: Treat crashed notarytool submits as incomplete uploads
date: 2026-09-17
category: workflow-issues
module: distribution
problem_type: workflow_issue
component: notarization
severity: high
applies_when:
  - Cutting a Developer ID / Sparkle / GitHub MacParakeet release
  - `xcrun notarytool submit` exits 138 / SIGBUS
  - `notarytool history` shows a new ID that stays In Progress
resolution_type: workflow_improvement
tags: [release, notarization, notarytool, sparkle, github-releases, r2]
---

# Treat Crashed notarytool Submits as Incomplete Uploads

## Context

MacParakeet 0.8.5 (`fb186349`) signed cleanly, then
`scripts/dist/sign_notarize.sh` called default `notarytool submit` (progress +
S3 acceleration, no `--wait`). The process died with SIGBUS / exit 138.
Apple still listed new IDs. Both stayed `In Progress` for the rest of the
day. The same zip, submitted with `--no-wait --no-progress --no-s3-acceleration
--output-format json`, printed `Successfully uploaded file` and was **Accepted**
in under a minute.

The 0.8.5 agent spent ~55 minutes polling the crash-era IDs because
[`docs/distribution.md`](../../distribution.md) said a local crash is not
proof that no submission exists, and not to resubmit solely because Apple is
slow. That advice is correct for a **finished** upload. It is wrong for a
**crash during upload**.

Full timeline and leftover IDs:
[`docs/audits/2026-09-17-0.8.5-release-postmortem.md`](../../audits/2026-09-17-0.8.5-release-postmortem.md).

Same-day 0.8.4 morning history had seven ghost `MacParakeet.dmg` IDs before one
Accepted. The 0.8.0 packaging note already saw SIGBUS 138 with a registered ID
still In Progress eleven minutes later.

## Problem

`notarytool history` listing an `In Progress` row after a crash is a
reservation, not a receipt. The upload often never finished. Polling cannot
converge. Rebuilding `dist/` discards a signed artifact that was already fine.

A second, independent trap: local `gh release upload` of the ~174 MB DMG to
`uploads.github.com` from this Mac fails TLS (HTTP 500, `tls: bad record MAC`,
LibreSSL stall). `gh` inside Actions also hung. Ubuntu `curl` of the verified
R2 object attached `MacParakeet.dmg` in 29 seconds.

## Solution

1. Submit with:

   ```bash
   xcrun notarytool submit dist/MacParakeet.app.zip \
     --keychain-profile "AC_PASSWORD" \
     --no-wait --no-progress --no-s3-acceleration \
     --output-format json
   ```

   Never `--wait`. `sign_notarize.sh` now uses these flags for app zip and DMG.

2. Poll only IDs whose submit printed `Successfully uploaded file`. If submit
   crashed, resubmit the **same bytes**. Do not poll the ghost ID for 30
   minutes.

3. Staple only the artifact whose submission is `Accepted`.

4. Upload R2 first. Create the GitHub `vX.Y.Z` release without assets. Attach
   `MacParakeet.dmg` from a GitHub-hosted Ubuntu job that downloads the R2
   object and checks size + SHA-256 before POSTing to
   `uploads.github.com`. Recipe: `docs/distribution.md` gotcha 1b.

## Why this works

`--no-progress --no-s3-acceleration` avoids the local notarytool networking
path that SIGBUS-crashes on this Mac. JSON output makes “upload finished”
machine-checkable. Resubmitting the same zip does not change Sparkle bytes.
R2 is already the Sparkle source of truth; GitHub only needs a copy for the
Homebrew cask filename `MacParakeet.dmg`.

## Prevention

Do not weaken gotcha 1a (genuine slow Apple processing after a successful
upload). Distinguish:

| Signal | Action |
| --- | --- |
| SIGBUS / exit 138 / no `Successfully uploaded file` | Ghost ID. Resubmit same artifact with the safe flags. |
| `Successfully uploaded file`, then `In Progress` | Real processing. Bound-poll that exact ID. Do not rebuild. |
| `Accepted` | Staple those exact bytes. |
