#ifndef MPKCrashSignalHandler_h
#define MPKCrashSignalHandler_h

#include <stddef.h>
#include <stdint.h>

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
    const char *crash_id;
    const char *crash_session;
    const char *os_build;
    const char *shared_cache_uuid;
    const char *shared_cache_slide;
} MPKCrashMetadata;

/// Optional system identity, read once in NORMAL startup context only. Failure
/// leaves the unavailable fields empty. Uses SDK-public Mach/sysctl interfaces.
typedef struct {
    char os_build[32];
    char shared_cache_uuid[37];
    char shared_cache_slide[24];
} MPKCrashSystemMetadata;
void MPKReadCrashSystemMetadata(MPKCrashSystemMetadata *metadata);

/// Normal-time, content-free observation. No I/O, allocation, formatting or
/// waiting. Records may be dropped under competing writers. The opaque payload
/// is the versioned CrashAudioContext numeric schema, never a pointer/string.
void MPKRecordCrashBreadcrumb(uint64_t value);
/// A process-local attempt token, NOT an engine generation. Zero on exhaustion;
/// tokens never repeat. Allocation uses a single atomic operation.
uint32_t MPKNextCrashAttempt(void);
/// Independent workflow registry snapshot (0 none, 1 dictation, 2 meeting,
/// 3 both). This is not a statement of microphone hardware activity.
void MPKSetCrashRegisteredConsumers(uint32_t consumers);
/// Copies bounded metadata and up to 32 complete numeric breadcrumbs into the
/// caller's buffer, returning bytes written (not NUL-terminated). No allocation,
/// I/O, locks or retries; safe in the fatal handler. Also used in normal ObjC
/// exception reporting. Never concurrently mutate the startup metadata.
size_t MPKCopyCrashContext(char *buffer, size_t capacity);

/// Installs `SA_SIGINFO` handlers for the fixed diagnostic signal set
/// (`SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGFPE`) that write a
/// crash report to `crash_file_path` before re-raising for default
/// (`SIG_DFL`) termination. Every fatal exit explicitly restores SIG_DFL;
/// it does not rely on SA_RESETHAND resetting SIGTRAP on Darwin. If re-raising
/// unexpectedly returns, _exit terminates without resuming faulting code.
///
/// The minimum report uses fixed buffers, bounded manual formatting and
/// async-signal-safe I/O. No Swift/Objective-C runtime, allocating formatter,
/// or symbol lookup runs before the minimum report's write completes.
/// Short writes and EINTR are retried; zero writes and other errors stop the
/// attempt and skip the optional backtrace.
///
/// `backtrace()` remains best effort and is not async-signal-safe: it may
/// allocate or deadlock. It is called only after the complete minimum report
/// has been accepted by `write()`. There is no fsync or power-loss guarantee.
/// A concurrent fatal signal can terminate the process before that write
/// completes. A single atomic guard prevents competing writers; losing
/// threads re-raise immediately without waiting. No recovery is attempted.
///
/// Installs an alternate stack backed by process-lifetime C storage on the
/// calling thread. Call from the main thread during startup. Other threads
/// do not receive an alternate stack, so their stack-overflow crashes may
/// not produce a report. Metadata is copied before handlers are installed.
/// A separate atomic guard makes only the first call effective; a later call
/// (direct or concurrent) returns immediately without touching the metadata
/// buffers, sigaltstack, or sigaction state the first call installed.
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
