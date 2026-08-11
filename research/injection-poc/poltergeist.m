// libpoltergeist.dylib — in-process capture + input shim for AppKit apps.
// Injected via DYLD_INSERT_LIBRARIES. No screenshot API, no global event posting.
//
// Build:
//   clang -dynamiclib -arch arm64 -framework Cocoa -o libpoltergeist.dylib poltergeist.m
//
// Capture:  -[NSView cacheDisplayInRect:toBitmapImageRep:] (renders the layer tree
//           in-process; survives screen lock / screensaver / display sleep).
// Input:    +[NSEvent mouseEventWithType:...] / keyEventWithType:... delivered with
//           -[NSApplication postEvent:atStart:] — never touches WindowServer's global
//           cursor or the HID event stream, so the real mouse never moves.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <pthread.h>
#import <sys/stat.h>

static const char *kDir       = "/tmp/poltergeist";
static const char *kLoaded    = "/tmp/poltergeist/loaded.txt";
static const char *kLatestPng = "/tmp/poltergeist/latest.png";
static const char *kSockPath  = "/tmp/poltergeist.sock";

#pragma mark - Capture (must run on main thread)

static NSWindow *PGFrontWindow(void) {
    NSApplication *app = NSApp;
    if (!app) return nil;
    NSWindow *w = app.keyWindow ?: app.mainWindow;
    if (!w) {
        for (NSWindow *cand in app.windows) {
            if (cand.isVisible && cand.contentView) { w = cand; break; }
        }
    }
    return w;
}

// Render the front window's content view into a PNG at `path`, atomically.
// Returns YES on success. MUST be called on the main thread.
static BOOL PGCaptureToPath(NSString *path) {
    NSWindow *win = PGFrontWindow();
    if (!win) { NSLog(@"[poltergeist] no front window"); return NO; }
    NSView *view = win.contentView;
    if (!view) { NSLog(@"[poltergeist] no content view"); return NO; }

    NSRect r = view.bounds;
    if (r.size.width < 1 || r.size.height < 1) return NO;

    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:r];
    if (!rep) { NSLog(@"[poltergeist] no bitmap rep"); return NO; }
    [view cacheDisplayInRect:r toBitmapImageRep:rep];

    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) { NSLog(@"[poltergeist] png encode failed"); return NO; }

    NSString *tmp = [path stringByAppendingString:@".tmp"];
    if (![png writeToFile:tmp atomically:NO]) {
        NSLog(@"[poltergeist] write failed: %@", tmp);
        return NO;
    }
    // Atomic swap into place.
    rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
    return YES;
}

#pragma mark - Input synthesis (must run on main thread)

static void PGClick(CGFloat x, CGFloat y) {
    NSWindow *win = PGFrontWindow();
    if (!win) return;
    NSInteger wn = win.windowNumber;
    // Window-local point, AppKit coords (origin bottom-left of content view).
    NSPoint p = NSMakePoint(x, y);
    NSTimeInterval t = [[NSProcessInfo processInfo] systemUptime];

    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                       location:p
                                  modifierFlags:0
                                      timestamp:t
                                   windowNumber:wn
                                        context:nil
                                    eventNumber:0
                                     clickCount:1
                                       pressure:1.0];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                     location:p
                                modifierFlags:0
                                    timestamp:t + 0.02
                                 windowNumber:wn
                                      context:nil
                                  eventNumber:0
                                   clickCount:1
                                     pressure:0.0];
    if (down) [NSApp postEvent:down atStart:NO];
    if (up)   [NSApp postEvent:up   atStart:NO];
}

// Type text into the front window. Most reliable path for TextEdit: insert directly
// into the field editor / first-responder text view via -insertText:. Fall back to
// synthesized keyDown events.
static void PGType(NSString *text) {
    NSWindow *win = PGFrontWindow();
    if (!win) return;

    id responder = win.firstResponder;
    if ([responder isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)responder;
        [tv insertText:text replacementRange:tv.selectedRange];
        return;
    }
    if ([responder respondsToSelector:@selector(insertText:)]) {
        // NSText / older responders
        [(NSText *)responder insertText:text];
        return;
    }

    // Fallback: synthesize a keyDown/keyUp per character and post to the app.
    NSInteger wn = win.windowNumber;
    NSTimeInterval t = [[NSProcessInfo processInfo] systemUptime];
    for (NSUInteger i = 0; i < text.length; i++) {
        NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
        NSEvent *kd = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:t
                                   windowNumber:wn
                                        context:nil
                                     characters:ch
                    charactersIgnoringModifiers:ch
                                      isARepeat:NO
                                        keyCode:0];
        NSEvent *ku = [NSEvent keyEventWithType:NSEventTypeKeyUp
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:t + 0.005
                                   windowNumber:wn
                                        context:nil
                                     characters:ch
                    charactersIgnoringModifiers:ch
                                      isARepeat:NO
                                        keyCode:0];
        if (kd) [NSApp postEvent:kd atStart:NO];
        if (ku) [NSApp postEvent:ku atStart:NO];
        t += 0.01;
    }
}

#pragma mark - Command dispatch

// Parse+run one command line. Dispatched to the main thread by the socket thread.
static void PGHandleCommand(NSString *line) {
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) return;

    NSRange sp = [line rangeOfString:@" "];
    NSString *cmd = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? @""   : [line substringFromIndex:sp.location + 1];

    if ([cmd isEqualToString:@"shot"]) {
        NSString *path = arg.length ? arg : @(kLatestPng);
        PGCaptureToPath(path);
    } else if ([cmd isEqualToString:@"click"]) {
        NSArray *parts = [arg componentsSeparatedByString:@" "];
        if (parts.count >= 2) PGClick([parts[0] doubleValue], [parts[1] doubleValue]);
    } else if ([cmd isEqualToString:@"type"]) {
        PGType(arg);
    } else {
        NSLog(@"[poltergeist] unknown cmd: %@", cmd);
    }
}

#pragma mark - Control socket (background thread)

static void *PGSocketThread(void *unused) {
    (void)unused;
    unlink(kSockPath);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { NSLog(@"[poltergeist] socket() failed"); return NULL; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kSockPath, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[poltergeist] bind() failed"); close(fd); return NULL;
    }
    if (listen(fd, 8) < 0) {
        NSLog(@"[poltergeist] listen() failed"); close(fd); return NULL;
    }
    NSLog(@"[poltergeist] control socket at %s", kSockPath);

    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) continue;
        char buf[8192];
        ssize_t n = read(c, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            NSString *payload = [NSString stringWithUTF8String:buf];
            // A single connection may carry multiple newline-separated commands.
            for (NSString *l in [payload componentsSeparatedByString:@"\n"]) {
                NSString *cl = [l copy];
                dispatch_async(dispatch_get_main_queue(), ^{ PGHandleCommand(cl); });
            }
        }
        close(c);
    }
    return NULL;
}

#pragma mark - Bootstrap

static void PGStartTimerAndSocket(void) {
    // Idempotent: the launch notification and the main-queue fallback may both fire.
    static BOOL started = NO;
    if (started) return;
    started = YES;

    // Repeating main-thread capture timer (~1.5s).
    NSTimer *t = [NSTimer timerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        PGCaptureToPath(@(kLatestPng));
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];

    pthread_t th;
    pthread_create(&th, NULL, PGSocketThread, NULL);
    pthread_detach(th);
}

__attribute__((constructor))
static void PGInit(void) {
    mkdir(kDir, 0755);
    @autoreleasepool {
        FILE *f = fopen(kLoaded, "w");
        if (f) { fprintf(f, "loaded pid=%d\n", getpid()); fclose(f); }
    }
    NSLog(@"[poltergeist] injected into pid %d", getpid());

    // AppKit may not be up yet at constructor time. Defer real work until the app
    // finishes launching; also arm on the next main-runloop tick as a belt-and-braces.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) { PGStartTimerAndSocket(); }];

    dispatch_async(dispatch_get_main_queue(), ^{
        // If the app already finished launching before we registered, arm now.
        // PGStartTimerAndSocket is idempotent, so a double-fire is harmless.
        PGStartTimerAndSocket();
    });
}
