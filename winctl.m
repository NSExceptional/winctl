// winctl.m — out-of-process, no-injection "see & control" CLI.
//
// A single compiled binary that lets an agent (or a human) screenshot a
// specific app window and send it keystrokes WITHOUT injecting code into the
// target, WITHOUT moving the real cursor, and WITHOUT depending on the flaky
// `screencapture` (which on this box returns only the desktop) — it reads the
// window's backing store, so it also survives the screensaver / locked screen.
//
// Everything private (SkyLight HW capture, the obsoleted CGWindowListCreateImage)
// is resolved at runtime via dlsym — nothing private is linked.
//
// Subcommands:
//   winctl list [--all] [--json]
//   winctl shot     <target> <out.png> [--json]
//   winctl type     <target> <text...>
//   winctl key      <target> <keyspec>          e.g. return, cmd+s, cmd+shift+4
//   winctl hold     <target> <keyspec>[:ms] …   press key(s) DOWN for a duration (walk games)
//   winctl click    <target> <x> <y>            (OOP; actuates a background control)
//   winctl click    <target> --title T [--role R] [--id ID] [--press]
//   winctl describe <target> [--actionable] [--role R] [--title T] [--id ID] [--json]
//   winctl doctor [--json]
//
// `describe` and the element form of `click` read the target's Accessibility
// element tree OUT OF PROCESS (no injection) so you can target a control by
// role/title/identifier instead of guessing pixel coordinates. `--press` invokes
// AXPress directly; otherwise the element's on-screen center is clicked via the
// same cursor-free, background-window field-51 path used by coordinate clicks.
//
// <target> is one of:
//   an app name   (case-insensitive substring; picks its largest normal window)
//   pid:N         (that process; its largest normal window)
//   win:ID        (that exact CGWindowID)
//
// Build:
//   clang -arch arm64 -fobjc-arc -fmodules -O2 \
//     -framework Cocoa -framework ApplicationServices -framework IOSurface \
//     -lsqlite3 -o winctl winctl.m

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <signal.h>

// Private libsystem SPI: mark a posix_spawn attribute so the spawned child
// becomes the TCC-*responsible* process for itself, decoupled from whatever
// host (VS Code, Terminal, Ocean…) launched us. This is the same mechanism
// Claude.app's `disclaimer` helper uses to get a stable TCC identity.
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim);
extern char **environ;

// ---------------------------------------------------------------------------
// Private / obsoleted symbols, resolved at runtime via dlsym.
// ---------------------------------------------------------------------------
typedef CGImageRef (*CGWindowListCreateImage_t)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
typedef int CGSConnectionID;
typedef uint32_t CGSWindowCaptureOptions;
typedef CGSConnectionID (*CGSMainConnectionID_t)(void);
typedef CFArrayRef (*HWCapture_t)(CGSConnectionID cid, CGWindowID *list, uint32_t count, CGSWindowCaptureOptions options);

// SkyLight event SPIs used by `click` to make an OOP mouse event hit-test to a
// specific (background) window. `SLEventSetIntegerValueField` is the
// non-validating field setter — the public CGEventSetIntegerValueField may
// silently ignore the undocumented window-routing index 51. `SLEventPostToPid`
// posts via the IOHIDPostEvent path (reaches Catalyst/Chromium); we fire it
// alongside the public CGEventPostToPid for belt-and-suspenders coverage.
typedef void (*SLEventSetIntegerValueField_t)(CGEventRef, uint32_t, int64_t);
typedef void (*SLEventPostToPid_t)(pid_t, CGEventRef);
// Private: set the event's WINDOW-LOCAL location (top-left origin, y-down). This
// is what makes the routed (field-51) event hit-test at the right point inside
// the target window — without it AppKit derives locationInWindow as (0,…) and
// the click misses the control. See research/hittest/README.md.
typedef void (*CGEventSetWindowLocation_t)(CGEventRef, double, double);

// Public preflight (CoreGraphics) — check current process' Screen Recording grant
// without triggering a prompt.
extern bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));

// csops(): query a process' code-signing status. On a box booted with
// amfi_get_out_of_my_way=1, AMFI stamps EVERY non-Apple binary CS_PLATFORM_BINARY;
// since winctl is Developer-signed (not an Apple platform binary), that flag on
// ourselves is a reliable signal that AMFI enforcement is relaxed — which is
// exactly the regime where tccd denies prompts and a manual path-identity grant
// is both necessary and possible.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x04000000
#endif

static const char *kSystemTCC = "/Library/Application Support/com.apple.TCC/TCC.db";
static const char *kSelfClient = "com.nscake.winctl";  // our own stable TCC identity (see below)

// The AX-family services winctl needs, granted by PATH (see `grant`/`doctor`).
static const char *kWinctlServices[] = {
    "kTCCServiceScreenCapture",   // shot
    "kTCCServiceAccessibility",   // describe / --press
    "kTCCServicePostEvent",       // click / type / key (synthetic input)
    "kTCCServiceListenEvent",     // composes to Accessibility
};

// YES when AMFI enforcement is relaxed on this machine (amfi_get_out_of_my_way).
static BOOL amfiRelaxed(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & CS_PLATFORM_BINARY) != 0;
}

// This binary's resolved (symlink-followed) path — the identity tccd keys a bare
// CLI on. Matches the `binary_path` tccd logs, so it's what a grant must name.
static NSString *selfBinaryPath(void) {
    char exePath[PATH_MAX] = {0}, real[PATH_MAX] = {0};
    uint32_t sz = sizeof(exePath);
    if (_NSGetExecutablePath(exePath, &sz) != 0) return nil;
    const char *p = realpath(exePath, real) ? real : exePath;
    return @(p);
}

static NSString *sqlQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------
static void die(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "winctl: %s\n", s.UTF8String);
    exit(1);
}

static NSString *jsonEscape(NSString *s) {
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

// ---------------------------------------------------------------------------
// Window model + target resolution
// ---------------------------------------------------------------------------
typedef struct {
    CGWindowID wid;
    pid_t pid;
    CGRect bounds;   // CG global coords, top-left origin, y-down
    BOOL found;
} PGTarget;

// Copy on-screen (or all) window info dictionaries.
static NSArray<NSDictionary *> *copyWindows(BOOL all) {
    CGWindowListOption opt = all ? (kCGWindowListOptionAll)
                                 : (kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements);
    CFArrayRef arr = CGWindowListCopyWindowInfo(opt, kCGNullWindowID);
    return CFBridgingRelease(arr);
}

static CGRect boundsOf(NSDictionary *w) {
    CGRect b = CGRectZero;
    CFDictionaryRef d = (__bridge CFDictionaryRef)w[(id)kCGWindowBounds];
    if (d) CGRectMakeWithDictionaryRepresentation(d, &b);
    return b;
}

// A "normal" window: layer 0, non-trivial size, visible alpha.
static BOOL isNormalWindow(NSDictionary *w) {
    NSNumber *layer = w[(id)kCGWindowLayer];
    if (layer && layer.intValue != 0) return NO;
    NSNumber *alpha = w[(id)kCGWindowAlpha];
    if (alpha && alpha.doubleValue <= 0.0) return NO;
    CGRect b = boundsOf(w);
    if (b.size.width < 2 || b.size.height < 2) return NO;
    return YES;
}

// Pick the largest normal window from a candidate list (front-to-back order is
// preserved by CGWindowList; area is a robust tiebreaker that avoids tiny
// helper/panel windows).
static NSDictionary *largestNormal(NSArray<NSDictionary *> *cands) {
    NSDictionary *best = nil; double bestArea = -1;
    for (NSDictionary *w in cands) {
        if (!isNormalWindow(w)) continue;
        CGRect b = boundsOf(w);
        double a = b.size.width * b.size.height;
        if (a > bestArea) { bestArea = a; best = w; }
    }
    return best;
}

static PGTarget resolveTarget(NSString *target) {
    PGTarget t = {0}; t.found = NO;
    NSArray<NSDictionary *> *wins = copyWindows(NO);

    if ([target hasPrefix:@"win:"]) {
        CGWindowID wid = (CGWindowID)strtoul([target substringFromIndex:4].UTF8String, NULL, 10);
        // Search including off-screen so win:ID always resolves if it exists.
        NSArray<NSDictionary *> *all = copyWindows(YES);
        for (NSDictionary *w in all) {
            if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid) {
                t.wid = wid; t.pid = (pid_t)[w[(id)kCGWindowOwnerPID] intValue];
                t.bounds = boundsOf(w); t.found = YES; return t;
            }
        }
        return t;
    }

    if ([target hasPrefix:@"pid:"]) {
        pid_t pid = (pid_t)atoi([target substringFromIndex:4].UTF8String);
        // Prefer an on-screen normal window; fall back to any (off-screen / other
        // Space) so capture-by-pid still works when the window isn't frontmost.
        for (int pass = 0; pass < 2 && !t.found; pass++) {
            NSArray<NSDictionary *> *pool = pass == 0 ? wins : copyWindows(YES);
            NSMutableArray *cands = [NSMutableArray array];
            for (NSDictionary *w in pool)
                if ((pid_t)[w[(id)kCGWindowOwnerPID] intValue] == pid) [cands addObject:w];
            NSDictionary *best = largestNormal(cands);
            if (best) {
                t.wid = [best[(id)kCGWindowNumber] unsignedIntValue];
                t.pid = pid; t.bounds = boundsOf(best); t.found = YES;
            }
        }
        return t;
    }

    // App-name substring (case-insensitive) against the owner name. Prefer an
    // on-screen normal window; fall back to any window for the same app.
    for (int pass = 0; pass < 2 && !t.found; pass++) {
        NSArray<NSDictionary *> *pool = pass == 0 ? wins : copyWindows(YES);
        NSMutableArray *cands = [NSMutableArray array];
        for (NSDictionary *w in pool) {
            NSString *owner = w[(id)kCGWindowOwnerName];
            if (owner && [owner rangeOfString:target options:NSCaseInsensitiveSearch].location != NSNotFound)
                [cands addObject:w];
        }
        NSDictionary *best = largestNormal(cands);
        if (best) {
            t.wid = [best[(id)kCGWindowNumber] unsignedIntValue];
            t.pid = (pid_t)[best[(id)kCGWindowOwnerPID] intValue];
            t.bounds = boundsOf(best); t.found = YES;
        }
    }
    return t;
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------
static int cmd_list(NSArray<NSString *> *args) {
    BOOL all = [args containsObject:@"--all"];
    BOOL json = [args containsObject:@"--json"];
    NSArray<NSDictionary *> *wins = copyWindows(all);

    if (json) {
        NSMutableString *out = [NSMutableString stringWithString:@"["];
        BOOL first = YES;
        for (NSDictionary *w in wins) {
            if (!all && !isNormalWindow(w)) continue;
            CGRect b = boundsOf(w);
            if (!first) [out appendString:@","];
            first = NO;
            [out appendFormat:@"{\"windowId\":%u,\"pid\":%d,\"app\":\"%@\",\"title\":\"%@\",\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f}",
                [w[(id)kCGWindowNumber] unsignedIntValue],
                [w[(id)kCGWindowOwnerPID] intValue],
                jsonEscape(w[(id)kCGWindowOwnerName]),
                jsonEscape(w[(id)kCGWindowName]),
                b.origin.x, b.origin.y, b.size.width, b.size.height];
        }
        [out appendString:@"]"];
        printf("%s\n", out.UTF8String);
        return 0;
    }

    printf("%-8s  %-6s  %-24s  %-30s  %5s %5s %5s %5s\n",
           "win-id", "pid", "app", "title", "x", "y", "w", "h");
    for (NSDictionary *w in wins) {
        if (!all && !isNormalWindow(w)) continue;
        CGRect b = boundsOf(w);
        NSString *app = w[(id)kCGWindowOwnerName] ?: @"?";
        NSString *title = w[(id)kCGWindowName] ?: @"";
        if (app.length > 24) app = [app substringToIndex:24];
        if (title.length > 30) title = [title substringToIndex:30];
        printf("%-8u  %-6d  %-24s  %-30s  %5.0f %5.0f %5.0f %5.0f\n",
               [w[(id)kCGWindowNumber] unsignedIntValue],
               [w[(id)kCGWindowOwnerPID] intValue],
               app.UTF8String, title.UTF8String,
               b.origin.x, b.origin.y, b.size.width, b.size.height);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------
// Returns a +1 CGImageRef (caller CFReleases) for the given window, preferring
// SkyLight HW capture (2x retina, cleanest pixels), falling back to the
// obsoleted CGWindowListCreateImage. Returns NULL on failure.
static CGImageRef captureWindow(CGWindowID wid, const char **methodOut) {
    // SkyLight HW capture.
    CGSMainConnectionID_t mainCID = (CGSMainConnectionID_t)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    HWCapture_t sls = (HWCapture_t)dlsym(RTLD_DEFAULT, "SLSHWCaptureWindowList");
    HWCapture_t cgs = (HWCapture_t)dlsym(RTLD_DEFAULT, "CGSHWCaptureWindowList");
    if (mainCID && (sls || cgs)) {
        CGSConnectionID cid = mainCID();
        CGWindowID list[1] = { wid };
        uint32_t opts[] = { 0, 0x0800 };
        for (int oi = 0; oi < 2; oi++) {
            CFArrayRef arr = NULL;
            if (sls) arr = sls(cid, list, 1, opts[oi]);
            if ((!arr || CFArrayGetCount(arr) == 0) && cgs) {
                if (arr) CFRelease(arr);
                arr = cgs(cid, list, 1, opts[oi]);
            }
            if (arr && CFArrayGetCount(arr) > 0) {
                CGImageRef img = (CGImageRef)CFArrayGetValueAtIndex(arr, 0);
                CGImageRef ret = CGImageRetain(img);
                CFRelease(arr);
                if (methodOut) *methodOut = "SkyLightHW";
                return ret;
            }
            if (arr) CFRelease(arr);
        }
    }
    // Fallback: CGWindowListCreateImage (compile-time unavailable in the 15 SDK).
    CGWindowListCreateImage_t fn = (CGWindowListCreateImage_t)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (fn) {
        CGImageRef img = fn(CGRectNull, kCGWindowListOptionIncludingWindow, wid,
                            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
        if (img) { if (methodOut) *methodOut = "CGWindowListCreateImage"; return img; }
    }
    if (methodOut) *methodOut = "none";
    return NULL;
}

// Write CGImage to PNG; report the fraction of sampled pixels that are non-black.
static BOOL writePNG(CGImageRef img, NSString *path, double *nonblackOut) {
    if (!img) return NO;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w == 0 || h == 0) return NO;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL ok = [png writeToFile:path atomically:YES];
    if (nonblackOut) {
        long long nb = 0, cnt = 0;
        for (size_t y = 0; y < h; y += 8) for (size_t x = 0; x < w; x += 8) {
            NSColor *c = [[rep colorAtX:(NSInteger)x y:(NSInteger)y]
                          colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            CGFloat r,g,b,a; [c getRed:&r green:&g blue:&b alpha:&a];
            if ((r+g+b) * 255 > 30) nb++;
            cnt++;
        }
        *nonblackOut = cnt ? (double)nb/cnt : 0;
    }
    return ok;
}

static int cmd_shot(NSArray<NSString *> *args) {
    BOOL json = [args containsObject:@"--json"];
    NSMutableArray *pos = [NSMutableArray array];
    for (NSString *a in args) if (![a hasPrefix:@"--"]) [pos addObject:a];
    if (pos.count < 2) die(@"usage: winctl shot <target> <out.png> [--json]");
    NSString *targetStr = pos[0];
    NSString *outPath = [pos[1] stringByExpandingTildeInPath];

    PGTarget t = resolveTarget(targetStr);
    if (!t.found) die(@"no window matched target '%@' (try `winctl list`)", targetStr);

    const char *method = "none";
    CGImageRef img = captureWindow(t.wid, &method);
    if (!img)
        die(@"capture failed for win:%u (Screen Recording not granted to the responsible app? run `winctl doctor`)", t.wid);

    double nb = 0;
    BOOL ok = writePNG(img, outPath, &nb);
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CFRelease(img);
    if (!ok) die(@"failed to write PNG to %@", outPath);

    if (json) {
        printf("{\"path\":\"%s\",\"width\":%zu,\"height\":%zu,\"windowId\":%u,\"method\":\"%s\",\"nonblack\":%.3f}\n",
               jsonEscape(outPath).UTF8String, w, h, t.wid, method, nb);
    } else {
        printf("wrote %s (%zux%zu, win:%u, %s, nonblack=%.3f)\n",
               outPath.UTF8String, w, h, t.wid, method, nb);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Input synthesis via CGEventPostToPid (cursor-free, out-of-process)
// ---------------------------------------------------------------------------
static int cmd_type(NSArray<NSString *> *args) {
    if (args.count < 2) die(@"usage: winctl type <target> <text...>");
    NSString *targetStr = args[0];
    NSString *text = [[args subarrayWithRange:NSMakeRange(1, args.count-1)] componentsJoinedByString:@" "];

    PGTarget t = resolveTarget(targetStr);
    if (!t.found) die(@"no window matched target '%@'", targetStr);

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    NSUInteger n = text.length;
    for (NSUInteger i = 0; i < n; i++) {
        UniChar ch = [text characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true);
        CGEventRef up   = CGEventCreateKeyboardEvent(src, 0, false);
        CGEventKeyboardSetUnicodeString(down, 1, &ch);
        CGEventKeyboardSetUnicodeString(up,   1, &ch);
        CGEventPostToPid(t.pid, down);
        CGEventPostToPid(t.pid, up);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        usleep(4000);
    }
    if (src) CFRelease(src);
    printf("typed %lu chars to pid %d (win:%u)\n", (unsigned long)n, t.pid, t.wid);
    return 0;
}

// keyspec -> (base keycode, modifier flags)
static BOOL parseKeyspec(NSString *spec, CGKeyCode *codeOut, CGEventFlags *flagsOut) {
    NSDictionary<NSString *, NSNumber *> *named = @{
        @"return": @36, @"enter": @36, @"tab": @48, @"space": @49,
        @"delete": @51, @"backspace": @51, @"forwarddelete": @117,
        @"esc": @53, @"escape": @53,
        @"left": @123, @"right": @124, @"down": @125, @"up": @126,
        @"home": @115, @"end": @119, @"pageup": @116, @"pagedown": @121,
        @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97,
        @"f7": @98, @"f8": @100, @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111,
    };
    NSDictionary<NSString *, NSNumber *> *letters = @{
        @"a":@0,@"s":@1,@"d":@2,@"f":@3,@"h":@4,@"g":@5,@"z":@6,@"x":@7,@"c":@8,
        @"v":@9,@"b":@11,@"q":@12,@"w":@13,@"e":@14,@"r":@15,@"y":@16,@"t":@17,
        @"o":@31,@"u":@32,@"i":@34,@"p":@35,@"l":@37,@"j":@38,@"k":@40,@"n":@45,@"m":@46,
        @"1":@18,@"2":@19,@"3":@20,@"4":@21,@"5":@23,@"6":@22,@"7":@26,@"8":@28,@"9":@25,@"0":@29,
        @"-":@27,@"=":@24,@"[":@33,@"]":@30,@";":@41,@"'":@39,@",":@43,@".":@47,@"/":@44,@"`":@50,@"\\":@42,
    };
    CGEventFlags flags = 0;
    NSArray<NSString *> *parts = [spec.lowercaseString componentsSeparatedByString:@"+"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *p = parts[i];
        BOOL isLast = (i == parts.count - 1);
        if (!isLast) {
            if ([p isEqualToString:@"cmd"] || [p isEqualToString:@"command"] || [p isEqualToString:@"⌘"]) flags |= kCGEventFlagMaskCommand;
            else if ([p isEqualToString:@"shift"] || [p isEqualToString:@"⇧"]) flags |= kCGEventFlagMaskShift;
            else if ([p isEqualToString:@"ctrl"] || [p isEqualToString:@"control"] || [p isEqualToString:@"⌃"]) flags |= kCGEventFlagMaskControl;
            else if ([p isEqualToString:@"alt"] || [p isEqualToString:@"opt"] || [p isEqualToString:@"option"] || [p isEqualToString:@"⌥"]) flags |= kCGEventFlagMaskAlternate;
            else if ([p isEqualToString:@"fn"]) flags |= kCGEventFlagMaskSecondaryFn;
            else return NO;  // unknown modifier
        } else {
            NSNumber *code = named[p] ?: letters[p];
            if (!code) return NO;
            *codeOut = (CGKeyCode)code.intValue;
        }
    }
    *flagsOut = flags;
    return YES;
}

static int cmd_key(NSArray<NSString *> *args) {
    if (args.count < 2) die(@"usage: winctl key <target> <keyspec>  (e.g. return, cmd+s, cmd+shift+4)");
    NSString *targetStr = args[0];
    NSString *spec = args[1];

    CGKeyCode code = 0; CGEventFlags flags = 0;
    if (!parseKeyspec(spec, &code, &flags))
        die(@"could not parse keyspec '%@'", spec);

    PGTarget t = resolveTarget(targetStr);
    if (!t.found) die(@"no window matched target '%@'", targetStr);

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, code, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, code, false);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPostToPid(t.pid, down);
    usleep(8000);
    CGEventPostToPid(t.pid, up);
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    if (src) CFRelease(src);
    printf("sent key '%s' (code %u, flags 0x%llx) to pid %d (win:%u)\n",
           spec.UTF8String, code, (unsigned long long)flags, t.pid, t.wid);
    return 0;
}

// ---------------------------------------------------------------------------
// `hold` — press key(s) DOWN, wait, then release UP. Games that integrate
// movement over HELD-key time (Panda3D / Toontown) don't move on a tap; they
// need the key down for a real duration. Delivered via the same cursor-free
// CGEventPostToPid path as `key`, so it actuates a BACKGROUND window.
//
// The keyUp is GUARANTEED: an interrupt (Ctrl+C / SIGTERM) only sets a flag —
// the ordered release below still runs — so winctl NEVER leaves a key stuck
// down in the target.
// ---------------------------------------------------------------------------
static CGEventSourceRef gHoldSrc = NULL;         // shared source for a hold session
static pid_t            gHoldPid = 0;            // target pid for held keys
static CGKeyCode        gHeldCodes[16];          // keys currently DOWN (press order)
static CGEventFlags     gHeldFlags[16];          // flags each was pressed with
static int              gHeldN = 0;
static volatile sig_atomic_t gHoldInterrupted = 0;

// Async-signal-safe: only record that we were interrupted. The hold loop sees
// the flag, stops, and releases everything through the normal code path.
static void onHoldSignal(int sig) { (void)sig; gHoldInterrupted = 1; }

static void holdPress(CGKeyCode code, CGEventFlags flags) {
    CGEventRef e = CGEventCreateKeyboardEvent(gHoldSrc, code, true);
    if (!e) return;
    CGEventSetFlags(e, flags);
    CGEventPostToPid(gHoldPid, e);
    CFRelease(e);
    if (gHeldN < (int)(sizeof(gHeldCodes) / sizeof(*gHeldCodes))) {
        gHeldCodes[gHeldN] = code; gHeldFlags[gHeldN] = flags; gHeldN++;
    }
}

// Release every held key in reverse press order (base key first, then the
// modifiers). Idempotent — safe after a partial press or a second call.
static void holdReleaseAll(void) {
    for (int i = gHeldN - 1; i >= 0; i--) {
        CGEventRef e = CGEventCreateKeyboardEvent(gHoldSrc, gHeldCodes[i], false);
        if (!e) continue;
        CGEventSetFlags(e, gHeldFlags[i]);
        CGEventPostToPid(gHoldPid, e);
        CFRelease(e);
    }
    gHeldN = 0;
}

// One segment: press the chord's modifiers (cumulative flags) then the base key
// DOWN, hold duration_ms, then release everything UP. Returns NO if interrupted.
static BOOL holdOne(CGKeyCode code, CGEventFlags flags, int duration_ms, int repeat_ms) {
    static const struct { CGEventFlags mask; CGKeyCode kc; } kMods[] = {
        { kCGEventFlagMaskCommand,     55 },   // command
        { kCGEventFlagMaskShift,       56 },   // shift
        { kCGEventFlagMaskControl,     59 },   // control
        { kCGEventFlagMaskAlternate,   58 },   // option
        { kCGEventFlagMaskSecondaryFn, 63 },   // fn
    };
    CGEventFlags cum = 0;
    for (int i = 0; i < (int)(sizeof(kMods) / sizeof(*kMods)); i++)
        if (flags & kMods[i].mask) { cum |= kMods[i].mask; holdPress(kMods[i].kc, cum); }
    holdPress(code, flags);   // base key DOWN, carrying the full chord's flags

    // Hold. Sleep in short slices so an interrupt breaks out promptly. A single
    // held keydown is enough for engines that latch on the down/up transition
    // (Panda3D / Toontown); --repeat pulses autorepeat keydowns for anything
    // that instead needs a repeating stream to sustain the action.
    int elapsed = 0, sinceRep = 0; const int slice = 10;   // ms
    while (elapsed < duration_ms && !gHoldInterrupted) {
        usleep((useconds_t)slice * 1000);
        elapsed += slice; sinceRep += slice;
        if (repeat_ms > 0 && sinceRep >= repeat_ms && !gHoldInterrupted) {
            CGEventRef r = CGEventCreateKeyboardEvent(gHoldSrc, code, true);
            if (r) {
                CGEventSetFlags(r, flags);
                CGEventSetIntegerValueField(r, kCGKeyboardEventAutorepeat, 1);
                CGEventPostToPid(gHoldPid, r);
                CFRelease(r);
            }
            sinceRep = 0;
        }
    }

    holdReleaseAll();   // ALWAYS: base UP, then modifiers UP (reverse order)
    return !gHoldInterrupted;
}

// A non-empty token made up entirely of decimal digits (a bare duration).
static BOOL isAllDigits(NSString *s) {
    if (s.length == 0) return NO;
    NSCharacterSet *notDigit = [NSCharacterSet decimalDigitCharacterSet].invertedSet;
    return [s rangeOfCharacterFromSet:notDigit].location == NSNotFound;
}

static int cmd_hold(NSArray<NSString *> *args) {
    // Optional flags first, so a numeric positional isn't mistaken for a value.
    int repeat_ms = 0;
    NSMutableArray<NSString *> *pos = [NSMutableArray array];
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--repeat"] && i + 1 < args.count) repeat_ms = args[++i].intValue;
        else if ([a hasPrefix:@"--repeat="]) repeat_ms = [a substringFromIndex:9].intValue;
        else [pos addObject:a];
    }
    if (pos.count < 2)
        die(@"usage: winctl hold <target> <keyspec>[:ms] [duration_ms | more segments]\n"
             "       winctl hold win:42 up 1500            (single hold, 1500 ms)\n"
             "       winctl hold win:42 up:1200 left:400   (sequence of timed holds)");

    NSString *targetStr = pos[0];

    // Parse the tokens after the target into (keyspec, ms, code, flags) segments.
    // "keyspec:ms" is one segment; a bare keyspec defaults to 500 ms; a lone
    // integer overrides the PREVIOUS segment's duration (the single-hold form
    // `hold <target> up 1500`). All keyspecs are validated up front, before we
    // touch the target, so a typo can't leave a key half-pressed.
    NSMutableArray<NSMutableArray *> *segs = [NSMutableArray array];
    for (NSUInteger i = 1; i < pos.count; i++) {
        NSString *tok = pos[i];
        if (isAllDigits(tok)) {
            if (segs.count == 0) die(@"'%@' has no keyspec before it", tok);
            int ms = tok.intValue; if (ms < 1) ms = 1; if (ms > 120000) ms = 120000;
            segs.lastObject[1] = @(ms);
            continue;
        }
        NSString *spec = tok; int ms = 500;
        NSRange colon = [tok rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location != NSNotFound) {
            NSString *msStr = [tok substringFromIndex:colon.location + 1];
            if (!isAllDigits(msStr)) die(@"bad segment '%@' (want keyspec:ms, e.g. up:1200)", tok);
            spec = [tok substringToIndex:colon.location];
            ms = msStr.intValue;
        }
        CGKeyCode code = 0; CGEventFlags flags = 0;
        if (!parseKeyspec(spec, &code, &flags)) die(@"could not parse keyspec '%@'", spec);
        if (ms < 1) ms = 1; if (ms > 120000) ms = 120000;   // cap: never hold past 2 min
        [segs addObject:@[spec, @(ms), @(code), @(flags)].mutableCopy];
    }
    if (segs.count == 0) die(@"no keyspec to hold");

    PGTarget t = resolveTarget(targetStr);
    if (!t.found) die(@"no window matched target '%@'", targetStr);

    // Guaranteed-release wiring: an interrupt only sets gHoldInterrupted; the
    // release inside holdOne still runs, so no key is ever left stuck DOWN.
    gHoldSrc = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    gHoldPid = t.pid;
    signal(SIGINT,  onHoldSignal);
    signal(SIGTERM, onHoldSignal);

    for (NSUInteger i = 0; i < segs.count; i++) {
        NSArray *s = segs[i];
        CGKeyCode code = (CGKeyCode)[s[2] unsignedIntValue];
        CGEventFlags flags = (CGEventFlags)[s[3] unsignedLongLongValue];
        if (!holdOne(code, flags, [s[1] intValue], repeat_ms)) break;   // interrupted
        if (i + 1 < segs.count) usleep(8000);                           // gap between segments
    }
    if (gHoldSrc) { CFRelease(gHoldSrc); gHoldSrc = NULL; }

    NSMutableArray<NSString *> *shown = [NSMutableArray array];
    for (NSArray *s in segs) [shown addObject:[NSString stringWithFormat:@"%@:%@ms", s[0], s[1]]];
    printf("held %s on pid %d (win:%u)%s\n",
           [shown componentsJoinedByString:@" "].UTF8String, t.pid, t.wid,
           gHoldInterrupted ? "  [interrupted — keys released]" : "");
    return gHoldInterrupted ? 130 : 0;
}

// Stamp an integer field on a CGEvent, preferring the non-validating SkyLight
// setter (so the undocumented window-routing index 51 actually lands); fall back
// to the public setter if SkyLight isn't resolvable.
static void stampField(SLEventSetIntegerValueField_t sl, CGEventRef ev, uint32_t f, int64_t v) {
    if (sl) sl(ev, f, v);
    else    CGEventSetIntegerValueField(ev, (CGEventField)f, v);
}

// Apply the verified window-routing stamp set that makes a backgrounded window
// hit-test the event to its control instead of falling back to a screen-location
// hit-test (which skips non-key windows -> the target sees windowNumber 0 and no
// control fires). Field 51 = the target CGWindowID is the essential router;
// 1/3/7/40 make it a valid actuating left click. See research/hittest/README.md.
static void stampClick(SLEventSetIntegerValueField_t sl, CGEventSetWindowLocation_t setLoc,
                       CGEventRef ev, pid_t pid, CGWindowID wid,
                       double wx, double wy, int64_t clickState, int64_t group) {
    if (setLoc) setLoc(ev, wx, wy);  // window-local hit-test point (top-left origin)
    stampField(sl, ev, 1,  clickState);  // kCGMouseEventClickState (0 for move, 1 for down/up)
    stampField(sl, ev, 3,  0);    // kCGMouseEventButtonNumber (0 = left)
    stampField(sl, ev, 7,  3);    // kCGMouseEventSubtype (NSEventSubtypeTouch)
    stampField(sl, ev, 40, pid);  // kCGEventTargetUnixProcessID
    stampField(sl, ev, 58, group);// click-group id (gesture coalescing)
    stampField(sl, ev, 51, wid);  // windowNumber (undocumented) — the router
    stampField(sl, ev, 91, wid);  // kCGMouseEventWindowUnderMousePointer
    stampField(sl, ev, 92, wid);  // ...ThatCanHandleThisEvent
}

// ---------------------------------------------------------------------------
// Accessibility: element tree (describe) + element targeting for click.
// ---------------------------------------------------------------------------
// This is the OOP analog of the sim tool's `describe`: we read the target's
// accessibility element tree from OUTSIDE the process (no injection). It needs
// the *responsible* identity to hold the Accessibility grant — under our
// self-disclaim that means winctl's own grant; run WINCTL_DISCLAIMED=1 to borrow
// the calling host's grant instead (used for testing before the one-time grant).

// Read a string-ish attribute (AXString or AXNumber) as an NSString, or nil.
static NSString *axString(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID())      s = [(__bridge NSString *)v copy];
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) s = [(__bridge NSNumber *)v stringValue];
    CFRelease(v);
    return s;
}

// The human label for a node: first non-empty of Title / Description / Value / Help.
static NSString *axLabel(AXUIElementRef el) {
    CFStringRef attrs[] = { kAXTitleAttribute, kAXDescriptionAttribute,
                            kAXValueAttribute, kAXHelpAttribute };
    for (int i = 0; i < 4; i++) {
        NSString *s = axString(el, attrs[i]);
        if (s.length) return s;
    }
    return @"";
}

// Screen frame (top-left origin, y-down — same convention as CGWindowBounds and
// our synthetic-click global coords), or NO if the element has no geometry.
static BOOL axFrame(AXUIElementRef el, CGRect *out) {
    CFTypeRef posV = NULL, sizeV = NULL;
    CGPoint p = CGPointZero; CGSize s = CGSizeZero;
    BOOL ok = NO;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &posV) == kAXErrorSuccess && posV) {
        AXValueGetValue((AXValueRef)posV, kAXValueCGPointType, &p);
        if (AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &sizeV) == kAXErrorSuccess && sizeV) {
            AXValueGetValue((AXValueRef)sizeV, kAXValueCGSizeType, &s);
            *out = CGRectMake(p.x, p.y, s.width, s.height);
            ok = YES;
            CFRelease(sizeV);
        }
        CFRelease(posV);
    }
    return ok;
}

// Does the element expose AXPress (i.e. is it a first-class click target)?
static BOOL axPressable(AXUIElementRef el) {
    CFArrayRef names = NULL;
    BOOL press = NO;
    if (AXUIElementCopyActionNames(el, &names) == kAXErrorSuccess && names) {
        press = CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), kAXPressAction);
        CFRelease(names);
    }
    return press;
}

typedef void (^AXVisitor)(AXUIElementRef el, int depth, BOOL *stop);
static void axWalk(AXUIElementRef el, int depth, int maxDepth, BOOL *stop, AXVisitor visit) {
    if (*stop) return;
    visit(el, depth, stop);
    if (*stop || depth >= maxDepth) return;
    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
        CFArrayRef arr = (CFArrayRef)kids;
        CFIndex n = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n && !*stop; i++)
            axWalk((AXUIElementRef)CFArrayGetValueAtIndex(arr, i), depth + 1, maxDepth, stop, visit);
        CFRelease(kids);
    }
}

// Does a node match the (optional) role / title-substring / identifier filters?
static BOOL axMatches(AXUIElementRef el, NSString *role, NSString *title, NSString *ident) {
    if (role) {
        NSString *r = axString(el, kAXRoleAttribute);
        if (!(r && [r caseInsensitiveCompare:role] == NSOrderedSame)) return NO;
    }
    if (ident) {
        NSString *idv = axString(el, kAXIdentifierAttribute);
        if (!(idv && [idv isEqualToString:ident])) return NO;
    }
    if (title) {
        NSString *lbl = axLabel(el);
        if (!(lbl && [lbl rangeOfString:title options:NSCaseInsensitiveSearch].location != NSNotFound))
            return NO;
    }
    return YES;
}

// First element (depth-first) matching the filters AND having a clickable frame.
// Returns a +1 AXUIElementRef (caller CFReleases) and fills frameOut, or NULL.
static AXUIElementRef copyMatchingElement(pid_t pid, NSString *role, NSString *title,
                                          NSString *ident, CGRect *frameOut) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    __block AXUIElementRef match = NULL;
    __block CGRect mframe = CGRectZero;
    BOOL stop = NO;
    axWalk(app, 0, 80, &stop, ^(AXUIElementRef el, int depth, BOOL *st) {
        if (!axMatches(el, role, title, ident)) return;
        CGRect f; if (!axFrame(el, &f) || f.size.width < 1 || f.size.height < 1) return;
        match = (AXUIElementRef)CFRetain(el); mframe = f; *st = YES;
    });
    CFRelease(app);
    if (match && frameOut) *frameOut = mframe;
    return match;
}

static int cmd_describe(NSArray<NSString *> *args) {
    BOOL json = [args containsObject:@"--json"];
    BOOL actionable = [args containsObject:@"--actionable"];
    NSMutableArray *pos = [NSMutableArray array];
    NSString *role = nil, *title = nil, *ident = nil; int maxDepth = 60;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if      ([a isEqualToString:@"--role"]  && i + 1 < args.count) role  = args[++i];
        else if ([a isEqualToString:@"--title"] && i + 1 < args.count) title = args[++i];
        else if ([a isEqualToString:@"--id"]    && i + 1 < args.count) ident = args[++i];
        else if ([a isEqualToString:@"--depth"] && i + 1 < args.count) maxDepth = args[++i].intValue;
        else if (![a hasPrefix:@"--"]) [pos addObject:a];
    }
    if (pos.count < 1)
        die(@"usage: winctl describe <target> [--actionable] [--role R] [--title T] [--id ID] [--depth N] [--json]");

    PGTarget t = resolveTarget(pos[0]);
    if (!t.found) die(@"no window matched target '%@'", pos[0]);
    if (!AXIsProcessTrusted())
        fprintf(stderr, "winctl: warning — Accessibility not granted to the responsible identity; "
                        "tree may be empty. Run `winctl doctor`.\n");

    AXUIElementRef app = AXUIElementCreateApplication(t.pid);
    __block NSMutableString *out = [NSMutableString stringWithString:json ? @"[" : @""];
    __block BOOL first = YES;
    BOOL stop = NO;
    axWalk(app, 0, maxDepth, &stop, ^(AXUIElementRef el, int depth, BOOL *st) {
        NSString *r = axString(el, kAXRoleAttribute) ?: @"?";
        NSString *lbl = axLabel(el);
        NSString *idv = axString(el, kAXIdentifierAttribute);
        BOOL press = axPressable(el);
        if (!axMatches(el, role, title, ident)) return;
        if (actionable && !press) return;
        CGRect f = CGRectZero; BOOL hasFrame = axFrame(el, &f);
        if (json) {
            if (!first) [out appendString:@","];
            first = NO;
            [out appendFormat:@"{\"depth\":%d,\"role\":\"%@\",\"label\":\"%@\",\"id\":\"%@\","
                              @"\"pressable\":%s,\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f}",
                depth, jsonEscape(r), jsonEscape(lbl), jsonEscape(idv ?: @""),
                press ? "true" : "false",
                f.origin.x, f.origin.y, f.size.width, f.size.height];
        } else {
            NSMutableString *line = [NSMutableString string];
            for (int i = 0; i < depth; i++) [line appendString:@"  "];
            [line appendString:r];
            if (lbl.length)  [line appendFormat:@" “%@”", lbl.length > 60 ? [lbl substringToIndex:60] : lbl];
            if (idv.length)  [line appendFormat:@" #%@", idv];
            if (press)       [line appendString:@" [AXPress]"];
            if (hasFrame)    [line appendFormat:@" @%.0f,%.0f %.0fx%.0f",
                                 f.origin.x, f.origin.y, f.size.width, f.size.height];
            [out appendFormat:@"%@\n", line];
        }
    });
    CFRelease(app);
    if (json) [out appendString:@"]"];
    printf("%s%s", out.UTF8String, json ? "\n" : "");
    return 0;
}

// The proven cursor-free actuation: stamp field 51 = target CGWindowID so a
// BACKGROUND window hit-tests the click to its control, post via
// CGEventPostToPid (+ SLEventPostToPid). Returns how far the real cursor moved
// (should be ~0). See research/hittest/README.md.
static double synthClickAt(PGTarget t, CGPoint g) {
    SLEventSetIntegerValueField_t slSet =
        (SLEventSetIntegerValueField_t)dlsym(RTLD_DEFAULT, "SLEventSetIntegerValueField");
    SLEventPostToPid_t slPost =
        (SLEventPostToPid_t)dlsym(RTLD_DEFAULT, "SLEventPostToPid");
    CGEventSetWindowLocation_t setLoc =
        (CGEventSetWindowLocation_t)dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");

    // Window-local hit-test point (top-left origin, y-down) = global minus the
    // window's CG bounds origin. Essential: field 51 routes the event to the
    // window, but AppKit only hit-tests the control if the window location is set.
    double wx = g.x - t.bounds.origin.x, wy = g.y - t.bounds.origin.y;
    int64_t group = (int64_t)(mach_absolute_time() & 0x7fffffff);

    CGEventRef q0 = CGEventCreate(NULL);
    CGPoint cursorBefore = CGEventGetLocation(q0);
    if (q0) CFRelease(q0);

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef mv   = CGEventCreateMouseEvent(src, kCGEventMouseMoved,    g, kCGMouseButtonLeft);
    CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, g, kCGMouseButtonLeft);
    CGEventRef up   = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp,   g, kCGMouseButtonLeft);
    stampClick(slSet, setLoc, mv,   t.pid, t.wid, wx, wy, 0, group);
    stampClick(slSet, setLoc, down, t.pid, t.wid, wx, wy, 1, group);
    stampClick(slSet, setLoc, up,   t.pid, t.wid, wx, wy, 1, group);
    void (^post)(CGEventRef) = ^(CGEventRef ev){
        if (slPost) slPost(t.pid, ev);
        CGEventPostToPid(t.pid, ev);
    };
    if (mv)   { post(mv);   CFRelease(mv); }
    usleep(15000);
    if (down) { post(down); CFRelease(down); }
    usleep(30000);
    if (up)   { post(up);   CFRelease(up); }
    if (src) CFRelease(src);

    CGEventRef q1 = CGEventCreate(NULL);
    CGPoint cursorAfter = CGEventGetLocation(q1);
    if (q1) CFRelease(q1);
    return hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y);
}

static int cmd_click(NSArray<NSString *> *args) {
    // Two forms:
    //   winctl click <target> <x> <y>                        (window-relative point)
    //   winctl click <target> --title T [--role R] [--id ID] [--press]
    // The element form resolves a control via Accessibility and clicks its
    // center (or, with --press, invokes AXPress directly).
    NSMutableArray *pos = [NSMutableArray array];
    NSString *role = nil, *title = nil, *ident = nil; BOOL usePress = NO;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if      ([a isEqualToString:@"--role"]  && i + 1 < args.count) role  = args[++i];
        else if ([a isEqualToString:@"--title"] && i + 1 < args.count) title = args[++i];
        else if ([a isEqualToString:@"--id"]    && i + 1 < args.count) ident = args[++i];
        else if ([a isEqualToString:@"--press"]) usePress = YES;
        else if (![a hasPrefix:@"--"]) [pos addObject:a];
    }
    BOOL elementMode = (role || title || ident);
    if (!elementMode && pos.count < 3) die(@"usage: winctl click <target> <x> <y>\n"
                                            "   or: winctl click <target> --title T [--role R] [--id ID] [--press]");
    if (pos.count < 1) die(@"winctl click: missing <target>");

    PGTarget t = resolveTarget(pos[0]);
    if (!t.found) die(@"no window matched target '%@'", pos[0]);

    if (elementMode) {
        if (!AXIsProcessTrusted())
            fprintf(stderr, "winctl: warning — Accessibility not granted to the responsible identity; "
                            "element lookup may fail. Run `winctl doctor`.\n");
        CGRect f = CGRectZero;
        AXUIElementRef el = copyMatchingElement(t.pid, role, title, ident, &f);
        if (!el) die(@"no element matched (role=%@ title=%@ id=%@) in %@",
                     role ?: @"*", title ?: @"*", ident ?: @"*", pos[0]);

        NSString *desc = [NSString stringWithFormat:@"role=%@ title=%@ id=%@",
                          role ?: @"*", title ?: @"*", ident ?: @"*"];
        if (usePress) {
            AXError pe = AXUIElementPerformAction(el, kAXPressAction);
            CFRelease(el);
            if (pe != kAXErrorSuccess) die(@"AXPress failed (err=%d)", pe);
            printf("pressed element (%s) via AXPress on pid %d\n", desc.UTF8String, t.pid);
            return 0;
        }
        CGPoint g = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        CFRelease(el);
        double moved = synthClickAt(t, g);
        printf("clicked element (%s) at global %.0f,%.0f on pid %d (win:%u); cursor_moved=%.1fpx\n",
               desc.UTF8String, g.x, g.y, t.pid, t.wid, moved);
        return 0;
    }

    // Coordinate form: window-relative -> CG global (bounds origin is top-left).
    double x = [pos[1] doubleValue], y = [pos[2] doubleValue];
    CGPoint g = CGPointMake(t.bounds.origin.x + x, t.bounds.origin.y + y);
    double moved = synthClickAt(t, g);
    printf("clicked global %.0f,%.0f (win-relative %.0f,%.0f) on pid %d (win:%u); cursor_moved=%.1fpx\n",
           g.x, g.y, x, y, t.pid, t.wid, moved);
    return 0;
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------
// Read a client's auth_value for a service from the system TCC.db (readable by
// the user for SELECT). Returns -1 if the row is absent.
static int tccAuth(const char *service, const char *client) {
    sqlite3 *db = NULL; int auth = -1;
    if (sqlite3_open_v2(kSystemTCC, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return -2; }
    sqlite3_stmt *st = NULL;
    const char *sql = "SELECT auth_value FROM access WHERE service=? AND client=? LIMIT 1;";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, service, -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 2, client, -1, SQLITE_STATIC);
        if (sqlite3_step(st) == SQLITE_ROW) auth = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return auth;
}

static const char *authStr(int a) {
    switch (a) {
        case 2: return "ALLOWED";
        case 0: return "DENIED";
        case 1: return "unknown/limited";
        case -1: return "not set";
        default: return "TCC.db unreadable";
    }
}

static int cmd_doctor(NSArray<NSString *> *args) {
    BOOL json = [args containsObject:@"--json"];

    BOOL disclaimed = getenv("WINCTL_DISCLAIMED") != NULL;

    // Live self-check: because we self-disclaimed, "the responsible process" IS
    // winctl — so these reflect winctl's OWN grant, not the host's.
    BOOL liveScreen = CGPreflightScreenCaptureAccess ? CGPreflightScreenCaptureAccess() : NO;
    BOOL liveAX = AXIsProcessTrusted();

    // Standing grant for winctl in the system TCC.db. On an AMFI-relaxed box a
    // bare CLI is identified by its PATH (client_type=1), not its bundle id —
    // tccd can't resolve a bundle id without a .app — so a bundle-id row is
    // ignored for Accessibility/PostEvent. We therefore accept a grant under
    // EITHER identity (bundle id or the resolved binary path).
    NSString *binPath = selfBinaryPath();
    int (^bestAuth)(const char *) = ^(const char *svc){
        int a = tccAuth(svc, kSelfClient);
        if (binPath) { int b = tccAuth(svc, binPath.UTF8String); if (b > a) a = b; }
        return a;
    };
    int selfScreen = bestAuth("kTCCServiceScreenCapture");
    int selfAX     = bestAuth("kTCCServiceAccessibility");
    BOOL amfi = amfiRelaxed();

    // Three states, not two:
    //   granted  — a TCC.db row says ALLOWED for winctl (bundle-id OR path)
    //   live     — the running (disclaimed) process is actually honored right now
    // GREEN requires BOTH. granted-but-not-live (AMBER) usually means the row is
    // keyed to the WRONG identity — a bundle-id row that tccd won't match for a
    // bare CLI; re-grant by PATH (see below).
    BOOL granted = disclaimed && selfScreen == 2 && selfAX == 2;
    BOOL live    = liveScreen && liveAX;
    BOOL green   = granted && live;

    if (json) {
        printf("{\"disclaimed\":%s,\"amfiRelaxed\":%s,\"liveScreenCapture\":%s,\"liveAccessibility\":%s,"
               "\"self\":{\"client\":\"%s\",\"screenCapture\":\"%s\",\"accessibility\":\"%s\"},"
               "\"granted\":%s,\"liveActive\":%s,\"harnessIndependent\":%s}\n",
               disclaimed?"true":"false", amfi?"true":"false",
               liveScreen?"true":"false", liveAX?"true":"false",
               kSelfClient, authStr(selfScreen), authStr(selfAX),
               granted?"true":"false", live?"true":"false", green?"true":"false");
        return green ? 0 : 1;
    }

    printf("winctl doctor\n");
    printf("==================\n");
    printf("Self-disclaim: %s (TCC-responsible process = %s)\n",
           disclaimed ? "ACTIVE" : "NOT active (running un-disclaimed!)",
           disclaimed ? "winctl itself" : "the calling host");
    printf("AMFI enforcement: %s\n", amfi
           ? "RELAXED (amfi_get_out_of_my_way) — bare CLIs are granted by PATH; `winctl grant` can self-grant"
           : "ENFORCING (standard Mac) — grant via System Settings; winctl can't edit TCC under SIP");
    printf("\n");
    printf("Standing grant for %s (system TCC.db) — authoritative:\n", kSelfClient);
    printf("  kTCCServiceScreenCapture  : %s\n", authStr(selfScreen));
    printf("  kTCCServiceAccessibility  : %s\n", authStr(selfAX));
    printf("\n");
    printf("Live preflight (this running process; may lag briefly after a tccd restart):\n");
    printf("  Screen Recording : %s\n", liveScreen ? "GRANTED" : "not-yet (or lagging)");
    printf("  Accessibility    : %s\n", liveAX ? "GRANTED" : "not-yet (or lagging)");
    printf("\n");
    if (green) {
        printf("=> GREEN: winctl has its own TCC identity and grant, live and active — it WORKS\n"
               "   UNDER ANY HARNESS (VS Code, Terminal, Ocean, cron…): the grant follows winctl,\n"
               "   not the host.\n");
    } else if (granted && !live) {
        printf("=> AMBER: a grant row exists but tccd is NOT honoring it live. Usually the row is\n"
               "   keyed to the WRONG identity — a bundle-id row that tccd can't match for a bare\n"
               "   CLI (it identifies winctl by PATH). Re-grant by PATH; see below.\n");
    } else {
        printf("=> RED: not granted to winctl's own identity yet. See below.\n");
    }

    if (!green) {
        if (amfi)
            printf("\n   Fix: run `sudo winctl grant` (writes winctl's PATH into the system TCC.db).\n");
        else
            printf("\n   Fix: System Settings > Privacy & Security > add %s to\n"
                   "        Accessibility and Screen Recording (winctl can't edit TCC under SIP).\n",
                   binPath ? binPath.UTF8String : "the winctl binary");
    }
    return green ? 0 : 1;
}

// ---------------------------------------------------------------------------
// grant — self-install winctl's TCC grant (AMFI-relaxed boxes only)
// ---------------------------------------------------------------------------
// Writes path-identity rows (client_type=1, NULL csreq) for winctl's four
// services directly into the SYSTEM TCC.db, then restarts tccd. This only works
// where TCC can be edited at all — i.e. AMFI relaxed AND SIP disabled (Tanner's
// research box). On a standard Mac (AMFI enforcing / SIP on) it refuses and
// explains the System Settings route instead.
static int cmd_grant(NSArray<NSString *> *args) {
    BOOL revoke = [args containsObject:@"--revoke"];
    NSString *bin = selfBinaryPath();
    if (!bin) die(@"cannot resolve winctl's own binary path");

    if (!amfiRelaxed()) {
        printf("winctl grant: this looks like a standard Mac (AMFI enforcing). winctl can't\n"
               "edit the SIP-protected TCC database here. Grant it the normal way — prompts work:\n"
               "  System Settings > Privacy & Security > Accessibility     — add %s\n"
               "  System Settings > Privacy & Security > Screen Recording  — add %s\n",
               bin.UTF8String, bin.UTF8String);
        return 2;
    }
    if (geteuid() != 0)
        die(@"writing the system TCC.db needs root — re-run: sudo winctl grant%@",
            revoke ? @" --revoke" : @"");

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(kSystemTCC, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSString *e = db ? @(sqlite3_errmsg(db)) : @"open failed";
        if (db) sqlite3_close(db);
        die(@"cannot open %s for write: %@ (SIP enabled?)", kSystemTCC, e);
    }
    for (size_t i = 0; i < sizeof(kWinctlServices) / sizeof(*kWinctlServices); i++) {
        NSString *sql = revoke
            ? [NSString stringWithFormat:
                @"DELETE FROM access WHERE service='%s' AND client=%@ AND client_type=1;",
                kWinctlServices[i], sqlQuote(bin)]
            : [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO access "
                 "(service,client,client_type,auth_value,auth_reason,auth_version,csreq,flags) "
                 "VALUES ('%s',%@,1,2,4,1,NULL,0);", kWinctlServices[i], sqlQuote(bin)];
        char *err = NULL;
        if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err) != SQLITE_OK) {
            NSString *e = err ? @(err) : @"?";
            sqlite3_free(err);
            sqlite3_close(db);
            die(@"TCC write failed: %@", e);
        }
    }
    sqlite3_close(db);
    system("/usr/bin/killall tccd >/dev/null 2>&1");

    printf("%s winctl by PATH (%s) for: ScreenCapture, Accessibility, PostEvent, ListenEvent.\n",
           revoke ? "Revoked" : "Granted", bin.UTF8String);
    printf("Verify: winctl doctor\n");
    return 0;
}

// ---------------------------------------------------------------------------
// sim — drive an iOS Simulator (capture via simctl, input via idb)
// ---------------------------------------------------------------------------
// Same model as Claude Desktop's simulator pane: discrete device-framebuffer
// screenshots + HID input to the SimDevice — never the host cursor. Capture uses
// `xcrun simctl io … screenshot` (CoreSimulator framebuffer). Input shells out to
// Meta's `idb`, which wraps the SAME FBSimulatorControl/Indigo HID engine Claude
// links in-process — so `sim tap/swipe/type` deliver real device HID events.

// Launch a tool inheriting our stdio; returns its exit status (-1 if it couldn't
// be launched).
static int runInherit(NSString *launchPath, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:launchPath];
    t.arguments = args;
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

// Launch a tool capturing stdout; fills *status. Returns nil if launch failed.
static NSString *runCapture(NSString *launchPath, NSArray<NSString *> *args, int *status) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:launchPath];
    t.arguments = args;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) { if (status) *status = -1; return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (status) *status = t.terminationStatus;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// Common tool dirs not always on a minimal harness PATH: pipx → ~/.local/bin,
// Homebrew → /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel).
static NSArray<NSString *> *extraToolDirs(void) {
    return @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"],
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
    ];
}

// Resolve a tool: PATH first, then the well-known dirs above (nil if absent).
static NSString *toolPath(NSString *name) {
    int st = 0;
    NSString *p = runCapture(@"/usr/bin/which", @[name], &st);
    p = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (st == 0 && p.length) return p;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in extraToolDirs()) {
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:cand]) return cand;
    }
    return nil;
}

// Prepend the well-known dirs to PATH so a launched tool (idb) can itself find
// its helpers (idb_companion) even under a harness with a minimal PATH.
static void augmentPathEnv(void) {
    NSString *cur = @(getenv("PATH") ?: "");
    NSString *extra = [extraToolDirs() componentsJoinedByString:@":"];
    setenv("PATH", [[extra stringByAppendingString:@":"] stringByAppendingString:cur].UTF8String, 1);
}

// Resolve <target> (a udid, a name substring, or "booted") to a concrete udid.
static NSString *simResolveUdid(NSString *target) {
    int st = 0;
    NSString *json = runCapture(@"/usr/bin/xcrun", @[@"simctl", @"list", @"devices", @"-j"], &st);
    if (!json) return nil;
    NSDictionary *root = [NSJSONSerialization
        JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSDictionary *devices = root[@"devices"];
    NSMutableArray<NSDictionary *> *booted = [NSMutableArray array];
    for (NSString *runtime in devices)
        for (NSDictionary *d in devices[runtime])
            if ([d[@"state"] isEqualToString:@"Booted"]) [booted addObject:d];

    BOOL wantBooted = [target isEqualToString:@"booted"];
    for (NSDictionary *d in booted) {
        if (wantBooted) return d[@"udid"];
        if ([d[@"udid"] isEqualToString:target]) return d[@"udid"];
        if ([d[@"name"] rangeOfString:target options:NSCaseInsensitiveSearch].location != NSNotFound)
            return d[@"udid"];
    }
    // An explicit udid that isn't currently booted is still usable for `shot`.
    if (!wantBooted && target.length >= 32 && [target containsString:@"-"]) return target;
    return nil;
}

// Device pixels-per-point (retina scale) from idb, for converting screenshot
// pixel coordinates to the logical points idb's HID expects. 1.0 on failure.
static double simDensity(NSString *idb, NSString *udid) {
    int st = 0;
    NSString *out = runCapture(idb, @[@"describe", @"--json", @"--udid", udid], &st);
    if (!out) return 1.0;
    NSDictionary *d = [NSJSONSerialization
        JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    double density = [d[@"screen_dimensions"][@"density"] doubleValue];
    return density > 0 ? density : 1.0;
}

static int cmd_sim(NSArray<NSString *> *args) {
    if (args.count < 1) {
        fputs("usage: winctl sim <list|shot|tap|swipe|type|key|button> …  (see `winctl sim --help`)\n", stderr);
        return 2;
    }
    NSString *sub = args[0];
    NSArray<NSString *> *rest = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];

    if ([sub isEqualToString:@"list"]) {
        BOOL all = [rest containsObject:@"--all"];
        return runInherit(@"/usr/bin/xcrun",
            all ? @[@"simctl", @"list", @"devices", @"available"]
                : @[@"simctl", @"list", @"devices", @"booted"]);
    }

    NSMutableArray<NSString *> *pos = [NSMutableArray array];
    for (NSString *a in rest) if (![a hasPrefix:@"--"]) [pos addObject:a];
    if (pos.count < 1) die(@"winctl sim %@: missing <udid|name|booted>", sub);
    NSString *udid = simResolveUdid(pos[0]);
    if (!udid) die(@"no simulator matched '%@' (see `winctl sim list`)", pos[0]);

    if ([sub isEqualToString:@"shot"]) {
        if (pos.count < 2) die(@"usage: winctl sim shot <udid|name|booted> <out.png>");
        int st = runInherit(@"/usr/bin/xcrun", @[@"simctl", @"io", udid, @"screenshot", pos[1]]);
        if (st == 0) printf("wrote %s (simulator %s)\n", pos[1].UTF8String, udid.UTF8String);
        return st;
    }

    // Input subcommands need idb (the FBSimulatorControl/Indigo bridge). Make sure
    // idb — and the idb_companion it spawns — are findable under a minimal PATH.
    augmentPathEnv();
    NSString *idb = toolPath(@"idb");
    if (!idb)
        die(@"`idb` is not installed — needed for simulator input (tap/swipe/type/key/button).\n"
             "  install: brew install idb-companion && pip3 install fb-idb\n"
             "Capture (`winctl sim shot`) and `winctl sim list` work without it.");

    // tap/swipe coordinates are given in SHOT PIXELS (what `sim shot` produces)
    // and auto-scaled to the logical points idb wants; `--points` passes raw points.
    BOOL rawPoints = [rest containsObject:@"--points"];
    BOOL coordCmd = [sub isEqualToString:@"tap"] || [sub isEqualToString:@"swipe"];
    double scale = (coordCmd && !rawPoints) ? simDensity(idb, udid) : 1.0;
    NSString *(^pt)(NSString *) = ^(NSString *s) {
        return scale == 1.0 ? s : (NSString *)[@(lround([s doubleValue] / scale)) stringValue];
    };

    NSArray<NSString *> *idbArgs = nil;
    if ([sub isEqualToString:@"tap"]) {
        if (pos.count < 3) die(@"usage: winctl sim tap <target> <x> <y>");
        idbArgs = @[@"ui", @"tap", pt(pos[1]), pt(pos[2]), @"--udid", udid];
    } else if ([sub isEqualToString:@"swipe"]) {
        if (pos.count < 5) die(@"usage: winctl sim swipe <target> <x1> <y1> <x2> <y2> [duration]");
        NSMutableArray *a = [@[@"ui", @"swipe", pt(pos[1]), pt(pos[2]), pt(pos[3]), pt(pos[4])] mutableCopy];
        if (pos.count >= 6) { [a addObject:@"--duration"]; [a addObject:pos[5]]; }
        [a addObjectsFromArray:@[@"--udid", udid]];
        idbArgs = a;
    } else if ([sub isEqualToString:@"type"]) {
        if (pos.count < 2) die(@"usage: winctl sim type <target> <text…>");
        NSString *text = [[pos subarrayWithRange:NSMakeRange(1, pos.count - 1)] componentsJoinedByString:@" "];
        idbArgs = @[@"ui", @"text", text, @"--udid", udid];
    } else if ([sub isEqualToString:@"key"]) {
        if (pos.count < 2) die(@"usage: winctl sim key <target> <hid-keycode>");
        idbArgs = @[@"ui", @"key", pos[1], @"--udid", udid];
    } else if ([sub isEqualToString:@"button"]) {
        if (pos.count < 2) die(@"usage: winctl sim button <target> <APPLE_PAY|HOME|LOCK|SIDE_BUTTON|SIRI>");
        idbArgs = @[@"ui", @"button", pos[1], @"--udid", udid];
    } else {
        die(@"unknown: winctl sim %@ (try list|shot|tap|swipe|type|key|button)", sub);
    }
    return runInherit(idb, idbArgs);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
static void usage(void) {
    fprintf(stderr,
        "winctl — out-of-process, no-injection window capture & input\n\n"
        "usage:\n"
        "  winctl list     [--all] [--json]\n"
        "  winctl shot     <target> <out.png> [--json]\n"
        "  winctl type     <target> <text...>\n"
        "  winctl key      <target> <keyspec>     e.g. return, cmd+s, cmd+shift+4, esc, tab\n"
        "  winctl hold     <target> <keyspec>[:ms] [ms]   hold key(s) DOWN (e.g. up 1500, up:1200 left:400)\n"
        "  winctl click    <target> <x> <y> | --title T [--role R] [--id ID] [--press]\n"
        "  winctl describe <target> [--actionable] [--role R] [--title T] [--id ID] [--json]\n"
        "  winctl doctor   [--json]\n"
        "  winctl grant    [--revoke]             self-install the TCC grant (AMFI-relaxed box)\n"
        "  winctl sim      <list|shot|tap|swipe|type|key|button> …   drive an iOS Simulator\n\n"
        "<target>:  app-name-substring | pid:N | win:ID   (from `winctl list`)\n"
        "`winctl <command> --help` for flags, examples, and caveats.\n"
        "Permissions/capture/input acting up? run `winctl doctor` — it explains this box's\n"
        "TCC/AMFI quirks and how to fix them.\n");
}

// Per-command help — the canonical home for usage/examples/caveats (the skill
// points here rather than duplicating docs). Returns YES if it handled a
// help request for `cmd`.
static BOOL cmdHelp(NSString *cmd, NSArray<NSString *> *args) {
    if (!([args containsObject:@"-h"] || [args containsObject:@"--help"])) return NO;
    const char *h = NULL;
    if ([cmd isEqualToString:@"shot"]) h =
        "winctl shot — screenshot a specific window by reading its backing store.\n\n"
        "  winctl shot <target> <out.png> [--json]\n\n"
        "Returns the ACTUAL window even when `screencapture` gives only the desktop,\n"
        "and works under the screensaver / display-asleep / off-Space (it doesn't read\n"
        "the framebuffer). --json => {path,width,height,windowId,method,nonblack};\n"
        "nonblack near 0 means a blank/black capture — re-check the target.\n";
    else if ([cmd isEqualToString:@"describe"]) h =
        "winctl describe — dump a window's Accessibility element tree, out-of-process.\n\n"
        "  winctl describe <target> [--actionable] [--role R] [--title T] [--id ID] [--depth N] [--json]\n\n"
        "  --actionable   only elements exposing AXPress (the clickable set)\n"
        "  --role/--title/--id   filter matches; --title is a case-insensitive substring\n"
        "  --json         machine-readable\n\n"
        "Each node prints:  role \xE2\x80\x9Clabel\xE2\x80\x9D #identifier [AXPress] @x,y wxh\n"
        "Feed a match into `winctl click --title/--role/--id`.\n"
        "Needs the Accessibility grant (see `winctl doctor`).\n\n"
        "example:\n"
        "  winctl describe Safari --actionable\n";
    else if ([cmd isEqualToString:@"click"]) h =
        "winctl click — click a control in a window (out-of-process; cursor never moves).\n\n"
        "  winctl click <target> <x> <y>                       window-relative point\n"
        "  winctl click <target> --title T [--role R] [--id ID] [--press]\n\n"
        "Element form (prefer over x/y — far less brittle):\n"
        "  --title T   control whose label/title contains T (case-insensitive)\n"
        "  --role  R   AX role, e.g. AXButton, to disambiguate\n"
        "  --id    ID  exact AX identifier (from `winctl describe`)\n"
        "  --press     invoke AXPress directly — most robust for buttons; no geometry\n\n"
        "Actuates a BACKGROUND window without activating it. Needs the Accessibility\n"
        "grant (see `winctl doctor`). Works unlocked or under a screensaver; a real\n"
        "password-LOCK makes WindowServer drop ALL synthetic input.\n\n"
        "examples:\n"
        "  winctl click Safari --title \"Reload\"\n"
        "  winctl click Safari --id GoBackButton --press\n"
        "  winctl click win:9125 90 72\n";
    else if ([cmd isEqualToString:@"type"] || [cmd isEqualToString:@"key"]) h =
        "winctl type — type unicode text into the focused responder (cursor-free).\n"
        "  winctl type <target> <text...>\n\n"
        "winctl key — press a key or chord (cursor-free).\n"
        "  winctl key <target> <keyspec>     e.g. return, tab, esc, cmd+s, cmd+shift+4\n\n"
        "Both deliver to the target's key window. Need the Accessibility grant and an\n"
        "UNLOCKED session (a password-LOCK drops synthetic input; a screensaver is OK).\n";
    else if ([cmd isEqualToString:@"hold"]) h =
        "winctl hold — press key(s) DOWN for a real duration, then release (cursor-free).\n\n"
        "  winctl hold <target> <keyspec> [duration_ms]     single hold (default 500 ms)\n"
        "  winctl hold <target> <keyspec>[:ms] <keyspec>[:ms] …   a sequence, played in order\n"
        "  [--repeat MS]      also pulse autorepeat keydowns every MS while held\n\n"
        "A tap (see `key`) is too brief for engines that integrate movement over HELD\n"
        "time (Panda3D / Toontown): the toon moves only while the key is really down. So\n"
        "`hold` presses down, waits, releases — a chord presses modifiers+key down and\n"
        "releases in reverse. The keyUp ALWAYS fires (even on Ctrl+C), so a key is never\n"
        "left stuck down. A single held keydown suffices for engines that latch on the\n"
        "down/up transition; add --repeat for anything needing a repeating stream. Same\n"
        "grant / unlocked-session rules as `key`.\n\n"
        "examples:\n"
        "  winctl hold win:20722 up 1500                    walk forward ~1.5s\n"
        "  winctl hold win:20722 up:1200 left:400 up:1500   scripted path\n"
        "  winctl hold Toontown shift+up 800                hold a chord\n";
    else if ([cmd isEqualToString:@"list"]) h =
        "winctl list — enumerate windows: win-id, pid, app, title, bounds.\n\n"
        "  winctl list [--all] [--json]\n\n"
        "  --all    include off-screen / non-normal windows\n"
        "The win-id / pid it prints are the <target> for the other commands.\n";
    else if ([cmd isEqualToString:@"doctor"]) h =
        "winctl doctor — verify winctl's own TCC grants and report this box's quirks.\n\n"
        "  winctl doctor [--json]\n\n"
        "Reports self-disclaim state, AMFI enforcement (relaxed vs standard), the standing\n"
        "grant, and a live self-check; GREEN => WORKS UNDER ANY HARNESS. When not green it\n"
        "says how to fix it for THIS box (a bare CLI is granted by PATH on an AMFI-relaxed\n"
        "box; via System Settings on a standard Mac). Run this first for any capture/input\n"
        "or permission weirdness.\n";
    else if ([cmd isEqualToString:@"grant"]) h =
        "winctl grant — self-install winctl's TCC grant (AMFI-relaxed box only).\n\n"
        "  sudo winctl grant            grant ScreenCapture/Accessibility/PostEvent/ListenEvent\n"
        "  sudo winctl grant --revoke   remove those grants\n\n"
        "Writes path-identity rows (client_type=1, NULL csreq) into the SYSTEM TCC.db and\n"
        "restarts tccd — needs root, and only works where TCC is editable (AMFI relaxed +\n"
        "SIP off). On a standard Mac it refuses and points you to System Settings instead.\n"
        "The grant is keyed to winctl's PATH: rebuilds are fine, but MOVING the binary\n"
        "voids it (re-run). Verify with `winctl doctor`.\n";
    else if ([cmd isEqualToString:@"sim"]) h =
        "winctl sim — drive an iOS Simulator directly (device framebuffer + HID), the way\n"
        "Claude Desktop's simulator pane does — never the host cursor.\n\n"
        "  winctl sim list [--all]                 booted sims (or all available)\n"
        "  winctl sim shot   <target> <out.png>    device-framebuffer screenshot (via simctl)\n"
        "  winctl sim tap    <target> <x> <y> [--points]\n"
        "  winctl sim swipe  <target> <x1> <y1> <x2> <y2> [duration] [--points]\n"
        "  winctl sim type   <target> <text…>\n"
        "  winctl sim key    <target> <hid-keycode>\n"
        "  winctl sim button <target> <APPLE_PAY|HOME|LOCK|SIDE_BUTTON|SIRI>\n\n"
        "<target>:  a udid, a device-name substring, or `booted`.\n"
        "tap/swipe take coordinates in `sim shot` PIXELS (auto-scaled to the device's\n"
        "logical points); pass `--points` to give raw points instead. So: screenshot with\n"
        "`sim shot`, read a pixel coordinate off it, and tap that same number.\n"
        "Capture/list use `xcrun simctl` (no extra deps). Input uses Meta's `idb`\n"
        "(brew install idb-companion && pip3 install fb-idb) — the same FBSimulatorControl\n"
        "/Indigo HID engine Claude links in-process; winctl tells you if it's missing.\n\n"
        "examples:\n"
        "  winctl sim shot booted /tmp/sim.png\n"
        "  winctl sim tap booted 200 420\n";
    if (!h) return NO;
    fputs(h, stdout);
    return YES;
}

// ---------------------------------------------------------------------------
// Self-disclaim: re-exec ourselves ONCE as the TCC-responsible process.
// ---------------------------------------------------------------------------
// When a bare CLI runs, TCC attributes its Screen-Recording/Accessibility use to
// whatever *host* is responsible for the shell (VS Code, Terminal, Ocean…) — so
// the tool only works where that host happens to be granted. To get a STABLE,
// host-independent identity we re-exec ourselves once with the private
// `responsibility_spawnattrs_setdisclaim` spawn attribute: the child is
// "disclaimed" from its parent's responsibility, so it becomes responsible for
// ITSELF. Combined with our stable code signature (identifier
// com.nscake.winctl + Tanner's Apple Development cert), TCC then keys the
// request on `com.nscake.winctl` regardless of the launching harness.
//
// We guard with WINCTL_DISCLAIMED so this happens exactly once; the child
// (which has the env var set) skips the re-exec and does the real work.
static void reexecDisclaimed(int argc, const char *argv[]) {
    if (getenv("WINCTL_DISCLAIMED")) return;  // already the disclaimed child

    char exePath[PATH_MAX];
    uint32_t sz = sizeof(exePath);
    if (_NSGetExecutablePath(exePath, &sz) != 0) return;  // can't find self; run in-place
    char real[PATH_MAX];
    const char *path = realpath(exePath, real) ? real : exePath;

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return;
    responsibility_spawnattrs_setdisclaim(&attr, 1);
    setenv("WINCTL_DISCLAIMED", "1", 1);

    char **newargv = calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) newargv[i] = (char *)argv[i];
    newargv[argc] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, newargv, environ);
    posix_spawnattr_destroy(&attr);
    free(newargv);
    if (rc != 0) {
        // Fall through and run un-disclaimed rather than failing hard.
        unsetenv("WINCTL_DISCLAIMED");
        return;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 2; }
        NSString *cmd = @(argv[1]);
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) [args addObject:@(argv[i])];

        // Help paths do no capture/input — handle them before self-disclaiming.
        if ([cmd isEqualToString:@"-h"] || [cmd isEqualToString:@"--help"] || [cmd isEqualToString:@"help"]) { usage(); return 0; }
        if (cmdHelp(cmd, args)) return 0;   // `winctl <command> --help`

        // `grant` (root, edits TCC only) and `sim` (shells out to simctl/idb) don't
        // touch our own capture/input path, so they must NOT self-disclaim.
        // Everything else becomes TCC-responsible for itself first.
        if (!([cmd isEqualToString:@"grant"] || [cmd isEqualToString:@"sim"]))
            reexecDisclaimed(argc, argv);

        if ([cmd isEqualToString:@"list"])     return cmd_list(args);
        if ([cmd isEqualToString:@"shot"])     return cmd_shot(args);
        if ([cmd isEqualToString:@"type"])     return cmd_type(args);
        if ([cmd isEqualToString:@"key"])      return cmd_key(args);
        if ([cmd isEqualToString:@"hold"])     return cmd_hold(args);
        if ([cmd isEqualToString:@"click"])    return cmd_click(args);
        if ([cmd isEqualToString:@"describe"]) return cmd_describe(args);
        if ([cmd isEqualToString:@"doctor"])   return cmd_doctor(args);
        if ([cmd isEqualToString:@"grant"])    return cmd_grant(args);
        if ([cmd isEqualToString:@"sim"])      return cmd_sim(args);

        fprintf(stderr, "winctl: unknown command '%s'\n", cmd.UTF8String);
        usage();
        return 2;
    }
}
