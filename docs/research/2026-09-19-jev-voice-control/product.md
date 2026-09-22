# Product: intent capture on the Mac

Dictation puts words in a field. Voice Control captures **intent** and executes it on the real frontmost app: observe the Accessibility tree, compile a tool, act, verify.

Invocation is deliberate. Hold Control–Option–Space, or type in the inbox. There is no wake word and no always-on listening. Ordinary dictation keeps its current meaning.

## The panel is the cockpit

Always visible while the mode is on: listening state, command vs typing, the last committed utterance, the current task, Stop. Hidden mode is how people who cannot look away get lost.

Intent is restated as an effect, not a vibe. “Click Save (the second one)” beats “Working…”. When several controls match, a numbered list in the panel is that restatement. On-screen number overlays are later; the interaction is the same (“say the number”), the affordance is not.

Correction is cheaper than restart. “No, the other one”, “Actually London”, and a typed revision keep verified history. A single last-string variable is not enough.

Help is pulled from **this** window. It lists observed unique controls (“Click Save — or just say Save”). Never a static superpower list.

Failures name the missing permission or the unmatched choice. Silence is not “I didn’t understand”, and a denied microphone is not silence.

One panel. Not an Iron Man HUD.

## Identifying is not authorizing

Choosing option two resolves a target. It does not approve sending, purchasing, or deleting. Every path returns through the same consequence policy.

Confirm only:

- payment or purchase commitment
- destructive deletion
- external send / submit

Navigation, opening selectors, choosing dates, filling requested values, scrolling, searching, and an unambiguous “click Search” proceed without a prompt. Searching for a flight does not authorize buying a ticket.

The confirmation names the compiled effect and what **Cancel task** does (“Nothing is paid / deleted / sent”). Isolated `yes` / `confirm` / `confirm this action` authorize. `ok`, `okay`, and filler words do not. Isolated `no` / `cancel` / `cancel task` decline.

If the target, amount, recipient, or requested outcome is genuinely missing, ask that slot by name (“Need a destination”). Do not ask “are you sure?” for ordinary navigation.

## Command vs typing

Voice computer-use is two products on one microphone:

1. **Commands** that change the world
2. **Literal speech** that must land as text and must not be reinterpreted as a command

Isolated utterances enter typing (`typing mode`, `start typing`, `literal mode`, …). Isolated `command mode` / `stop typing` leave it. `type literally command mode` types those words. Substring matching is illegal: a dictated sentence must not flip the mode.

Stop from typing is `command stop`, not a word buried in the payload.

## Speech, privacy, Stop

Audio stays on the Mac. Jev is cloud text-only, explicit consent, BYO key in Keychain. The request is the goal plus bounded visible control labels — never audio, screenshots, field values, or selected text on the Jev wire.

Stop revokes in-flight authority. The user moving the mouse or switching apps pauses automation; Continue reobserves. Unknown effects do not retry.

TTS, when it arrives, is on-device `AVSpeechSynthesizer`: short status lines, barge-in cancels speech. Personality voices are out. See [later](later.md).

## Correction amends the task

Retain what still applies. Revise the part that changed. Reobserve before acting. A transcript string is not a referent.

| Situation | Experience | Boundary |
|---|---|---|
| Before any action: “Find flights to Paris… actually London.” | Commit the corrected destination. | Do not act on an abandoned partial. |
| After filling Paris: “Actually London.” | Update destination; keep origin, date, trip type. | Ask which slot if London could mean something else. |
| Wrong candidate: “No, the other one.” | Refer to recent alternatives; exclude the rejected one. | Numbered list if more than one remains. |
| “Undo that.” after a field change | Restore the last owned text edit while it still matches. | Do not overwrite a later manual edit or pretend a send can be undone. |
| User fixes a field, then “Continue.” | Observe the corrected state; continue the remaining goal. | Do not restore the old selected value. |
| Outcome of a press is unknown | Name the step and the missing evidence. | Resume must not automatically repeat it. |

Goal revision is not physical rollback. Changing the date after a field was filled updates that field. Changing the date after a purchase completed cannot un-buy the ticket. Receipts stay.

## Mixed input

Typing, clicking, dragging, or scrolling that competes with automation **pauses** it. The task remains. Stop is still authoritative. Pointer motion alone is not takeover. Continue reobserves; it does not replay.

Listening, understanding the goal, and holding permission to mutate the UI are three different things. Pausing execution does not erase the goal.

## Traces answer four questions

What did I request? What changed? Where did it stop? What can I fix?

Show “verified” only when the recorded postcondition supports it. An Accessibility dispatch is not a completed user goal.

After a turn, `/tmp/macparakeet-voice-control/latest.md` is the wide event (outcome, why, actor, route, last control). `latest.json` joins the steps. Local logs may include the instruction and control labels so a turn can be debugged. Copy diagnostics strips names. Field values, selected text, audio, screenshots, credentials, and remote bodies stay out. A later replay inspects the record; it does not re-execute on the live desktop.

## Native Accessibility only

Install MacParakeet, grant macOS permissions, enable Voice Control, speak to the app already in front of you. No extension, developer mode, native-host registration, CDP, special profile, or browser restart. Web content is a region of the Accessibility tree. An optional connected-tab DOM adapter may supply page candidates later; AX remains the fallback and the Flights path. The earlier extension experiment is [historical](historical-browser-extension/README.md).

## What we will not build

Wake words. Cloud STT or cloud TTS as the default. Keyword soup (`"shutdown" in query`). LLM output executed as AppleScript, JavaScript, pyautogui, or shell. Delay-as-confirmation. Substring `yes` authorizing a payment. A model that can talk the capability floor down.
