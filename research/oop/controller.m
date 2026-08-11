// controller.m — OUT-OF-PROCESS automation controller for Poltergeist/oop.
//
// HARD CONSTRAINT: this process never injects code into the target and never
// calls task_for_pid. Everything is done from this separate process via public
// AX, CGEventPostToPid, and public/private capture APIs.
//
// Bundle id: com.nscake.PoltergeistController (for a stable TCC identity).
//
// Usage:
//   controller <pid> <windowNumber> <out_dir> [--act-only|--see-only] [--tag NAME]
//
// It performs, and logs the result of, each cell of the capability matrix:
//   ACT: AXPerformAction(kAXPressAction) + AXSetAttributeValue(kAXValueAttribute)
//   ACT: CGEventPostToPid (mouse down/up at button screen coords)  + cursor delta
//   SEE: CGWindowListCreateImage
//   SEE: CGSHWCaptureWindowList / SLSHWCaptureWindowList (private SkyLight HW)
//   SEE: CARenderServerRenderLayerWithTransform into an IOSurface (best effort)

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// CGWindowListCreateImage is compile-time UNAVAILABLE in the macOS 15 SDK
// (Apple obsoleted it in favor of ScreenCaptureKit). Resolve it at runtime via
// dlsym to test whether the symbol still functions out-of-process.
typedef CGImageRef (*CGWindowListCreateImage_t)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

// ---------------------------------------------------------------------------
// Private prototypes (SkyLight / CoreGraphics window server + CARenderServer)
// ---------------------------------------------------------------------------
typedef int CGSConnectionID;
typedef uint32_t CGSWindowCaptureOptions;
// All private symbols are resolved at runtime via dlsym so we don't need to
// link the private SkyLight/QuartzCore-private frameworks.
typedef CGSConnectionID (*CGSMainConnectionID_t)(void);
typedef CFArrayRef (*HWCapture_t)(CGSConnectionID cid, CGWindowID *list, uint32_t count, CGSWindowCaptureOptions options);
typedef CGError (*CARenderServerRenderLayerWithTransform_t)(mach_port_t, uint32_t, uint32_t, IOSurfaceRef, int, int, const CATransform3D *);
typedef mach_port_t (*CARenderServerGetServerPort_t)(const char *);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static NSString *gOut = @"/tmp/poltergeist-oop";
static NSString *gTag = @"run";
static FILE *gLog = NULL;

static void logline(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "%s\n", s.UTF8String);
    fflush(stdout);
    if (gLog) { fprintf(gLog, "%s\n", s.UTF8String); fflush(gLog); }
}

// Write a CGImageRef to PNG, return YES on success and fill non-black fraction.
static BOOL writePNG(CGImageRef img, NSString *path, double *nonblackOut, int *maxChanOut) {
    if (!img) return NO;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w == 0 || h == 0) return NO;

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];

    // Pixel check: fraction of sampled pixels that are non-black.
    long long nb = 0, cnt = 0; int mx = 0;
    for (size_t y = 0; y < h; y += 4) {
        for (size_t x = 0; x < w; x += 4) {
            NSColor *c = [rep colorAtX:(NSInteger)x y:(NSInteger)y];
            CGFloat r,g,b,a;
            [[c colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] getRed:&r green:&g blue:&b alpha:&a];
            int R=r*255,G=g*255,B=b*255;
            if (R>mx)mx=R; if(G>mx)mx=G; if(B>mx)mx=B;
            if (R+G+B > 30) nb++;
            cnt++;
        }
    }
    if (nonblackOut) *nonblackOut = cnt ? (double)nb/cnt : 0;
    if (maxChanOut) *maxChanOut = mx;
    return png != nil;
}

// ---------------------------------------------------------------------------
// AX walk
// ---------------------------------------------------------------------------
// Iterative BFS with a node cap (AX trees can contain reference cycles, so a
// naive recursion stack-overflows). Returns a +1 retained match or NULL.
// Depth-limited recursive search from the app element's kAXChildrenAttribute.
// (kAXWindowsAttribute returned unusable refs on this box; the app's direct
// children hold the real window subtree.) Returns a +1 retained match or NULL.
static AXUIElementRef copyDescMatchingRole(AXUIElementRef el, CFStringRef role, int depth) {
    if (depth > 8) return NULL;
    CFTypeRef r = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &r) == kAXErrorSuccess && r) {
        BOOL match = CFEqual(r, role);
        CFRelease(r);
        if (match) return (AXUIElementRef)CFRetain(el);
    }
    CFTypeRef kids = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
        CFIndex n = CFArrayGetCount((CFArrayRef)kids);
        for (CFIndex i = 0; i < n && !found; i++)
            found = copyDescMatchingRole((AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)kids, i), role, depth+1);
        CFRelease(kids);
    }
    return found;
}
// Get the app's front window via kAXMainWindow / kAXFocusedWindow (the app's
// generic children were self-referential on this box and omitted the window).
static AXUIElementRef copyMainWindow(AXUIElementRef app) {
    CFTypeRef w = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &w) == kAXErrorSuccess && w)
        return (AXUIElementRef)w;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &w) == kAXErrorSuccess && w)
        return (AXUIElementRef)w;
    return NULL;
}
static AXUIElementRef copyChildMatchingRole(AXUIElementRef app, CFStringRef role) {
    AXUIElementRef win = copyMainWindow(app);
    if (!win) return NULL;
    AXUIElementRef found = copyDescMatchingRole(win, role, 0);
    CFRelease(win);
    return found;
}

static NSString *axStringValue(AXUIElementRef el) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXValueAttribute, &v) == kAXErrorSuccess && v) {
        NSString *s = [(__bridge id)v description];
        CFRelease(v);
        return s;
    }
    return nil;
}

// Read the "pressed N" label by walking static text elements and returning the
// first whose value contains "pressed".
static NSString *readPressLabel(AXUIElementRef app) {
    // Walk all descendants collecting AXStaticText values.
    __block NSString *result = nil;
    NSMutableArray *stack = [NSMutableArray array];
    AXUIElementRef win = copyMainWindow(app);
    if (win) { [stack addObject:(__bridge id)win]; CFRelease(win); }
    int visited = 0;
    while (stack.count && !result && visited++ < 3000) {
        id lastObj = stack.lastObject;                 // keep a strong ref for the body
        [stack removeLastObject];
        AXUIElementRef el = (__bridge AXUIElementRef)lastObj;
        CFTypeRef role = NULL;
        if (AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role) == kAXErrorSuccess && role) {
            if (CFEqual(role, kAXStaticTextRole)) {
                NSString *s = axStringValue(el);
                if (s && [s.lowercaseString containsString:@"pressed"]) { CFRelease(role); result = s; break; }
            }
            CFRelease(role);
        }
        CFTypeRef kids = NULL;
        if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
            CFIndex n = CFArrayGetCount((CFArrayRef)kids);
            for (CFIndex i = 0; i < n; i++)
                [stack addObject:(__bridge id)CFArrayGetValueAtIndex((CFArrayRef)kids, i)];
            CFRelease(kids);
        }
    }
    return result;
}

// Recursive, depth-limited AX tree dump (role + title + childcount + errors).
static int gDumpBudget = 80;
static void dumpTree(AXUIElementRef el, int depth) {
    if (depth > 6 || gDumpBudget-- <= 0) return;
    CFTypeRef r = NULL, t = NULL;
    AXError re = AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &r);
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute, &t);
    CFTypeRef kids = NULL;
    AXError ke = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids);
    long kc = (ke==kAXErrorSuccess && kids) ? CFArrayGetCount((CFArrayRef)kids) : -1;
    NSMutableString *ind = [NSMutableString string];
    for (int i=0;i<depth;i++) [ind appendString:@"  "];
    logline(@"[tree]%@ roleErr=%d role=%@ title=%@ childCount=%ld",
            ind, (int)re, r?(__bridge id)r:@"(nil)", t?(__bridge id)t:@"-", kc);
    if (r) CFRelease(r); if (t) CFRelease(t);
    for (long i=0;i<kc;i++)
        dumpTree((AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)kids,i), depth+1);
    if (kids) CFRelease(kids);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: controller <pid> <windowNumber> <out_dir> [--act-only|--see-only] [--tag NAME]\n");
            return 2;
        }
        pid_t pid = (pid_t)atoi(argv[1]);
        CGWindowID wid = (CGWindowID)strtoul(argv[2], NULL, 10);
        gOut = @(argv[3]);
        BOOL doAct = YES, doSee = YES, haveClick = NO, haveOffset = NO;
        CGPoint clickArg = {0,0}; CGPoint offArg = {0,0};
        for (int i = 4; i < argc; i++) {
            if (strcmp(argv[i], "--act-only") == 0) doSee = NO;
            else if (strcmp(argv[i], "--see-only") == 0) doAct = NO;
            else if (strcmp(argv[i], "--tag") == 0 && i+1 < argc) gTag = @(argv[++i]);
            else if (strcmp(argv[i], "--click") == 0 && i+2 < argc) { clickArg.x = atof(argv[i+1]); clickArg.y = atof(argv[i+2]); i+=2; haveClick = YES; }
            else if (strcmp(argv[i], "--offset") == 0 && i+2 < argc) { offArg.x = atof(argv[i+1]); offArg.y = atof(argv[i+2]); i+=2; haveOffset = YES; }
        }
        // Resolve click from the window's CG bounds + offset (flip-free, robust).
        if (haveOffset) {
            CFArrayRef wl = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
            fprintf(stdout, "[resolve] wl=%p count=%ld\n", (void*)wl, wl?(long)CFArrayGetCount(wl):-1);
            if (wl && CFArrayGetCount(wl) > 0) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(wl, 0);
                CGRect b; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &b);
                clickArg = CGPointMake(b.origin.x + offArg.x, b.origin.y + offArg.y);
                haveClick = YES;
                fprintf(stdout, "[resolve] window CG bounds=%.0f,%.0f,%.0f,%.0f -> click=%.0f,%.0f\n",
                        b.origin.x,b.origin.y,b.size.width,b.size.height, clickArg.x, clickArg.y);
            }
            if (wl) CFRelease(wl);
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:gOut withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *logPath = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"controller_%@.log", gTag]];
        gLog = fopen(logPath.fileSystemRepresentation, "w");

        logline(@"=== controller tag=%@ pid=%d wid=%u trusted=%d ===",
                gTag, pid, wid, AXIsProcessTrusted());

        // --keytest: post a 'x' keystroke to the pid via CGEventPostToPid to
        // sanity-check whether CGEventPostToPid delivers events to a process OOP.
        for (int i = 4; i < argc; i++) {
            if (strcmp(argv[i], "--keytest") == 0) {
                CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
                CGEventRef kd = CGEventCreateKeyboardEvent(src, (CGKeyCode)7 /*x*/, true);
                CGEventRef ku = CGEventCreateKeyboardEvent(src, (CGKeyCode)7, false);
                if (kd) { CGEventPostToPid(pid, kd); CFRelease(kd); }
                usleep(30000);
                if (ku) { CGEventPostToPid(pid, ku); CFRelease(ku); }
                if (src) CFRelease(src);
                fprintf(stdout, "[keytest] posted 'x' keyDown/Up to pid %d\n", pid);
                return 0;
            }
        }

        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, 5.0);
        // Some apps gate their in-process AX tree until an assistive client asks
        // for it. Nudge it on (still fully OOP, no injection).
        AXError me1 = AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
        AXError me2 = AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
        logline(@"[AX activate] AXManualAccessibility set err=%d  AXEnhancedUserInterface set err=%d", (int)me1, (int)me2);
        usleep(200000);

        // ---- AX diagnostics: probe the main window --------------------------
        {
            CFTypeRef ws=NULL; AXError we=AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &ws);
            long wc=(we==kAXErrorSuccess && ws)?CFArrayGetCount((CFArrayRef)ws):-1;
            if (ws) CFRelease(ws);
            CFTypeRef mw=NULL; AXError mwe=AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &mw);
            CFTypeRef mwrole=NULL; if(mw){AXUIElementCopyAttributeValue((AXUIElementRef)mw,kAXRoleAttribute,&mwrole);}
            logline(@"[AX diag] AXWindows count=%ld  AXMainWindow err=%d role=%@", wc, (int)mwe, mwrole?(__bridge id)mwrole:@"(nil)");
            if(mwrole)CFRelease(mwrole); if(mw)CFRelease(mw);
            AXUIElementRef win = copyMainWindow(app);
            if (!win) {
                logline(@"[AX diag] copyMainWindow=NULL (no kAXMainWindow/kAXFocusedWindow)");
            } else {
                dumpTree(win, 0);
                CFRelease(win);
            }
        }

        // ---- ACT 1: AX press + AX set value ----------------------------------
        if (doAct) {
            NSString *before = readPressLabel(app);
            AXUIElementRef button = copyChildMatchingRole(app, kAXButtonRole);
            AXError perr = kAXErrorFailure;
            logline(@"[ACT AX press ] button_found=%d", button!=NULL);
            if (button) {
                perr = AXUIElementPerformAction(button, kAXPressAction);
                CFRelease(button);
            }
            // small settle
            usleep(120000);
            NSString *after = readPressLabel(app);
            logline(@"[ACT AX press ] err=%d label_before=%@ label_after=%@ landed=%d",
                    (int)perr, before ?: @"(nil)", after ?: @"(nil)",
                    (before && after && ![before isEqualToString:after]) ? 1 : 0);

            AXUIElementRef field = copyChildMatchingRole(app, kAXTextFieldRole);
            AXError serr = kAXErrorFailure;
            NSString *fval = nil;
            if (field) {
                CFStringRef v = CFSTR("typed via AX");
                serr = AXUIElementSetAttributeValue(field, kAXValueAttribute, v);
                usleep(80000);
                fval = axStringValue(field);
                CFRelease(field);
            }
            logline(@"[ACT AX setval] err=%d field_now=%@ landed=%d",
                    (int)serr, fval ?: @"(nil)",
                    (fval && [fval containsString:@"typed via AX"]) ? 1 : 0);
        }

        // ---- ACT 2: CGEventPostToPid at button screen coords -----------------
        if (doAct) {
            // Get button screen rect via AX (kAXPosition is top-left, screen coords, y-down).
            AXUIElementRef button = copyChildMatchingRole(app, kAXButtonRole);
            CGPoint pos = {0,0}; CGSize sz = {0,0}; BOOL haveRect = NO;
            if (button) {
                CFTypeRef p=NULL,s=NULL;
                if (AXUIElementCopyAttributeValue(button, kAXPositionAttribute, &p)==kAXErrorSuccess && p) {
                    AXValueGetValue((AXValueRef)p, kAXValueCGPointType, &pos); CFRelease(p);
                }
                if (AXUIElementCopyAttributeValue(button, kAXSizeAttribute, &s)==kAXErrorSuccess && s) {
                    AXValueGetValue((AXValueRef)s, kAXValueCGSizeType, &sz); CFRelease(s);
                    haveRect = YES;
                }
                CFRelease(button);
            }
            logline(@"[ACT CGEvent] ax_button_found=%d ax_pos=%.0f,%.0f ax_size=%.0f,%.0f haveClickArg=%d clickArg=%.0f,%.0f",
                    button!=NULL, pos.x, pos.y, sz.width, sz.height, haveClick, clickArg.x, clickArg.y);
            // Prefer AX-derived rect; fall back to the explicit --click point
            // (target-reported CG global coords), so this path is independent of
            // whether AX discovery of the button worked.
            CGPoint click = haveRect ? CGPointMake(pos.x + sz.width/2, pos.y + sz.height/2)
                                     : clickArg;
            if (!haveRect && haveClick) haveRect = YES; // we do have a usable point

            NSString *labelBefore = readPressLabel(app);

            // Record real cursor position BEFORE.
            CGEventRef q0 = CGEventCreate(NULL);
            CGPoint cursorBefore = CGEventGetLocation(q0);
            if (q0) CFRelease(q0);

            // Use an explicit HID-state event source.
            CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef mv = CGEventCreateMouseEvent(src, kCGEventMouseMoved, click, kCGMouseButtonLeft);
            if (mv) { CGEventPostToPid(pid, mv); CFRelease(mv); }
            usleep(20000);
            CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, click, kCGMouseButtonLeft);
            CGEventRef up   = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp,   click, kCGMouseButtonLeft);
            if (down) { CGEventPostToPid(pid, down); CFRelease(down); }
            usleep(40000);
            if (up)   { CGEventPostToPid(pid, up);   CFRelease(up); }
            usleep(200000);
            if (src) CFRelease(src);

            CGEventRef q1 = CGEventCreate(NULL);
            CGPoint cursorAfter = CGEventGetLocation(q1);
            if (q1) CFRelease(q1);

            NSString *labelAfter = readPressLabel(app);
            // AX-independent ground truth: the target writes label.txt on press.
            NSString *extFile = @"/tmp/poltergeist-oop/label.txt";
            NSString *ext = [NSString stringWithContentsOfFile:extFile encoding:NSUTF8StringEncoding error:nil];
            double moved = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y);
            logline(@"[ACT CGEventPostToPid] click=%.0f,%.0f haveRect=%d ax_label_before=%@ ax_label_after=%@ ext_label=%@ cursor_before=%.0f,%.0f cursor_after=%.0f,%.0f cursor_moved_px=%.1f",
                    click.x, click.y, haveRect,
                    labelBefore ?: @"(nil)", labelAfter ?: @"(nil)",
                    [(ext?:@"(none)") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                    cursorBefore.x, cursorBefore.y, cursorAfter.x, cursorAfter.y, moved);
        }

        // ---- SEE a: CGWindowListCreateImage ----------------------------------
        if (doSee) {
            CGWindowListCreateImage_t fn = (CGWindowListCreateImage_t)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
            if (!fn) {
                logline(@"[SEE CGWindowListCreateImage] symbol NOT resolvable via dlsym (removed)");
            } else {
                CGImageRef img = fn(CGRectNull,
                    kCGWindowListOptionIncludingWindow, wid,
                    kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
                NSString *p = [gOut stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"see_cgwindowlist_%@.png", gTag]];
                double nb=0; int mx=0;
                BOOL ok = writePNG(img, p, &nb, &mx);
                if (img) CFRelease(img);
                logline(@"[SEE CGWindowListCreateImage] resolved=1 image=%d ok=%d nonblack=%.3f max_channel=%d -> %@",
                        img!=NULL, ok, nb, mx, ok ? p : @"(no image)");
            }
        }

        // ---- SEE b: SkyLight HW capture --------------------------------------
        if (doSee) {
            CGSMainConnectionID_t mainCID = (CGSMainConnectionID_t)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
            HWCapture_t sls = (HWCapture_t)dlsym(RTLD_DEFAULT, "SLSHWCaptureWindowList");
            HWCapture_t cgs = (HWCapture_t)dlsym(RTLD_DEFAULT, "CGSHWCaptureWindowList");
            logline(@"[SEE SkyLightHW] resolved: CGSMainConnectionID=%d SLSHWCaptureWindowList=%d CGSHWCaptureWindowList=%d",
                    mainCID!=NULL, sls!=NULL, cgs!=NULL);
            if (mainCID && (sls || cgs)) {
                CGSConnectionID cid = mainCID();
                CGWindowID list[1] = { wid };
                CFArrayRef arr = NULL;
                const char *sym = "none";
                uint32_t opts[] = {0, 0x0800};
                for (int oi = 0; oi < 2 && !(arr && CFArrayGetCount(arr)); oi++) {
                    if (sls) { arr = sls(cid, list, 1, opts[oi]); sym = "SLSHWCaptureWindowList"; }
                    if ((!arr || CFArrayGetCount(arr)==0) && cgs) { if(arr)CFRelease(arr); arr = cgs(cid, list, 1, opts[oi]); sym = "CGSHWCaptureWindowList"; }
                }
                if (arr && CFArrayGetCount(arr) > 0) {
                    CGImageRef img = (CGImageRef)CFArrayGetValueAtIndex(arr, 0);
                    NSString *p = [gOut stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"see_skylighthw_%@.png", gTag]];
                    double nb=0; int mx=0;
                    BOOL ok = writePNG(img, p, &nb, &mx);
                    logline(@"[SEE SkyLightHW %s] ok=%d nonblack=%.3f max_channel=%d -> %@", sym, ok, nb, mx, p);
                    CFRelease(arr);
                } else {
                    logline(@"[SEE SkyLightHW] call returned empty/null (last sym tried=%s)", sym);
                    if (arr) CFRelease(arr);
                }
            } else {
                logline(@"[SEE SkyLightHW] required symbols not resolvable; skipping");
            }
        }

        // ---- SEE c: CARenderServer into IOSurface (best effort) --------------
        if (doSee) {
            CARenderServerRenderLayerWithTransform_t caRender =
                (CARenderServerRenderLayerWithTransform_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderLayerWithTransform");
            if (!caRender) {
                logline(@"[SEE CARenderServer] symbol not resolvable; skipping");
            } else {
                // The hard part: obtaining the target window's CAContext (context_id)
                // from ANOTHER process. There is no public/entitlement-free API to
                // enumerate a foreign process's CAContext ids. Documenting the
                // attempt: we do NOT have the context_id out-of-process, so we cannot
                // legitimately drive CARenderServerRenderLayerWithTransform for the
                // target's layer tree without cooperation from inside the target.
                logline(@"[SEE CARenderServer] symbol present but context_id for a FOREIGN window is not obtainable out-of-process (no public enumeration of another process's CAContext ids); NOT REACHABLE without in-target cooperation. Skipping.");
            }
        }

        CFRelease(app);
        logline(@"=== controller done tag=%@ ===", gTag);
    }
    return 0;
}
