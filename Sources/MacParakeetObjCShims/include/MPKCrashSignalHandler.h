#ifndef MPKCrashSignalHandler_h
#define MPKCrashSignalHandler_h

#ifdef __cplusplus
extern "C" {
#endif

/// Process metadata snapshotted once at app startup (main thread, before any
/// signal can fire) and read only from the signal handler thereafter. Every
/// field must be a null-terminated C string; `MPKInstallCrashSignalHandler`
/// copies each into a fixed-size internal buffer (truncating if needed), so
/// the caller's backing storage may be freed as soon as the call returns.
typedef struct {
    const char *app_version;
    const char *os_version;
    const char *mach_uuid;
    const char *aslr_slide;
} MPKCrashMetadata;

/// Installs `SA_SIGINFO` handlers for the fixed diagnostic signal set
/// (`SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGFPE`) that write a
/// crash report to `crash_file_path` before re-raising for default
/// (`SIG_DFL`) termination.
///
/// The handler itself performs no allocation and calls no Objective-C/Swift
/// runtime entry point, `dladdr`, or dyld image enumeration; it uses only
/// `snprintf`, `open`, `write`, `close`, `backtrace`, `time`, and `raise` —
/// the async-signal-safe subset documented in Darwin's `sigaction(2)`.
/// `backtrace()` itself is not strictly async-signal-safe (it can in theory
/// deadlock on the dyld lock); this is a known, accepted limitation of this
/// reporter, not a safety guarantee, and other crash reporters (Sentry,
/// PLCrashReporter) making a similar tradeoff does not make it safe here —
/// it is why the minimal report below is written and durable on disk
/// *before* `backtrace()` runs.
///
/// A single atomic guard ensures only the first crashing thread writes a
/// report; a second, concurrently crashing thread re-raises immediately so
/// it terminates via `SIG_DFL` rather than resuming from its own fault site.
/// There is no recover-and-continue path: the process always terminates via
/// the signal's default disposition after (or in place of) writing a report.
///
/// Must be called exactly once, from the main thread, before any other
/// thread starts.
///
/// - Parameters:
///   - crash_file_path: Null-terminated destination path. Copied internally;
///     the caller's storage may be freed after this call returns.
///   - metadata: Copied internally; see field documentation above. May be
///     `NULL`, in which case all metadata fields are recorded as empty.
void MPKInstallCrashSignalHandler(const char *crash_file_path,
                                   const MPKCrashMetadata *metadata);

/// Claims the same single-entry guard the signal handler above uses, without
/// writing a report. Call this from a normal (non-signal) context after
/// writing a richer report through another path — e.g. the ObjC
/// uncaught-exception handler — and before that path might raise a signal
/// (such as the `SIGABRT` the ObjC runtime raises after an uncaught
/// exception's handler chain returns). Without this, the C signal handler
/// would overwrite the richer report with a generic signal report. Idempotent.
void MPKMarkCrashHandlerEntered(void);

#ifdef __cplusplus
}
#endif

#endif /* MPKCrashSignalHandler_h */
