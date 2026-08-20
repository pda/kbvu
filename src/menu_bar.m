#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/AudioHardware.h>
#import <ServiceManagement/ServiceManagement.h>

typedef struct {
    uint64_t frames_sent;
    uint64_t frames_suppressed;
    uint64_t output_reports;
    uint64_t input_reports;
    uint64_t hid_busy_nanoseconds;
    uint64_t usb_link_speed_bps;
    double reply_latency_average_ms;
    double reply_latency_median_ms;
    double reply_latency_p99_ms;
    uint16_t reply_latency_samples;
    uint16_t usb_vendor_id;
    uint16_t usb_product_id;
    uint8_t hid_report_size;
    uint8_t left_segments;
    uint8_t right_segments;
    uint8_t red;
    uint8_t green;
    uint8_t blue;
} KBVUMenuSnapshot;

_Static_assert(sizeof(KBVUMenuSnapshot) == 88,
               "unexpected menu snapshot layout");

extern void kbvu_request_stop(void);
extern double kbvu_display_interval_seconds(void);
extern int kbvu_menu_tracking_tick(void *context, KBVUMenuSnapshot *snapshot);

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

static NSString *KBVUFormatFrameCount(uint64_t count) {
    if (count < 100000) {
        return [NSNumberFormatter
            localizedStringFromNumber:@(count)
                           numberStyle:NSNumberFormatterDecimalStyle];
    }

    const double divisor = count < 1000000
        ? 1000.0
        : (count < 1000000000 ? 1000000.0 : 1000000000.0);
    NSString *suffix = count < 1000000
        ? @"K"
        : (count < 1000000000 ? @"M" : @"B");
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.maximumFractionDigits = 1;
    return [NSString stringWithFormat:@"%@%@",
                                      [formatter stringFromNumber:@(count / divisor)],
                                      suffix];
}

@interface KBVUMeterView : NSView
@property(nonatomic, assign) NSUInteger leftSegments;
@property(nonatomic, assign) NSUInteger rightSegments;
@property(nonatomic, strong) NSColor *barColor;
- (void)updateWithSnapshot:(KBVUMenuSnapshot)snapshot;
@end

@implementation KBVUMeterView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    _barColor = [NSColor colorWithSRGBRed:51.0 / 255.0
                                    green:199.0 / 255.0
                                     blue:1.0
                                    alpha:1.0];
    self.autoresizingMask = NSViewWidthSizable;
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = @"Stereo VU meter";
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)updateWithSnapshot:(KBVUMenuSnapshot)snapshot {
    self.leftSegments = MIN(snapshot.left_segments, 10);
    self.rightSegments = MIN(snapshot.right_segments, 10);
    self.barColor = [NSColor colorWithSRGBRed:snapshot.red / 255.0
                                        green:snapshot.green / 255.0
                                         blue:snapshot.blue / 255.0
                                        alpha:1.0];
    self.accessibilityValue = [NSString
        stringWithFormat:@"Left %lu of 10, right %lu of 10",
                         (unsigned long)self.leftSegments,
                         (unsigned long)self.rightSegments];
    self.needsDisplay = YES;
}

- (void)drawBarAtX:(CGFloat)x
                 y:(CGFloat)y
    filledSegments:(NSUInteger)filled {
    const CGFloat segmentSize = 6;
    const CGFloat segmentGap = 3;
    NSColor *emptyFill = [NSColor.blackColor colorWithAlphaComponent:0.2];
    NSColor *cellOutline =
        [NSColor.secondaryLabelColor colorWithAlphaComponent:0.65];
    for (NSUInteger index = 0; index < 10; index++) {
        NSRect segment = NSMakeRect(
            x + index * (segmentSize + segmentGap), y, segmentSize, segmentSize);
        NSBezierPath *outline = [NSBezierPath
            bezierPathWithRoundedRect:NSInsetRect(segment, 0.5, 0.5)
                              xRadius:1
                              yRadius:1];
        [(index < filled ? self.barColor : emptyFill) setFill];
        [outline fill];
        [cellOutline setStroke];
        outline.lineWidth = 1;
        [outline stroke];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName:
            [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };
    [@"L" drawAtPoint:NSMakePoint(11, 3) withAttributes:attributes];
    [self drawBarAtX:29 y:8 filledSegments:self.leftSegments];
    [@"R" drawAtPoint:NSMakePoint(130, 3) withAttributes:attributes];
    [self drawBarAtX:148 y:8 filledSegments:self.rightSegments];
}

@end

@interface KBVUDiagnosticsView : NSView
@property(nonatomic, strong) NSTextField *usbLabel;
@property(nonatomic, strong) NSTextField *trafficLabel;
@property(nonatomic, strong) NSTextField *latencyLabel;
@property(nonatomic, strong) NSTextField *loadLabel;
@property(nonatomic, strong) NSTextField *frameLabel;
- (void)updateUSBText:(NSString *)usbText frameText:(NSString *)frameText;
- (void)updateTrafficText:(NSString *)trafficText;
- (void)updateLatencyText:(NSString *)latencyText;
- (void)updateLoadText:(NSString *)loadText;
@end

@implementation KBVUDiagnosticsView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    const CGFloat lineHeight = 15;
    NSArray<NSString *> *initialText = @[
        @"USB  waiting…",
        @"HID  sampling…",
        @"Reply  sampling…",
        @"Rate  sampling…",
        @"Frames  0 sent · 0 dupes skipped",
    ];
    NSMutableArray<NSTextField *> *labels = [NSMutableArray arrayWithCapacity:5];
    for (NSUInteger index = 0; index < initialText.count; index++) {
        NSTextField *label = [NSTextField labelWithString:initialText[index]];
        label.frame = NSMakeRect(20, 1 + index * lineHeight,
                                 frame.size.width - 28, lineHeight);
        label.font = [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightRegular];
        label.textColor = NSColor.secondaryLabelColor;
        label.lineBreakMode = NSLineBreakByClipping;
        label.usesSingleLineMode = YES;
        label.autoresizingMask = NSViewWidthSizable;
        [self addSubview:label];
        [labels addObject:label];
    }
    _usbLabel = labels[0];
    _trafficLabel = labels[1];
    _latencyLabel = labels[2];
    _loadLabel = labels[3];
    _frameLabel = labels[4];
    self.autoresizingMask = NSViewWidthSizable;
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)updateUSBText:(NSString *)usbText frameText:(NSString *)frameText {
    self.usbLabel.stringValue = usbText;
    self.frameLabel.stringValue = frameText;
}

- (void)updateTrafficText:(NSString *)trafficText {
    self.trafficLabel.stringValue = trafficText;
}

- (void)updateLatencyText:(NSString *)latencyText {
    self.latencyLabel.stringValue = latencyText;
}

- (void)updateLoadText:(NSString *)loadText {
    self.loadLabel.stringValue = loadText;
}

@end

@interface KBVUMenuController : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *keyboardStatusItem;
@property(nonatomic, strong) KBVUMeterView *meterView;
@property(nonatomic, strong) NSMenuItem *diagnosticsSeparatorItem;
@property(nonatomic, strong) NSMenuItem *diagnosticsItem;
@property(nonatomic, strong) KBVUDiagnosticsView *diagnosticsView;
@property(nonatomic, strong) NSMenuItem *outputHeadingItem;
@property(nonatomic, strong) NSArray<NSMenuItem *> *outputDeviceItems;
@property(nonatomic, strong) NSMenuItem *startAtLoginItem;
@property(nonatomic, strong) NSTimer *trackingTimer;
@property(nonatomic, assign) void *tickContext;
@property(nonatomic, assign) EventHandlerRef hotKeyHandler;
@property(nonatomic, assign) EventHotKeyRef hotKey;
@property(nonatomic, assign) BOOL showDiagnostics;
@property(nonatomic, assign) NSTimeInterval statsSampleTime;
@property(nonatomic, assign) uint64_t sampledOutputReports;
@property(nonatomic, assign) uint64_t sampledInputReports;
@property(nonatomic, assign) uint64_t sampledFrames;
@property(nonatomic, assign) uint64_t sampledHIDBusyNanoseconds;
- (void)cycleOutputDevice;
- (void)updateDiagnosticsWithSnapshot:(KBVUMenuSnapshot)snapshot;
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
    button.toolTip = @"Keyboard VU — Option-click for HID diagnostics";

    _menu = [[NSMenu alloc] initWithTitle:@"Keyboard VU"];
    _keyboardStatusItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:nil
        keyEquivalent:@""];
    _keyboardStatusItem.enabled = NO;
    [_menu addItem:_keyboardStatusItem];

    NSMenuItem *meterItem = [[NSMenuItem alloc]
        initWithTitle:@"Stereo VU meter"
               action:nil
        keyEquivalent:@""];
    _meterView = [[KBVUMeterView alloc]
        initWithFrame:NSMakeRect(0, 0, 250, 22)];
    meterItem.view = _meterView;
    [_menu addItem:meterItem];

    _diagnosticsSeparatorItem = [NSMenuItem separatorItem];
    _diagnosticsSeparatorItem.hidden = YES;
    [_menu addItem:_diagnosticsSeparatorItem];

    _diagnosticsItem = [[NSMenuItem alloc]
        initWithTitle:@"Keyboard diagnostics"
               action:nil
        keyEquivalent:@""];
    _diagnosticsView = [[KBVUDiagnosticsView alloc]
        initWithFrame:NSMakeRect(0, 0, 360, 77)];
    _diagnosticsItem.view = _diagnosticsView;
    _diagnosticsItem.hidden = YES;
    [_menu addItem:_diagnosticsItem];
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
    self.showDiagnostics =
        (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    self.diagnosticsSeparatorItem.hidden = !self.showDiagnostics;
    self.diagnosticsItem.hidden = !self.showDiagnostics;
    [self.diagnosticsView updateTrafficText:@"HID  sampling…"];
    self.statsSampleTime = 0;
    [self refreshOutputDevices];
    [self updateStartAtLoginItem];
    [self.trackingTimer invalidate];
    self.trackingTimer =
        [NSTimer timerWithTimeInterval:kbvu_display_interval_seconds()
                                target:self
                              selector:@selector(trackingTimerFired:)
                              userInfo:nil
                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.trackingTimer
                                 forMode:NSEventTrackingRunLoopMode];
    [self trackingTimerFired:self.trackingTimer];
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    [self.trackingTimer invalidate];
    self.trackingTimer = nil;
}

- (void)trackingTimerFired:(NSTimer *)timer {
    (void)timer;
    if (self.tickContext != NULL) {
        KBVUMenuSnapshot snapshot = {0};
        if (kbvu_menu_tracking_tick(self.tickContext, &snapshot) != 0) {
            [self.statusItem.menu cancelTracking];
            return;
        }
        [self.meterView updateWithSnapshot:snapshot];
        [self updateDiagnosticsWithSnapshot:snapshot];
    }
    [self drainPendingHotKeyEvents];
}

- (void)updateDiagnosticsWithSnapshot:(KBVUMenuSnapshot)snapshot {
    if (!self.showDiagnostics) {
        return;
    }

    const uint64_t totalFrames =
        snapshot.frames_sent + snapshot.frames_suppressed;
    const double suppressedPercent = totalFrames == 0
        ? 0
        : 100.0 * snapshot.frames_suppressed / totalFrames;
    NSString *sent = KBVUFormatFrameCount(snapshot.frames_sent);
    NSString *suppressed = KBVUFormatFrameCount(snapshot.frames_suppressed);
    NSString *frameText = [NSString
        stringWithFormat:@"Frames  %@ sent · %@ dupes skipped (%.0f%%)", sent,
                         suppressed, suppressedPercent];

    NSString *usbText;
    if (snapshot.usb_link_speed_bps == 0) {
        usbText = [NSString
            stringWithFormat:@"USB  %04x:%04x · %u-byte HID",
                             (unsigned int)snapshot.usb_vendor_id,
                             (unsigned int)snapshot.usb_product_id,
                             (unsigned int)snapshot.hid_report_size];
    } else {
        const double linkSpeed = snapshot.usb_link_speed_bps >= 1000000000
            ? snapshot.usb_link_speed_bps / 1000000000.0
            : snapshot.usb_link_speed_bps / 1000000.0;
        NSString *linkUnit = snapshot.usb_link_speed_bps >= 1000000000
            ? @"Gb/s"
            : @"Mb/s";
        usbText = [NSString
            stringWithFormat:@"USB  %04x:%04x · %.3g %@ · %u-byte HID",
                             (unsigned int)snapshot.usb_vendor_id,
                             (unsigned int)snapshot.usb_product_id, linkSpeed,
                             linkUnit, (unsigned int)snapshot.hid_report_size];
    }
    [self.diagnosticsView updateUSBText:usbText frameText:frameText];

    if (snapshot.reply_latency_samples == 0) {
        [self.diagnosticsView updateLatencyText:@"Reply  sampling…"];
    } else {
        [self.diagnosticsView
            updateLatencyText:[NSString
                stringWithFormat:@"Reply  avg %.1f · p50 %.1f · p99 %.1f ms",
                                 snapshot.reply_latency_average_ms,
                                 snapshot.reply_latency_median_ms,
                                 snapshot.reply_latency_p99_ms]];
    }

    const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.statsSampleTime == 0) {
        self.statsSampleTime = now;
        self.sampledOutputReports = snapshot.output_reports;
        self.sampledInputReports = snapshot.input_reports;
        self.sampledFrames = totalFrames;
        self.sampledHIDBusyNanoseconds = snapshot.hid_busy_nanoseconds;
        return;
    }

    const NSTimeInterval elapsed = now - self.statsSampleTime;
    if (elapsed < 0.5) {
        return;
    }

    const uint64_t outputReports =
        snapshot.output_reports - self.sampledOutputReports;
    const uint64_t inputReports =
        snapshot.input_reports - self.sampledInputReports;
    const double outputRate = outputReports / elapsed;
    const double inputRate = inputReports / elapsed;
    const double frameRate = (totalFrames - self.sampledFrames) / elapsed;
    const double hidBusyPercent =
        100.0 * (snapshot.hid_busy_nanoseconds -
                 self.sampledHIDBusyNanoseconds) /
        (elapsed * 1000000000.0);
    const double bytesPerSecond =
        (outputReports + inputReports) * snapshot.hid_report_size / elapsed;
    NSString *throughput = bytesPerSecond < 1024
        ? [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond]
        : [NSString stringWithFormat:@"%.1f KiB/s", bytesPerSecond / 1024.0];
    if (outputReports == 0 && inputReports == 0) {
        [self.diagnosticsView updateTrafficText:@"HID  idle · 0 B/s"];
    } else {
        [self.diagnosticsView
            updateTrafficText:[NSString
                stringWithFormat:@"HID  out %.1f/s · in %.1f/s · %@",
                                 outputRate, inputRate, throughput]];
    }
    [self.diagnosticsView
        updateLoadText:[NSString
            stringWithFormat:@"Rate  %.1f fps · HID busy %.0f%%", frameRate,
                             hidBusyPercent]];

    self.statsSampleTime = now;
    self.sampledOutputReports = snapshot.output_reports;
    self.sampledInputReports = snapshot.input_reports;
    self.sampledFrames = totalFrames;
    self.sampledHIDBusyNanoseconds = snapshot.hid_busy_nanoseconds;
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
        // Update the current-output badge in the open menu.
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
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:name
                   action:@selector(toggleOutputDevice:)
            keyEquivalent:@""];
        item.target = self;
        item.representedObject = device[KBVUDeviceUIDKey];
        if (deviceID == currentDeviceID) {
            item.badge = [[NSMenuItemBadge alloc] initWithString:@"Current"];
        }
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
