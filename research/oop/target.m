// target.m — tiny NON-sandboxed AppKit app used as the out-of-process (OOP)
// automation target. Standard AppKit controls, AX-accessible by default.
//
//   * NSButton "Press me" -> increments a counter, updates an NSTextField label
//     to "pressed N".
//   * An editable NSTextField the controller can set via AX / type into.
//
// Build:
//   clang -arch arm64 -framework Cocoa -o Target.app/Contents/MacOS/Target target.m

#import <Cocoa/Cocoa.h>

// NSApplication subclass that records every event it receives, so an external
// observer can tell whether CGEventPostToPid actually delivered events to this
// process (ground truth, independent of AX / control actuation).
@interface PGApplication : NSApplication @end
@implementation PGApplication
- (void)sendEvent:(NSEvent *)event {
    NSEventType t = event.type;
    if (t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp ||
        t == NSEventTypeMouseMoved || t == NSEventTypeKeyDown || t == NSEventTypeKeyUp) {
        NSString *line = [NSString stringWithFormat:@"evt type=%lu loc=%.0f,%.0f win=%ld\n",
                          (unsigned long)t, event.locationInWindow.x, event.locationInWindow.y,
                          (long)event.windowNumber];
        FILE *f = fopen("/tmp/poltergeist-oop/events.txt", "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    }
    [super sendEvent:event];
}
@end

@interface PGTargetDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSButton *button;
@property (nonatomic) NSTextField *label;      // shows "pressed N"
@property (nonatomic) NSTextField *field;      // editable
@property (nonatomic) NSInteger count;
@end

@implementation PGTargetDelegate

- (void)pressed:(id)sender {
    self.count += 1;
    self.label.stringValue = [NSString stringWithFormat:@"pressed %ld", (long)self.count];
    // Also write to a file so an external observer can confirm the press landed
    // even without reading AX (belt & braces for the matrix).
    NSString *s = [NSString stringWithFormat:@"pressed %ld\n", (long)self.count];
    [s writeToFile:@"/tmp/poltergeist-oop/label.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/tmp/poltergeist-oop"
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSRect frame = NSMakeRect(0, 0, 420, 200);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered
        defer:NO];
    self.window.title = @"Poltergeist OOP Target";
    [self.window center];

    NSView *cv = self.window.contentView;

    NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 140, 140, 32)];
    btn.title = @"Press me";
    btn.bezelStyle = NSBezelStyleRounded;
    btn.target = self;
    btn.action = @selector(pressed:);
    [btn setAccessibilityIdentifier:@"pressButton"];
    [cv addSubview:btn];
    self.button = btn;

    NSTextField *label = [NSTextField labelWithString:@"pressed 0"];
    label.frame = NSMakeRect(180, 146, 200, 24);
    label.font = [NSFont systemFontOfSize:18];
    [label setAccessibilityIdentifier:@"pressLabel"];
    [cv addSubview:label];
    self.label = label;

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 360, 28)];
    field.stringValue = @"edit me";
    field.editable = YES;
    field.selectable = YES;
    field.delegate = self;
    [field setAccessibilityIdentifier:@"textField"];
    [cv addSubview:field];
    self.field = field;

    NSTextField *hint = [NSTextField labelWithString:@"OOP automation target"];
    hint.frame = NSMakeRect(20, 30, 360, 20);
    hint.textColor = NSColor.secondaryLabelColor;
    [cv addSubview:hint];

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:field];
    [NSApp activateIgnoringOtherApps:YES];

    // Advertise our window id + button frame so the controller can find us.
    [self writeInfo];
}

- (void)writeInfo {
    NSInteger wn = self.window.windowNumber;
    // Button frame in screen coords (AppKit, origin bottom-left).
    NSRect inWin = [self.button convertRect:self.button.bounds toView:nil];
    NSRect inScreen = [self.window convertRectToScreen:inWin];
    // Button center in CoreGraphics GLOBAL coords (origin top-left), which is
    // what CGEventCreateMouseEvent / CGEventPostToPid expect. Flip Y using the
    // PRIMARY (menu-bar) screen height — the screen whose frame.origin == (0,0).
    CGFloat menuBarScreenH = NSScreen.screens.firstObject.frame.size.height;
    for (NSScreen *s in NSScreen.screens) {
        if (s.frame.origin.x == 0 && s.frame.origin.y == 0) { menuBarScreenH = s.frame.size.height; break; }
    }
    CGFloat cgX = inScreen.origin.x + inScreen.size.width/2.0;
    CGFloat cgY = menuBarScreenH - (inScreen.origin.y + inScreen.size.height/2.0);
    // Robust, flip-free: button center as an offset from the window's TOP-LEFT
    // corner (points). Controller adds this to the window's CG bounds origin.
    NSRect wf = self.window.frame;                       // screen, bottom-left, incl. titlebar
    CGFloat cx = inScreen.origin.x + inScreen.size.width/2.0;
    CGFloat cy = inScreen.origin.y + inScreen.size.height/2.0; // bottom-left
    CGFloat offX = cx - wf.origin.x;
    CGFloat offY = (wf.origin.y + wf.size.height) - cy;  // distance down from window top
    NSString *info = [NSString stringWithFormat:
        @"pid=%d windowNumber=%ld button_screen_appkit=%.1f,%.1f,%.1f,%.1f button_cg_center=%.1f,%.1f button_win_offset=%.1f,%.1f\n",
        getpid(), (long)wn,
        inScreen.origin.x, inScreen.origin.y, inScreen.size.width, inScreen.size.height,
        cgX, cgY, offX, offY];
    [info writeToFile:@"/tmp/poltergeist-oop/info.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)controlTextDidChange:(NSNotification *)note {
    NSString *v = [[[note object] stringValue] stringByAppendingString:@"\n"];
    [v writeToFile:@"/tmp/poltergeist-oop/field.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [PGApplication sharedApplication];
        PGTargetDelegate *d = [PGTargetDelegate new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
