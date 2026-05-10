# Dictation Paste Targeting UX

Status: **ACTIVE**
Owner: Core app team
Updated: 2026-05-10

## Decision

MacParakeet dictation should default to the **finish-target model**:

```text
user speaks
    |
    v
transcript becomes ready
    |
    v
paste into the currently focused editable target
```

This keeps paste behavior aligned with where the user's attention and cursor are
when text is inserted.

## Rationale

Dictation has a small but real delay between speaking and insertion. During that
delay, users can intentionally move focus to the field they want to receive the
text. The currently focused editable target is therefore the clearest signal of
intent for the default behavior.

Start-target locking, where the app remembers the app or field active at the
start of dictation, can be useful for users who glance away while waiting. It is
also easier to reason about in automation scenarios. But it is not clearly the
right default for plain dictation because users can forget where they started,
or begin speaking before the final input field is focused.

## Product Rule

1. Default dictation insertion should use the target focused at paste time.
2. If no editable target can receive paste, copy to clipboard and show fallback.
3. Do not silently paste into a stale app just because it was active at dictation
   start.
4. If original-target locking returns later, expose it as an intentional mode or
   setting, not as the default.

## Follow-Up

Future hardening should focus on current editable-target detection, insertion
verification, and better paste diagnostics before revisiting PID or AX-element
locking.
