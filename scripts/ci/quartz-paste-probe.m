// Qualifies normal native destination delivery, not Jump Desktop or physical keys.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (strcmp(getenv("GITHUB_ACTIONS") ?: "", "true") ||
            strcmp(getenv("RUNNER_ENVIRONMENT") ?: "", "github-hosted")) {
            fprintf(stderr, "Refusing input outside a disposable GitHub-hosted runner.\n");
            return 1;
        }
        if (argc == 2 && !strcmp(argv[1], "--post")) {
            if (!CGPreflightPostEventAccess()) {
                puts("{\"result\":\"unavailable\",\"reason\":\"post_permission\"}");
                return 1;
            }
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
            CGEventRef down = CGEventCreateKeyboardEvent(source, 9, true);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 9, false);
            if (!source || !down || !up) {
                if (down) CFRelease(down);
                if (up) CFRelease(up);
                if (source) CFRelease(source);
                exit(1);
            }
            CGEventSetFlags(down, kCGEventFlagMaskCommand);
            CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventSetIntegerValueField(down, kCGEventSourceUserData, 0x4D505343);
            CGEventSetIntegerValueField(up, kCGEventSourceUserData, 0x4D505343);
            CGEventPost(kCGSessionEventTap, down);
            CGEventPost(kCGSessionEventTap, up);
            CFRelease(down); CFRelease(up); CFRelease(source);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 160)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 160)];
        window.contentView = text;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Main"];
        NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
        edit.submenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [edit.submenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [menu addItem:edit];
        app.mainMenu = menu;
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
            object:app queue:nil usingBlock:^(NSNotification *notification) {
                (void)notification;
                [window makeKeyAndOrderFront:nil];
                [window makeFirstResponder:text];
                [app activate];
            }];
        NSString *expected = @"quartz-session-paste-1286";
        NSTimeInterval readinessDeadline = NSProcessInfo.processInfo.systemUptime + 10;
        __block NSTimeInterval deliveryDeadline = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (!app.active || !window.keyWindow || window.firstResponder != text) {
                if (NSProcessInfo.processInfo.systemUptime >= readinessDeadline) {
                    printf("{\"result\":\"unavailable\",\"reason\":\"receiver_not_focused\","
                           "\"active\":%d,\"key_window\":%d,\"first_responder\":%d}\n",
                           app.active, window.keyWindow, window.firstResponder == text);
                    exit(1);
                }
                return;
            }
            [timer invalidate];
            deliveryDeadline = NSProcessInfo.processInfo.systemUptime + 5;
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:expected forType:NSPasteboardTypeString];
            puts("{\"result\":\"receiver_ready\"}");
            fflush(stdout);
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if ([text.string isEqualToString:expected]) {
                puts("{\"result\":\"native_paste_observed\",\"jump_desktop_tested\":false}");
                [timer invalidate];
                exit(0);
            }
            if (deliveryDeadline && NSProcessInfo.processInfo.systemUptime >= deliveryDeadline) {
                puts("{\"result\":\"paste_delivery_timeout\"}");
                exit(1);
            }
        }];
        [app run];
        return 1;
    }
}
