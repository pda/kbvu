#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/AudioHardware.h>
#import <ServiceManagement/ServiceManagement.h>

extern void kbvu_request_stop(void);
extern int kbvu_menu_tracking_tick(void *context);

static NSString *const KBVUSelectedOutputUIDsKey = @"SelectedOutputDeviceUIDs";
static NSString *const KBVUDeviceIDKey = @"id";
static NSString *const KBVUDeviceNameKey = @"name";
static NSString *const KBVUDeviceUIDKey = @"uid";

static BOOL KBVUGetAudioUInt32Property(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32 *value) {
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size,
                                      value) == noErr;
}

static NSString *KBVUAudioDeviceString(
    AudioObjectID deviceID,
    AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size,
                                   &value) != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSArray<NSDictionary<NSString *, id> *> *KBVUAvailableOutputDevices(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0,
                                       NULL, &size) != noErr || size == 0) {
        return @[];
    }

    NSMutableData *deviceData = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                   &size, deviceData.mutableBytes) != noErr) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *outputs =
        [NSMutableArray array];
    const AudioObjectID *deviceIDs = deviceData.bytes;
    const NSUInteger deviceCount = size / sizeof(*deviceIDs);
    for (NSUInteger index = 0; index < deviceCount; index++) {
        AudioObjectID deviceID = deviceIDs[index];
        UInt32 alive = 0;
        UInt32 canBeDefault = 0;
        if (!KBVUGetAudioUInt32Property(
                deviceID, kAudioDevicePropertyDeviceIsAlive,
                kAudioObjectPropertyScopeGlobal, &alive) ||
            alive == 0 ||
            !KBVUGetAudioUInt32Property(
                deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                kAudioDevicePropertyScopeOutput, &canBeDefault) ||
            canBeDefault == 0) {
            continue;
        }

        NSString *name =
            KBVUAudioDeviceString(deviceID, kAudioObjectPropertyName);
        NSString *uid =
            KBVUAudioDeviceString(deviceID, kAudioDevicePropertyDeviceUID);
        if (name == nil || uid == nil) {
            continue;
        }
        [outputs addObject:@{
            KBVUDeviceIDKey: @(deviceID),
            KBVUDeviceNameKey: name,
            KBVUDeviceUIDKey: uid,
        }];
    }

    [outputs sortUsingComparator:^NSComparisonResult(
        NSDictionary<NSString *, id> *left,
        NSDictionary<NSString *, id> *right) {
        return [left[KBVUDeviceNameKey]
            localizedCaseInsensitiveCompare:right[KBVUDeviceNameKey]];
    }];
    return outputs;
}

static AudioObjectID KBVUDefaultOutputDevice(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                   &size, &deviceID) != noErr) {
        return kAudioObjectUnknown;
    }
    return deviceID;
}

static void KBVUSetDefaultOutputDevice(AudioObjectID deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(deviceID);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, size,
                               &deviceID);
}

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
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *keyboardStatusItem;
@property(nonatomic, strong) NSMenuItem *outputHeadingItem;
@property(nonatomic, strong) NSArray<NSMenuItem *> *outputDeviceItems;
@property(nonatomic, strong) NSMenuItem *startAtLoginItem;
@property(nonatomic, strong) NSTimer *trackingTimer;
@property(nonatomic, assign) void *tickContext;
@property(nonatomic, assign) EventHandlerRef hotKeyHandler;
@property(nonatomic, assign) EventHotKeyRef hotKey;
- (void)cycleOutputDevice;
@end

static OSStatus KBVUHandleCycleHotKey(
    EventHandlerCallRef nextHandler,
    EventRef event,
    void *userData) {
    (void)nextHandler;
    (void)event;
    KBVUMenuController *menuController =
        (__bridge KBVUMenuController *)userData;
    [menuController cycleOutputDevice];
    return noErr;
}

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

    _menu = [[NSMenu alloc] initWithTitle:@"Keyboard VU"];
    _keyboardStatusItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:nil
        keyEquivalent:@""];
    _keyboardStatusItem.enabled = NO;
    [_menu addItem:_keyboardStatusItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    BOOL hotKeyAvailable = [self registerCycleHotKey];
    _outputHeadingItem = [[NSMenuItem alloc]
        initWithTitle:(hotKeyAvailable ? @"Cycle Audio Outputs (F13)"
                                           : @"Audio Outputs (F13 unavailable)")
               action:nil
        keyEquivalent:@""];
    _outputHeadingItem.enabled = NO;
    _outputHeadingItem.toolTip =
        hotKeyAvailable
            ? @"Remap the knob button to F13; checked devices are included in the cycle"
            : @"Another application has already reserved the F13 global shortcut";
    [_menu addItem:_outputHeadingItem];
    _outputDeviceItems = @[];
    [self refreshOutputDevices];
    [_menu addItem:[NSMenuItem separatorItem]];

    _startAtLoginItem = [[NSMenuItem alloc]
        initWithTitle:@"Start at Login"
               action:@selector(toggleStartAtLogin:)
        keyEquivalent:@""];
    _startAtLoginItem.target = self;
    [_menu addItem:_startAtLoginItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit Keyboard VU"
               action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [_menu addItem:quit];
    _menu.delegate = self;
    _statusItem.menu = _menu;
    [self setKeyboardConnected:NO];
    [self updateStartAtLoginItem];
    return self;
}

- (void)dealloc {
    if (_hotKey != NULL) {
        UnregisterEventHotKey(_hotKey);
    }
    if (_hotKeyHandler != NULL) {
        RemoveEventHandler(_hotKeyHandler);
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self refreshOutputDevices];
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
    [self drainPendingHotKeyEvents];
}

// While the status-item menu is open, the main run loop is in menu-tracking
// mode and queued Carbon hotkey events are not dispatched until the menu
// closes, so F13 appears to do nothing until then. This timer runs in
// NSEventTrackingRunLoopMode, so drain queued hotkey events here and
// dispatch them to the handler immediately.
- (void)drainPendingHotKeyEvents {
    if (self.hotKeyHandler == NULL) {
        return;
    }
    EventTypeSpec spec = {
        kEventClassKeyboard,
        kEventHotKeyPressed,
    };
    BOOL dispatched = NO;
    for (;;) {
        EventRef event = AcquireFirstMatchingEventInQueue(
            GetMainEventQueue(), 1, &spec, kEventQueueOptionsNone);
        if (event == NULL) {
            break;
        }
        RemoveEventFromQueue(GetMainEventQueue(), event);
        SendEventToEventTarget(event, GetApplicationEventTarget());
        ReleaseEvent(event);
        dispatched = YES;
    }
    if (dispatched) {
        // Update the "— Current" marker in the open menu.
        [self refreshOutputDevices];
    }
}

- (void)setKeyboardConnected:(BOOL)connected {
    if (connected) {
        self.keyboardStatusItem.title = @"NuPhy Air75 V3 connected";
        self.keyboardStatusItem.image = nil;
        self.keyboardStatusItem.toolTip = nil;
        return;
    }

    self.keyboardStatusItem.title = @"NuPhy Air75 V3 disconnected — waiting…";
    NSImage *warning =
        [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle"
                  accessibilityDescription:@"Keyboard disconnected"];
    warning.template = YES;
    self.keyboardStatusItem.image = warning;
    self.keyboardStatusItem.toolTip =
        @"Reconnect the keyboard by USB; Keyboard VU will resume automatically";
}

- (BOOL)registerCycleHotKey {
    EventTypeSpec eventType = {
        kEventClassKeyboard,
        kEventHotKeyPressed,
    };
    OSStatus status = InstallApplicationEventHandler(
        KBVUHandleCycleHotKey, 1, &eventType, (__bridge void *)self,
        &_hotKeyHandler);
    if (status != noErr) {
        return NO;
    }

    EventHotKeyID hotKeyID = {
        .signature = 'KBVU',
        .id = 1,
    };
    status = RegisterEventHotKey(kVK_F13, 0, hotKeyID,
                                 GetApplicationEventTarget(), 0, &_hotKey);
    if (status != noErr) {
        RemoveEventHandler(_hotKeyHandler);
        _hotKeyHandler = NULL;
        return NO;
    }
    return YES;
}

- (NSMutableSet<NSString *> *)selectedOutputUIDs {
    NSArray *saved =
        [NSUserDefaults.standardUserDefaults arrayForKey:KBVUSelectedOutputUIDsKey];
    NSMutableSet<NSString *> *selected = [NSMutableSet set];
    for (id value in saved ?: @[]) {
        if ([value isKindOfClass:NSString.class]) {
            [selected addObject:value];
        }
    }
    return selected;
}

- (void)saveSelectedOutputUIDs:(NSSet<NSString *> *)selected {
    NSArray<NSString *> *saved =
        [selected.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [NSUserDefaults.standardUserDefaults setObject:saved
                                            forKey:KBVUSelectedOutputUIDsKey];
}

- (void)refreshOutputDevices {
    for (NSMenuItem *item in self.outputDeviceItems) {
        [self.menu removeItem:item];
    }

    NSArray<NSDictionary<NSString *, id> *> *devices =
        KBVUAvailableOutputDevices();
    NSSet<NSString *> *selected = [self selectedOutputUIDs];
    AudioObjectID currentDeviceID = KBVUDefaultOutputDevice();
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    NSInteger insertIndex = [self.menu indexOfItem:self.outputHeadingItem] + 1;

    for (NSDictionary<NSString *, id> *device in devices) {
        AudioObjectID deviceID = [device[KBVUDeviceIDKey] unsignedIntValue];
        NSString *name = device[KBVUDeviceNameKey];
        if (deviceID == currentDeviceID) {
            name = [name stringByAppendingString:@" — Current"];
        }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:name
                   action:@selector(toggleOutputDevice:)
            keyEquivalent:@""];
        item.target = self;
        item.representedObject = device[KBVUDeviceUIDKey];
        item.state = [selected containsObject:item.representedObject]
                         ? NSControlStateValueOn
                         : NSControlStateValueOff;
        [self.menu insertItem:item atIndex:insertIndex++];
        [items addObject:item];
    }

    if (items.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc]
            initWithTitle:@"No output devices available"
                   action:nil
            keyEquivalent:@""];
        empty.enabled = NO;
        [self.menu insertItem:empty atIndex:insertIndex];
        [items addObject:empty];
    }
    self.outputDeviceItems = items;
}

- (void)toggleOutputDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    if (![uid isKindOfClass:NSString.class]) {
        return;
    }

    NSMutableSet<NSString *> *selected = [self selectedOutputUIDs];
    if ([selected containsObject:uid]) {
        [selected removeObject:uid];
        sender.state = NSControlStateValueOff;
    } else {
        [selected addObject:uid];
        sender.state = NSControlStateValueOn;
    }
    [self saveSelectedOutputUIDs:selected];
}

- (void)cycleOutputDevice {
    NSSet<NSString *> *selected = [self selectedOutputUIDs];
    NSArray<NSDictionary<NSString *, id> *> *available =
        KBVUAvailableOutputDevices();
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *device in available) {
        if ([selected containsObject:device[KBVUDeviceUIDKey]]) {
            [candidates addObject:device];
        }
    }
    if (candidates.count == 0) {
        return;
    }

    AudioObjectID currentDeviceID = KBVUDefaultOutputDevice();
    NSUInteger targetIndex = 0;
    for (NSUInteger index = 0; index < candidates.count; index++) {
        AudioObjectID deviceID =
            [candidates[index][KBVUDeviceIDKey] unsignedIntValue];
        if (deviceID == currentDeviceID) {
            if (candidates.count == 1) {
                return;
            }
            targetIndex = (index + 1) % candidates.count;
            break;
        }
    }

    AudioObjectID targetDeviceID =
        [candidates[targetIndex][KBVUDeviceIDKey] unsignedIntValue];
    if (targetDeviceID != currentDeviceID) {
        KBVUSetDefaultOutputDevice(targetDeviceID);
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

void kbvu_menubar_set_keyboard_connected(int connected) {
    [controller setKeyboardConnected:connected != 0];
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
