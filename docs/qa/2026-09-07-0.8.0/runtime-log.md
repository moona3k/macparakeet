# Executed release QA log

Initial candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`. Test fixes are uncommitted until their gates pass. All dates are 2026-09-07, local Pacific time unless noted.

## Environment and isolation

- Owning branch/worktree: `release/0.8.0-qa` in `/Users/dmoon/code/macparakeet-qa`; unrelated original checkout preserved.
- GUI: copy of Xcode Release dev product, renamed/re-signed as `com.macparakeet.qa.release080`, displayed version 0.8.0. This is a QA copy, not a notarized distribution candidate.
- `CFFIXED_USER_HOME` redirects Foundation home/Application Support and the actual open SQLite path; verified with a resolver probe and `lsof`. A unique bundle ID isolates ordinary GUI preferences. Named preference suites and the shared LLM Keychain do not follow that isolation. No saved provider settings/credentials are changed.
- Public FluidAudio model cache cloned with APFS copy-on-write into the temporary home. No personal transcripts/audio/databases copied. All created/deleted QA data is synthetic or a named public corpus fixture. Telemetry disabled per process.
- Built-in computer tool failed with `Sky Computer Use requires the trusted nodeRepl runtime`. Used native macOS AX APIs and per-window `screencapture`, with Accessibility and Screen Capture access verified.
- AX inspection/button presses worked; setting text via AX changed the visible field but did not update its SwiftUI binding. Keyboard/click attempts did not reach the app. The initial AppleScript frontmost query was malformed and misleadingly referenced loginwindow. A corrected query and `IOConsoleLocked = No` established that the desktop is unlocked. Separate terminal tool calls bring cmux forward, so activation and key delivery must happen within one guarded command. Initial typing attempts are not app-failure evidence.
- A stale onboarding window ID failed screenshot capture. Fresh window discovery fixed it. Capture only the app window, exclude Apple/Services menu branches from reusable AX snapshots, and do not publish raw initial recent-item metadata.

## Recovery regression

Command: `MACPARAKEET_TELEMETRY=0 swift test --filter 'MeetingRecordingRecoveryServiceTests.testDiscardWithStaleLock'`.

Observed: build completed; 2 tests ran and failed with 8 assertions. Both same-process and other-live-process finalization fixtures lost their source bytes and lock after stale discard. Raw local evidence: `/tmp/macparakeet-080-qa/evidence/recovery-discard-red.log`. The test uses disposable audio and deterministic ownership, with no timing sleeps or real process termination.

Fix implements the existing finalization ownership claim before discard and restores ownership after a failed operation. Focused green validation is pending. This focused invocation does not consume the reserved full-suite gate.

## GUI observations so far

- Vocabulary Raw and Clean modes render; Manage Words opens a sheet with a search field, empty-state guidance, Add Rule inputs, a disabled Select entry point, and Done. Screenshots retained.
- A native key event sent to the QA PID updated the actual SwiftUI binding; Add saved `QAWidget`, verified independently in SQLite. AX value-setting alone is not equivalent to typing. Modal file-panel buttons invoked synchronously via AXPress can time out; focusing the button and sending Space opens the actual panel. Reusable native helper now supports PID-targeted Unicode and virtual key events, avoiding input into unrelated windows. Bulk deletion and live audio remain pending.

## Running CLI matrix

Exact executable: owning worktree `.build/debug/macparakeet-cli`, reports 3.3.0. Real inference is run sequentially with explicit engine/variant, raw processing, speaker detection off, no history, an owned database path and isolated Foundation home. Each process has a 240-second bound and records command, fixture SHA-256, exit, wall time, JSON and stderr.

Local runner and outputs: `/tmp/macparakeet-080-qa/run-asr.py`, `/tmp/macparakeet-080-qa/audio-runtime/`. Model inventory confirms Parakeet v2/v3/Unified, Nemotron multilingual and Cohere installed; English Nemotron and Whisper Turbo absent in the isolated cache. Installation is not inference proof.

Full Swift suite: **not yet run**. Root owns the single final invocation after fixes converge.

## Desktop scheduling and focused green gates

The user confirmed they are actively using the desktop. Further focus/input, GUI deletion and live capture actions are paused. Native Select mode was captured before that confirmation; no bulk deletion was executed. The 1,024-entry fixture was imported through the actual CLI (one snippet also added), then the QA app was ordinarily restarted and displayed 1,025 rules including the earlier GUI-created word.

Recovery/lock/settlement families: 85 tests passed. Cache regression before the fix: two failures with six assertions out of four cases. After ID scoping: all 23 cache/layout/action tests passed. Commits: `c506d7ef` and `df98cfbd`. The single full-suite gate remains pending.
