# ADR-033: Explicit Voice Control

Status: ACCEPTED for implementation; release qualification pending.
Date: 2026-09-19.

## Decision

Add user-invoked Voice Control as a deliberate extension to ADR-027's private
speech-memory direction. Speech can express actions on the user's Mac as well
as material to retain. Commands are ephemeral by default and do not enter the
speech library. This surface is distinct from ordinary dictation.

Reuse the process-wide microphone stream and STT scheduler (ADR-016). Command
capture owns its own session and ephemeral audio, but no independent speech
runtime. Raw audio stays local. The final unmodified transcript supplies the
instruction; dictation cleanup, text replacement and paste processing do not.

Jev receives minimized command and relevant UI text after explicit cloud
consent. Credentials belong in Keychain. This extends ADR-011's cloud boundary
with structured decision requests, separate from configured writing providers.
The provider's response selects typed capabilities and observed targets; it
never grants authority or supplies executable code.

A bounded runner retains goals across fresh observations. Separate generation
is needed only for writing/reasoning that selection cannot supply. Native AX, including browser webpage controls, executes local effects with revalidation,
consequence-based action-bound confirmations, revocable authority and explicit outcomes. Goal
completion must be supported by observed evidence, not a model's optimism.

Spoken rewrites reuse ADR-022's configured providers while preserving the
selection captured for the command. They must not recapture an unrelated
selection after a network wait. Ordinary dictation and Transform cancellation
semantics remain unchanged; command insertion stops queued input on revocation.

## Boundaries

No ambient activation, arbitrary shell/code execution, unattended remote
control, or automatic expansion into another browser profile. Normal dictation
never becomes a command. Secure fields are excluded before context creation.
The user may stop locally without waiting for a model response. Already
submitted effects are reported honestly; unknown effects are not replayed.

## Consequences

The capability and compatibility matrix must be qualified per app, browser,
operation and speech engine. A development build and fixture tests do not imply
stable release readiness. The feature remains explicitly enabled and subject to
its evaluation gates. See the [implementation plan](../../plans/active/2026-09-19-jev-voice-control.md).

## User direction amendment — 2026-09-19

Browser control requires no extension, debugging port, special browser profile or
restart. Prior extension integration remains archived research only. Ordinary
reasonably implied steps of an explicit goal are authorized together; mechanical
button/key operations are not alone a reason to ask permission. Payment and
comparable consequential commitments remain deliberate boundaries. Clarification
asks for genuinely missing intent, separately from consequence approval.

Corrections amend the task without erasing actual effect receipts. Manual input
pauses authority while preserving the goal; explicit continuation reobserves and
respects manual edits. Useful live activity may contain task content; bounded
operational traces are local, with a content-minimized shareable copy and a
separate on-disk session log for debugging. There is no automatic upload or
raw audio/screenshot recording. See the linked direction documents in the plan.

## Implementation amendment — 2026-09-20

The DEBUG experiment now includes:

- Native AX for apps and the user's existing browser; no required extension or CDP.
  An optional connected-tab DOM adapter may supply page candidates later; AX
  remains the fallback and the Flights acceptance path.
- Local routes for allowlisted sites, Google Flights form filling, ordinary
  web search boxes, Gmail Compose, and app activation. Jev never receives
  `role=url` destinations.
- Decision machine: `VoiceControlSituation` + enabled events. Unique events
  execute locally. Competing events are one Jev Choice. Return is not enabled
  while a suggestion or date picker is open. See
  `docs/research/2026-09-19-jev-voice-control/architecture.md`.
- Joinable per-step traces plus one wide event per turn (`latest.md`). Local
  logs may include the instruction and control labels; Copy diagnostics omits
  them. Field values stay out.
- Consequence policy that proceeds on ordinary search/navigation/form steps
  and asks only for payment, destructive deletion, or send.

Native Google Flights search completion and integrated microphone
qualification remain separate from this implementation decision.

## Observation amendment — 2026-09-20: two on-device sources

Accessibility is the primary and authoritative observation source. On-device
Vision OCR of the frontmost window is an optional **second** source, opt-in per
user because it needs Screen Recording permission.

- **Targets.** Recognised text that no Accessibility control already names
  becomes a `role: "text"` pressable target with a private pixel centre.
  Accessibility handles are always preferred; a pixel click is the fallback
  only when no handle exists, and its receipt is `unknown` unless transition
  evidence changes. Text targets are offered to Jev only on a plain surface,
  never while a suggestion or date picker is open.
- **State.** Window text in reading order joins the snapshot `summary` under
  the existing cloud-context consent, so Jev and local matchers see prices,
  dates, status lines and result rows the app never labelled.
- **Boundaries.** Pixels never leave the Mac. No image is persisted, not even
  for local debugging. Lines inside secure fields' frames and lines containing
  the secure-word list are dropped before they become targets or state. The
  4,000-character summary cap is unchanged. Screen text is local-log only and
  never enters shareable diagnostics.
- **Not decided here.** Default-on. That waits for replay-corpus measurements
  of latency and clarify rate with and without screen text, per the plan in
  `plans/active/2026-09-20-voice-control-observability-perception-decision.md`.
