#!/usr/bin/env bash
#
# reset_and_run_fresh.sh
#
# Simulates a "fresh install" of the dev build for manual onboarding testing
# without needing a new macOS user account or VM.
#
# ──────────────────────────────────────────────────────────────────────────────
# Why this exists (durable dev tool — expected to be reused)
# ──────────────────────────────────────────────────────────────────────────────
#
# Your dev machine already has Microphone, Accessibility, and Screen &
# System Audio Recording permissions granted to MacParakeet-Dev. That means
# macOS's TCC database silently skips every permission prompt, so onboarding,
# first-use flows, and permission-gated features APPEAR TO WORK PERFECTLY
# even when they're completely broken for a brand-new user.
#
# This script exists so that a ~5-minute manual check is enough to test any
# change that touches:
#
#   - Onboarding (any step), especially permission-gated steps
#   - PermissionService / TCC flows
#   - First-run behavior gated on `onboarding.completedAtISO`
#   - Meeting recording first-use permission flow
#   - The optional Screen & System Audio Recording step (added in 2631b83,
#     see plans/completed/2026-04-onboarding-screen-recording-permission.md)
#   - Any new onboarding capability work from the broader issue #66 refactor
#
# Reach for this script whenever you're about to touch code in those areas.
# It is NOT a one-off — it was written to save every future session 10-15
# minutes vs spinning up a VM or a second macOS user account.
#
# ──────────────────────────────────────────────────────────────────────────────
# Maintenance notes
# ──────────────────────────────────────────────────────────────────────────────
#
# - If Apple renames a TCC category (they did between macOS 12→13→14), the
#   `tccutil reset <category>` lines below will need updating. `tccutil` with
#   no args prints the current category list.
# - If a new onboarding UserDefaults key gets added alongside existing ones
#   (e.g. "onboarding.foo"), add a matching `defaults delete` line in step 3
#   so the reset is complete.
# - The `com.macparakeet.dev` bundle ID is the dev build only; production
#   uses `com.macparakeet.MacParakeet`. Do not point this script at the
#   production bundle — you'd nuke a real user's permissions.
#
# ──────────────────────────────────────────────────────────────────────────────
#
# What this does:
#   1. Quits any running MacParakeet-Dev instance
#   2. Resets TCC permissions (Microphone, Accessibility, Screen Recording, etc.)
#      for the dev bundle ID — macOS will re-prompt on first use
#   3. Clears the onboarding completion flag so the onboarding window reopens
#   4. Clears the meeting-recording skip flag so the new optional step is shown
#   5. Rebuilds and launches the dev app via run_app.sh
#
# What this does NOT do (intentionally):
#   - Does not delete the dictation/transcription database at
#     ~/Library/Application Support/MacParakeet/macparakeet.db
#   - Does not touch downloaded STT/diarization models (they take ~6 GB to
#     re-download). If you want a true cold-start, delete that folder manually.
#   - Does not touch LLM API keys, hotkey config, or other settings you'd miss
#
# Usage:
#   scripts/dev/reset_and_run_fresh.sh
#
# After it launches:
#   See the "Manual verification scenarios" note printed at the end.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_BUNDLE_ID="com.macparakeet.dev"

echo "[1/5] Quitting any running MacParakeet-Dev…"
osascript -e 'tell application "MacParakeet-Dev" to quit' 2>/dev/null || true
pkill -x "MacParakeet" 2>/dev/null || true
sleep 0.5

echo "[2/5] Resetting TCC permissions for ${DEV_BUNDLE_ID}…"
# These can fail silently if the app has never requested the permission yet —
# that's fine, tccutil just has nothing to reset.
tccutil reset Microphone           "$DEV_BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility        "$DEV_BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture        "$DEV_BUNDLE_ID" 2>/dev/null || true
tccutil reset SystemPolicyAllFiles "$DEV_BUNDLE_ID" 2>/dev/null || true

# Broad fallback in case a category was missed above.
tccutil reset All                  "$DEV_BUNDLE_ID" 2>/dev/null || true

echo "[3/5] Clearing onboarding flags from UserDefaults…"
defaults delete "$DEV_BUNDLE_ID" "onboarding.completedAtISO"          2>/dev/null || true
defaults delete "$DEV_BUNDLE_ID" "onboarding.meetingRecordingSkipped" 2>/dev/null || true

echo "[4/5] Rebuilding and launching dev app…"
"$ROOT_DIR/scripts/dev/run_app.sh"

cat <<'EOF'

[5/5] Ready for manual verification.

Run these scenarios in order:

  A. GRANT path (the thing this PR fixes)
     - Walk through onboarding to the "Meeting Recording (Optional)" step
     - Click "Enable meeting recording", grant in System Settings
     - Within ~2s the onboarding UI should flip to granted
     - Finish onboarding, click "Record meeting" from the menu bar
     - EXPECT: recording starts with NO permission prompt

  B. SKIP path (don't break existing users)
     - Re-run this script to reset
     - At the meeting recording step, click "Skip — I'll set this up later"
     - Finish onboarding, click "Record meeting"
     - EXPECT: existing first-use permission prompt still works

  C. EXISTING-USER safety
     - Do NOT run this script
     - Just launch the app normally (scripts/dev/run_app.sh)
     - EXPECT: no onboarding window reopens for users already past it

If any scenario fails, note what you saw and revert 2631b83.
EOF
