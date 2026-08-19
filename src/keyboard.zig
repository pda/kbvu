const std = @import("std");
const hid = @import("hid.zig");

pub const report_size = hid.report_size;
pub const maximum_payload_size = 56;
pub const side_light_first_index: u8 = 84;
pub const side_light_count = 20;

pub fn sleepMilliseconds(milliseconds: u32) void {
    hid.sleepMilliseconds(milliseconds);
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
    const enter_iap: u8 = 0xef;
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
    hid_device: hid.Device,

    pub fn open() !Keyboard {
        return .{
            .hid_device = try hid.Device.open(.{
                .vendor_id = vendor_id,
                .product_id = product_id,
                .usage_page = usage_page,
                .usage = usage,
            }),
        };
    }

    pub fn start(self: *Keyboard) void {
        self.hid_device.start();
    }

    pub fn close(self: *Keyboard) void {
        self.hid_device.close();
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
            if (attempt > 0) hid.sleepMilliseconds(120);
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
        hid.sleepMilliseconds(100);
        try self.verifyColors(first_index, colors);
    }

    pub fn requestEnterIap(self: *Keyboard) !void {
        _ = try self.transact(command.enter_iap, 4, 0, 0, &.{ 2, 0, 0, 0 });
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
        hid.fillRandom(handshake[8..]);
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
        return self.hid_device.sendAndReceive(
            report,
            .{ 0xaa, requested_command },
            1500,
        );
    }
};

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
