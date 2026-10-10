# Voice Control and Jev: refresh code review

Date: 2026-10-09. Read-only review of the clean worktree
a clean worktree on `feat/voice-control-jev-upgrade`
(`edc5df07a`, identical to `origin/main`). The fixes from the
[2026-09-25 deep review](../2026-09-25-voice-control-jev-deep-review.md) are
merged here (anchored web routes, `VoiceControlGoalText`, tail-first spans,
retry on 429/503/529, `input_tokens`).

Scope read in full: `Sources/MacParakeetCore/Services/VoiceControl/` (25 files),
`Sources/MacParakeet/App/VoiceControlCoordinator.swift`,
`Sources/MacParakeet/Views/VoiceControl/VoiceControlPanel.swift`,
`Sources/MacParakeetViewModels/VoiceControlViewModel.swift`, the CLI replay
command, `spec/contracts/voice-control.md`, ADR-033, the research `evidence.md`,
and the Jev docs (`llms.txt`, `models.md`, `confidence.md`, `api.md`,
`model-jaggedness/jev-1.13.md`).

**Line numbers refer to committed `edc5df07a`.** While this review ran, an
uncommitted edit to `JevDecisionClient.swift` (ordered `options` lists, escape
options last, a `withoutTextTwins` filter, `null` criteria for targets) and a
new `scripts/dev/voice_control_jev_eval.py` appeared in the worktree from other
work. I did not touch or review them. That edit appears to address H1 and part
of the duplicated-criteria point; check H1's test recommendation against it.

## How findings were verified

- **Baseline.** `swift test --filter 'VoiceControl|JevLean|JevClient|AXTreeWalk|ScreenTextSource|SpokenDateParser|NativeVoiceControl'`
  from this worktree (scratch build path): 234 tests, 0 failures, 1 skipped
  (the opt-in live E2E).
- **Probe tests.** To avoid editing the worktree, I copied it to a scratchpad
  and added one probe file (`ReviewProbeTests.swift`, not committed anywhere).
  Each probe asserts the current, buggy behavior, so a pass confirms the
  finding. Results are quoted under each finding as "Verified (probe)".
- **Standalone scripts.** Two scratch Swift programs confirmed (a) that
  `JSONEncoder` emits dictionary and struct keys in a different order on every
  process launch, and (b) that cancelling a task blocked in
  `URLSession.data(for:)` throws `URLError(.cancelled)` (code -999), not
  `CancellationError`.
- Everything else is marked "Read" (code reading only). Nothing here was run
  against live Jev, a live microphone or a live app.

Jev usage in this review: none. No request was sent to Jev; all
classification of findings was done by reading code and running local tests.

## Summary

The safety core (revocable authority, consume-once observations, honest
receipts, no replay of unknown effects) is still sound. The top problems are:

1. **Jev option order is random on every app launch** (Swift `Dictionary` ->
   `JSONEncoder`). Jev 1.13 leans toward the first-listed option, so the same
   screen and command can resolve differently after a relaunch, replay is not
   reproducible, and the deliberate "cue tails first" span order never reaches
   the wire. This is the single highest-leverage fix.
2. **Stop during a Jev request is reported as "Jev is unavailable. Check your
   API key and connection."** instead of "Stopped".
3. **Several local routes hijack ordinary sentences** before the page or Jev
   sees them: any mid-sentence ` type `, any `open …` whose words contain the
   app's name (`open the first email` in Mail answers "Mail is already in
   front."), and suffix stripping (`click new tab` becomes a 3-way pick).
4. **The conversation state traps the user.** After any clarification, every
   next utterance is treated as the answer (the contract says unrelated
   instructions start a new task). After a finished task, `undo`, `make it …`,
   `no …` and similar revise the *old* task, which disables the local routes.
5. **Hands-free mode pauses and discards speech on any click, key or scroll**,
   even with no task running.
6. **Latency is dominated by three full Accessibility walks per spoken command
   and serial verification sleeps**, not by Jev. A simple `click Save` costs
   about 2.5 s to "Done"; a Jev-routed one-shot command adds a second Jev call
   because every command is run as an open-ended goal.

## Findings ranked by severity

Severity scale: **High** = wrong effect, wrong user-visible state on a common
path, or systematic decision-quality loss. **Medium** = clunky or misleading on
a common path, or wrong effect on a plausible path. **Low** = edge case, copy,
diagnostics.

### H1. Jev Choice options are serialized in random order on every launch

- **Where.** `JevDecisionClient.swift:604` (`Question.criteria: [String: String]`),
  built at `:92-133` (`kind`, `consequence`, `direction`), `:262-275`
  (`targetCriteria`), `:135-136` (`values`), `:468-470` (`outcome`). Encoded with
  a plain `JSONEncoder()` at `:402` (no `.sortedKeys`, and sorted keys would
  not give a meaningful order either).
- **Scenario.** Swift `Dictionary` iteration order is seeded per process.
  `JSONEncoder` also emits keyed-container (struct) fields in a varying order.
  A scratch program encoding `["finished","none","press","fill","scroll"]`
  printed three different orders across three launches, for example
  `fill, none, press, scroll, finished` and then `finished, press, none, fill,
  scroll`; target ids `n:0 … n:7` came out shuffled with `none` sometimes
  first. The Jev 1.13 jaggedness page says Choice answers lean toward the
  first-listed option. Consequences:
  - The same screen and command can get a different `kind` or `target` after
    an app relaunch. Ties between `press` and `none`, or between two similar
    controls, are broken by the hash seed.
  - `none` / `finished` / `insufficient_evidence` / `clarify` are sometimes the
    first option, which biases toward doing nothing or toward declaring done.
  - `sourceSpans` carefully orders cue tails first (`:524-602`), but the
    `values` dictionary destroys that order before it is sent.
  - `macparakeet-cli voice-control replay --jev` cannot reproduce a recorded
    decision, and the replay-corpus experiments the earlier review recommended
    are confounded by order noise.
- **Verified.** Standalone script (order varies per launch), and probe P6,
  which captures the real request body from `JevDecisionClient`. Four launches
  produced four different `kind` orders: `none, fill, finished, press`;
  `finished, none, fill, press`; `press, none, finished, fill`;
  `finished, none, press, fill`. An escape option was first in three of four.
  The top-level `model` / `state` / `questions` order also changed every run.
- **Fix.** Make every question's options an ordered list on the wire. Either
  build the request body with a small hand-written JSON writer that emits keys
  in insertion order, or use a custom `Encodable` that writes an
  `[(key, value)]` array into a raw-JSON fragment. Pick the order on purpose:
  substantive options in traversal order (targets) or cue-first order (spans),
  and the escape options (`none`, `finished`, `insufficient_evidence`,
  `clarify`) last. Add a test that two encodes of the same request are
  byte-identical and that `none` is last. When the top two probabilities are
  within a small margin on a consequential press, re-ask with the two
  candidates swapped (the Jev docs' self-consistency pattern) or show a pick.

### H2. Stop during a Jev request shows "Jev is unavailable"

- **Where.** `JevDecisionClient.swift:409-416`. Only `CancellationError` is
  treated as cancellation; every other error, including
  `URLError(.cancelled)`, becomes `JevDecisionError.unavailable`. The runner
  then reports it as a failure (`VoiceControlTurnRunner.swift:723-725`), because
  `report` only treats `CancellationError` as a pause.
- **Scenario.** The user says or clicks Stop while the panel shows "Choosing
  the next step…". The coordinator sets "Stopped. Check the app, then choose
  Continue." (`VoiceControlCoordinator.swift:611`), then the runner's
  `.failed("Jev is unavailable. Check your API key and connection.")` arrives and
  overwrites it (`VoiceControlViewModel.swift:105`). The phase becomes
  `.failed`, so the Continue button disappears, and the trace records
  `task failed` with `unavailable` instead of `paused`. Users will read this as
  a key or network problem.
- **Verified.** Script: cancelling `URLSession.data(for:)` throws
  `URLError(.cancelled)`. Probe P5: a runner whose Jev transport throws
  `URLError(.cancelled)` on cancellation ends with
  `.failed("Jev is unavailable. Check your API key and connection.")` after
  `stop()`.
- **Fix.** In `send`, map `URLError.cancelled` (and any error thrown while
  `Task.isCancelled`) to `CancellationError`. In the runner's `decision(...)`
  catch, rethrow `CancellationError` whenever `authority.isValid == false`,
  whatever the underlying error. Add a test with a transport that throws
  `URLError(.cancelled)`.

### H3. A mid-sentence "type" turns the rest of the sentence into typed text

- **Where.** `VoiceControlCommandRouter.typePayload` (`:214-236`), checked
  first in `decide` (`:46-65`).
- **Scenario.** The trailing-clause rule finds the last ` type ` anywhere in a
  single-line command. `what type of file is this` with a focused field inserts
  `of file is this`. `click the file type menu` with no focused field returns
  "Focus one editable field before typing." instead of pressing the control.
  Any request that mentions "type" (font type, blood type, change the type to
  PDF, select the ticket type) is affected, and this route runs before every
  other route, including named presses.
- **Verified (probe P1).** Both cases reproduce exactly as described.
- **Fix.** Accept the trailing clause only after a clause boundary that reads
  as a new command: `now type`, `then type`, `and type`, or after `,` / `.`.
  Never accept it after an article or noun (`the type`, `file type`,
  `what type`). Better: keep only the leading `type …` form locally and let the
  Jev route (H11) handle the rest.

### H4. `open …` containing the app's name answers "already in front"

- **Where.** `VoiceControlCommandRouter.swift:136-149` with
  `requestedApplication` (`:248-256`) and `application(named:matches:)`
  (`:257-261`). `alreadyFront` is `current == requested ||
  current.contains(requested) || requested.contains(current)`.
- **Scenario.** In Mail, `open the first email` gives requested
  `first email`, which contains `mail`, so the router returns
  "Mail is already in front." and does nothing. Same shape: `open the notes
  from yesterday` in Notes, `open message from Sam` in Messages, `open the
  source code` in an app named Code. The reverse containment also activates the
  wrong app: with Arc running, `go to search results` matches `Arc` because
  "search" contains "arc", and the router activates Arc. Because `go to` is a
  prefix, `go to the next page` is also parsed as an app request (it usually
  falls through, but only by luck of app names).
- **Verified (probe P2).** Both the Mail and the Arc cases reproduce.
- **Fix.** Match app names on whole words only, against the full name or a
  known alias (`chrome`, `vs code`), and only when the remainder is just the
  name (allow `the` / `app`). Never answer "already in front" unless the
  request equals the current app's name. Drop `go to` as an app prefix, or
  require the request to equal an app name exactly.

### H5. After a clarification, every utterance is taken as its answer

- **Where.** `VoiceControlCoordinator.dispatch` (`:560-601`):
  `clarification = model.conversation.takeClarification()` routes any text to
  `runner.clarify`. `VoiceControlConversationState.receive` keeps
  `expectedResponse = .clarification` until a pause, cancel, completion or
  failure (`VoiceControlViewModel.swift:10-17`). In the runner, an answer that
  is neither a number nor an exact label while a numbered pick is open just
  re-prompts (`VoiceControlTurnRunner.swift:165-183`).
- **Scenario.** Many local routes end with a clarification ("Which part of the
  window should I scroll?", "Focus one editable field before typing.", "Which
  control should I use? Please say its full label."). The user then says a
  different command, for example `open Safari`. It is appended to the old goal
  as `User clarification: open Safari`. The amended, multi-line goal no longer
  matches any local route (they all test `lower.hasPrefix(...)` on the whole
  goal), so it goes to Jev with the stale task and history. With a numbered
  pick open, a new command re-prompts "Which one? Say the number." until the
  user says a number, `cancel` or `stop`. The contract says the opposite:
  "Unrelated instructions start a new task; clarification answers retain their
  pending response" (`spec/contracts/voice-control.md:214`).
- **Verified.** Read. (The coordinator is in the app target and has no unit
  tests; the router half, that an amended goal skips local routes, is shown in
  probe P18.)
- **Fix.** Classify the utterance before treating it as an answer: a number or
  ordinal, an offered label, or a short noun phrase is an answer; anything that
  parses as a local command (leading verb such as `open`, `click`, `type`,
  `scroll`, `go to`, a reserved key, help) starts a new task. This is a good
  bounded Jev Noul ("Is this utterance an answer to the question, or a new
  instruction?") when local rules are unsure. Also let the router evaluate the
  newest user segment for local routes, not the whole scaffold.

### H6. After a finished task, `undo`, `make it …` and `no …` revise the old task

- **Where.** `VoiceControlConversationState.isCorrection`
  (`VoiceControlViewModel.swift:18-21`) includes `undo`, `make it`, `not `,
  `no `, `change the`, `instead`, `the other`. The coordinator treats a match
  as a correction whenever `model.goal` is non-empty
  (`VoiceControlCoordinator.swift:564-566`), and `model.goal` is only cleared on
  cancel or End. The runner's `hasTask` stays true after completion
  (`VoiceControlTurnRunner.swift:90`), so `revise` amends the finished task.
- **Scenario.** `type hello` completes. The user says `undo`. Instead of the
  local undo route (`VoiceControlCommandRouter.swift:150-154`), the runner
  builds `Continue this task … Original goal: type hello / User correction:
  undo`, the router misses every local route, and the decision goes to Jev
  (cloud, slower, and Jev may or may not pick the synthetic undo target). The
  same happens to `make it shorter` (meant as a rewrite), `no thanks`, or
  `change the title to …` in a new context.
- **Verified (probe P18, router half).** `undo` alone routes locally to the
  undo target; the amended goal falls through to the fallback engine.
- **Fix.** A completed, failed or cancelled task is not revisable: clear the
  runner goal (or mark it closed) on `.completed`, and only treat corrections as
  revisions while a task is paused, awaiting clarification, or running. Remove
  `undo` from the correction prefixes; it is a command. Route local commands on
  the newest user segment even inside an amended goal.

### H7. Hands-free mode pauses and drops speech on any click, key or scroll

- **Where.** `VoiceControlCoordinator.handleExternalInput` (`:179-205`) with the
  global and local monitors (`:156-178`, mask includes `.leftMouseDown`,
  `.scrollWheel`, `.keyDown`). The lease is held for the whole hands-free
  session because `releaseFinishedSessionIfMicOff` requires the mic to be off
  (`:530-547`).
- **Scenario.** Hands-free listening, no task running. The user clicks into a
  text field to focus it, intending to say `type hello` (the help text and the
  "Focus one editable field" clarification both tell them to focus a field).
  The click revokes pending transcripts, discards the utterance in progress,
  sets phase `.paused`, and shows "You have control. Make your correction, then
  choose Continue." There is nothing to continue. Scrolling the page with the
  trackpad while speaking has the same effect.
- **Verified.** Read.
- **Fix.** Only treat external input as a manual takeover while the runner has
  live work (`runner.hasLiveWork`) or a pending confirmation. With no live
  work, ignore input (or only cancel a pending confirmation). Never discard an
  utterance that is still being spoken because of a click.

### H8. Jev-routed one-shot commands run as open-ended goals

- **Where.** `VoiceControlTurnRunner.run` (`:477-576`) loops observe/decide
  after every successful effect. The router stops locally only for exact named
  presses and local direct routes (`VoiceControlCommandRouter.swift:28-45`,
  `:100-103`). The unconstrained Jev `kind` question says "Choose finished only
  when every goal condition is visible" (`JevDecisionClient.swift:111`).
- **Scenario.** `press the blue submit thing`, `go to the next page`, `open the
  second result`. After Jev's press succeeds with a transition, the runner
  re-observes and asks Jev again. That costs a second Jev round trip on every
  semantic command. Worse, a literal reading of "go to the next page" on a page
  that still shows a Next button can choose `press Next` again. Duplicate
  protection does not stop it, because the pre-state changed. The loop ends
  only when Jev says `finished`, two observations are unchanged, or the 40
  effect budget runs out.
- **Verified.** Read. Not tested against live Jev.
- **Fix.** Add a `scope` head to the first unconstrained request (single
  action versus multi-step goal; one more head in the same fan-out costs
  almost no latency). When it says single action, finish after one verified or
  transition receipt, as the named-press path already does. Keep the loop for
  explicit multi-step goals.

### M1. Low-confidence decisions dead-end instead of offering numbered picks

- **Where.** `JevDecisionClient.resolveLean` (`:317-336`), `choose` (`:488-491`).
- **Scenario.** When `min(kind, target)` is below 0.5, the user gets "Which
  control should I use? Please say its full label." or "Please describe the next
  step more specifically." Jev already returned the full probability map, and
  the runner already supports numbered picks (`.pick`). For competing picker
  rows (`outcome`), a low-confidence answer is exactly the case where "1. Zürich
  HB  2. Zürich Airport" is the right UX.
- **Verified.** Read.
- **Fix.** When the target head's top two or three options hold most of the
  mass (for example a cumulative 0.8) and the kind is confident, return
  `.pick` with those labels. For `outcome`, return a pick over the top events.
  Keep the plain clarification only when the mass is spread.

### M2. Near-duplicate value spans split probability below the gate

- **Where.** `JevDecisionClient.sourceSpans` `offer` (`:554-565`) adds both the
  raw span and a punctuation-trimmed copy. The value gate is `>= 0.5`
  (`:170`, `:356`).
- **Scenario.** ASR text `set the destination to London.` offers both
  `London.` and `London` (and more near-duplicates such as `to London`). If
  Jev splits mass roughly evenly between the two London variants, the top
  probability is about 0.5 and, with about 250 options, confidence
  `(n * p_max - 1) / (n - 1)` is just under 0.5. The turn then asks "What exact
  text should I enter into Where to?" although the answer is clear.
- **Verified.** Read, plus the Jev confidence formula from `confidence.md`. Not
  measured live.
- **Fix.** Offer only the trimmed form when the raw form differs only by
  boundary punctuation, or group equivalent spans and gate on the summed
  probability in code. Also avoid offering both `X` and `X` with trailing
  filler.

### M3. The follow-up value request re-sends the entire state

- **Where.** `JevDecisionClient.swift:160-183`. The comment says "One more
  small request", but it reuses `state` (full observation, summary, history).
- **Scenario.** Any fill into a field that is not focused (most form steps)
  costs two sequential Jev calls with the same state. That is about 300 ms of
  extra latency and double the input tokens per fill step.
- **Verified (probe P7).** With 120 targets and a 4 KB summary, the first
  request was 28,823 bytes and the follow-up 23,810 bytes; both carried the
  same 23,046-byte `state`. The follow-up is 83% of the first request.
- **Fix.** Add one target-agnostic value head to the first request whenever
  any offered field is editable ("Which exact span of the user's words is the
  value for the next field to fill?"). Fall back to the follow-up only when
  that head is below the gate or the target turns out to be a different field
  with a different value. If the follow-up stays, send a reduced state (goal,
  the one target, history) instead of the whole observation.

### M4. Every spoken command performs three full observations

- **Where.** Invocation snapshot at key-down
  (`VoiceControlCoordinator.swift:321-325`, `:366-369`), awaited before submit
  (`:585-589`); the runner's first observation (`VoiceControlTurnRunner.swift:490`);
  and the post-effect observation the loop needs before it can report done.
  Typed panel submissions do a full `adapter.observe()` before submit as well
  (`needsSnapshot`, `:578`, `:585-586`).
- **Scenario.** The invocation snapshot is used only to check a rewrite's
  selection (`VoiceControlCommandRouter.swift:167-177`), yet it is a full AX
  walk plus optional OCR (measured 620 ms in Notes, 844 ms in Chrome Gmail,
  2.1 s capped in Finder, per `evidence.md`). It also resets the adapter's
  handle table, so it cannot be reused. If the user speaks briefly, the turn
  waits for it. A simple `click Save` spends roughly: STT final pass 0.2-0.3 s,
  observation 0.6-2 s, press plus verification 0.5-1.5 s, then a second
  observation 0.6-2 s before "Done".
- **Verified.** Read. Timings are from the existing evidence table, not new
  measurements.
- **Fix.** (a) Capture only the focused element's selection at invocation, not
  a full walk, and only await it when the command is a rewrite. (b) Reuse a
  fresh invocation snapshot as the runner's first observation when it is under
  about 1 s old, the context id matches, and no external input arrived; execute
  already revalidates the fingerprint. Or start the runner's observation at
  key-up, in parallel with the STT final pass. (c) For local direct routes
  whose receipt is `verified`, finish without the post-effect observation.

### M5. Press verification adds serial sleeps and a pre-press walk

- **Where.** `NativeVoiceControlAdapter.execute` `.press` (`:477-517`):
  `transitionEvidence()` before the press (a walk bounded at 200 nodes or
  350 ms, `:684-711`), then 120 ms, then up to 3 x (120 ms + another evidence
  walk). Keys: up to 4 x 120 ms (`:542-553`). Web destinations: a fixed 1.8 s
  sleep (`:352`). Combo-box fill: a fixed 450 ms (`:461-463`).
- **Scenario.** An ordinary button that does not change structure costs about
  1.5 s before returning `unknown`. A navigation costs at least the pre-press
  walk plus 240 ms. The 1.8 s website sleep is paid even when the page loads in
  300 ms.
- **Verified.** Read.
- **Fix.** Drop the pre-press evidence walk and compare post-press evidence
  against the observation already taken (the fingerprint check already
  guarantees the target is unchanged). Poll the destination for a URL or title
  change with a timeout instead of sleeping 1.8 s. Return as soon as the first
  evidence differs (already done) and shorten the first wait.

### M6. Chrome observations pay a pre-walk, and 250 ms when no web area exists

- **Where.** `enableChromiumAccessibilityIfNeeded` (`:873-890`) and
  `hasPopulatedWebArea` (`:891-907`).
- **Scenario.** Every Chromium observation first runs a separate DFS of up to
  400 nodes (2 AX IPCs each) looking for a populated `AXWebArea`. When the front
  window has none (settings, a new-tab page, a PDF, a download bubble, or a
  page that has not rendered yet), it re-sets the flags and sleeps 250 ms on
  every observation.
- **Verified.** Read.
- **Fix.** Remember per pid that the flags were applied and only repeat when
  the walk itself finds an empty web area. Let `AXTreeWalk` report "web area
  present but empty" so no separate pre-walk is needed.

### M7. The candidate pass repeats AX reads and has no time budget

- **Where.** `NativeVoiceControlAdapter.observe` (`:149-188`), `isSecure`
  (`:815-821`), `fingerprint` (`:974-981`), `ancestorIsWebArea` (`:928-936`).
- **Scenario.** The walk already read role, label, frame and value in one
  batched IPC per node. For each kept candidate, the adapter then reads value,
  enabled, two settability checks, subrole plus the three label attributes
  again (`isSecure`), selection, and a fingerprint that re-reads role, subrole,
  three labels, value, enabled, URL and selected range. That is roughly 15-20
  more IPCs per candidate, plus up to 24 parent hops in browsers when the walk
  did not already know the web-area ancestry. With 150-200 candidates in a web
  page that is thousands of IPCs, each with a 150 ms timeout, and none of it is
  inside the walk's 2 s budget. `metrics.walkMilliseconds` also includes this
  pass and the OCR wait (`:304-307`), so the `walk:` log line misattributes it.
- **Verified.** Read.
- **Fix.** Add subrole, enabled, URL and selected range to the batched walk
  read, and build the fingerprint and secure check from those facts. Give the
  candidate pass its own deadline and mark the snapshot partial when it
  expires. Log walk, candidate pass and OCR wait as separate numbers.

### M8. Keyword floor confirms ordinary nouns as payment or send

- **Where.** `VoiceControlConsequencePolicy.consequence`
  (`VoiceControlDiagnostics.swift:325-371`). Any label of five words or fewer
  that contains `order`, `booking`, `share`, `post`, `send` and so on.
- **Scenario.** `Sort order`, `Order history`, `Booking details` all ask
  "Confirm payment on Sort order? Cancel task stops here. Nothing is paid."
  `Share` asks "Confirm send". A model label cannot lower these by design, so
  the friction is permanent.
- **Verified (probe P10).** All four labels classify as non-ordinary.
- **Fix.** Count a floor word only when it leads the label as an imperative
  (`Order now`, `Place order`, `Send`, `Share to …`), or when it is the whole
  label. Keep nouns such as `Sort order` and `Order history` ordinary unless
  the target's own consequence metadata says otherwise.

### M9. Suffix stripping turns exact labels into picks

- **Where.** `VoiceControlLocalTools.spokenControlName` (`:91-93`) strips
  ` tab`, ` menu`, ` button`, ` link` before matching; `matchingControls`
  only matches the stripped phrase (`:104-118`).
- **Scenario.** `click new tab` in Safari or Chrome with `New Tab`, `New
  Window` and `New Private Window` visible: the phrase becomes `new`, exact
  match fails, prefix match finds all three, and the user gets "Which one? Say
  the number." for a command that named one control exactly. Same for `click
  the Format menu` when a `Format` and `Format menu` both exist, or a tab named
  `Settings tab`.
- **Verified (probe P4).** Returns a three-way pick.
- **Fix.** Try an exact match on the unstripped phrase first; strip suffixes
  only if that fails.

### M10. Web fills and form plans use `setValue` without the typing fallback

- **Where.** `VoiceControlWebQuery.nextAction` (`:27-31`) and
  `VoiceControlFlightPlan` (`:84-105`) emit `.setValue`; Jev fills prefer
  `.setValue` when offered (`JevDecisionClient.swift:176`, `:349-351`). The
  adapter's HID typing fallback runs only for `.insertText`
  (`NativeVoiceControlAdapter.swift:444-458`), and its own comment says Chrome
  search fields can accept an AX write while the value never changes.
- **Scenario.** In Chrome, a `setValue` whose readback never matches returns
  `unknown`. The runner pauses ("could not be verified … will not be
  repeated") and the effect is blocked from retry, so the task stalls on the
  first field.
- **Verified.** Read. Not reproduced live; the evidence doc notes setter
  timing issues in Chrome.
- **Fix.** Use `.insertText` (select-all then type, or the existing selection
  path) for web fields, or give `.setValue` the same "value did not move, type
  into the focused control" fallback.

### M11. Panel feedback does not name the target, and picks are text only

- **Where.** `VoiceControlViewModel.apply` (`:89-111`),
  `VoiceControlPanel.swift:57-145`.
- **Scenario.** While acting, the message is "Applying the next step…" and the
  activity line is "Attempting: press" (raw operation name, no label). Before
  acting there is no highlight of the chosen control, so a wrong target is
  discovered only after the effect. Numbered picks appear as a multi-line
  message ("Which one? Say the number. 1. … 2. …") with no clickable rows and no
  on-screen badges, so two identical "Reply" buttons cannot be told apart
  except by order. The panel is a fixed 470 x 470 floating window pinned top
  right, with diagnostics, a text field and five or six buttons always visible,
  far from where the user is looking.
- **Verified.** Read.
- **Fix.** (a) Show the target label in the acting message ("Clicking
  ‘Search flights’…"). (b) Draw a brief highlight around the target frame (the
  adapter already has `BoundTarget.frame`) for about 300 ms before a Jev-chosen
  press; for picks, draw numbered badges at each candidate's frame and render
  the options as clickable rows. (c) Collapse the panel to a compact HUD
  (status line, transcript, mic level, Stop) and move setup and diagnostics
  behind a disclosure.

### M12. Error mapping hides auth and size failures

- **Where.** `JevDecisionClient.send` (`:425`): every non-200 that is not
  retryable becomes `.unavailable` ("Check your API key and connection.").
- **Scenario.** A 401 (revoked key), a 400 or 413 (state over Jev's 32k-token
  state limit, which the local 120 KB byte cap does not guarantee), and a 500
  all show the same message. A large page that exceeds the token limit looks
  like a network problem rather than "focus a smaller window".
- **Verified.** Read; limits from `models.md`.
- **Fix.** Map 401/403 to a key error, 400/413/422 to `contextTooLarge`, and
  keep `.unavailable` for 5xx and transport errors. Calibrate the byte cap with
  the recorded `input_tokens`.

### M13. Toggling screen text says "End, then Start" but needs an app relaunch

- **Where.** `VoiceControlCoordinator.swift:105-112`. The adapter is created
  once in `AppDelegate.swift:723-727` and stored as `let adapter` in the
  coordinator; End and Start reuse it.
- **Scenario.** The user enables Vision screen text, follows the instruction to
  End and Start, and still gets no screen text until they quit the app.
- **Verified.** Read.
- **Fix.** Let the adapter read the setting per observation, or rebuild the
  adapter in `ensureSession`. At minimum change the copy to "Quit and reopen
  MacParakeet to apply."

### M14. Confirmation decline copy says "skips this press" but cancels the task

- **Where.** `VoiceControlConfirmationCopy.prompt`
  (`VoiceControlSessionGrammar.swift:110`) versus `VoiceControlCoordinator.swift:497-503`
  (`no` calls `cancelTask`, which clears the goal and history).
- **Scenario.** "I can’t tell what Continue does. Press it anyway? Cancel task
  skips this press." Saying `no` discards the entire task, not just the press.
  The contract table also lists `okay` as a confirmation
  (`spec/contracts/voice-control.md:193`), while the grammar deliberately
  rejects `ok` / `okay` (`:349`).
- **Verified.** Read.
- **Fix.** Offer a real "Skip this step" (decline, keep the task, re-observe and
  ask what to do next) and keep "Cancel task" separate. Fix the contract row.

### M15. Local `scroll down` dead-ends whenever there is more than one scroll area

- **Where.** `VoiceControlCommandRouter.swift:155-161`; scrolling requires a
  settable scroll bar (`NativeVoiceControlAdapter.swift:555-574`).
- **Scenario.** Most windows have a sidebar plus content, so `scroll down`
  answers "Which part of the window should I scroll?", and that clarification
  then captures the next utterance (H5). In browsers, the web content's outer
  scroll area sits outside the web area and is filtered by
  `keepOfferedControl` (`:921-927`), and Chromium does not expose a settable
  scroll bar, so web scrolling may not be possible at all.
- **Verified.** Read. The Chromium part is a risk, not reproduced.
- **Fix.** Prefer the scroll area that contains the focused element, else the
  largest visible one. For browsers, post scroll-wheel or Page Down events to
  the window instead of setting a scroll bar value.

### L1. Transition evidence counts live text as a transition

- **Where.** `transitionEvidence` (`NativeVoiceControlAdapter.swift:684-711`)
  includes `AXStaticText` values.
- **Scenario.** A clock, a video timestamp, a streaming chat or a progress
  label changes within 120 ms, so a press that did nothing is reported as
  `transitionObserved`. For a one-shot named press, `alreadyPressedByName` then
  finishes the task as if it worked.
- **Fix.** Exclude static text from the evidence, or require a change in
  controls, focus, URL or window rather than only text.

### L2. Page-match hints are substrings of the whole page

- **Where.** `VoiceControlWebDestination.pageMatches` (`:159-167`).
- **Scenario.** Any page whose text contains "youtube" ("Watch on YouTube")
  counts as YouTube, so `open YouTube` does not navigate. Any travel site with
  "Where to?" counts as Google Flights, so `VoiceControlFlightPlan` drives
  Kayak's form with Google Flights assumptions.
- **Fix.** Match on the window title or the URL (`AXURL` of the web area),
  which the adapter can read once per observation.

### L3. `walkMilliseconds` reads the clock twice

- **Where.** `NativeVoiceControlAdapter.swift:306-307` computes seconds from one
  `.now` and attoseconds from another. Near a second boundary the value is off
  by almost 1 s. It also includes the candidate pass and OCR wait (M7).
- **Fix.** Compute one `Duration` and convert it once.

### L4. Stale invocation snapshot reuse

- **Where.** `VoiceControlCoordinator.swift:580-589`. When
  `shouldPauseForSpeech` is false (a confirmation or clarification is
  pending), no new invocation task starts, and dispatch awaits the previous
  capture's task.
- **Scenario.** A rewrite spoken as a clarification answer validates against an
  old selection and returns "The original selection changed".
- **Fix.** Clear `invocationSnapshotTask` at each capture start; see M4 for
  replacing it with a selection-only read.

### L5. Gate semantics depend on option count

- **Where.** `JevDecisionClient.gate = 0.5` applied to every head.
- **Note.** Jev Choice confidence is `(n * p_max - 1) / (n - 1)`. The same 0.5
  gate means `p_max >= 0.67` for a three-option `kind`, `>= 0.6` for five, and
  about `0.5` for a 200-option `target`. That is defensible, but it is not
  documented, and adding or removing a `kind` option (for example `scroll`)
  silently changes the bar. Write it down next to the gate, or gate on
  `p_max` per head.

## Jev usage quality

| Aspect | Current | Assessment |
|---|---|---|
| Option order | Random per launch (H1) | Fix first; it confounds every other measurement. |
| Ordering bias (focused/editable first) | `prioritised` only decides which 200 survive truncation (`:200-220`), then sorts back to traversal order; wire order is random anyway | After H1, choose order deliberately: traversal order for targets, escape options last. Do not put the focused field first by default; that converts the first-option lean into a focus bias. |
| Criteria duplication | Every target is in `state.observation.targets` as JSON (id, label, role, value, operations, isNavigation, isFocused, selectedText, valueIsComplete, consequence, isOffscreen, region) and again as a criteria sentence | Still true from the earlier review. Send targets once: compact criteria sentences with `null`-free state, or a compact `state.controls` line list. Also drop the snapshot UUID, `contextID` and `isComplete` noise. |
| State size | Up to 200 targets, 4 KB summary, up to 24 KB of value spans, history; 120 KB byte cap | The 120 KB cap is not tied to Jev's 32k-token state limit (M12). Spans dominate long goals. With H1 fixed, measure `input_tokens` and cut spans first (the jaggedness page lists large irrelevant state as a known failure). |
| Gate | 0.5 on `min(kind, target)`, `kind` alone for finished/none, 0.5 on `outcome` and `value` | Reasonable; see L5 and M1 (use the probabilities for picks rather than a dead-end). |
| Consequence head | Five-way Choice on every unconstrained request; argmax only | Still advisory and useful for unlabeled "Confirm" buttons. Per-hazard Nouls remain the better primitive (earlier review). Low priority. |
| Value spans | Tails first, then all spans up to 12 words, raw plus trimmed duplicates | Order lost (H1); duplicates split mass (M2). |
| Follow-up value request | Second sequential call with the full state | M3. |
| Calls per turn | Local exact command: 0. Jev press: 1, plus 1 more for the post-effect "finished?" check (H8). Unfocused fill: 2, plus the post-effect check. Picker rows: 1 `outcome`. A 3-field form: about 3 x (1-2) + checks, so 6-9 sequential calls. | H8 and M3 together remove roughly half of the calls on common paths. |
| Connection reuse | `URLSession.shared`, no warm-up | The first decision in a session pays DNS and TLS. A content-free `GET /v1/models` at key-down would hide it behind speech (it sends no user data, but confirm it stays within the consent text). |
| Timeout | 15 s per attempt, up to 3 attempts | Up to about 45 s of "Choosing the next step…" before an error. A 5 s per-attempt timeout matches a voice UX better. |

## Latency budget (reading-based)

Measured inputs: observation 620 ms (Notes), 844 ms (Chrome Gmail), 2.1 s
capped (Finder) from `evidence.md`; synthetic Jev calls 216-297 ms median
about 240-300 ms. Everything else is from code constants.

| Stage | `click Save` (local) | `press the blue submit thing` (Jev) | Where |
|---|---|---|---|
| Hold tail after key-up | 200 ms | 200 ms | `AppHotkeyCoordinator.holdToTalkStopTailMs` |
| STT final pass (preview is display-only) | 150-300 ms | 150-300 ms | `VoiceControlSpeechSession.commit` |
| Wait for invocation snapshot | 0-2 s (if speech was shorter than the walk) | same | M4 |
| Observation 1 | 0.6-2 s | 0.6-2 s | adapter `observe` |
| Decision | under 1 ms | 250-500 ms | router / Jev |
| Pre-press evidence walk + press + verification | 0.4-1.5 s | 0.4-1.5 s | M5 |
| Observation 2 | 0.6-2 s | 0.6-2 s | runner loop |
| Second decision | under 1 ms (local "already pressed") | 250-500 ms | H8 |
| **Effect visible** | about 1.4-4 s after key-up | about 1.7-4.5 s | |
| **"Done" shown** | about 2-6 s | about 2.5-7 s | |

Hands-free adds 900 ms of required silence before the STT pass.

What to parallelize or cache, in order of payoff:

1. Start the runner's first observation at key-up, in parallel with the STT
   pass, or reuse a fresh invocation snapshot (M4).
2. Replace the invocation walk with a selection-only read (M4).
3. Finish local verified commands and single-action Jev commands without the
   second observation and decision (M4c, H8).
4. Remove the pre-press evidence walk and fixed sleeps (M5).
5. Batch the candidate-pass reads into the walk and skip the Chromium pre-walk
   (M6, M7).
6. Put the value head in the first request (M3).
7. Pre-warm the Jev connection at key-down.

## Architecture: what to cut or simplify

The earlier review's architectural points are all still true: the router is an
ordered if-chain of substring rules that runs before the page; site macros
(Flights, YouTube, Gmail Compose, Maps, Wikipedia, Google Search) live in core
and leak into generic legality (`VoiceControlSituation` keys on "Where else",
`isOverlayChrome` keys on "departure" and "dates"); target ids are walk
positions; and the per-step classifier is used as a planner. New observations:

- **Order of the chain (19 branches)** in `VoiceControlCommandRouter.decide`:
  help, verified-direct completion, type, replace, reserved key, already
  verified, already pressed, web destination, flight plan, web query, Gmail
  compose, browser for web goal, app request, undo, scroll, rewrite, named press,
  competing landings, Jev. Three of the confirmed bugs above (H3, H4, M9) come
  from early branches matching inside sentences meant for later branches. The
  fix pattern is the same for all of them: local branches must match the
  *whole* utterance (exact grammar), and everything else goes to one Jev
  request with a `route` head.
- **The router only sees the whole amended goal.** Because local routes test
  `lower.hasPrefix(...)` on the full scaffold text, any task with a correction or
  clarification loses every local route (H5, H6). Route on the newest user
  segment; keep the scaffold only for the Jev state.
- **`isCorrection` prefix list belongs in the same place as the grammar.**
  Today the correction/new-task decision lives in the view model, the grammar
  in core, and the clarification capture in the coordinator. One function,
  "classify this utterance against the current conversation state", in core
  with unit tests, would make H5 and H6 testable.
- **Candidates to cut** if the product is "command and control first" (the
  earlier review's option A): `VoiceControlFlightPlan` (325 lines), the
  Flights strings in `VoiceControlSituation` / `VoiceControlLegality`,
  `VoiceControlNamedPageAction` (Gmail Compose only), `VoiceControlWebQuery`
  site prefixes, and the allowlisted destinations injected into every browser
  snapshot. Keep `open <site>` as a plain URL route if wanted. About 600 lines
  and roughly half of the router tests go with them.
- **Keep:** `ActionAuthority`, receipts, duplicate and uncertain-effect
  blocking, consequence floor (with M8 fixed), `AXTreeWalk` and its tests, the
  trace store and replay CLI (more valuable once H1 makes replay
  deterministic).

## Test coverage gaps

- No test exercises cancellation through a real-shaped transport error
  (`URLError(.cancelled)`) (H2).
- No test asserts the wire order or byte stability of a Jev request (H1).
- No negative tests for the trailing `type` clause, app-name containment, or
  suffix stripping with an exact unstripped label (H3, H4, M9).
- The coordinator (clarification capture, correction detection, external
  input takeover) has no unit tests because it lives in the app target. Moving
  the utterance classification into core would make H5, H6 and H7 testable.
- All evidence remains fixture-only. There is still no live
  microphone-to-effect latency number and no wrong-target rate.

## Appendix: probe results

The probe file lived only in a scratchpad copy of this worktree
(`Tests/MacParakeetTests/VoiceControl/ReviewProbeTests.swift`, built with its
own `--scratch-path`). Nothing was added to the worktree except this report.
Each probe asserts the current, buggy behavior, so a pass confirms the
finding. All 8 passed.

| Probe | Finding | Observed output |
|---|---|---|
| P1 | H3 | `what type of file is this` -> `insertText "of file is this"`; `click the file type menu` -> `clarify("Focus one editable field before typing.")` |
| P2 | H4 | Mail, `open the first email` -> `information("Mail is already in front.")`; Finder with Arc running, `go to search results` -> `activateApp app:1` (Arc) |
| P4 | M9 | `click new tab` -> `pick` over `New Tab`, `New Window`, `New Private Window` |
| P5 | H2 | Runner + `JevDecisionClient`, `stop()` mid-request -> last event `failed("Jev is unavailable. Check your API key and connection.")` |
| P6 | H1 | `kind` wire order differed on each of four launches; escape option first in three |
| P7 | M3 | Request bytes `[28823, 23810]`, `state` bytes `[23046, 23046]` |
| P10 | M8 | `Sort order`, `Order history`, `Booking details` -> `payment`; `Share` -> `externalCommitment` |
| P18 | H6 | `undo` -> local `press undo`; the same `undo` as a correction of `type hello` -> fallback engine |

Standalone scripts (scratchpad only): `JSONEncoder` key order across three
launches (three different orders), and `URLSession.data(for:)` cancellation
(`URLError` code -999, `.cancelled`).
