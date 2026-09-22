# Native Google Flights qualification

Native Google Flights **results** and the integrated microphone have not passed. This is the procedure for those remaining gates. Current honesty: [evidence](evidence.md).

Work in this repository on `feat/jev-voice-control`. Do not reset, stash, or switch branches to establish a baseline. Ordinary dictation and Transforms must still work after a Voice Control session.

## Product rules that apply on the real page

Native Accessibility only: no extension, CDP, DOM injection, browser restart, or alternate automation backend. Ordinary authorized steps proceed without repeated confirmation. Payment, destructive operations, and consequential external commitments stay deliberate. Manual input pauses automation while preserving the task. Stop revokes in-flight authority. Unknown effects do not replay.

## Acceptance bar

Use the real page: https://www.google.com/travel/flights?gl=US&hl=en-US

Run in a dedicated window of the existing Chrome process, with the production native adapter, runner, and Jev client. Native tools may inspect the page; distinguish tester intervention from product actions.

1. **Complete search.** Typed goal: `Find one-way flights from Zürich to London on September 20 2026.` (Use an explicitly stated future date if running later.) Verify one-way, origin, destination, date, and displayed flight results. Stop at results; do not book or pay. Typing tests the execution loop, not speech capture.
2. **Contextual correction.** Change London to Paris while the task is active, then correct it back. Preserve the original goal and unaffected fields. Exercise “the other one” against a genuinely ambiguous set.
3. **Manual takeover.** Physically edit a field or use the mouse while automation runs. Confirm pause, preserved progress, and that Continue observes the new state. Moving to an unrelated window must not allow actions there or silently discard the task.
4. **Stop.** During model work and during a pending effect. No new effects afterward. Unknown effects are not replayed. The UI distinguishes stopped, waiting, failed, and completed.
5. **Ordinary versus consequential.** Search, dropdown selection, field editing, and navigation should not repeatedly ask permission. Use a disposable synthetic payment fixture for confirmation, expiry, and uncertain outcomes. Never a real purchase.
6. **Integrated voice.** One complete command through the app’s actual command microphone into native execution, then an ordinary dictation and a voice-to-Transform smoke. A typed harness does not satisfy this check.
7. **Observability.** After a turn, read `/tmp/macparakeet-voice-control/latest.md` first, then `latest.json`. Local logs may include the instruction and labels; Copy diagnostics does not. No keys, raw audio, field values, selected text, or full private page snapshots in shared artifacts.

Report failures as well as successes. Separate correctness from speed.

## Known AX facts on this page

- Trip selector choices are pressable `AXStaticText` with empty labels and AXValue (`One way`, `Round trip`, `Multi-city`). Ordinary list selection is not a consequential commitment.
- The initial page is ~355 AX nodes; form controls sit at depth 22. Traversal is depth 32, 600-node bound. A truncated observation is not proof the goal is satisfied.
- Typed text in an origin field is not a committed airport. A generic interface change is not proof of search results.
- Chrome AX writes become readable asynchronously. Bounded read-only polling verifies the original write; never replay an uncertain write.
- Overlay detection requires a focused suggestion or `Where else?` chrome. Airport names on a results list are the form, not a picker. Return is not enabled while a suggestion or date picker is open.

## Setup

From the repository root, following `AGENTS.md`. Do not use Orca.

```sh
GIT_EXEC_PATH=/opt/homebrew/opt/git/libexec/git-core \
MACPARAKEET_DEBUG_APP_STATE_DIR=/tmp/jev-qualification/app-state \
scripts/dev/run_app.sh --enable-voice-control
```

Configure BYO Jev through the experimental panel. Credentials live in Keychain service `com.macparakeet.voice-control.jev`, account `apiKey`. Never print the key or put it in shell arguments, documentation, screenshots, logs, or commits.

### Synthetic native harness

`scripts/dev/voice-control/run_ax_browser_probe.py` compiles production Types, Diagnostics, TurnRunner, CommandRouter, JevDecisionClient, and NativeVoiceControlAdapter against the loopback fixture. **Guarded to the synthetic fixture only.** Do not relax its URL/title checks to hit real Google Flights: it logs full snapshot context, which is inappropriate for an account-bearing page.

The native fixture must be foreground when execution starts after compilation.

## What a qualification report must say

Exact source revision, dirty state, app build identity, environment, commands, each attempt’s outcome, interventions, timings, failures, and artifact paths. Distinguish typed harness, integrated voice, fixture, and real-site evidence. Preserve waits and failures. Scope recordings to the dedicated window; exclude credentials and account details.
