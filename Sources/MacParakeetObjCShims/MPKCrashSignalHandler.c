#include "MPKCrashSignalHandler.h"

#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

// Metadata is copied during startup and remains fixed during signal handling.
// The atomic entry guard gives one handler ownership of the report buffers.
// Minimum-report formatting uses bounded byte copies and integer arithmetic.

#define MPK_REPORT_BUFFER_SIZE 4096
#define MPK_PATH_BUFFER_SIZE 512
#define MPK_APP_VERSION_SIZE 64
#define MPK_OS_VERSION_SIZE 32
#define MPK_MACH_UUID_SIZE 48
#define MPK_ASLR_SLIDE_SIZE 24
#define MPK_FRAME_CAPACITY 64
#define MPK_SIGNAL_NAME_MAX 16

// sigaltstack retains this address; static storage keeps it valid for life.
_Alignas(16) static char g_alt_stack[SIGSTKSZ];

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
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Crash entry guard must be lock-free");
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

// MARK: - Bounded manual appenders
//
// Replace an earlier `snprintf`-based implementation. `snprintf` is not on
// POSIX's async-signal-safe function list; these appenders do the same job
// with only bounds-checked byte copies and integer math — no locale lookup,
// no allocation, no varargs.

static size_t mpk_append_bytes(char *buf, size_t buf_size, size_t offset, const char *src, size_t len) {
    if (offset >= buf_size) return offset;
    size_t remaining = buf_size - offset;
    size_t n = len > remaining ? remaining : len;
    memcpy(buf + offset, src, n);
    return offset + n;
}

#define MPK_APPEND_LIT(buf, buf_size, offset, lit) \
    mpk_append_bytes((buf), (buf_size), (offset), (lit), sizeof(lit) - 1)

// Bounded copy of a NUL-terminated C string whose maximum length is known at
// the call site (e.g. a fixed internal buffer's capacity). Scans byte by
// byte instead of calling `strlen`, so every caller supplies its own
// compile-time-known upper bound rather than relying on `strlen`'s
// (unspecified here) async-signal-safety.
static size_t mpk_append_cstr(char *buf, size_t buf_size, size_t offset, const char *s, size_t max_len) {
    size_t len = 0;
    while (len < max_len && s[len] != '\0') {
        len++;
    }
    return mpk_append_bytes(buf, buf_size, offset, s, len);
}

// Appends the base-10 representation of a signed 64-bit value. The
// magnitude is computed as `-(value + 1) + 1` rather than `-value` so that
// `INT64_MIN` (and, by promotion, `INT32_MIN` such as a `si_code` boundary
// value) never triggers signed overflow: negating `value + 1` is always
// representable because it discards the one magnitude `-value` alone could
// overflow on the min value.
static size_t mpk_append_i64(char *buf, size_t buf_size, size_t offset, int64_t value) {
    char tmp[24];
    size_t ti = sizeof(tmp);
    uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1u : (uint64_t)value;
    if (magnitude == 0) {
        tmp[--ti] = '0';
    } else {
        while (magnitude > 0) {
            tmp[--ti] = (char)('0' + (magnitude % 10));
            magnitude /= 10;
        }
    }
    if (value < 0) {
        tmp[--ti] = '-';
    }
    return mpk_append_bytes(buf, buf_size, offset, tmp + ti, sizeof(tmp) - ti);
}

// Appends the lowercase hex digits of an unsigned 64-bit value (no "0x"
// prefix; callers append that literal separately so it can share a line
// with other text).
static size_t mpk_append_hex_u64(char *buf, size_t buf_size, size_t offset, uint64_t value) {
    static const char kHexDigits[] = "0123456789abcdef";
    char tmp[16];
    size_t ti = sizeof(tmp);
    if (value == 0) {
        tmp[--ti] = '0';
    } else {
        while (value > 0) {
            tmp[--ti] = kHexDigits[value & 0xF];
            value >>= 4;
        }
    }
    return mpk_append_bytes(buf, buf_size, offset, tmp + ti, sizeof(tmp) - ti);
}

// MARK: - File I/O: retried on EINTR, tolerant of short writes

static int mpk_open_report_file(int flags) {
    int fd;
    do {
        fd = open(g_crash_file_path, flags, 0644);
    } while (fd < 0 && errno == EINTR);
    return fd;
}

// Writes exactly `len` bytes from `buf` to `fd`, retrying on `EINTR` and on
// short writes (a single `write` is not required to consume the whole
// buffer). Stops as soon as `write` returns `0` or a non-`EINTR` error:
// neither condition is expected to resolve by retrying, and a signal
// handler must never spin or block waiting for a stalled fd — this is a
// best-effort persistence attempt, not a guarantee the full report lands.
static int mpk_write_all(int fd, const char *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = write(fd, buf + total, len - total);
        if (n > 0) {
            total += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return 0;
    }
    return 1;
}

static void mpk_signal_handler(int sig, siginfo_t *info, void *uap) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_handler_entered, &expected, 1)) {
        // A second thread crashed concurrently with the first. Re-raise so
        // it terminates via SIG_DFL rather than resuming from its fault.
        // This handler makes no attempt to serialize or wait for the first
        // thread's report to finish — best-effort, not a durability
        // guarantee for either thread's evidence.
        raise(sig);
        return;
    }

    uint64_t fault_addr = (uint64_t)(uintptr_t)(info != NULL ? info->si_addr : NULL);
    int32_t si_code = info != NULL ? (int32_t)info->si_code : 0;
    uint64_t pc = 0;
    int has_pc = mpk_extract_pc(uap, &pc);

    // Minimal evidence first: metadata, si_code, fault address, and (when
    // available) the interrupted instruction pointer. Written to disk
    // before the best-effort backtrace below, so a hang or crash inside
    // backtrace() does not prevent this minimal report from being attempted.
    // "Written" here means handed to `write()` successfully, i.e.
    // accepted by the OS — not that it has survived a power loss; there is
    // no fsync in this path.
    size_t offset = 0;
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "crash_type: signal\nsignal: ");
    offset = mpk_append_i64(g_report_buffer, sizeof(g_report_buffer), offset, sig);
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nname: ");
    offset = mpk_append_cstr(g_report_buffer, sizeof(g_report_buffer), offset, mpk_signal_name(sig), MPK_SIGNAL_NAME_MAX);
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\ntimestamp: ");
    offset = mpk_append_i64(g_report_buffer, sizeof(g_report_buffer), offset, (int64_t)time(NULL));
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\napp_ver: ");
    offset = mpk_append_cstr(g_report_buffer, sizeof(g_report_buffer), offset, g_app_version, sizeof(g_app_version));
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nos_ver: ");
    offset = mpk_append_cstr(g_report_buffer, sizeof(g_report_buffer), offset, g_os_version, sizeof(g_os_version));
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nuuid: ");
    offset = mpk_append_cstr(g_report_buffer, sizeof(g_report_buffer), offset, g_mach_uuid, sizeof(g_mach_uuid));
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nslide: ");
    offset = mpk_append_cstr(g_report_buffer, sizeof(g_report_buffer), offset, g_aslr_slide, sizeof(g_aslr_slide));
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nsi_code: ");
    offset = mpk_append_i64(g_report_buffer, sizeof(g_report_buffer), offset, (int64_t)si_code);
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\nfault_addr: 0x");
    offset = mpk_append_hex_u64(g_report_buffer, sizeof(g_report_buffer), offset, fault_addr);
    offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\n");

    if (has_pc) {
        offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "pc: 0x");
        offset = mpk_append_hex_u64(g_report_buffer, sizeof(g_report_buffer), offset, pc);
        offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), offset, "\n");
    }

    int fd = mpk_open_report_file(O_WRONLY | O_CREAT | O_TRUNC);
    int minimum_written = 0;
    if (fd >= 0) {
        minimum_written = mpk_write_all(fd, g_report_buffer, offset);
        close(fd);
    }
    if (!minimum_written) {
        raise(sig);
        return;
    }

    // Best-effort backtrace, appended only after the minimal report above has
    // been fully accepted by write(). backtrace() is not strictly async-signal-safe
    // (see the header doc); if it hangs, the minimal report already written
    // still describes the fault. This step is skipped entirely, not
    // retried, if it fails or returns no frames.
    int frame_count = backtrace(g_frames, MPK_FRAME_CAPACITY);
    if (frame_count > 0) {
        size_t stack_offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), 0, "--- stack ---\n");

        for (int i = 0; i < frame_count; i++) {
            if (stack_offset + 20 >= sizeof(g_report_buffer)) break;
            stack_offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), stack_offset, "0x");
            stack_offset = mpk_append_hex_u64(
                g_report_buffer, sizeof(g_report_buffer), stack_offset,
                (uint64_t)(uintptr_t)g_frames[i]
            );
            stack_offset = MPK_APPEND_LIT(g_report_buffer, sizeof(g_report_buffer), stack_offset, "\n");
        }

        int append_fd = mpk_open_report_file(O_WRONLY | O_APPEND);
        if (append_fd >= 0) {
            mpk_write_all(append_fd, g_report_buffer, stack_offset);
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

    // sigaltstack is per-thread: only the main-thread caller gets this
    // process-lifetime backing. Worker stack overflows may have no report.
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_alt_stack;
    ss.ss_size = sizeof(g_alt_stack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

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
