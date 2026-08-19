#import <AppKit/AppKit.h>

extern void kbvu_request_stop(void);

@interface KBVUMenuController : NSObject
@property(nonatomic, strong) NSStatusItem *statusItem;
@end

@implementation KBVUMenuController

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = _statusItem.button;
    if (button == nil) {
        return nil;
    }

    NSImage *image = [NSImage imageWithSystemSymbolName:@"waveform"
                               accessibilityDescription:@"Keyboard VU"];
    if (image != nil) {
        image.template = YES;
        button.image = image;
    } else {
        button.title = @"VU";
    }
    button.toolTip = @"Keyboard VU";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Keyboard VU"];
    NSMenuItem *status = [[NSMenuItem alloc]
        initWithTitle:@"Keyboard VU is running"
               action:nil
        keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit Keyboard VU"
               action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    _statusItem.menu = menu;
    return self;
}

- (void)quit:(id)sender {
    (void)sender;
    kbvu_request_stop();
}

@end

static KBVUMenuController *controller;

int kbvu_is_app_bundle(void) {
    NSString *extension = NSBundle.mainBundle.bundlePath.pathExtension;
    return [extension caseInsensitiveCompare:@"app"] == NSOrderedSame;
}

int kbvu_menubar_start(void) {
    if (controller != nil) {
        return 0;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    controller = [[KBVUMenuController alloc] init];
    return controller == nil ? -1 : 0;
}

void kbvu_menubar_pump(void) {
    @autoreleasepool {
        for (;;) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event == nil) {
                break;
            }
            [NSApp sendEvent:event];
        }
        [NSApp updateWindows];
    }
}

void kbvu_menubar_show_error(const char *message) {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleCritical;
        alert.messageText = @"Keyboard VU could not start";
        NSString *details = [NSString stringWithUTF8String:message];
        alert.informativeText = details ?: @"An unknown error occurred.";
        [alert addButtonWithTitle:@"OK"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    }
}

void kbvu_menubar_stop(void) {
    if (controller == nil) {
        return;
    }
    [[NSStatusBar systemStatusBar] removeStatusItem:controller.statusItem];
    controller = nil;
}
