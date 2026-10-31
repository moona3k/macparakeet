// Standalone experiment for #1286. Only run on a disposable hosted CI desktop.
// No text, clipboard data, or user input is captured. F20 is the only test key.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static const CGKeyCode testKey = 90; // F20; no text or modifier chord.
static const int64_t marker = 0x4D50524F4245;
static CGEventSourceRef activeSource;
static CGEventTapLocation activeLocation;
static unsigned observedDown;
static unsigned observedUp;

static CGEventRef observe(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    (void)context;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == marker) {
        if (type == kCGEventKeyDown) observedDown++;
        if (type == kCGEventKeyUp) observedUp++;
    }
    return event;
}

static void settle(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
}

static void snapshot(const char *phase) {
    printf("{\"phase\":\"%s\",\"pid\":%d,\"session_down\":%s,\"hid_down\":%s,"
           "\"observed_down\":%u,\"observed_up\":%u}\n",
           phase, getpid(),
           CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, testKey) ? "true" : "false",
           CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey) ? "true" : "false",
           observedDown, observedUp);
    if (activeSource) {
        CGEventSourceStateID sourceID = CGEventSourceGetSourceStateID(activeSource);
        printf("{\"actual_source_state\":%d,\"source_down\":%s}\n", sourceID,
               CGEventSourceKeyState(sourceID, testKey) ? "true" : "false");
    }
    fflush(stdout);
}

static bool post(bool down) {
    CGEventRef event = CGEventCreateKeyboardEvent(activeSource, testKey, down);
    if (!event) return false;
    CGEventSetFlags(event, 0);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, marker);
    CGEventPost(activeLocation, event);
    CFRelease(event);
    return true;
}

static void cleanup(void) {
    if (!activeSource) return;
    post(false);
    usleep(100000);
    CFRelease(activeSource);
    activeSource = NULL;
}

static bool allUp(void) {
    return !CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, testKey)
        && !CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey);
}

static void childProcess(const char *executable, const char *mode, const char *argument) {
    pid_t child = fork();
    if (child == 0) {
        execl(executable, executable, mode, argument, NULL);
        _exit(127);
    }
    if (child < 0) exit(1);
    int status;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) exit(1);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--read-only") == 0) {
        snapshot("fresh_process");
        return 0;
    }
    const char *ci = getenv("GITHUB_ACTIONS");
    const char *runner = getenv("RUNNER_ENVIRONMENT");
    if (!ci || strcmp(ci, "true") || !runner || strcmp(runner, "github-hosted")) {
        fprintf(stderr, "Refusing global input outside a disposable GitHub-hosted runner.\n");
        return 1;
    }
    printf("{\"post_access\":%s}\n", CGPreflightPostEventAccess() ? "true" : "false");
    if (!CGPreflightPostEventAccess()) {
        puts("{\"result\":\"unavailable\",\"reason\":\"event_post_permission\"}");
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "--orphan-producer") == 0) {
        activeSource = CGEventSourceCreate((CGEventSourceStateID)atoi(argv[2]));
        activeLocation = kCGHIDEventTap;
        if (!activeSource || !allUp() || !post(true)) return 1;
        usleep(200000);
        snapshot("producer_before_exit_without_release");
        CFRelease(activeSource);
        activeSource = NULL;
        return 0; // Deliberately no atexit release in this isolated child.
    }
    atexit(cleanup);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp), observe, NULL);
    if (!tap) {
        puts("{\"result\":\"unavailable\",\"reason\":\"delivery_witness_permission\"}");
        return 1;
    }
    CFRunLoopSourceRef tapSource = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    if (!tapSource) { CFRelease(tap); return 1; }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopDefaultMode);
    CGEventSourceStateID states[] = {kCGEventSourceStateHIDSystemState,
        kCGEventSourceStateCombinedSessionState, kCGEventSourceStatePrivate};
    CGEventTapLocation locations[] = {kCGHIDEventTap, kCGSessionEventTap};
    for (unsigned location = 0; location < 2; location++) {
        for (unsigned state = 0; state < 3; state++) {
            if (!allUp()) {
                fprintf(stderr, "Test key already down; refusing to alter existing input.\n");
                return 1;
            }
            activeSource = CGEventSourceCreate(states[state]);
            activeLocation = locations[location];
            if (!activeSource) return 1;
            printf("{\"source_state\":%d,\"post_location\":%u}\n", states[state], locations[location]);
            snapshot("before");
            unsigned downBefore = observedDown;
            if (!post(true)) return 1;
            settle();
            snapshot("down_without_up");
            if (observedDown == downBefore) {
                puts("{\"result\":\"inconclusive\",\"reason\":\"no_down_delivery\"}");
                return 1;
            }
            childProcess(argv[0], "--read-only", NULL);
            if (!post(false)) return 1;
            settle();
            snapshot("released");
            cleanup();
            snapshot("source_destroyed");
            if (!allUp()) return 1;
        }
    }
    for (unsigned state = 0; state < 2; state++) {
        if (!allUp()) return 1;
        activeLocation = kCGHIDEventTap;
        activeSource = CGEventSourceCreate(states[state]);
        if (!activeSource) return 1;
        char argument[16];
        snprintf(argument, sizeof(argument), "%d", states[state]);
        printf("{\"orphan_source_state\":%d}\n", states[state]);
        childProcess(argv[0], "--orphan-producer", argument);
        settle();
        snapshot("producer_exited_without_release");
        childProcess(argv[0], "--read-only", NULL);
        cleanup();
        settle();
        snapshot("orphan_cleanup");
        if (!allUp()) return 1;
    }
    // Model an intercepted session keyDown replayed at either entry point,
    // followed by the original producer's session keyUp. Observe the old HID
    // path rather than assuming whether that later release clears HID state.
    for (unsigned location = 0; location < 2; location++) {
        if (!allUp()) return 1;
        activeSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        activeLocation = kCGSessionEventTap;
        if (!activeSource) return 1;
        printf("{\"replay_post_location\":%u}\n", locations[location]);
        unsigned originalDownBefore = observedDown;
        if (!post(true)) return 1;
        settle();
        snapshot("replay_original_session_down");
        if (observedDown == originalDownBefore ||
            !CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, testKey) ||
            CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey)) {
            activeLocation = kCGHIDEventTap;
            return 1;
        }
        activeLocation = locations[location];
        unsigned replayDownBefore = observedDown;
        if (!post(true)) return 1;
        settle();
        snapshot("replay_copy_down");
        if (observedDown == replayDownBefore) return 1;
        bool replayKeptHIDUp = !CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey);
        activeLocation = kCGSessionEventTap;
        unsigned releaseBefore = observedUp;
        bool releasePosted = post(false);
        // Any failure from here must still release an old HID replay at HID.
        activeLocation = kCGHIDEventTap;
        if (!releasePosted) return 1;
        settle();
        snapshot("replay_session_release");
        if (observedUp == releaseBefore) return 1;
        bool replayFinishedUp = allUp();
        cleanup();
        settle();
        snapshot("replay_cleanup");
        if (!allUp()) return 1;
        if (locations[location] == kCGSessionEventTap && (!replayKeptHIDUp || !replayFinishedUp)) {
            puts("{\"result\":\"failed\",\"reason\":\"session_replay_contaminated_state\"}");
            return 1;
        }
    }
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopDefaultMode);
    CFMachPortInvalidate(tap);
    CFRelease(tapSource);
    CFRelease(tap);
    puts("{\"result\":\"observed\",\"physical_holds_tested\":false,\"jump_desktop_tested\":false}");
    return 0;
}
