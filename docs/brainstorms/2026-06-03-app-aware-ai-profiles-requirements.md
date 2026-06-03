---
date: 2026-06-03
topic: app-aware-ai-profiles
---

# App-Aware AI Profiles Requirements

Generated in the style of `/ce-brainstorm` from:

- GitHub issues `#117` and `#412`.
- Fresh current-code inspection of MacParakeet `origin/main`.
- Fresh external research summarized in
  `docs/research/2026-06-app-aware-ai-profiles-competitor-research.md`.

## Problem

MacParakeet's Dictation AI Formatter has one global prompt. That works for
generic cleanup, but it forces users to either write one overly broad prompt or
manually change settings when moving between apps.

The user need is concrete:

- Slack or Messages should stay casual and concise.
- Mail should read more professionally.
- Terminal or code editors should preserve command names, flags, paths, and
  formatting.
- Browser-hosted apps like Gmail are desirable, but browser tab/domain matching
  adds enough complexity to defer.

## Product Goal

Let users define local app-aware AI Formatter profiles that choose a different
formatter prompt based on the focused paste target at dictation finish time,
while preserving MacParakeet's local-first privacy contract and existing global
formatter fallback. If focus drifts to MacParakeet UI during teardown, the
runtime may fall back to a start-time app snapshot captured before MacParakeet
can become frontmost.

## Non-Goals

- No browser hostname/domain matching in v1.
- No window-title matching in v1.
- No selected-text, clipboard, or screen/OCR context in v1.
- No automatic cloud LLM enablement. AI Formatter remains opt-in and uses the
  user's configured provider.
- No file/URL transcription app profiles in v1.
- No full workflow engine with per-profile STT engine, language, provider,
  dictionary, snippets, or auto-send settings in v1.
- No telemetry containing exact bundle IDs, app names, profile IDs/names,
  hostnames, prompts, transcripts, selected text, clipboard, or screen text.

## Actors

- Dictation user: wants output style to fit the app they are typing into.
- Power user: wants exact app prompts and predictable fallback behavior.
- App runtime: captures local app context at the right lifecycle moment.
- Settings UI: creates, edits, enables, disables, and deletes profiles.
- Telemetry pipeline: keeps the existing coarse app-category boundary and does
  not learn exact app/profile identities in V1.

## Requirements

### R1 - Global Fallback Preserved

The existing global AI Formatter prompt remains the default behavior. If no
enabled profile matches the focused app, MacParakeet uses the same prompt it
uses today.

Acceptance:

- With zero profiles, AI Formatter output path is byte-for-byte equivalent in
  prompt selection to current behavior.
- Disabling all profiles returns to the existing global prompt.
- AI Formatter disabled means no profile runs.

### R2 - Exact-App Profiles

Users can create an enabled profile for a specific macOS app bundle ID.

Acceptance:

- V1 supports manually entering a bundle ID.
- A running-app picker is allowed as a future UX improvement, but not required
  for the first implementation.
- The profile stores a user-visible app name when available, but matches by
  normalized bundle ID.
- When multiple apps are open, the focused paste target at dictation finish time
  determines the profile unless focus drift makes that context invalid.

### R3 - Category Profiles

Users can create an enabled profile for one coarse local category:

- `messaging`
- `email`
- `browser`
- `notes`
- `docs`
- `code`
- `terminal`
- `other`

Acceptance:

- Categories use the same local mapping as `TelemetryAppCategory`.
- Category profiles are lower precedence than exact-app profiles.
- Unknown bundle IDs map to `other`.

### R4 - Deterministic Matching

Prompt resolution is deterministic and explainable.

V1 precedence:

1. Enabled exact-bundle profile.
2. Enabled category profile.
3. Existing global AI Formatter prompt.

Acceptance:

- Exact app beats category every time.
- Category beats global only when no exact app profile matches.
- Duplicate exact-app profiles are prevented or resolved by a documented
  deterministic order.
- The resolved profile includes a local explanation: exact app, category, or
  global fallback.

### R5 - Prompt Template Contract

Each profile stores a prompt template with the same transcript placeholder
contract as the current global AI Formatter prompt.

Acceptance:

- `{{TRANSCRIPT}}` works the same way in profile prompts as in the global prompt.
- Empty profile prompt bodies normalize to the default prompt or are rejected in
  UI; they must not send an empty LLM task by accident.
- The formatter preserves fallback behavior if the LLM call fails: use standard
  cleanup and post the existing warning.

### R6 - Local App Context

MacParakeet captures local app context near dictation finish time, before the AI
Formatter prompt is resolved. It also keeps a start-time snapshot as a fallback
for focus-drift cases where the stop/undo-time context is missing or identifies
MacParakeet itself.

Acceptance:

- Recording start captures a best-effort app snapshot before MacParakeet UI can
  become frontmost.
- Stop recording and undo-cancel both update the app context for the active
  dictation session.
- Stop/undo-time context wins when it is valid because it reflects the paste
  target model already used by telemetry.
- Start-time context is used only as fallback for missing/self-app stop context.
- Stale session updates are ignored.
- App context contains exact bundle ID and display name locally. Telemetry
  receives only the existing coarse `app_category` in V1.

### R7 - Settings UX

Settings provides a compact profile management surface under the AI Formatter
area.

Acceptance:

- Users can list, add, edit, disable, and delete profiles.
- Add-app flow supports manual bundle ID entry.
- Running-app picker support is a future enhancement, not a V1 acceptance gate.
- Category flow supports picking a category from a fixed list.
- The prompt editor is consistent with the existing AI Formatter prompt editor.
- The UI shows precedence or match explanation clearly enough that users can
  understand why exact app beats category.
- Suggested templates are allowed in a future iteration, but no new profile
  changes output until the user explicitly enables it.

### R8 - Privacy and Telemetry

Profile matching is local-only. V1 does not add formatter-profile telemetry
fields; telemetry keeps using existing formatter events and existing coarse
`app_category` fields only.

Existing telemetry allowed in V1:

- Existing `app_category`.
- Existing success/failure/latency fields.

Future aggregate profile-adoption telemetry is allowed only if the paired
website Worker allowlist and stats paths are updated before shipping, and only
if it remains non-identifying.

Disallowed telemetry:

- Bundle ID.
- App display name.
- Profile ID.
- Profile name.
- Profile match kind in V1.
- Hostname/domain.
- Prompt body.
- Transcript text.
- Selected text.
- Clipboard text.
- Screen/OCR text.

### R9 - Local History / Debuggability

MacParakeet should preserve enough local metadata to explain a completed
dictation's profile routing.

Acceptance:

- Completed dictation rows can record matched profile ID/name and match kind.
- The data is local user data.
- Exact bundle ID can remain in existing local `pastedToApp` behavior; it is
  not sent to telemetry.

### R10 - Transform Compatibility Path

The design must not block future per-app Transform prompt variants.

Acceptance:

- The app-context capture/matcher domain types can be reused by Transforms.
- The first implementation does not need to change Transform behavior.
- The old transform-only ADR is treated as prior art and can be rewritten after
  Dictation Formatter profiles land.

## Key User Flows

### Flow A - Slack Profile

1. User enables AI Formatter.
2. User creates profile "Slack casual" by entering Slack's bundle ID.
3. User writes a prompt that keeps messages short and conversational.
4. User dictates into Slack.
5. MacParakeet matches the exact Slack bundle ID and uses the profile prompt.
6. History/debug metadata shows the matched profile.

### Flow B - Email Category

1. User creates category profile "Professional email" for `email`.
2. User dictates into Mail.
3. MacParakeet maps Mail to `email` and uses the category prompt.
4. If the user later creates an exact Mail profile, the exact profile wins.

### Flow C - Terminal Exact App

1. User creates profile "Terminal commands" for Terminal or iTerm.
2. Prompt says to preserve CLI command names, flags, paths, and newlines.
3. User dictates a shell command.
4. MacParakeet uses the exact-app prompt and does not let a broader category
   profile override it.

### Flow D - Browser V1

1. User dictates into Chrome on Gmail.
2. V1 sees Chrome as the app.
3. If the user has a Chrome exact-app profile, it applies.
4. Otherwise if the user has a `browser` category profile, it applies.
5. Gmail-specific domain matching is not attempted in v1.

## Open Decisions

1. Whether to add a running-app picker on top of manual bundle ID entry.
   Recommendation: future UX polish after the core routing slice lands.
2. Whether to ship disabled category templates for Email, Chat, Docs/Notes, and
   Terminal. Recommendation: yes, as creation templates only in a later polish
   slice.
3. Whether manual profile hotkeys should be part of this feature. Recommendation:
   no for v1; use existing dictation hotkey behavior.
