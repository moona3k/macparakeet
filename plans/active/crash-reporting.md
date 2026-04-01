# Crash Reporting Implementation Plan

> Status: **ACTIVE**

## Context

MacParakeet had a v0.4.22 incident where users crashed on the onboarding screen but we had **zero visibility** — the crash kills the telemetry service before it can report anything. We need a lightweight crash reporter that persists crash data to disk before the process dies, then sends it as a telemetry event on next launch.

**Design philosophy:** This is Sentry's core architecture distilled to its minimum for a small indie macOS app. No over-engineering — just signal handlers, a file on disk, and a telemetry event.

**Reviewed by:** Gemini + Codex. Findings incorporated below.

## How It Works

```
1. App starts → CrashReporter.install()   (before anything else)
     - Ensures crash directory exists
     - Snapshots version strings + Mach-O UUID into static C buffers
     - Allocates alternate signal stack (sigaltstack) for stack overflow handling
     - Registers signal handlers (SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE)
     - Registers NSSetUncaughtExceptionHandler for ObjC exceptions

2. App crashes → Signal handler fires
     - atomic_flag guards against concurrent entry from multiple threads
     - Formats crash info into pre-allocated buffer using snprintf
     - Captures stack trace via backtrace() (up to 64 frames)
     - Writes to ~/Library/Application Support/MacParakeet/crash_report.txt
     - Uses POSIX functions (open/write/close) + snprintf (safe on Darwin)
     - Restores SIG_DFL then re-raises signal so macOS gets the crash too

3. Next launch → CrashReporter.sendPendingReport(via: telemetryService)
     - Reads crash_report.txt if it exists
     - Sends crash_occurred telemetry event (respects opt-out)
     - Deletes the file unconditionally
```

## Known Limitations (Documented, Accepted)

- **`backtrace()` is not strictly async-signal-safe** — can deadlock if dyld lock is held at crash time. Accepted: pragmatic choice, same tradeoff Crashlytics/PLCrashReporter make. Worst case: one crash report lost.
- **`SIGKILL` (OOM kills) cannot be caught** — fundamental OS limitation.
- **Swift async backtraces not captured** — only physical thread stack, not logical async call chain. No async-signal-safe way to get these.
- **Framework crash addresses** need their own image slide for symbolication. We capture main executable slide + UUID, which covers most crashes. Framework crashes show raw addresses only.

## Implementation Steps

### Step 1: Add `crashOccurred` event type

**File:** `Sources/MacParakeetCore/Services/TelemetryEvent.swift`

- Add `case crashOccurred = "crash_occurred"` to `TelemetryEventName`
- Add to `TelemetryEventSpec`:
  ```swift
  case crashOccurred(crashType: String, signal: String, name: String,
                     crashTimestamp: String, crashAppVer: String,
                     crashOsVer: String, uuid: String,
                     slide: String, stackTrace: String)
  ```
- Add `name` mapping, `props` computation (stack_trace truncated to 1024 chars)
- Add to `TelemetryImplementedContract.requiredProps`

### Step 2: Add `crashOccurred` to immediate flush events

**File:** `Sources/MacParakeetCore/Services/TelemetryService.swift`

- Add `.crashOccurred` to the `immediateEvents` set (line 37-49)

### Step 3: Create CrashReporter

**File:** `Sources/MacParakeetCore/Services/CrashReporter.swift` (NEW)

Single class with two sections:

**Static install section** (C-level, async-signal-safe):
- Pre-allocated 4 KB `[CChar]` buffer for formatting
- Pre-snapshotted C strings: crash file path, app version, OS version, Mach-O UUID (from `SystemInfo.current` + dyld image header)
- `install()`:
  1. Ensures `AppPaths.appSupportDir` exists (mkdir if needed)
  2. Pre-resolves crash file path to C string buffer
  3. Allocates alternate signal stack via `sigaltstack()` (handles stack overflow crashes)
  4. Registers signal handlers for `SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE` using `sigaction` with `SA_ONSTACK`
  5. Registers `NSSetUncaughtExceptionHandler`
- `signalHandler` — `@convention(c)` function that:
  1. `atomic_flag_test_and_set` — only first thread proceeds, others skip
  2. Formats crash_type, signal number, name (static lookup), `time(NULL)` timestamp, pre-snapshotted version/uuid/slide
  3. Calls `backtrace()` for up to 64 frames, formats each as `0x%lx`
  4. Writes to crash file via POSIX `open(..., O_WRONLY | O_CREAT | O_TRUNC)`/`write`/`close`
  5. Restores `SIG_DFL` via `signal(sig, SIG_DFL)` then `raise(sig)` (avoids infinite loop)
- ObjC exception handler — can use normal Swift (not in signal context), captures exception name + sanitized reason + `callStackReturnAddresses`

**Report recovery section** (normal Swift):
- `CrashReport` struct with parsed fields
- `loadPendingReport(from:)` — reads file, parses `key: value` lines + stack trace
- `sendPendingReport(via:)` — loads report → sends `TelemetryEventSpec.crashOccurred` → deletes file
- `crashReportPath` — `AppPaths.appSupportDir + "/crash_report.txt"`

**Key design decisions:**
- **No protocol** — signal handlers are process-global singletons by nature. Testable parts (parsing, telemetry integration) use a `from:` path parameter.
- **Single crash file, not timestamped** — only one crash per launch. New crash overwrites old. No stale file accumulation.
- **File deleted unconditionally** — even if telemetry is disabled. `TelemetryService.send()` handles opt-out internally.
- **Plain text, line-oriented format** — not JSON (too risky to build balanced braces in a signal handler):
  ```
  crash_type: signal
  signal: 11
  name: SIGSEGV
  timestamp: 1711900000
  app_ver: 0.5.1
  os_ver: 15.3.1
  uuid: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
  slide: 0x100000
  --- stack ---
  0x00000001a2f3b4c0
  0x00000001a2f3b4d8
  ```
- **`crash_type` discriminator** — `signal` vs `exception` at top of file, cleaner parsing

### Step 4: Wire into app lifecycle

**File:** `Sources/MacParakeet/MacParakeetApp.swift`
- Add `CrashReporter.install()` as first line of `static func main()`, before everything

**File:** `Sources/MacParakeet/App/AppEnvironment.swift`
- Add `CrashReporter.sendPendingReport(via: telemetryService)` after line 118 (`Telemetry.send(.appLaunched)`)

### Step 5: Add backend support

**File:** `~/code/macparakeet-website/functions/api/telemetry.ts`
- Add `"crash_occurred"` to the `ALLOWED_EVENTS` set (line 78)
- No schema changes — crash data fits in the existing `props` JSON column

### Step 6: Tests

**File:** `Tests/MacParakeetTests/Services/CrashReporterTests.swift` (NEW)

Tests use a temp directory (no real app paths):
- `testLoadPendingReportParsesValidSignalCrash` — write synthetic crash file, verify all fields parsed
- `testLoadPendingReportParsesExceptionCrash` — write ObjC exception variant with reason field
- `testLoadPendingReportReturnsNilForMissingFile`
- `testLoadPendingReportReturnsNilForEmptyFile`
- `testLoadPendingReportHandlesMalformedFile` — partial/corrupt data doesn't crash
- `testSendPendingReportSendsEventAndDeletesFile` — mock telemetry, verify event props + file deleted
- `testSendPendingReportDeletesFileEvenWhenNoService` — no stale crash files
- `testSendPendingReportNoOpWithoutCrashFile`

**NOT tested:** Signal handler installation or actual signal delivery (kills the test process).

## Files Changed

| File | Action | Notes |
|------|--------|-------|
| `Sources/MacParakeetCore/Services/CrashReporter.swift` | NEW | Core crash reporter |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | MODIFY | Add crashOccurred event |
| `Sources/MacParakeetCore/Services/TelemetryService.swift` | MODIFY | Add to immediateEvents |
| `Sources/MacParakeet/MacParakeetApp.swift` | MODIFY | Install crash reporter |
| `Sources/MacParakeet/App/AppEnvironment.swift` | MODIFY | Send pending report |
| `functions/api/telemetry.ts` (website) | MODIFY | Add to allowlist |
| `Tests/MacParakeetTests/Services/CrashReporterTests.swift` | NEW | Test suite |

## Verification

1. `swift test` — all existing tests pass + new crash reporter tests pass
2. Build app via `scripts/dev/run_app.sh`
3. Manually verify: write a synthetic crash file to `~/Library/Application Support/MacParakeet/crash_report.txt`, launch app, check telemetry D1 for `crash_occurred` event
4. Deploy website worker with updated allowlist
