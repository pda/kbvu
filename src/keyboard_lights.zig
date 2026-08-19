const std = @import("std");
const keyboard = @import("keyboard.zig");
const meter = @import("meter.zig");

const retry_delay_updates = 20;

pub const Status = enum {
    waiting,
    connected,
};

const SavedState = struct {
    lighting: keyboard.LightingState,
    colors: [keyboard.side_light_count]keyboard.Color,
};

pub const Connection = struct {
    active: ?Output = null,
    saved: ?SavedState = null,
    retry_updates: u8 = 0,

    pub fn render(self: *Connection, reading: meter.MeterReading) Status {
        if (self.active) |*output| {
            output.render(reading) catch {
                self.saved = output.savedState();
                output.abandon();
                self.active = null;
                self.retry_updates = retry_delay_updates;
                return .waiting;
            };
            return .connected;
        }

        if (self.retry_updates != 0) {
            self.retry_updates -= 1;
            return .waiting;
        }

        self.active = Output.open() catch {
            self.retry_updates = retry_delay_updates;
            return .waiting;
        };
        const output = &self.active.?;
        output.start(self.saved) catch {
            output.abandon();
            self.active = null;
            self.retry_updates = retry_delay_updates;
            return .waiting;
        };
        self.saved = output.savedState();
        output.render(reading) catch {
            output.abandon();
            self.active = null;
            self.retry_updates = retry_delay_updates;
            return .waiting;
        };
        return .connected;
    }

    pub fn close(self: *Connection) void {
        if (self.active) |*output| output.close();
        self.active = null;
    }
};

pub const Output = struct {
    device: keyboard.Keyboard,
    original_state: keyboard.LightingState = undefined,
    original_colors: [keyboard.side_light_count]keyboard.Color = undefined,
    restore_needed: bool = false,

    pub fn open() !Output {
        return .{ .device = try keyboard.Keyboard.open() };
    }

    pub fn start(self: *Output, saved: ?SavedState) !void {
        self.device.start();
        if (try self.device.lightCount() != 104) return error.UnexpectedLightCount;

        if (saved) |original| {
            self.original_state = original.lighting;
            self.original_colors = original.colors;
        } else {
            var state = try self.device.readLightingState(0);
            if (state[9] == 5) {
                // Recover after an interrupted run before establishing this
                // run's baseline. Mode 4 was the pre-kbvu stock side mode.
                state[9] = 4;
                try self.device.setLightingStateVerified(0, state);
            }
            self.original_state = state;
            try self.device.readColors(keyboard.side_light_first_index, &self.original_colors);
        }
        self.restore_needed = true;

        var custom_state = self.original_state;
        custom_state[0] = 21;
        custom_state[4] = 0;
        custom_state[9] = 5;
        try self.device.setLightingStateVerified(0, custom_state);
    }

    pub fn render(self: *Output, reading: meter.MeterReading) !void {
        const colors = colorsForReading(reading);
        try self.device.setColors(keyboard.side_light_first_index, &colors);
    }

    fn savedState(self: *const Output) SavedState {
        std.debug.assert(self.restore_needed);
        return .{
            .lighting = self.original_state,
            .colors = self.original_colors,
        };
    }

    fn abandon(self: *Output) void {
        self.restore_needed = false;
        self.device.close();
    }

    pub fn close(self: *Output) void {
        if (self.restore_needed) {
            self.device.setColorsVerified(
                keyboard.side_light_first_index,
                &self.original_colors,
            ) catch |err| {
                std.debug.print("warning: side-light color restoration failed: {t}\n", .{err});
            };
            self.device.setLightingStateVerified(0, self.original_state) catch |err| {
                std.debug.print("warning: lighting state restoration failed: {t}\n", .{err});
            };
        }
        self.device.close();
    }
};

pub fn colorsForReading(reading: meter.MeterReading) [keyboard.side_light_count]keyboard.Color {
    var colors: [keyboard.side_light_count]keyboard.Color = @splat(keyboard.Color.black);
    const bass_color = meter.colorForBass(reading.bass_db);
    const color = keyboard.Color{
        .red = bass_color.red,
        .green = bass_color.green,
        .blue = bass_color.blue,
    };

    // The firmware groups the two physical bars as consecutive ten-LED ranges,
    // ordered top-to-bottom. Fill each range from its end so the VU grows up.
    const left_count = meter.segmentsForDbfs(reading.left_dbfs);
    const right_count = meter.segmentsForDbfs(reading.right_dbfs);
    @memset(colors[10 - left_count .. 10], color);
    @memset(colors[20 - right_count .. 20], color);
    return colors;
}

test "stereo levels set independent bar lengths with shared bass color" {
    const colors = colorsForReading(.{
        .left_dbfs = -37,
        .right_dbfs = -13,
        .bass_db = -10,
    });
    const yellow = keyboard.Color{ .red = 255, .green = 210, .blue = 63 };

    for (colors[0..7]) |color| try std.testing.expectEqual(keyboard.Color.black, color);
    for (colors[7..10]) |color| try std.testing.expectEqual(yellow, color);
    for (colors[10..12]) |color| try std.testing.expectEqual(keyboard.Color.black, color);
    for (colors[12..20]) |color| try std.testing.expectEqual(yellow, color);
}

test "silence leaves both bars dark" {
    const colors = colorsForReading(.{
        .left_dbfs = meter.minimum_dbfs,
        .right_dbfs = meter.minimum_dbfs,
        .bass_db = -3,
    });
    for (colors) |color| try std.testing.expectEqual(keyboard.Color.black, color);
}
