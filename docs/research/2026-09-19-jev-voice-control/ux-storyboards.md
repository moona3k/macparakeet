# Voice Control: proposed interaction storyboards

Date: 2026-09-19. **Design proposals, not screenshots or implemented behavior.** These concrete journeys complement the [canonical plan](../../../plans/active/2026-09-19-jev-voice-control.md) and [route catalog](routing-catalog.md). Product states below take precedence over aspirational demo behavior. Copy is illustrative and should be tested with users.

## 1. Hold to inspect, release to act

**Task:** open a specific link in Safari.

| Moment | Speech / gesture | Visible experience | System behavior |
|---|---|---|---|
| Invoke | Hold command key | Small pill: `Listening · Safari` | Confirm capture readiness; observe current page scope |
| Describe | “Open the pricing page” | Live words; subtle outline on Pricing | Local exact match or Jev semantic decision; no click |
| Inspect | User keeps holding | `Open Pricing` beside highlighted link | Preview persists; user can revise without paying a confirmation dialog |
| Correct | “Actually, the enterprise one” | Outline moves; label changes | Revised utterance supersedes prior proposal |
| Commit | Release | `Opening Enterprise pricing` | Final ASR reconciled; target revalidated; one effect |
| Verify | No extra speech | `Opened Enterprise pricing` briefly | Observe destination; dismiss |

The differentiator is that the user controls how much preview time they want. Expert users release immediately; uncertain users hold and correct. Never add an artificial animation delay after a valid commitment just to display a preview.

## 2. “The other one” without starting over

**Task:** choose between two similarly labeled project controls.

The user says “Open the project settings.” Two small labels appear only next to plausible targets: **1 Personal project** and **2 Work project**. The pill asks **Which project?** It does not show confidence percentages or a full accessibility-tree dump.

“Two” identifies the target. The same policy checks still run. If opening settings is a verified navigation action, it opens directly; if the control actually deletes or publishes, its consequence is separately shown. “Not two, one” is a correction, not a substring match for two.

After an incorrect but reversible navigation, “no, the other one” refers to the last compatible candidate/receipt set. Back is allowed only when the current history entry still belongs to our navigation. If the user navigated manually, the reply is **The page changed. Which one do you mean?** and the system redisplays current choices. Never replay an old node ID.

A hold-to-talk invocation can end while the clarification card remains. The microphone is off; a small **Hold to answer** hint and expiry make that clear. The 30-second continuation window is an initial default to evaluate, not a permanent timing requirement.

## 3. Typing feels like typing

**Task:** enter multiple sentences in Notes, including words that sound like commands.

“Type the words click send” inserts **click send**, not a click. This one-shot form ends at release/acoustic endpoint. “Start typing” enters an explicitly persistent mode whose pill says **Typing words · Notes**. Subsequent utterances insert literal text at a bound editor location. Natural punctuation handling follows the documented text-entry mode; it must not silently strip original words like “please” or “now.”

The exact proposed local escape is **command mode** as an isolated utterance. The pill then returns to **Listening for commands**. **command stop** halts queued input from persistent typing. To insert a reserved phrase itself, use **type literally command mode** or spelling. Show this escape in the Typing chip on first use and in Help. Evaluate whether users understand it; do not assume a magic prefix solves the entire mixed-mode problem.

“Replace tomorrow with Friday” highlights a precise range. Duplicate occurrences trigger short numbered range choices. “Make that paragraph shorter” becomes a rewrite through the configured text provider; show **Rewriting selection** and a comparison/acceptance affordance when warranted. The selection snapshot must stay bound throughout speech and generation.

If cancelled midway through insertion: **Stopped after ‘Hello’.** The system does not finish the remaining sentence under an inherited dictation cancellation policy.

## 4. A small sequence stays small

**Task:** “Open Safari, then open a new tab.”

The compact task card shows **Open Safari → New tab**. The first action focuses Safari and verifies it; the second resolves against that newly observed window. This needs a known sequence of capabilities, not a generative planner. A user can say **Stop** between actions; the UI then says **Paused after opening Safari** with Resume/Cancel.

“Type research and development” is one literal insertion. “Select all and delete” is parsed as a sequence only in an explicitly understood editor context, with range/consequence policy; it is not generalized to file deletion. Ambiguous conjunctions get a question rather than a guessed split.

## 5. A larger task shows progress and boundaries

**Task:** “Use this note to draft a reply in Mail.”

1. Capture the user-selected note as a bounded content snapshot. Show its source title, not all background windows.
2. Identify the intended Mail account/thread; ask if ambiguous.
3. If generation sends note contents to a configured cloud provider, honor that branch's disclosure/consent. Jev routing consent alone is not permission for full document upload.
4. Show progress in the same small card: **Reading selected note → Drafting → Placing draft**.
5. Verify the draft is in the intended field. Show **Draft ready in Work Mail**.
6. A separate Send request shows recipient, account and final content. A changed draft invalidates prior approval. If acknowledgement is absent after dispatch: **Couldn’t confirm it was sent. Check Mail before trying again.**

The first release may report this full task unsupported while still providing its qualified direct-control pieces. Never pretend all full-vision storyboards are launch promises.

## 6. Stopping and failure remain understandable

- **Stop:** revoke queued effects, halt motion, pause task, keep an explicitly active command session available for repair. Already-dispatched effects are reported.
- **Cancel:** discard pending task and approvals.
- **Stop listening:** microphone off, task paused. Resume requires fresh invocation/context.
- **Network unavailable:** **Jev is unavailable. Exact commands still work.** Only advertise the local capabilities actually available; no secret fallback to another provider.
- **Missing permission:** **Allow Accessibility to control buttons in Notes.** Offer a focused Settings path; preserve the user's task text locally while setup occurs, then require a fresh context before execution.
- **Unknown target:** **I can’t find that control. Show choices?** A grid/OCR option appears only when supported and enabled.
- **Unexpected app switch:** **Paused because you switched to Mail.** Do not wrest focus back.

For VoiceOver/hands-free use, short spoken state/choice feedback is optional and interruptible. Visual-only users get equivalent feedback. Voice output cannot become command input. All states need accessible labels independent of color/motion.

## First-run teaching and daily discoverability

First-run setup should teach only three successful experiences on local practice content: **open a control**, **correct the target**, **stop**. Then demonstrate the distinction between Dictation and Voice Control, show the active mode and explain the cloud text boundary. Test whether users can repeat these tasks without reading instructions.

“What can I say here?” reveals a small set of available actions derived from the current capability snapshot. A user can pin an optional exact-name/number overlay, but default UI stays quiet. Repeated uncertainty should offer a useful explicit target label or spelling mode, not repeatedly ask the same vague question. Routine successes disappear; partial/unknown outcomes remain inspectable until acknowledged.

## What to test with people

Compare hold-preview-release against immediate-on-endpoint; brief labels against always-visible labels; one-shot insertion against persistent Typing; natural correction against restarting; silent versus optional spoken feedback. Score completed tasks, unnecessary prompts, repair turns, perceived control, mode comprehension and physical effort alongside latency. None of these storyboards is validated merely because it reads smoothly.
