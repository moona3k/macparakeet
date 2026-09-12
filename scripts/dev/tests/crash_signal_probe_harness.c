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

#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Not `static`: `nm` needs it in the harness binary's external symbol table so
// the test can look up its address range and confirm the reported interrupted
// PC actually falls inside this function (not inside the handler).
__attribute__((noinline)) void mpk_probe_trigger_segv(void) {
    volatile int *p = (volatile int *)0;
    *p = 1;
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
        fprintf(stderr, "modes: abort | segv | reinstall_abort | long_meta_abort\n");
        return 2;
    }
    const char *path = argv[1];
    const char *mode = argv[2];

    if (strcmp(mode, "segv") == 0) {
        install_with_app_version(path, "probe-app-ver");
        mpk_probe_trigger_segv();
    } else if (strcmp(mode, "reinstall_abort") == 0) {
        // Duplicate-install safety: a second install() call must not corrupt
        // state, and its metadata must be what later fires.
        install_with_app_version(path, "first-install-version");
        install_with_app_version(path, "second-install-version");
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
    } else {
        install_with_app_version(path, "probe-app-ver");
        abort();
    }

    return 0;
}
