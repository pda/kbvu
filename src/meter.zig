const std = @import("std");

pub const bar_cell_count = 10;
pub const minimum_dbfs: f64 = -50.0;
pub const display_interval_seconds: f64 = 0.05;

const queue_capacity = 256;

pub const BlockLevels = struct {
    left_sum_squares: f64,
    right_sum_squares: f64,
    sample_count: u32,
};

/// A bounded single-producer, single-consumer queue. The Core Audio callback is
/// the only producer and the display loop is the only consumer.
pub const SampleQueue = struct {
    blocks: [queue_capacity]BlockLevels,
    write_index: std.atomic.Value(usize),
    read_index: std.atomic.Value(usize),
    dropped_blocks: std.atomic.Value(u64),

    pub fn init() SampleQueue {
        return .{
            .blocks = undefined,
            .write_index = .init(0),
            .read_index = .init(0),
            .dropped_blocks = .init(0),
        };
    }

    pub fn pushStrided(
        self: *SampleQueue,
        left: [*]const f32,
        right: [*]const f32,
        frame_count: u32,
        stride: u32,
    ) void {
        if (frame_count == 0 or stride == 0) return;

        var block = BlockLevels{
            .left_sum_squares = 0,
            .right_sum_squares = 0,
            .sample_count = frame_count,
        };
        for (0..frame_count) |frame| {
            const sample_index = frame * stride;
            const left_sample: f64 = left[sample_index];
            const right_sample: f64 = right[sample_index];
            block.left_sum_squares += left_sample * left_sample;
            block.right_sum_squares += right_sample * right_sample;
        }

        const write_index = self.write_index.load(.monotonic);
        const next_index = (write_index + 1) % queue_capacity;
        if (next_index == self.read_index.load(.acquire)) {
            _ = self.dropped_blocks.fetchAdd(1, .monotonic);
            return;
        }
        self.blocks[write_index] = block;
        self.write_index.store(next_index, .release);
    }

    pub fn pop(self: *SampleQueue) ?BlockLevels {
        const read_index = self.read_index.load(.monotonic);
        if (read_index == self.write_index.load(.acquire)) return null;

        const block = self.blocks[read_index];
        self.read_index.store((read_index + 1) % queue_capacity, .release);
        return block;
    }
};

pub const StereoLevels = struct {
    left_dbfs: f64,
    right_dbfs: f64,
};

pub const Meter = struct {
    displayed: StereoLevels = .{
        .left_dbfs = minimum_dbfs,
        .right_dbfs = minimum_dbfs,
    },

    const decay_db_per_second = 30.0;

    pub fn update(self: *Meter, queue: *SampleQueue, elapsed_seconds: f64) StereoLevels {
        var sums = BlockLevels{
            .left_sum_squares = 0,
            .right_sum_squares = 0,
            .sample_count = 0,
        };
        while (queue.pop()) |block| {
            sums.left_sum_squares += block.left_sum_squares;
            sums.right_sum_squares += block.right_sum_squares;
            sums.sample_count += block.sample_count;
        }

        const measured = if (sums.sample_count == 0)
            StereoLevels{ .left_dbfs = minimum_dbfs, .right_dbfs = minimum_dbfs }
        else
            StereoLevels{
                .left_dbfs = sumSquaresToDbfs(sums.left_sum_squares, sums.sample_count),
                .right_dbfs = sumSquaresToDbfs(sums.right_sum_squares, sums.sample_count),
            };

        const decay = decay_db_per_second * elapsed_seconds;
        self.displayed.left_dbfs = applyBallistics(self.displayed.left_dbfs, measured.left_dbfs, decay);
        self.displayed.right_dbfs = applyBallistics(self.displayed.right_dbfs, measured.right_dbfs, decay);
        return self.displayed;
    }
};

pub fn segmentsForDbfs(dbfs: f64) usize {
    if (dbfs <= minimum_dbfs) return 0;
    if (dbfs >= 0) return bar_cell_count;
    return @intFromFloat(@ceil((dbfs - minimum_dbfs) / 5.0));
}

pub fn writePlainFrame(writer: *std.Io.Writer, levels: StereoLevels) !void {
    try writer.print("L {d:.1} dBFS ", .{levels.left_dbfs});
    try writeBar(writer, levels.left_dbfs, false);
    try writer.print("\nR {d:.1} dBFS ", .{levels.right_dbfs});
    try writeBar(writer, levels.right_dbfs, false);
    try writer.writeByte('\n');
}

pub fn writeAnsiFrame(writer: *std.Io.Writer, levels: StereoLevels, first_frame: bool) !void {
    if (!first_frame) try writer.writeAll("\x1b[1A\r");
    try writer.writeAll("\x1b[2K\rL ");
    try writeBar(writer, levels.left_dbfs, true);
    try writer.writeAll("\n\x1b[2K\rR ");
    try writeBar(writer, levels.right_dbfs, true);
}

pub fn feedTestAudio(queue: *SampleQueue, frame_index: usize) void {
    const frame_count = 320;
    const target_dbfs = [_]StereoLevels{
        .{ .left_dbfs = -6, .right_dbfs = -18 },
        .{ .left_dbfs = -18, .right_dbfs = -6 },
        .{ .left_dbfs = -12, .right_dbfs = -12 },
        .{ .left_dbfs = minimum_dbfs, .right_dbfs = minimum_dbfs },
    };
    const target = target_dbfs[frame_index % target_dbfs.len];
    const left_peak = dbfsToSinePeak(target.left_dbfs);
    const right_peak = dbfsToSinePeak(target.right_dbfs);

    var samples: [frame_count * 2]f32 = undefined;
    for (0..frame_count) |frame| {
        // Twenty exact periods per block make the generated RMS deterministic.
        const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(frame)) / 16.0;
        samples[frame * 2] = @floatCast(@sin(phase) * left_peak);
        samples[frame * 2 + 1] = @floatCast(@sin(phase) * right_peak);
    }
    queue.pushStrided(samples[0..].ptr, samples[1..].ptr, frame_count, 2);
}

export fn kbvu_audio_samples(
    context: ?*anyopaque,
    left: [*]const f32,
    right: [*]const f32,
    frame_count: u32,
    stride: u32,
) callconv(.c) void {
    const queue: *SampleQueue = @ptrCast(@alignCast(context orelse return));
    queue.pushStrided(left, right, frame_count, stride);
}

fn sumSquaresToDbfs(sum_squares: f64, sample_count: u32) f64 {
    const mean_square = sum_squares / @as(f64, @floatFromInt(sample_count));
    const rms = @max(std.math.sqrt(mean_square), 0.000001);
    return @max(minimum_dbfs, 20.0 * std.math.log10(rms));
}

fn applyBallistics(displayed: f64, measured: f64, decay: f64) f64 {
    if (measured >= displayed) return measured;
    return @max(measured, displayed - decay);
}

fn dbfsToSinePeak(dbfs: f64) f64 {
    if (dbfs <= minimum_dbfs) return 0;
    return std.math.pow(f64, 10.0, dbfs / 20.0) * std.math.sqrt2;
}

fn writeBar(writer: *std.Io.Writer, dbfs: f64, ansi: bool) !void {
    const filled = segmentsForDbfs(dbfs);
    for (0..bar_cell_count) |cell| {
        if (ansi) {
            const color = if (cell < filled)
                if (cell < 6) "\x1b[32m" else if (cell < 8) "\x1b[33m" else "\x1b[31m"
            else
                "\x1b[2;37m";
            try writer.writeAll(color);
        }
        try writer.writeAll(if (cell < filled) "▪" else "▫");
    }
    if (ansi) try writer.writeAll("\x1b[0m");
}

test "interleaved stereo samples produce independent RMS levels" {
    var queue = SampleQueue.init();
    const samples = [_]f32{
        0.5,  0.25,
        -0.5, -0.25,
        0.5,  0.25,
        -0.5, -0.25,
    };
    queue.pushStrided(samples[0..].ptr, samples[1..].ptr, 4, 2);

    var meter = Meter{};
    const levels = meter.update(&queue, display_interval_seconds);
    try std.testing.expectApproxEqAbs(-6.0206, levels.left_dbfs, 0.001);
    try std.testing.expectApproxEqAbs(-12.0412, levels.right_dbfs, 0.001);
}

test "planar stereo samples produce independent RMS levels" {
    var queue = SampleQueue.init();
    const left = [_]f32{ 0.25, -0.25, 0.25, -0.25 };
    const right = [_]f32{ 0.5, -0.5, 0.5, -0.5 };
    queue.pushStrided(&left, &right, 4, 1);

    var meter = Meter{};
    const levels = meter.update(&queue, display_interval_seconds);
    try std.testing.expectApproxEqAbs(-12.0412, levels.left_dbfs, 0.001);
    try std.testing.expectApproxEqAbs(-6.0206, levels.right_dbfs, 0.001);
}

test "generated stereo test tone has its documented levels" {
    var queue = SampleQueue.init();
    feedTestAudio(&queue, 0);

    var meter = Meter{};
    const levels = meter.update(&queue, display_interval_seconds);
    try std.testing.expectApproxEqAbs(-6.0, levels.left_dbfs, 0.001);
    try std.testing.expectApproxEqAbs(-18.0, levels.right_dbfs, 0.001);
}

test "meter attacks immediately and decays by elapsed time" {
    var queue = SampleQueue.init();
    var meter = Meter{};
    feedTestAudio(&queue, 0);
    _ = meter.update(&queue, display_interval_seconds);

    feedTestAudio(&queue, 1);
    const levels = meter.update(&queue, display_interval_seconds);
    try std.testing.expectApproxEqAbs(-7.5, levels.left_dbfs, 0.001);
    try std.testing.expectApproxEqAbs(-6.0, levels.right_dbfs, 0.001);
}

test "dBFS maps to ten five-decibel cells" {
    for (0..bar_cell_count + 1) |expected| {
        const dbfs = minimum_dbfs + 5.0 * @as(f64, @floatFromInt(expected));
        try std.testing.expectEqual(expected, segmentsForDbfs(dbfs));
    }
    try std.testing.expectEqual(@as(usize, 0), segmentsForDbfs(-80));
    try std.testing.expectEqual(@as(usize, 1), segmentsForDbfs(-49.9));
    try std.testing.expectEqual(@as(usize, 10), segmentsForDbfs(3));
}

test "plain renderer is deterministic and contains ten cells per channel" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writePlainFrame(&writer, .{ .left_dbfs = -6, .right_dbfs = -18 });

    try std.testing.expectEqualStrings(
        "L -6.0 dBFS ▪▪▪▪▪▪▪▪▪▫\nR -18.0 dBFS ▪▪▪▪▪▪▪▫▫▫\n",
        writer.buffered(),
    );
}

test "ANSI renderer uses exactly two terminal lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeAnsiFrame(&writer, .{ .left_dbfs = -6, .right_dbfs = -18 }, true);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "\n"));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b[2K\rL "));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\n\x1b[2K\rR ") != null);
}
