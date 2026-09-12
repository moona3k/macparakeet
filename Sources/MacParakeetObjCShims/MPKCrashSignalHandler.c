#include "MPKCrashSignalHandler.h"

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

// All buffers below are written once, from the main thread, in
// MPKInstallCrashSignalHandler (before any signal can fire) and read only
// from mpk_signal_handler thereafter. No signal-handler code path allocates.

#define MPK_REPORT_BUFFER_SIZE 4096
#define MPK_PATH_BUFFER_SIZE 512
#define MPK_APP_VERSION_SIZE 64
#define MPK_OS_VERSION_SIZE 32
#define MPK_MACH_UUID_SIZE 48
#define MPK_ASLR_SLIDE_SIZE 24
#define MPK_FRAME_CAPACITY 64

static const int kMPKCrashSignals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
static const size_t kMPKCrashSignalCount = sizeof(kMPKCrashSignals) / sizeof(kMPKCrashSignals[0]);

static char g_crash_file_path[MPK_PATH_BUFFER_SIZE];
static char g_app_version[MPK_APP_VERSION_SIZE];
static char g_os_version[MPK_OS_VERSION_SIZE];
static char g_mach_uuid[MPK_MACH_UUID_SIZE];
static char g_aslr_slide[MPK_ASLR_SLIDE_SIZE];

static char g_report_buffer[MPK_REPORT_BUFFER_SIZE];
static void *g_frames[MPK_FRAME_CAPACITY];

/// Single-entry guard: only the first crashing thread writes a report.
static atomic_int g_handler_entered = 0;

static void mpk_copy_bounded(char *dst, size_t dst_size, const char *src) {
    if (src == NULL || dst_size == 0) {
        if (dst_size > 0) {
            dst[0] = '\0';
        }
        return;
    }
    strncpy(dst, src, dst_size - 1);
    dst[dst_size - 1] = '\0';
}

static const char *mpk_signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGFPE:  return "SIGFPE";
        default:      return "UNKNOWN";
    }
}

// Interrupted-PC extraction is inherently architecture-specific: `uap` is an
// opaque `ucontext_t *` whose machine-context layout differs per arch. An
// unrecognized arch simply omits the `pc` field from the report.
#if defined(__arm64__) || defined(__aarch64__)
static int mpk_extract_pc(void *uap, uint64_t *out_pc) {
    ucontext_t *ctx = (ucontext_t *)uap;
    if (ctx == NULL || ctx->uc_mcontext == NULL) return 0;
    *out_pc = (uint64_t)ctx->uc_mcontext->__ss.__pc;
    return 1;
}
#elif defined(__x86_64__)
static int mpk_extract_pc(void *uap, uint64_t *out_pc) {
    ucontext_t *ctx = (ucontext_t *)uap;
    if (ctx == NULL || ctx->uc_mcontext == NULL) return 0;
    *out_pc = (uint64_t)ctx->uc_mcontext->__ss.__rip;
    return 1;
}
#else
static int mpk_extract_pc(void *uap, uint64_t *out_pc) {
    (void)uap;
    (void)out_pc;
    return 0;
}
#endif

static size_t mpk_clamp(long written, size_t remaining) {
    if (written <= 0) return 0;
    size_t n = (size_t)written;
    return n > remaining ? remaining : n;
}

static void mpk_signal_handler(int sig, siginfo_t *info, void *uap) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_handler_entered, &expected, 1)) {
        // A second thread crashed concurrently with the first. Re-raise so
        // it terminates via SIG_DFL rather than resuming from its fault.
        raise(sig);
        return;
    }

    uint64_t fault_addr = (uint64_t)(uintptr_t)(info != NULL ? info->si_addr : NULL);
    int si_code = info != NULL ? info->si_code : 0;
    uint64_t pc = 0;
    int has_pc = mpk_extract_pc(uap, &pc);

    // Minimal evidence first: metadata, si_code, fault address, and (when
    // available) the interrupted instruction pointer. Written and durable on
    // disk before the best-effort backtrace below, so a hang or crash inside
    // backtrace() does not prevent this minimal report from surviving.
    long header_written = snprintf(
        g_report_buffer, sizeof(g_report_buffer),
        "crash_type: signal\n"
        "signal: %d\n"
        "name: %s\n"
        "timestamp: %ld\n"
        "app_ver: %s\n"
        "os_ver: %s\n"
        "uuid: %s\n"
        "slide: %s\n"
        "si_code: %d\n"
        "fault_addr: 0x%llx\n",
        sig,
        mpk_signal_name(sig),
        (long)time(NULL),
        g_app_version,
        g_os_version,
        g_mach_uuid,
        g_aslr_slide,
        si_code,
        (unsigned long long)fault_addr
    );
    size_t offset = mpk_clamp(header_written, sizeof(g_report_buffer));

    if (has_pc && offset < sizeof(g_report_buffer)) {
        long pc_written = snprintf(
            g_report_buffer + offset, sizeof(g_report_buffer) - offset,
            "pc: 0x%llx\n", (unsigned long long)pc
        );
        offset += mpk_clamp(pc_written, sizeof(g_report_buffer) - offset);
    }

    int fd = open(g_crash_file_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, g_report_buffer, offset);
        close(fd);
    }

    // Best-effort backtrace, appended only after the minimal report above is
    // already durable. backtrace() is not strictly async-signal-safe (see
    // the header doc); if it hangs, the minimal report already on disk still
    // describes the fault.
    int frame_count = backtrace(g_frames, MPK_FRAME_CAPACITY);
    if (frame_count > 0) {
        long marker_written = snprintf(g_report_buffer, sizeof(g_report_buffer), "--- stack ---\n");
        size_t stack_offset = mpk_clamp(marker_written, sizeof(g_report_buffer));

        for (int i = 0; i < frame_count; i++) {
            if (stack_offset + 20 >= sizeof(g_report_buffer)) break;
            long line_written = snprintf(
                g_report_buffer + stack_offset, sizeof(g_report_buffer) - stack_offset,
                "0x%llx\n", (unsigned long long)(uintptr_t)g_frames[i]
            );
            if (line_written <= 0) break;
            stack_offset += mpk_clamp(line_written, sizeof(g_report_buffer) - stack_offset);
        }

        int append_fd = open(g_crash_file_path, O_WRONLY | O_APPEND);
        if (append_fd >= 0) {
            write(append_fd, g_report_buffer, stack_offset);
            close(append_fd);
        }
    }

    // SA_RESETHAND already restored SIG_DFL for `sig` before this handler was
    // entered. Re-raise to let the OS default disposition terminate the
    // process; there is no recover-and-continue path.
    raise(sig);
}

void MPKInstallCrashSignalHandler(const char *crash_file_path, const MPKCrashMetadata *metadata) {
    mpk_copy_bounded(g_crash_file_path, sizeof(g_crash_file_path), crash_file_path);
    mpk_copy_bounded(g_app_version, sizeof(g_app_version), metadata != NULL ? metadata->app_version : NULL);
    mpk_copy_bounded(g_os_version, sizeof(g_os_version), metadata != NULL ? metadata->os_version : NULL);
    mpk_copy_bounded(g_mach_uuid, sizeof(g_mach_uuid), metadata != NULL ? metadata->mach_uuid : NULL);
    mpk_copy_bounded(g_aslr_slide, sizeof(g_aslr_slide), metadata != NULL ? metadata->aslr_slide : NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = mpk_signal_handler;
    action.sa_flags = SA_ONSTACK | SA_RESETHAND | SA_NODEFER | SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    for (size_t i = 0; i < kMPKCrashSignalCount; i++) {
        sigaction(kMPKCrashSignals[i], &action, NULL);
    }
}

void MPKMarkCrashHandlerEntered(void) {
    int expected = 0;
    atomic_compare_exchange_strong(&g_handler_entered, &expected, 1);
}
