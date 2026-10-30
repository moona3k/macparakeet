# Native Library persistence qualification

`scripts/testing/native-library-e2e.py` drives the real Dev app with macOS
Accessibility. It seeds a synthetic completed meeting through production GRDB
migrations and `MeetingArtifactStore` in a test-only XCTest, opens that exact
Library item, edits its notes through the native editor, waits (with a bounded
read-only check of the owned SQLite database) for the edited notes to persist
durably rather than for the transient visible Saved indicator, requests
ordinary AppKit quit so pending artifact writes flush, relaunches the same
bundle with the same state directory, checks the notes, and exports Markdown
through the UI. The transcript export must contain the synthetic transcript;
the separate durable meeting notes and meeting Markdown artifacts must contain
the edited notes. The UI transcript exporter intentionally does not export
notes. No public seed API is involved and the journey itself never exercises
transcription or the microphone, but ordinary AppDelegate startup can still
warm or download model assets and prompt for microphone access on its own; the
disposable account must have microphone permission denied, and this runner
does not execute inside a network sandbox.

## Prerequisites

Use a **dedicated disposable logged-in macOS account named `macparakeet-e2e`**.
It must own the active console. Do not rename your everyday account or run with
sudo. App state overrides isolate files, but Dev and stable still share some
preferences and Keychain entries. The explicit account attestation is required;
this runner must never run in an account containing valuable app state or keys.

Install Xcode and dependencies, use an owned checkout, and allow at least 25 GiB
free disk. Build once with `scripts/dev/run_app.sh`, complete onboarding manually
in this disposable account, disable optional telemetry/cloud integrations, and
quit the app. Grant Accessibility to the terminal used to run qualification, and
deny microphone permission for the app in this account: ordinary AppDelegate
startup can prompt for or touch the microphone even though the journey itself
never records or transcribes. This account and runner are not network-sandboxed;
only telemetry is explicitly disabled.
Do not run another MacParakeet instance or another UI driver during the journey.
The runner rejects existing app processes before it seeds or builds anything.

```sh
python3 scripts/testing/native-library-e2e.py --disposable-account --preflight-only
python3 scripts/testing/native-library-e2e.py --disposable-account
```

The runner uses `run_app.sh` for the Dev build, including its macro-validation
flag and signing behavior. Subsequent relaunch uses the identical built bundle.
It sends termination only to the exact owned executable path/PID. It never
kills a stable app, clears preferences, touches the clipboard, or deletes data.
Exports remain in this disposable account's Downloads. Each run retains its
fresh temporary state, logs, export copy, fixture ID, and pass/failure result JSON.
A passing result records the checkout commit; a failing result records the
error instead. Record OS/Xcode versions with release qualification evidence.
Failure is nonzero, with bounded commands and AX waits;
missing onboarding/accessibility prerequisites are failures, never passes.

## Verification boundary

The runner and AX helper are executable qualification infrastructure, not a
hosted CI promise. The initial implementation was syntax/type checked and its
ordinary-account rejection was exercised. The real GUI journey remains unrun
until a disposable logged-in account is available. SwiftUI AX exposure, first
launch/onboarding, editor AX writes, and export interaction require that runtime
qualification; no unit-test pass substitutes for it. This does not qualify
physical microphone, Bluetooth, TCC capture routes, paste, models, or signing.
