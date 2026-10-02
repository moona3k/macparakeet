---
title: Meeting notes excluded from Summary context (issue #1204)
date: 2026-10-02
category: logic-errors
module: Meeting summaries
problem_type: logic_error
component: prompt_assembly
symptoms:
  - Typed attendee spellings and URLs do not influence meeting summaries
  - Enabling meeting notes does not change an old result when regenerated
root_cause: Notes context is opt-in and regeneration replays the saved preference
resolution_type: code_fix
tags: [meetings, notes, summaries, prompt-context, issue-1204]
---

# Meeting notes excluded from Summary: issue #1204

## Approved direction and implementation plan

The user subsequently requested notes enabled by default and a reviewed PR.
The built-in Summary is now seeded with notes enabled. Existing preferences are
preserved because a stored false value cannot distinguish an untouched default
from an intentional opt-out. Other built-in and custom prompts remain unchanged.
The historical findings below describe 0.8.9 and the investigation base.

The implementation plan is to change Summary's seed preference, preserve
checkbox opt-outs across launches and Restore Defaults, retain generation
receipts and Regenerate replay policy, update ADR/CLI contracts, verify focused
repository and request-boundary tests, and publish the reviewed branch as a PR.
No schema migration, URL fetch, automatic AI run, or release deployment is added.

## Verdict and evidence

The reported behavior is reproducible under default settings. This does not
establish the reporter's actual checkbox setting or provider response: the issue
contains neither. The issue reports 0.8.9, commit `a89a152c84a9`. Inspection of
that commit and the investigation base `f43f4bed2` shows the same exclusion rule.

1. `Prompt.classicSummaryPrompt()` has no `{{userNotes}}` token and inherits
   `includeMeetingNotes = false`. Migration v0.33 also defaults existing prompts
   to false. This is an explicit opt-in decision in ADR-020, not a lost-notes
   database bug.
2. `PromptSystemPromptAssembler.effectiveUserNotes` returns nil unless the
   preference is enabled or the template explicitly references `{{userNotes}}`.
   Saved notes can therefore be present while absent from the AI request.
3. GUI generation reads committed notes and snapshots the effective input when
   enqueueing. Saved-detail AI actions flush pending note edits first. Automatic
   saved-audio summaries and CLI prompt generation use the same assembler.
4. `regeneratePromptResult` uses the saved result's
   `includeMeetingNotesSnapshot`, not the current library preference. It reads
   current notes only within that saved policy. A new generation uses the
   current library preference. This replay behavior is intentional but was not
   explained in the result UI.
5. Enabled automatic context previously instructed the model to resolve every
   factual conflict in favor of the transcript. That guidance can work against
   typed corrections of speech-recognition errors. No live-provider experiment
   was performed, so its effect on a particular output remains unmeasured.
6. URLs are supplied text context. This summary path does not fetch linked
   pages; a URL alone cannot provide the content behind it.

## Repair and invariants

- The meeting generation popover states whether notes context is enabled.
- Saved results expose their recorded notes snapshot, or explain the disabled
  setting and how to generate a new result after changing it. Imported or
  unlinked results without a notes receipt say the notes context was not
  recorded instead of claiming a disabled setting.
- Prompt Library copy describes the provider boundary and regeneration rule.
- Automatic context now permits explicit spelling corrections when the referent
  is clear and asks for relevant URLs to be preserved exactly. Names/links alone
  cannot establish attendance, speaker identity, decisions, or commitments.
- Summary's new-install default is enabled. Existing choices, including a saved
  opt-out on a legacy built-in row replaced by its canonical identity, replay behavior,
  notes persistence, the 8,000-word
  cap, custom template framing, and URL-fetch behavior remain unchanged.
- Historical snapshots are labeled neutrally: older versions stored full notes
  even when the request was capped, so they are not always exact sent receipts.

## Verification

The emitted-prompt regression failed against the old instruction before the
assembler fix. Focused tests exercise prompt rendering, default exclusion,
opt-in inclusion, current notes with saved regeneration policy, fresh generation
with the updated policy, automatic completion, and CLI prompt generation.
A generation-ID assertion distinguishes a newly saved result from the mock
repository's save call made during replacement.

Independent correctness and maintainability reviews were performed. The
historical-snapshot wording finding was addressed. Native visual interaction
and live-provider compliance are separate, unverified evidence lanes. Test
outcomes are recorded in the task handoff rather than treated as release proof.

## Workaround in 0.8.9

Open a saved meeting, click **+** next to its tabs, choose **Manage Prompts**,
expand **Summary** using its chevron, and enable **Include meeting notes as
context**. Return to **+ → Summary → Generate** to create a new result.
**Regenerate** on an existing result keeps its original setting.
