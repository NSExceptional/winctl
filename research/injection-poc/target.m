// target.m — a tiny throwaway, non-sandboxed AppKit app used as the injection
// target when the real target (TextEdit) is sandboxed. It just puts an editable
// NSTextView on screen and makes it first responder, so the injected dylib has a
// window to capture and a text view to type into.
//
// Build:
//   clang -arch arm64e -framework Cocoa -o Target.app/Contents/MacOS/Target target.m

#import <Cocoa/Cocoa.h>

@interface PGAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSTextView *textView;
@end

@implementation PGAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSRect frame = NSMakeRect(0, 0, 640, 400);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered
        defer:NO
    ];
    self.window.title = @"Poltergeist Target";
    [self.window center];

    NSTextView *tv = [[NSTextView alloc] initWithFrame:frame];
    tv.font = [NSFont systemFontOfSize:24];
    tv.string = @"Target ready. ";
    tv.automaticQuoteSubstitutionEnabled = NO;
    self.textView = tv;

    self.window.contentView = tv;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:tv];

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        PGAppDelegate *delegate = [PGAppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
