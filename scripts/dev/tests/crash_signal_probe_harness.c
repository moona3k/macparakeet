// Standalone child-process harness for CrashReporterSignalProbeTests. Compiled
// (by that Swift test, at test time) directly against the production
// Sources/MacParakeetObjCShims/MPKCrashSignalHandler.c and its header — this
// file does not reimplement any signal-handling logic itself. It only installs
// the real handler with test-controlled metadata and then deliberately faults
// or aborts, so the resulting on-disk report can be inspected by the test for
// real subprocess behavior (signal-exit disposition, interrupted PC, fault
// address) that can't be observed by calling C functions in-process without
// crashing the test runner.
#include "MPKCrashSignalHandler.h"

#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

// Not `static`: `nm` needs it in the harness binary's external symbol table so
// the test can look up its address range and confirm the reported interrupted
// PC actually falls inside this function (not inside the handler).
__attribute__((noinline)) void mpk_probe_trigger_segv(void) {
    volatile int *p = (volatile int *)0;
    *p = 1;
}

// MARK: - write()/backtrace() interposition (test-only, harness-side)
//
// This harness and the unmodified production MPKCrashSignalHandler.c are
// compiled into one executable by a single clang invocation (see
// CrashReporterSignalProbeTests.runProbe). When a symbol is defined in one
// of a link's own object files, the static linker binds calls to it from
// every other object file in that same link ahead of the same-named symbol
// in a linked shared library (libSystem) — no production source change,
// macro, or test-only build flag is involved. Production code still calls
// plain `write`/`backtrace`; only this harness binary's *link* redirects
// those calls, and only for the write/backtrace-injection modes below.

typedef ssize_t (*mpk_real_write_fn)(int, const void *, size_t);

typedef int (*mpk_real_backtrace_fn)(void **, int);
static mpk_real_write_fn g_real_write;
static mpk_real_backtrace_fn g_real_backtrace;

static ssize_t mpk_call_real_write(int fd, const void *buf, size_t count) {
    return g_real_write(fd, buf, count);
}

enum {
    MPK_WRITE_PASSTHROUGH = 0,
    MPK_WRITE_SHORT,           // never accept more than a few bytes per call
    MPK_WRITE_EINTR_THEN_SHORT, // first calls fail with EINTR, then succeed (short)
    MPK_WRITE_ALWAYS_ZERO,     // always report 0 bytes accepted, never fails
};

static int g_write_mode = MPK_WRITE_PASSTHROUGH;
static int g_write_call_count = 0;

ssize_t write(int fd, const void *buf, size_t count) {
    g_write_call_count++;
    switch (g_write_mode) {
        case MPK_WRITE_SHORT: {
            size_t capped = count > 3 ? 3 : count;
            return mpk_call_real_write(fd, buf, capped);
        }
        case MPK_WRITE_EINTR_THEN_SHORT:
            if (g_write_call_count <= 2) {
                errno = EINTR;
                return -1;
            }
            {
                size_t capped = count > 5 ? 5 : count;
                return mpk_call_real_write(fd, buf, capped);
            }
        case MPK_WRITE_ALWAYS_ZERO:
            return 0;
        default:
            return mpk_call_real_write(fd, buf, count);
    }
}

static int g_backtrace_fails = 0;
static int g_backtrace_exits = 0;

int backtrace(void **buffer, int size) {
    if (g_backtrace_exits) _exit(73);
    if (g_backtrace_fails) {
        // Production code treats a non-positive frame count as "skip the
        // stack section, keep the minimal report" — this simulates that
        // without needing a real dyld-lock hang to happen.
        return 0;
    }
    return g_real_backtrace(buffer, size);
}

static void install_with_app_version(const char *path, const char *app_version) {
    char slide_buf[24];
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    snprintf(slide_buf, sizeof(slide_buf), "0x%lx", (unsigned long)slide);

    MPKCrashMetadata metadata = {
        .app_version = app_version,
        .os_version = "probe-os-ver",
        .mach_uuid = "PROBE-UUID",
        .aslr_slide = slide_buf,
    };
    MPKInstallCrashSignalHandler(path, &metadata);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: crash_signal_probe_harness <crash_file_path> <mode>\n");
        fprintf(stderr,
                "modes: abort | segv | reinstall_abort | long_meta_abort | "
                "short_write_abort | eintr_write_abort | zero_write_abort | "
                "backtrace_fails_abort | backtrace_exits_abort | "
                "raise_segv | raise_abrt | raise_bus | raise_ill | raise_trap | raise_fpe\n");
        return 2;
    }
    // Arm only this disposable child; a hung handler fails with SIGALRM.
    alarm(10);
    // Resolve loader symbols before installing or entering the crash handler.
    g_real_write = (mpk_real_write_fn)dlsym(RTLD_NEXT, "write");
    g_real_backtrace = (mpk_real_backtrace_fn)dlsym(RTLD_NEXT, "backtrace");
    if (g_real_write == NULL || g_real_backtrace == NULL) return 3;

    const char *path = argv[1];
    const char *mode = argv[2];

    static const struct { const char *mode; int signal_number; } raised_signals[] = {
        { "raise_segv", SIGSEGV }, { "raise_abrt", SIGABRT },
        { "raise_bus", SIGBUS }, { "raise_ill", SIGILL },
        { "raise_trap", SIGTRAP }, { "raise_fpe", SIGFPE },
    };
    for (size_t i = 0; i < sizeof(raised_signals) / sizeof(raised_signals[0]); i++) {
        if (strcmp(mode, raised_signals[i].mode) == 0) {
            install_with_app_version(path, "probe-app-ver");
            raise(raised_signals[i].signal_number);
            return 4; // A fatal handler must never return to this call site.
        }
    }

    if (strcmp(mode, "segv") == 0) {
        install_with_app_version(path, "probe-app-ver");
        mpk_probe_trigger_segv();
    } else if (strcmp(mode, "reinstall_abort") == 0) {
        // Duplicate-install safety: a second install() call must not corrupt
        // state or overwrite the first snapshot; the first installation's
        // metadata must be what later fires.
        install_with_app_version(path, "first-install-version");
        char second_path[1024];
        int length = snprintf(second_path, sizeof(second_path), "%s.second", path);
        if (length < 0 || (size_t)length >= sizeof(second_path)) return 2;
        install_with_app_version(second_path, "second-install-version");
        abort();
    } else if (strcmp(mode, "long_meta_abort") == 0) {
        // Output truncation safety: app_version far longer than the
        // handler's fixed internal buffer must not overflow or crash, and
        // the written field must be a bounded, valid (truncated) C string.
        char long_version[256];
        memset(long_version, 'A', sizeof(long_version) - 1);
        long_version[sizeof(long_version) - 1] = '\0';
        install_with_app_version(path, long_version);
        abort();
    } else if (strcmp(mode, "short_write_abort") == 0) {
        // Proves the production write loop accumulates across many short
        // writes instead of silently truncating the report.
        g_write_mode = MPK_WRITE_SHORT;
        install_with_app_version(path, "probe-app-ver");
        abort();
    } else if (strcmp(mode, "eintr_write_abort") == 0) {
        // Proves the production write loop retries on EINTR instead of
        // treating it as a fatal error and abandoning the report.
        g_write_mode = MPK_WRITE_EINTR_THEN_SHORT;
        install_with_app_version(path, "probe-app-ver");
        abort();
    } else if (strcmp(mode, "zero_write_abort") == 0) {
        // Proves the production write loop gives up (does not spin forever)
        // when write() always reports 0 bytes accepted, and the process
        // still terminates via the signal's default disposition.
        g_write_mode = MPK_WRITE_ALWAYS_ZERO;
        g_backtrace_exits = 1; // Must be skipped after minimum write failure.
        install_with_app_version(path, "probe-app-ver");
        abort();
    } else if (strcmp(mode, "backtrace_exits_abort") == 0) {
        // Abrupt exit proves minimum evidence preceded the backtrace call.
        g_backtrace_exits = 1;
        install_with_app_version(path, "probe-app-ver");
        abort();
    } else if (strcmp(mode, "backtrace_fails_abort") == 0) {
        // Proves the minimal report is already on disk before backtrace()
        // runs, so a failed/empty backtrace does not lose it.
        g_backtrace_fails = 1;
        install_with_app_version(path, "probe-app-ver");
        abort();
    } else {
        install_with_app_version(path, "probe-app-ver");
        abort();
    }

    return 0;
}
