# Voice Command and Agent Mode Exploration

Status: **PROPOSED**
Owner: Core app team
Updated: 2026-05-10

## Objective

Explore a future mode where spoken intent can trigger app actions, selected-text
rewrites, or constrained agent workflows without weakening MacParakeet's
local-first dictation reliability.

This is intentionally separate from the paste hardening work. The immediate PR
should improve text delivery by targeting the app captured at dictation start.
Command/agent behavior needs a separate safety and product pass.

## Product Thesis

MacParakeet should stay excellent at plain dictation first. Voice command or
agent behavior is only worth shipping when it feels predictable:

1. normal speech inserts text
2. command speech is opt-in and visually distinct
3. actions run only against the intended target app or an explicit MacParakeet tool
4. failure never causes wrong-target paste, data loss, or hidden automation

## Candidate Capabilities

1. selected-text rewrite, building on the completed command-mode F10a plan
2. app-local actions such as press return, tab, escape, or submit after dictation
3. structured commands such as "summarize this selection" or "make this friendlier"
4. agent handoff for explicit tasks such as "turn this note into todos"
5. workflow macros with clear previews and confirmation before irreversible actions

## Safety Requirements

1. no arbitrary shell, network, file, or app automation by default
2. explicit confirmation before destructive or externally visible actions
3. allowlisted tools with typed arguments instead of free-form execution
4. clear mode boundary so plain dictation cannot accidentally become a command
5. no audio, transcript, selected text, or prompt content in telemetry
6. failure buckets should be structural only, such as permission denied, no selection,
   unsupported app, target changed, or action cancelled

## Architecture Notes

1. build on hardened clipboard delivery:
   - capture target process at command start
   - use PID-targeted paste/action delivery
   - preserve full pasteboard item snapshot/restore
2. reuse command-mode de-risk work in
   `plans/completed/2026-02-command-mode-f10a-de-risk-plan.md`
3. keep command orchestration outside SwiftUI views
4. keep Core APIs typed and testable; UI should only present state and confirmation
5. prefer selected-text and paste replacement contracts before broader app automation

## Open Questions

1. Should command mode be a separate hotkey/chord or inferred from language?
2. Should agent actions require a preview every time, or only for risky actions?
3. Which apps are in the first manual reliability matrix?
4. Is an LLM provider required, optional, or local-only for the first version?
5. What is the minimum useful command set that does not compromise dictation UX?

## First De-Risk Slice

1. implement target-captured paste delivery for dictation
2. manually test paste delivery across TextEdit, Notes, Slack, Safari textareas,
   Chrome, VS Code, Cursor, Terminal, and Messages
3. document unsupported or flaky target classes
4. only then revisit direct insertion, menu paste fallback, and insertion verification
5. start command/agent prototyping after the paste path has evidence across real apps
