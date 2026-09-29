// Standalone executable checks/benchmark against the production C implementation.
// No app, microphone, model, telemetry or user files are used.
#include "MPKCrashSignalHandler.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int interrupt_writer;
static atomic_int failures;
static const uint64_t payload = UINT64_C(0xfedcba9876543210);

void MPKCrashContextTestWillPublish(void) {
    if (interrupt_writer) raise(SIGABRT);
}

static void snapshot(char *buffer, size_t size) {
    size_t n = MPKCopyCrashContext(buffer, size - 1);
    buffer[n] = '\0';
}

static double seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void *writer(void *unused) {
    (void)unused;
    for (int i = 0; i < 100000; i++) MPKRecordCrashBreadcrumb(payload);
    return NULL;
}

static void *reader(void *unused) {
    (void)unused;
    for (int i = 0; i < 10000; i++) {
        char buffer[8192];
        snapshot(buffer, sizeof(buffer));
        unsigned long long previous = 0;
        int count = 0;
        char *cursor = buffer;
        while ((cursor = strstr(cursor, "breadcrumb: ")) != NULL) {
            unsigned long long sequence, value;
            if (sscanf(cursor, "breadcrumb: %llu,0x%llx", &sequence, &value) != 2
                || sequence <= previous || value != payload || ++count > 32) atomic_fetch_add(&failures, 1);
            previous = sequence;
            cursor++;
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    assert(argc >= 2);
    alarm(30);
    if (strcmp(argv[1], "interrupted") == 0) {
        assert(argc == 3);
        MPKCrashMetadata metadata = { .app_version = "probe", .crash_id = "12345678-1234-1234-1234-123456789abc" };
        MPKInstallCrashSignalHandler(argv[2], &metadata);
        for (int i = 0; i < 32; i++) MPKRecordCrashBreadcrumb(payload);
        interrupt_writer = 1;
        alarm(5);
        MPKRecordCrashBreadcrumb(0);
        return 2;
    }
    if (strcmp(argv[1], "concurrent") == 0) {
        pthread_t writers[4], r;
        double start = seconds();
        assert(pthread_create(&r, NULL, reader, NULL) == 0);
        for (int i = 0; i < 4; i++) assert(pthread_create(&writers[i], NULL, writer, NULL) == 0);
        for (int i = 0; i < 4; i++) assert(pthread_join(writers[i], NULL) == 0);
        assert(pthread_join(r, NULL) == 0);
        assert(atomic_load(&failures) == 0);
        printf("PASS concurrent writers/snapshot readers; elapsed_ms=%.3f\n", (seconds() - start) * 1000);
        return 0;
    }
    if (strcmp(argv[1], "benchmark") == 0) {
        // Batch samples amortize measurement overhead; these are per-call batch
        // means, not a claim about individual-call p99 or real-time deadlines.
        double samples[101];
        for (int sample = 0; sample < 101; sample++) {
            double start = seconds();
            for (int i = 0; i < 10000; i++) MPKRecordCrashBreadcrumb(payload);
            samples[sample] = (seconds() - start) * 1e9 / 10000;
        }
        for (int i = 0; i < 101; i++) for (int j = i + 1; j < 101; j++) {
            if (samples[j] < samples[i]) { double t = samples[i]; samples[i] = samples[j]; samples[j] = t; }
        }
        printf("record batch_mean_ns median=%.2f p95=%.2f max=%.2f\n", samples[50], samples[95], samples[100]);
        MPKCrashSystemMetadata metadata;
        double start = seconds();
        MPKReadCrashSystemMetadata(&metadata);
        printf("system_snapshot_us=%.2f os_build_present=%d cache_uuid_present=%d\n",
               (seconds() - start) * 1e6, metadata.os_build[0] != 0, metadata.shared_cache_uuid[0] != 0);
        return 0;
    }
    for (unsigned int i = 1; i <= 100; i++) MPKRecordCrashBreadcrumb(i);
    MPKSetCrashRegisteredConsumers(3);
    char buffer[8192];
    snapshot(buffer, sizeof(buffer));
    assert(strstr(buffer, "crash_registered_consumers: 3\n"));
    unsigned long long expected = 69;
    char *cursor = buffer;
    while ((cursor = strstr(cursor, "breadcrumb: ")) != NULL) {
        unsigned long long sequence, value;
        assert(sscanf(cursor, "breadcrumb: %llu,0x%llx", &sequence, &value) == 2);
        assert(sequence == expected && value == expected);
        expected++; cursor++;
    }
    assert(expected == 101);
    char guard[10]; memset(guard, 0x5a, sizeof(guard));
    assert(MPKCopyCrashContext(guard + 1, 8) == 8);
    assert(guard[0] == 0x5a && guard[9] == 0x5a);
    assert(MPKCopyCrashContext(NULL, 8) == 0);
    assert(MPKCopyCrashContext(guard, 0) == 0);
    assert(MPKNextCrashAttempt() == 1 && MPKNextCrashAttempt() == 2);
    puts("PASS ring wrap, monotonic ordering, finite consumers, bounded writes, attempt tokens");
    return 0;
}
