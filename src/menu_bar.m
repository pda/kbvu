#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

extern void kbvu_request_stop(void);
extern int kbvu_menu_tracking_tick(void *context);

static void KBVUShowAlert(NSString *title, NSString *message,
                          NSAlertStyle style) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = style;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

@interface KBVUMenuController : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *startAtLoginItem;
@property(nonatomic, strong) NSTimer *trackingTimer;
@property(nonatomic, assign) void *tickContext;
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

    _startAtLoginItem = [[NSMenuItem alloc]
        initWithTitle:@"Start at Login"
               action:@selector(toggleStartAtLogin:)
        keyEquivalent:@""];
    _startAtLoginItem.target = self;
    [menu addItem:_startAtLoginItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit Keyboard VU"
               action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    menu.delegate = self;
    _statusItem.menu = menu;
    [self updateStartAtLoginItem];
    return self;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self updateStartAtLoginItem];
    [self.trackingTimer invalidate];
    self.trackingTimer =
        [NSTimer timerWithTimeInterval:0.05
                                target:self
                              selector:@selector(trackingTimerFired:)
                              userInfo:nil
                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.trackingTimer
                                 forMode:NSEventTrackingRunLoopMode];
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    [self.trackingTimer invalidate];
    self.trackingTimer = nil;
}

- (void)trackingTimerFired:(NSTimer *)timer {
    (void)timer;
    if (self.tickContext != NULL &&
        kbvu_menu_tracking_tick(self.tickContext) != 0) {
        [self.statusItem.menu cancelTracking];
    }
}

- (void)updateStartAtLoginItem {
    switch (SMAppService.mainAppService.status) {
    case SMAppServiceStatusEnabled:
        self.startAtLoginItem.state = NSControlStateValueOn;
        self.startAtLoginItem.toolTip = nil;
        break;
    case SMAppServiceStatusRequiresApproval:
        self.startAtLoginItem.state = NSControlStateValueMixed;
        self.startAtLoginItem.toolTip =
            @"Approval is required in System Settings → Login Items";
        break;
    case SMAppServiceStatusNotRegistered:
    case SMAppServiceStatusNotFound:
        self.startAtLoginItem.state = NSControlStateValueOff;
        self.startAtLoginItem.toolTip = nil;
        break;
    }
}

- (void)toggleStartAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }

    NSError *error = nil;
    BOOL changed;
    if (service.status == SMAppServiceStatusEnabled) {
        changed = [service unregisterAndReturnError:&error];
    } else {
        changed = [service registerAndReturnError:&error];
    }
    [self updateStartAtLoginItem];

    if (!changed) {
        NSString *message = [NSString stringWithFormat:
            @"macOS could not change the Keyboard VU Login Item.\n\n%@",
            error.localizedDescription ?: @"An unknown error occurred."];
        KBVUShowAlert(@"Could not update Start at Login", message,
                      NSAlertStyleWarning);
        if (service.status == SMAppServiceStatusRequiresApproval) {
            [SMAppService openSystemSettingsLoginItems];
        }
    } else if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
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

void kbvu_menubar_set_tick_context(void *context) {
    controller.tickContext = context;
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
        NSString *details = [NSString stringWithUTF8String:message];
        KBVUShowAlert(@"Keyboard VU could not start",
                      details ?: @"An unknown error occurred.",
                      NSAlertStyleCritical);
    }
}

void kbvu_menubar_stop(void) {
    if (controller == nil) {
        return;
    }
    [controller.trackingTimer invalidate];
    [[NSStatusBar systemStatusBar] removeStatusItem:controller.statusItem];
    controller = nil;
}
