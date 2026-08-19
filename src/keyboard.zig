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
pub const maximum_payload_size = 56;
pub const side_light_first_index: u8 = 84;
pub const side_light_count = 20;

pub fn sleepMilliseconds(milliseconds: u32) void {
    _ = c.usleep(milliseconds * 1000);
}

const vendor_id: i32 = 0x19f5;
const product_id: i32 = 0x1028;
const usage_page: i32 = 1;
const usage: i32 = 0;

const command = struct {
    const get_firmware_info: u8 = 0xa1;
    const get_light_count: u8 = 0xd1;
    const get_light_color: u8 = 0xd2;
    const get_light_state: u8 = 0xd5;
    const set_light_state: u8 = 0xd6;
    const set_direct_lights: u8 = 0xd8;
    const set_secret_key: u8 = 0xee;
};

pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,

    pub const black: Color = .{ .red = 0, .green = 0, .blue = 0 };
};

pub const LightingState = [17]u8;

const Response = struct {
    payload: [maximum_payload_size]u8 = @splat(0),
    length: u8,
};

pub const Keyboard = struct {
    manager: c.IOHIDManagerRef,
    devices: c.CFSetRef,
    device: c.IOHIDDeviceRef,
    input_buffer: [report_size]u8 = @splat(0),
    response: ?[report_size]u8 = null,
    awaiting_command: u8 = 0,
    started: bool = false,

    pub fn open() !Keyboard {
        const manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone) orelse
            return error.ManagerCreateFailed;
        errdefer c.CFRelease(manager);

        const matching = try createMatchingDictionary();
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

    pub fn start(self: *Keyboard) void {
        c.IOHIDDeviceRegisterInputReportCallback(
            self.device,
            &self.input_buffer,
            report_size,
            inputReportCallback,
            self,
        );
        self.started = true;
    }

    pub fn close(self: *Keyboard) void {
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

    pub fn firmwareInfo(self: *Keyboard) ![8]u8 {
        const response = try self.transact(command.get_firmware_info, 8, 0, 0, &.{});
        var result: [8]u8 = undefined;
        @memcpy(&result, response.payload[0..8]);
        return result;
    }

    pub fn lightCount(self: *Keyboard) !u8 {
        const response = try self.transact(command.get_light_count, 1, 0, 0, &.{});
        return response.payload[0];
    }

    pub fn readLightingState(self: *Keyboard, handle: u8) !LightingState {
        const response = try self.transact(command.get_light_state, 17, 0, handle, &.{});
        var result: LightingState = undefined;
        @memcpy(&result, response.payload[0..17]);
        return result;
    }

    pub fn setLightingState(self: *Keyboard, handle: u8, state: LightingState) !void {
        const response = try self.transact(command.set_light_state, 17, 0, handle, &state);
        if (!std.mem.eql(u8, response.payload[0..17], &state)) return error.InvalidResponse;
    }

    pub fn setLightingStateVerified(self: *Keyboard, handle: u8, state: LightingState) !void {
        try self.setLightingState(handle, state);
        for (0..5) |attempt| {
            if (attempt > 0) _ = c.usleep(120_000);
            const actual = try self.readLightingState(handle);
            if (std.mem.eql(u8, &actual, &state)) return;
        }
        return error.VerificationFailed;
    }

    pub fn readColors(
        self: *Keyboard,
        first_index: u8,
        colors: []Color,
    ) !void {
        if (colors.len > 256 - @as(usize, first_index)) return error.TooManyColors;
        var offset: usize = 0;
        while (offset < colors.len) {
            const count: usize = @min(colors.len - offset, 18);
            const byte_count: usize = count * 3;
            const length: u8 = @intCast(byte_count);
            const address: u16 = @intCast((@as(usize, first_index) + offset) * 3);
            const response = try self.transact(command.get_light_color, length, address, 0, &.{});
            for (0..count) |index| {
                const source = index * 3;
                colors[offset + index] = .{
                    .red = response.payload[source],
                    .green = response.payload[source + 1],
                    .blue = response.payload[source + 2],
                };
            }
            offset += count;
        }
    }

    pub fn setColors(self: *Keyboard, first_index: u8, colors: []const Color) !void {
        if (colors.len > 256 - @as(usize, first_index)) return error.TooManyColors;
        var offset: usize = 0;
        while (offset < colors.len) {
            const count: usize = @min(colors.len - offset, 14);
            var payload: [maximum_payload_size]u8 = @splat(0);
            for (0..count) |index| {
                const target = index * 4;
                const color = colors[offset + index];
                payload[target] = @intCast(@as(usize, first_index) + offset + index);
                payload[target + 1] = color.red;
                payload[target + 2] = color.green;
                payload[target + 3] = color.blue;
            }
            const byte_count: usize = count * 4;
            const length: u8 = @intCast(byte_count);
            const response = try self.transact(
                command.set_direct_lights,
                length,
                0,
                0,
                payload[0..length],
            );
            if (!std.mem.eql(u8, response.payload[0..length], payload[0..length])) {
                return error.InvalidResponse;
            }
            offset += count;
        }
    }

    pub fn setColorsVerified(self: *Keyboard, first_index: u8, colors: []const Color) !void {
        try self.setColors(first_index, colors);
        _ = c.usleep(100_000);
        try self.verifyColors(first_index, colors);
    }

    pub fn verifyColors(self: *Keyboard, first_index: u8, colors: []const Color) !void {
        var actual: [side_light_count]Color = undefined;
        if (colors.len > actual.len) return error.TooManyColors;
        try self.readColors(first_index, actual[0..colors.len]);
        for (colors, actual[0..colors.len]) |expected, observed| {
            if (!std.meta.eql(expected, observed)) return error.VerificationFailed;
        }
    }

    fn transact(
        self: *Keyboard,
        requested_command: u8,
        length: u8,
        address: u16,
        handle: u8,
        payload: []const u8,
    ) !Response {
        if (length > maximum_payload_size or payload.len > maximum_payload_size) {
            return error.PayloadTooLarge;
        }

        var handshake: [report_size]u8 = @splat(0);
        handshake[0] = 0x55;
        handshake[1] = command.set_secret_key;
        c.arc4random_buf(&handshake[8], maximum_payload_size);
        if (handshake[28] == 0) handshake[28] = 0xaa;
        handshake[3] = checksum(&handshake);
        const handshake_response = try self.sendAndReceive(&handshake, command.set_secret_key);
        try validateRawResponse(&handshake_response, command.set_secret_key);

        const session_key = handshake[28];
        const request = makeRequest(
            requested_command,
            length,
            address,
            handle,
            payload,
            session_key,
        );
        const raw_response = try self.sendAndReceive(&request, requested_command);
        return decodeResponse(
            &raw_response,
            requested_command,
            length,
            address,
            handle,
            session_key,
        );
    }

    fn sendAndReceive(
        self: *Keyboard,
        report: *const [report_size]u8,
        requested_command: u8,
    ) ![report_size]u8 {
        self.response = null;
        self.awaiting_command = requested_command;
        const result = c.IOHIDDeviceSetReport(
            self.device,
            c.kIOHIDReportTypeOutput,
            0,
            report,
            report_size,
        );
        if (result != c.kIOReturnSuccess) return error.WriteFailed;

        for (0..75) |_| {
            _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0.02, 1);
            if (self.response) |response| return response;
        }
        return error.ResponseTimeout;
    }
};

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
    const self: *Keyboard = @ptrCast(@alignCast(context.?));
    if (report[0] != 0xaa or report[1] != self.awaiting_command) return;
    var response: [report_size]u8 = undefined;
    @memcpy(&response, report[0..report_size]);
    self.response = response;
}

fn createMatchingDictionary() !c.CFMutableDictionaryRef {
    const dictionary = c.CFDictionaryCreateMutable(
        c.kCFAllocatorDefault,
        4,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return error.OutOfMemory;
    errdefer c.CFRelease(dictionary);

    try setDictionaryInteger(dictionary, "VendorID", vendor_id);
    try setDictionaryInteger(dictionary, "ProductID", product_id);
    try setDictionaryInteger(dictionary, "PrimaryUsagePage", usage_page);
    try setDictionaryInteger(dictionary, "PrimaryUsage", usage);
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

fn makeRequest(
    requested_command: u8,
    length: u8,
    address: u16,
    handle: u8,
    payload: []const u8,
    session_key: u8,
) [report_size]u8 {
    var report: [report_size]u8 = @splat(0);
    report[0] = 0x55;
    report[1] = requested_command;
    report[4] = length ^ session_key;
    report[5] = @as(u8, @truncate(address)) ^ session_key;
    report[6] = @as(u8, @truncate(address >> 8)) ^ session_key;
    report[7] = handle ^ session_key;
    for (payload, 0..) |byte, index| report[8 + index] = byte ^ session_key;
    report[3] = checksum(&report);
    return report;
}

fn decodeResponse(
    raw: *const [report_size]u8,
    expected_command: u8,
    length: u8,
    address: u16,
    handle: u8,
    session_key: u8,
) !Response {
    try validateRawResponse(raw, expected_command);
    const expected_header = [4]u8{
        length,
        @truncate(address),
        @truncate(address >> 8),
        handle,
    };
    const raw_header = raw[4..8];
    var keyed_header: [4]u8 = undefined;
    for (raw_header, 0..) |byte, index| keyed_header[index] = byte ^ session_key;
    if (!std.mem.eql(u8, raw_header, &expected_header) and
        !std.mem.eql(u8, &keyed_header, &expected_header))
    {
        return error.InvalidResponse;
    }

    var response = Response{ .length = length };
    for (0..length) |index| response.payload[index] = raw[8 + index] ^ session_key;
    return response;
}

fn validateRawResponse(response: *const [report_size]u8, expected_command: u8) !void {
    if (response[0] != 0xaa or response[1] != expected_command) return error.InvalidResponse;
    if (response[3] != checksum(response)) return error.InvalidChecksum;
}

fn checksum(report: *const [report_size]u8) u8 {
    var sum: u8 = 0;
    for (report[4..]) |byte| sum +%= byte;
    return sum;
}

test "request encrypts route and payload then checksums bytes four through sixty-three" {
    const report = makeRequest(0xd5, 3, 0x1234, 1, &.{ 0x10, 0x20, 0x30 }, 0x5a);
    try std.testing.expectEqual(@as(u8, 0x55), report[0]);
    try std.testing.expectEqual(@as(u8, 0xd5), report[1]);
    try std.testing.expectEqual(@as(u8, 3 ^ 0x5a), report[4]);
    try std.testing.expectEqual(@as(u8, 0x34 ^ 0x5a), report[5]);
    try std.testing.expectEqual(@as(u8, 0x12 ^ 0x5a), report[6]);
    try std.testing.expectEqual(@as(u8, 1 ^ 0x5a), report[7]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10 ^ 0x5a, 0x20 ^ 0x5a, 0x30 ^ 0x5a }, report[8..11]);
    try std.testing.expectEqual(checksum(&report), report[3]);
}

test "response decoder accepts plain route and decrypts payload" {
    const key: u8 = 0x3c;
    var raw: [report_size]u8 = @splat(0);
    raw[0] = 0xaa;
    raw[1] = 0xd5;
    raw[4] = 3;
    raw[5] = 0x34;
    raw[6] = 0x12;
    raw[7] = 1;
    raw[8] = 1 ^ key;
    raw[9] = 2 ^ key;
    raw[10] = 3 ^ key;
    raw[3] = checksum(&raw);
    const response = try decodeResponse(&raw, 0xd5, 3, 0x1234, 1, key);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, response.payload[0..3]);
}
