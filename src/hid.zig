const std = @import("std");

// Direct declarations keep Zig's C translator away from unrelated Mach and
// blocks declarations in the macOS SDK. These signatures mirror CoreFoundation
// and IOHIDLib's public C APIs.
const c = struct {
    pub const CFIndex = isize;
    pub const CFAllocator = opaque {};
    pub const CFAllocatorRef = ?*const CFAllocator;
    pub const CFString = opaque {};
    pub const CFStringRef = *const CFString;
    pub const CFMutableDictionary = opaque {};
    pub const CFMutableDictionaryRef = *CFMutableDictionary;
    pub const CFSet = opaque {};
    pub const CFSetRef = *const CFSet;
    pub const CFRunLoop = opaque {};
    pub const CFRunLoopRef = *CFRunLoop;
    pub const IOHIDManager = opaque {};
    pub const IOHIDManagerRef = *IOHIDManager;
    pub const IOHIDDevice = opaque {};
    pub const IOHIDDeviceRef = *IOHIDDevice;
    pub const IOReturn = i32;
    pub const IOHIDReportType = c_uint;
    pub const IOHIDReportCallback = *const fn (
        context: ?*anyopaque,
        result: IOReturn,
        sender: ?*anyopaque,
        report_type: IOHIDReportType,
        report_id: u32,
        report: [*c]u8,
        report_length: CFIndex,
    ) callconv(.c) void;

    pub const kCFStringEncodingUTF8: u32 = 0x08000100;
    pub const kCFNumberIntType: c_uint = 9;
    pub const kIOHIDOptionsTypeNone: u32 = 0;
    pub const kIOHIDReportTypeOutput: IOHIDReportType = 1;
    pub const kIOReturnSuccess: IOReturn = 0;

    pub extern const kCFAllocatorDefault: CFAllocatorRef;
    pub extern const kCFRunLoopDefaultMode: CFStringRef;
    // Only these symbols' addresses are passed; their private struct layouts
    // are intentionally not represented here.
    pub extern const kCFTypeDictionaryKeyCallBacks: u8;
    pub extern const kCFTypeDictionaryValueCallBacks: u8;

    pub extern fn CFRelease(value: *const anyopaque) void;
    pub extern fn CFStringCreateWithCString(
        allocator: CFAllocatorRef,
        string: [*:0]const u8,
        encoding: u32,
    ) ?CFStringRef;
    pub extern fn CFNumberCreate(
        allocator: CFAllocatorRef,
        number_type: c_uint,
        value: *const anyopaque,
    ) ?*const anyopaque;
    pub extern fn CFNumberGetTypeID() usize;
    pub extern fn CFNumberGetValue(
        number: *const anyopaque,
        number_type: c_uint,
        value: *anyopaque,
    ) u8;
    pub extern fn CFGetTypeID(value: *const anyopaque) usize;
    pub extern fn CFDictionaryCreateMutable(
        allocator: CFAllocatorRef,
        capacity: CFIndex,
        key_callbacks: ?*const anyopaque,
        value_callbacks: ?*const anyopaque,
    ) ?CFMutableDictionaryRef;
    pub extern fn CFDictionarySetValue(
        dictionary: CFMutableDictionaryRef,
        key: *const anyopaque,
        value: *const anyopaque,
    ) void;
    pub extern fn CFSetGetCount(set: CFSetRef) CFIndex;
    pub extern fn CFSetGetValues(set: CFSetRef, values: [*]?*const anyopaque) void;
    pub extern fn CFRunLoopGetCurrent() CFRunLoopRef;
    pub extern fn CFRunLoopRunInMode(
        mode: CFStringRef,
        seconds: f64,
        return_after_source_handled: u8,
    ) c_int;

    pub extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: u32) ?IOHIDManagerRef;
    pub extern fn IOHIDManagerSetDeviceMatching(
        manager: IOHIDManagerRef,
        matching: ?*const anyopaque,
    ) void;
    pub extern fn IOHIDManagerScheduleWithRunLoop(
        manager: IOHIDManagerRef,
        run_loop: CFRunLoopRef,
        mode: CFStringRef,
    ) void;
    pub extern fn IOHIDManagerUnscheduleFromRunLoop(
        manager: IOHIDManagerRef,
        run_loop: CFRunLoopRef,
        mode: CFStringRef,
    ) void;
    pub extern fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: u32) IOReturn;
    pub extern fn IOHIDManagerClose(manager: IOHIDManagerRef, options: u32) IOReturn;
    pub extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?CFSetRef;

    pub extern fn IOHIDDeviceGetProperty(
        device: IOHIDDeviceRef,
        key: CFStringRef,
    ) ?*const anyopaque;
    pub extern fn IOHIDDeviceRegisterInputReportCallback(
        device: IOHIDDeviceRef,
        report: [*]u8,
        report_length: CFIndex,
        callback: ?IOHIDReportCallback,
        context: ?*anyopaque,
    ) void;
    pub extern fn IOHIDDeviceSetReport(
        device: IOHIDDeviceRef,
        report_type: IOHIDReportType,
        report_id: CFIndex,
        report: [*]const u8,
        report_length: CFIndex,
    ) IOReturn;

    pub extern fn arc4random_buf(buffer: *anyopaque, length: usize) void;
    pub extern fn usleep(microseconds: c_uint) c_int;
};

pub const report_size = 64;

pub const Match = struct {
    vendor_id: i32,
    product_id: i32,
    usage_page: ?i32 = null,
    usage: ?i32 = null,
};

pub const Device = struct {
    manager: c.IOHIDManagerRef,
    devices: c.CFSetRef,
    device: c.IOHIDDeviceRef,
    input_buffer: [report_size]u8 = @splat(0),
    response: ?[report_size]u8 = null,
    expected_prefix: ?[2]u8 = null,
    started: bool = false,

    pub fn open(match: Match) !Device {
        const manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone) orelse
            return error.ManagerCreateFailed;
        errdefer c.CFRelease(manager);

        const matching = try createMatchingDictionary(match);
        defer c.CFRelease(matching);
        c.IOHIDManagerSetDeviceMatching(manager, matching);
        c.IOHIDManagerScheduleWithRunLoop(
            manager,
            c.CFRunLoopGetCurrent(),
            c.kCFRunLoopDefaultMode,
        );

        const open_result = c.IOHIDManagerOpen(manager, c.kIOHIDOptionsTypeNone);
        if (open_result != c.kIOReturnSuccess) return error.ManagerOpenFailed;
        errdefer {
            c.IOHIDManagerUnscheduleFromRunLoop(
                manager,
                c.CFRunLoopGetCurrent(),
                c.kCFRunLoopDefaultMode,
            );
            _ = c.IOHIDManagerClose(manager, c.kIOHIDOptionsTypeNone);
        }

        const devices = c.IOHIDManagerCopyDevices(manager) orelse return error.DeviceNotFound;
        errdefer c.CFRelease(devices);
        if (c.CFSetGetCount(devices) != 1) return error.DeviceNotFound;

        var values: [1]?*const anyopaque = .{null};
        c.CFSetGetValues(devices, @ptrCast(&values));
        const raw_device = values[0] orelse return error.DeviceNotFound;
        const device: c.IOHIDDeviceRef = @ptrCast(@constCast(raw_device));

        if (getIntegerProperty(device, "MaxInputReportSize") != report_size or
            getIntegerProperty(device, "MaxOutputReportSize") != report_size)
        {
            return error.UnexpectedDevice;
        }

        return .{
            .manager = manager,
            .devices = devices,
            .device = device,
        };
    }

    pub fn start(self: *Device) void {
        c.IOHIDDeviceRegisterInputReportCallback(
            self.device,
            &self.input_buffer,
            report_size,
            inputReportCallback,
            self,
        );
        self.started = true;
    }

    pub fn close(self: *Device) void {
        if (self.started) {
            c.IOHIDDeviceRegisterInputReportCallback(
                self.device,
                &self.input_buffer,
                report_size,
                null,
                null,
            );
        }
        c.IOHIDManagerUnscheduleFromRunLoop(
            self.manager,
            c.CFRunLoopGetCurrent(),
            c.kCFRunLoopDefaultMode,
        );
        _ = c.IOHIDManagerClose(self.manager, c.kIOHIDOptionsTypeNone);
        c.CFRelease(self.devices);
        c.CFRelease(self.manager);
    }

    pub fn sendAndReceive(
        self: *Device,
        report: *const [report_size]u8,
        expected_prefix: ?[2]u8,
        timeout_ms: u32,
    ) ![report_size]u8 {
        self.response = null;
        self.expected_prefix = expected_prefix;
        const result = c.IOHIDDeviceSetReport(
            self.device,
            c.kIOHIDReportTypeOutput,
            0,
            report,
            report_size,
        );
        if (result != c.kIOReturnSuccess) return error.WriteFailed;

        const attempts = @max(1, (timeout_ms + 19) / 20);
        for (0..attempts) |_| {
            _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0.02, 1);
            if (self.response) |response| return response;
        }
        return error.ResponseTimeout;
    }
};

pub fn fillRandom(buffer: []u8) void {
    c.arc4random_buf(buffer.ptr, buffer.len);
}

pub fn sleepMilliseconds(milliseconds: u32) void {
    _ = c.usleep(milliseconds * 1000);
}

fn inputReportCallback(
    context: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    report_type: c.IOHIDReportType,
    report_id: u32,
    report: [*c]u8,
    report_length: c.CFIndex,
) callconv(.c) void {
    _ = sender;
    _ = report_type;
    _ = report_id;
    if (result != c.kIOReturnSuccess or context == null or report_length != report_size) return;
    const self: *Device = @ptrCast(@alignCast(context.?));
    if (self.expected_prefix) |prefix| {
        if (report[0] != prefix[0] or report[1] != prefix[1]) return;
    }
    var response: [report_size]u8 = undefined;
    @memcpy(&response, report[0..report_size]);
    self.response = response;
}

fn createMatchingDictionary(match: Match) !c.CFMutableDictionaryRef {
    const dictionary = c.CFDictionaryCreateMutable(
        c.kCFAllocatorDefault,
        if (match.usage_page == null) 2 else 4,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return error.OutOfMemory;
    errdefer c.CFRelease(dictionary);

    try setDictionaryInteger(dictionary, "VendorID", match.vendor_id);
    try setDictionaryInteger(dictionary, "ProductID", match.product_id);
    if (match.usage_page) |usage_page| {
        try setDictionaryInteger(dictionary, "PrimaryUsagePage", usage_page);
    }
    if (match.usage) |usage| {
        try setDictionaryInteger(dictionary, "PrimaryUsage", usage);
    }
    return dictionary;
}

fn setDictionaryInteger(dictionary: c.CFMutableDictionaryRef, name: [*:0]const u8, value: i32) !void {
    const key = c.CFStringCreateWithCString(
        c.kCFAllocatorDefault,
        name,
        c.kCFStringEncodingUTF8,
    ) orelse return error.OutOfMemory;
    defer c.CFRelease(key);
    var number_value = value;
    const number = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberIntType, &number_value) orelse
        return error.OutOfMemory;
    defer c.CFRelease(number);
    c.CFDictionarySetValue(dictionary, key, number);
}

fn getIntegerProperty(device: c.IOHIDDeviceRef, name: [*:0]const u8) ?i32 {
    const key = c.CFStringCreateWithCString(
        c.kCFAllocatorDefault,
        name,
        c.kCFStringEncodingUTF8,
    ) orelse return null;
    defer c.CFRelease(key);
    const property = c.IOHIDDeviceGetProperty(device, key) orelse return null;
    if (c.CFGetTypeID(property) != c.CFNumberGetTypeID()) return null;
    var value: i32 = 0;
    if (c.CFNumberGetValue(@ptrCast(property), c.kCFNumberIntType, &value) == 0) return null;
    return value;
}
