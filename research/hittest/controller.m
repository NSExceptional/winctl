// controller.m — OUT-OF-PROCESS synthetic mouse-click actuation experiment.
//
// Goal: make a synthetic left click actually ACTUATE an on-screen NSButton in a
// *separate* process, with NO code injection and WITHOUT moving the real cursor.
// The earlier oop/ experiment showed a bare CGEventPostToPid mouse event is
// delivered but arrives window-less (win=0) and un-hit-tested, so the button
// never fires. This tool tries the SkyLight / window-routed approaches.
//
// Ground truth of success: the target increments its counter and writes
// /tmp/poltergeist-hittest/label.txt ("pressed N"). We diff N before/after.
//
// All private symbols are resolved via dlsym from SkyLight (nothing private is
// linked). Usage:
//   controller <pid> <windowNumber> --cg <gx> <gy> --winlocal <wx> <wy> \
//              --method <name> [--tag <tag>]
//
// Methods (see runMethod): baseline, fields, sl, both, activate_both,
// front_both, psn, all.

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

// ---- public-but-deprecated Carbon PSN plumbing (declared by system headers:
// GetProcessForPID (Processes.h) + CGEventPostToPSN (CGEvent.h)) ----
// ProcessSerialNumber is {UInt32 highLongOfPSN; UInt32 lowLongOfPSN;} (8 bytes).
typedef ProcessSerialNumber PGPSN;
static inline uint32_t psnHi(PGPSN *p){ return p->highLongOfPSN; }
static inline uint32_t psnLo(PGPSN *p){ return p->lowLongOfPSN; }

// ---- private SkyLight / CoreGraphics SPI typedefs ----
typedef void  (*SLEventPostToPid_t)(pid_t, CGEventRef);
typedef void  (*SLEventSetIntegerValueField_t)(CGEventRef, uint32_t, int64_t);
typedef void  (*CGEventSetWindowLocation_t)(CGEventRef, double, double);
typedef int   (*SLPSPostEventRecordTo_t)(const void *psn, const uint8_t *bytes);
typedef int   (*_SLPSGetFrontProcess_t)(void *psn);
typedef int   (*SLPSSetFrontProcessWithOptions_t)(const void *psn, uint32_t wid, uint32_t opts);
typedef int   (*SLSGetWindowOwner_t)(uint32_t cid, uint32_t wid, uint32_t *outCid);
typedef int   (*SLSGetConnectionPSN_t)(uint32_t cid, void *psn);
typedef uint32_t (*CGSMainConnectionID_t)(void);

static SLEventPostToPid_t             pSLEventPostToPid;
static SLEventSetIntegerValueField_t  pSLSetIntField;
static CGEventSetWindowLocation_t     pCGEventSetWindowLocation;
static SLPSPostEventRecordTo_t        pSLPSPostEventRecordTo;
static _SLPSGetFrontProcess_t         pSLPSGetFrontProcess;
static SLPSSetFrontProcessWithOptions_t pSLPSSetFront;
static SLSGetWindowOwner_t            pSLSGetWindowOwner;
static SLSGetConnectionPSN_t          pSLSGetConnectionPSN;
static CGSMainConnectionID_t          pCGSMainConnectionID;

static FILE *gLog;
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "%s\n", s.UTF8String);
    if (gLog) { fputs(s.UTF8String, gLog); fputc('\n', gLog); fflush(gLog); }
}

static void loadSyms(void) {
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY|RTLD_GLOBAL);
    (void)sl;
    pSLEventPostToPid         = (SLEventPostToPid_t) dlsym(RTLD_DEFAULT, "SLEventPostToPid");
    pSLSetIntField            = (SLEventSetIntegerValueField_t) dlsym(RTLD_DEFAULT, "SLEventSetIntegerValueField");
    pCGEventSetWindowLocation = (CGEventSetWindowLocation_t) dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
    pSLPSPostEventRecordTo    = (SLPSPostEventRecordTo_t) dlsym(RTLD_DEFAULT, "SLPSPostEventRecordTo");
    pSLPSGetFrontProcess      = (_SLPSGetFrontProcess_t) dlsym(RTLD_DEFAULT, "_SLPSGetFrontProcess");
    pSLPSSetFront             = (SLPSSetFrontProcessWithOptions_t) dlsym(RTLD_DEFAULT, "SLPSSetFrontProcessWithOptions");
    pSLSGetWindowOwner        = (SLSGetWindowOwner_t) dlsym(RTLD_DEFAULT, "SLSGetWindowOwner");
    pSLSGetConnectionPSN      = (SLSGetConnectionPSN_t) dlsym(RTLD_DEFAULT, "SLSGetConnectionPSN");
    pCGSMainConnectionID      = (CGSMainConnectionID_t) dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    L(@"[syms] SLEventPostToPid=%p SLEventSetIntegerValueField=%p CGEventSetWindowLocation=%p SLPSPostEventRecordTo=%p _SLPSGetFrontProcess=%p SLPSSetFrontProcessWithOptions=%p SLSGetWindowOwner=%p SLSGetConnectionPSN=%p CGSMainConnectionID=%p",
      pSLEventPostToPid, pSLSetIntField, pCGEventSetWindowLocation, pSLPSPostEventRecordTo,
      pSLPSGetFrontProcess, pSLPSSetFront, pSLSGetWindowOwner, pSLSGetConnectionPSN, pCGSMainConnectionID);
}

// Stamp an integer field, preferring the non-validating SkyLight setter so
// undocumented indices (51, 58) actually land; fall back to the public one.
static BOOL gForcePublicSetter = NO;
static void setField(CGEventRef ev, uint32_t f, int64_t v) {
    if (pSLSetIntField && !gForcePublicSetter) pSLSetIntField(ev, f, v);
    else CGEventSetIntegerValueField(ev, (CGEventField)f, v);
}

// Ablation knobs (which stamps to apply). Defaults = full recipe.
static BOOL gStamp51 = YES, gStamp9192 = YES, gStampLoc = YES, gStampMisc = YES;
static BOOL gClickStateOnly = NO;

// Apply the window-routing stamp set that makes a backgrounded AppKit window
// hit-test the event to its control instead of falling back to a screen-location
// hit-test (which skips non-key windows -> win=0). Knobs allow ablation.
static void stampWindowRouting(CGEventRef ev, pid_t pid, uint32_t wid,
                               double wx, double wy, int64_t clickState,
                               int64_t buttonNumber, int64_t subtype,
                               int64_t clickGroup) {
    if (gStampLoc && pCGEventSetWindowLocation) pCGEventSetWindowLocation(ev, wx, wy);
    if (gStampMisc) {
        setField(ev, 1,  clickState);   // kCGMouseEventClickState
        if (!gClickStateOnly) {
            setField(ev, 3,  buttonNumber); // kCGMouseEventButtonNumber (0=left)
            setField(ev, 7,  subtype);      // kCGMouseEventSubtype (3=touch)
            setField(ev, 40, pid);          // kCGEventTargetUnixProcessID
            setField(ev, 58, clickGroup);   // click-group id (gesture coalescing)
        }
    }
    if (gStamp51)   setField(ev, 51, wid); // windowNumber (undocumented)
    if (gStamp9192){ setField(ev, 91, wid);  // kCGMouseEventWindowUnderMousePointer
                     setField(ev, 92, wid); }// ...ThatCanHandleThisEvent
}

// Resolve the PSN of the process that owns windowID (SkyLight path), else
// GetProcessForPID. Fills an 8-byte PSN buffer.
static BOOL psnForWindow(uint32_t wid, pid_t pid, PGPSN *out) {
    if (pSLSGetWindowOwner && pSLSGetConnectionPSN && pCGSMainConnectionID) {
        uint32_t cid = pCGSMainConnectionID();
        uint32_t owner = 0;
        if (pSLSGetWindowOwner(cid, wid, &owner) == 0 && owner != 0) {
            if (pSLSGetConnectionPSN(owner, out) == 0) return YES;
        }
    }
    return GetProcessForPID(pid, out) == 0;
}

// yabai / cua focus-without-raise: mark target window native-key & AppKit-active
// WITHOUT raising it, so its controls become hit-testable in the background.
static BOOL activateWithoutRaise(pid_t pid, uint32_t wid) {
    if (!pSLPSPostEventRecordTo || !pSLPSGetFrontProcess) return NO;
    PGPSN prev = {0,0}, target = {0,0};
    if (pSLPSGetFrontProcess(&prev) != 0) return NO;
    if (!psnForWindow(wid, pid, &target)) return NO;

    uint8_t buf[0xF8]; memset(buf, 0, sizeof buf);
    buf[0x04] = 0xF8;
    buf[0x08] = 0x0D;
    buf[0x3C] = (uint8_t)(wid & 0xFF);
    buf[0x3D] = (uint8_t)((wid >> 8) & 0xFF);
    buf[0x3E] = (uint8_t)((wid >> 16) & 0xFF);
    buf[0x3F] = (uint8_t)((wid >> 24) & 0xFF);
    buf[0x8A] = 0x02; // defocus previous front
    int a = pSLPSPostEventRecordTo(&prev, buf);
    buf[0x8A] = 0x01; // focus target
    int b = pSLPSPostEventRecordTo(&target, buf);
    L(@"[activateWithoutRaise] defocus_rc=%d focus_rc=%d", a, b);
    return a == 0 && b == 0;
}

static CGPoint cursorNow(void) {
    CGEventRef q = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(q);
    if (q) CFRelease(q);
    return p;
}

static NSInteger readCounter(void) {
    NSString *s = [NSString stringWithContentsOfFile:@"/tmp/poltergeist-hittest/label.txt"
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s) return -1;
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *parts = [s componentsSeparatedByString:@" "];
    if (parts.count >= 2) return [parts.lastObject integerValue];
    return -1;
}

// Post one CGEvent through the requested channel(s).
typedef enum { CH_CG=1, CH_SL=2, CH_BOTH=3, CH_PSN=4 } Channel;
static void postEvent(CGEventRef ev, pid_t pid, PGPSN *psn, Channel ch) {
    if ((ch & CH_SL) && pSLEventPostToPid) pSLEventPostToPid(pid, ev);
    if (ch & CH_CG) CGEventPostToPid(pid, ev);
    if ((ch & CH_PSN) && psn) CGEventPostToPSN(psn, ev);
}

typedef struct {
    pid_t pid; uint32_t wid;
    CGPoint cg;        // global CG coords, top-left origin (button center)
    double wx, wy;     // window-local coords
    BOOL haveWinLocal;
} Ctx;

// Core click recipe with knobs.
static void doClick(Ctx c, PGPSN *psn, Channel ch, BOOL stamp, BOOL primer) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    int64_t group = (int64_t)(mach_absolute_time() & 0x7fffffff);

    if (primer) {
        CGEventRef mv = CGEventCreateMouseEvent(src, kCGEventMouseMoved, c.cg, kCGMouseButtonLeft);
        if (stamp) stampWindowRouting(mv, c.pid, c.wid, c.wx, c.wy, 0, 0, 3, group);
        postEvent(mv, c.pid, psn, ch);
        if (mv) CFRelease(mv);
        usleep(15000);
    }

    CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, c.cg, kCGMouseButtonLeft);
    if (stamp) stampWindowRouting(down, c.pid, c.wid, c.wx, c.wy, 1, 0, 3, group);
    else       CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
    postEvent(down, c.pid, psn, ch);
    if (down) CFRelease(down);
    usleep(30000);

    CGEventRef up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, c.cg, kCGMouseButtonLeft);
    if (stamp) stampWindowRouting(up, c.pid, c.wid, c.wx, c.wy, 1, 0, 3, group);
    else       CGEventSetIntegerValueField(up, kCGMouseEventClickState, 1);
    postEvent(up, c.pid, psn, ch);
    if (up) CFRelease(up);

    if (src) CFRelease(src);
    usleep(200000); // let the target's run loop process
}

static void runMethod(NSString *m, Ctx c) {
    PGPSN psn = {0,0};
    BOOL havePSN = psnForWindow(c.wid, c.pid, &psn);
    L(@"[method %@] pid=%d wid=%u cg=%.1f,%.1f winlocal=%.1f,%.1f havePSN=%d psn=%u,%u",
      m, c.pid, c.wid, c.cg.x, c.cg.y, c.wx, c.wy, havePSN, psnHi(&psn), psnLo(&psn));

    NSInteger before = readCounter();
    if (before < 0) before = 0; // label.txt absent until first press == count 0
    CGPoint cb = cursorNow();

    // Is the target frontmost RIGHT NOW? (proves the background use case)
    PGPSN front = {0,0}; int frontMost = -1;
    if (pSLPSGetFrontProcess && pSLPSGetFrontProcess(&front) == 0 && havePSN)
        frontMost = (front.highLongOfPSN == psn.highLongOfPSN &&
                     front.lowLongOfPSN == psn.lowLongOfPSN) ? 1 : 0;
    L(@"[method %@] target_frontmost_at_click=%d", m, frontMost);

    if ([m isEqualToString:@"baseline"]) {
        // Reproduce the oop/ failure: bare CGEventPostToPid, no stamps, no primer.
        doClick(c, NULL, CH_CG, NO, NO);
    } else if ([m isEqualToString:@"fields"]) {
        // CGEventPostToPid + full window-routing stamps + primer.
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"sl"]) {
        // SLEventPostToPid only + stamps + primer.
        doClick(c, NULL, CH_SL, YES, YES);
    } else if ([m isEqualToString:@"both"]) {
        // postBoth: SLEventPostToPid + CGEventPostToPid, stamps + primer.
        doClick(c, NULL, CH_BOTH, YES, YES);
    } else if ([m isEqualToString:@"activate_both"]) {
        // focus-without-raise (background!) then postBoth.
        activateWithoutRaise(c.pid, c.wid);
        usleep(50000);
        doClick(c, NULL, CH_BOTH, YES, YES);
    } else if ([m isEqualToString:@"front_both"]) {
        // SLPSSetFrontProcessWithOptions (bring frontmost) then postBoth, restore.
        PGPSN prev = {0,0};
        BOOL havePrev = pSLPSGetFrontProcess && pSLPSGetFrontProcess(&prev) == 0;
        if (pSLPSSetFront && havePSN) pSLPSSetFront(&psn, c.wid, 0x400);
        usleep(60000);
        doClick(c, NULL, CH_BOTH, YES, YES);
        if (pSLPSSetFront && havePrev) pSLPSSetFront(&prev, 0, 0x400);
    } else if ([m isEqualToString:@"psn"]) {
        // CGEventPostToPSN (deprecated distinct routing) + stamps + primer.
        doClick(c, havePSN ? &psn : NULL, CH_PSN, YES, YES);
    // ---- ablations (CGEventPostToPid channel; isolate the essential stamp) ----
    } else if ([m isEqualToString:@"abl_primeronly"]) {
        gStamp51=gStamp9192=gStampLoc=gStampMisc=NO;   // primer, NO stamps
        doClick(c, NULL, CH_CG, NO, YES);
    } else if ([m isEqualToString:@"abl_noprimer"]) {
        doClick(c, NULL, CH_CG, YES, NO);              // full stamps, NO primer
    } else if ([m isEqualToString:@"abl_only51"]) {
        gStamp9192=gStampLoc=gStampMisc=NO;            // only windowNumber(51)
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_only9192"]) {
        gStamp51=gStampLoc=gStampMisc=NO;              // only 91/92
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_noloc"]) {
        gStampLoc=NO;                                  // stamps+primer, no WindowLocation
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_51_noprimer"]) {
        gStamp9192=gStampLoc=gStampMisc=NO;            // only 51, NO primer
        doClick(c, NULL, CH_CG, YES, NO);
    } else if ([m isEqualToString:@"abl_5191_nomisc"]) {
        gStampLoc=gStampMisc=NO;                       // 51+91/92 routing, no clickstate
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_misc51"]) {
        gStamp9192=gStampLoc=NO;                        // misc(clickstate..)+51
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_misc9192"]) {
        gStamp51=gStampLoc=NO;                           // misc(clickstate..)+91/92
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_misc_only"]) {
        gStamp51=gStamp9192=gStampLoc=NO;                // clickstate/pid etc, NO window routing
        doClick(c, NULL, CH_CG, YES, YES);
    } else if ([m isEqualToString:@"abl_51_clickstate"]) {
        // The proposed MINIMAL recipe: field 51 (windowNumber) + field 1
        // (clickState=1) only. No 91/92, no pid/subtype/group, no WindowLocation,
        // no primer. Posted via bare CGEventPostToPid.
        gStamp9192=gStampLoc=NO; gStampMisc=YES; gClickStateOnly=YES;
        doClick(c, NULL, CH_CG, YES, NO);
    } else if ([m isEqualToString:@"pure_public"]) {
        // ZERO private symbols: public CGEventSetIntegerValueField for ALL
        // stamps (incl. field 51) + public CGEventPostToPid. No SkyLight, no
        // CGEventSetWindowLocation. Tests whether the win is pure-public.
        gForcePublicSetter=YES; gStampLoc=NO;
        doClick(c, NULL, CH_CG, YES, YES);
    } else {
        L(@"[method %@] UNKNOWN", m);
        return;
    }

    usleep(120000);
    NSInteger after = readCounter();
    if (after < 0) after = 0;
    CGPoint ca = cursorNow();
    double moved = hypot(ca.x - cb.x, ca.y - cb.y);
    BOOL actuated = (after > before);
    L(@"[RESULT %@] counter_before=%ld counter_after=%ld ACTUATED=%@ target_frontmost=%d cursor_moved_px=%.1f",
      m, (long)before, (long)after, actuated ? @"YES" : @"NO", frontMost, moved);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <pid> <windowNumber> --cg gx gy [--winlocal wx wy] --method NAME [--tag T]\n", argv[0]);
            return 2;
        }
        Ctx c; memset(&c, 0, sizeof c);
        c.pid = (pid_t)atoi(argv[1]);
        c.wid = (uint32_t)strtoul(argv[2], NULL, 10);
        NSString *method = @"both";
        NSString *tag = @"run";
        for (int i = 3; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"--cg"] && i+2 < argc) {
                c.cg.x = atof(argv[++i]); c.cg.y = atof(argv[++i]);
            } else if ([a isEqualToString:@"--winlocal"] && i+2 < argc) {
                c.wx = atof(argv[++i]); c.wy = atof(argv[++i]); c.haveWinLocal = YES;
            } else if ([a isEqualToString:@"--method"] && i+1 < argc) {
                method = [NSString stringWithUTF8String:argv[++i]];
            } else if ([a isEqualToString:@"--tag"] && i+1 < argc) {
                tag = [NSString stringWithUTF8String:argv[++i]];
            }
        }
        NSString *logPath = [NSString stringWithFormat:@"/tmp/poltergeist-hittest/controller_%@.log", tag];
        gLog = fopen(logPath.UTF8String, "a");
        loadSyms();

        NSArray *methods;
        if ([method isEqualToString:@"all"]) {
            methods = @[@"baseline", @"fields", @"sl", @"both", @"activate_both", @"front_both", @"psn"];
        } else {
            methods = @[method];
        }
        for (NSString *m in methods) runMethod(m, c);
        if (gLog) fclose(gLog);
    }
    return 0;
}
