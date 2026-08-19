const std = @import("std");
const hid = @import("hid.zig");

pub const candidate_size = 284_112;
pub const candidate_sha256 = [32]u8{
    0x10, 0xdf, 0x67, 0xaa, 0xf7, 0xd4, 0x84, 0x1c,
    0xd5, 0x93, 0x40, 0xd0, 0x8a, 0x96, 0x99, 0xe7,
    0x97, 0x3f, 0xe6, 0xb5, 0xd8, 0xc0, 0xfc, 0x6a,
    0xef, 0xde, 0x99, 0x2e, 0xf0, 0x12, 0x9e, 0x7d,
};

const vendor_id: i32 = 0x19f5;
const product_id: i32 = 0x0722;
const block_size = 56;

const command = struct {
    const write: u8 = 0x80;
    const erase: u8 = 0x81;
    const verify: u8 = 0x82;
    const finalize: u8 = 0x83;
    const success: u8 = 0x84;
};

pub const Phase = enum {
    write,
    verify,
};

pub const ProgressCallback = *const fn (phase: Phase, completed: usize, total: usize) void;

pub fn validateCandidate(image: []const u8) !void {
    if (image.len != candidate_size) return error.UnexpectedFirmwareSize;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    if (!std.mem.eql(u8, &digest, &candidate_sha256)) return error.UnexpectedFirmwareHash;
}

pub const Updater = struct {
    hid_device: hid.Device,

    pub fn open() !Updater {
        return .{
            .hid_device = try hid.Device.open(.{
                .vendor_id = vendor_id,
                .product_id = product_id,
            }),
        };
    }

    pub fn start(self: *Updater) void {
        self.hid_device.start();
    }

    pub fn close(self: *Updater) void {
        self.hid_device.close();
    }

    pub fn flash(
        self: *Updater,
        image: []const u8,
        progress: ?ProgressCallback,
    ) !void {
        try validateCandidate(image);

        const erase = controlFrame(command.erase, 7, 0);
        try self.sendWithRetries(&erase, false, 5000, 3);

        try self.transfer(command.write, .write, image, progress);
        try self.transfer(command.verify, .verify, image, progress);

        const finalize = controlFrame(command.finalize, 2, 0);
        self.sendWithRetries(&finalize, false, 500, 1) catch |err| switch (err) {
            // Older related bootloaders reboot immediately after 0x83; the
            // caller verifies successful application enumeration afterward.
            error.WriteFailed, error.ResponseTimeout => return,
            else => return err,
        };

        const success = controlFrame(command.success, 1, 1);
        self.sendWithRetries(&success, false, 500, 1) catch |err| switch (err) {
            // Current NuPhyIO sends 0x84, but disconnecting before its response
            // is also consistent with a successful reboot.
            error.WriteFailed, error.ResponseTimeout => {},
            else => return err,
        };
    }

    fn transfer(
        self: *Updater,
        requested_command: u8,
        phase: Phase,
        image: []const u8,
        progress: ?ProgressCallback,
    ) !void {
        const total = (image.len + block_size - 1) / block_size;
        var offset: usize = 0;
        var completed: usize = 0;
        while (offset < image.len) {
            const chunk = image[offset..@min(offset + block_size, image.len)];
            const frame = dataFrame(requested_command, @intCast(offset), chunk);
            try self.sendWithRetries(&frame, true, 500, 3);
            offset += chunk.len;
            completed += 1;
            if (progress) |report| {
                if (completed == total or completed % 256 == 0) {
                    report(phase, completed, total);
                }
            }
        }
    }

    fn sendWithRetries(
        self: *Updater,
        frame: *const [hid.report_size]u8,
        require_zero_status: bool,
        timeout_ms: u32,
        retry_count: usize,
    ) !void {
        for (0..retry_count + 1) |attempt| {
            const response = self.hid_device.sendAndReceive(frame, null, timeout_ms) catch |err| {
                if (attempt == retry_count) return err;
                hid.sleepMilliseconds(500);
                continue;
            };
            if (!require_zero_status or (response[0] == 0 and response[1] == 0)) return;
            if (attempt == retry_count) return error.CommandRejected;
            hid.sleepMilliseconds(500);
        }
        unreachable;
    }
};

fn controlFrame(requested_command: u8, argument: u8, value: u8) [hid.report_size]u8 {
    var frame: [hid.report_size]u8 = @splat(0);
    frame[0] = requested_command;
    frame[1] = argument;
    frame[2] = value;
    return frame;
}

fn dataFrame(requested_command: u8, offset: u32, data: []const u8) [hid.report_size]u8 {
    std.debug.assert(data.len <= block_size);
    var frame: [hid.report_size]u8 = @splat(0);
    frame[0] = requested_command;
    frame[1] = @intCast(data.len);
    frame[2] = @truncate(offset);
    frame[3] = @truncate(offset >> 8);
    frame[4] = @truncate(offset >> 16);
    frame[5] = @truncate(offset >> 24);
    @memcpy(frame[6 .. 6 + data.len], data);
    return frame;
}

test "official Air75 updater control frames" {
    const erase = controlFrame(command.erase, 7, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x07, 0, 0, 0, 0, 0 }, erase[0..7]);

    const finalize = controlFrame(command.finalize, 2, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x83, 0x02, 0, 0 }, finalize[0..4]);

    const success = controlFrame(command.success, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x84, 0x01, 0x01 }, success[0..3]);
}

test "data frame encodes a little-endian offset and short final block" {
    const frame = dataFrame(command.verify, 0x0004_55b8, &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x03, 0xb8, 0x55, 0x04, 0x00, 1, 2, 3 },
        frame[0..9],
    );
    try std.testing.expectEqual(@as(u8, 0), frame[9]);
}

test "candidate manifest rejects wrong size and content" {
    try std.testing.expectError(error.UnexpectedFirmwareSize, validateCandidate(&.{}));
    const wrong: [candidate_size]u8 = @splat(0);
    try std.testing.expectError(error.UnexpectedFirmwareHash, validateCandidate(&wrong));
}
