const std = @import("std");

pub const bar_cell_count = 10;
pub const minimum_dbfs: f64 = -50.0;
pub const display_interval_seconds: f64 = 0.05;

const queue_capacity = 256;
const default_sample_rate_hz: f64 = 48_000.0;
const bass_cutoff_hz: f64 = 200.0;
const minimum_bass_db: f64 = -60.0;

pub const BlockLevels = struct {
    left_sum_squares: f64,
    right_sum_squares: f64,
    left_bass_sum_squares: f64,
    right_bass_sum_squares: f64,
    sample_count: u32,
};

const LowPass = struct {
    first: f64 = 0,
    second: f64 = 0,

    fn process(self: *LowPass, sample: f64, alpha: f64) f64 {
        self.first += alpha * (sample - self.first);
        self.second += alpha * (self.first - self.second);
        return self.second;
    }
};

/// A bounded single-producer, single-consumer queue. The Core Audio callback is
/// the only producer and the display loop is the only consumer.
pub const SampleQueue = struct {
    blocks: [queue_capacity]BlockLevels,
    write_index: std.atomic.Value(usize),
    read_index: std.atomic.Value(usize),
    dropped_blocks: std.atomic.Value(u64),
    low_pass_alpha: f64,
    left_low_pass: LowPass,
    right_low_pass: LowPass,

    pub fn init() SampleQueue {
        return .{
            .blocks = undefined,
            .write_index = .init(0),
            .read_index = .init(0),
            .dropped_blocks = .init(0),
            .low_pass_alpha = lowPassAlpha(default_sample_rate_hz),
            .left_low_pass = .{},
            .right_low_pass = .{},
        };
    }

    /// Must be called before the producer starts writing samples.
    pub fn configureSampleRate(self: *SampleQueue, sample_rate_hz: f64) void {
        self.low_pass_alpha = lowPassAlpha(sample_rate_hz);
        self.left_low_pass = .{};
        self.right_low_pass = .{};
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
            .left_bass_sum_squares = 0,
            .right_bass_sum_squares = 0,
            .sample_count = frame_count,
        };
        for (0..frame_count) |frame| {
            const sample_index = frame * stride;
            const left_sample: f64 = left[sample_index];
            const right_sample: f64 = right[sample_index];
            block.left_sum_squares += left_sample * left_sample;
            block.right_sum_squares += right_sample * right_sample;

            const left_bass = self.left_low_pass.process(left_sample, self.low_pass_alpha);
            const right_bass = self.right_low_pass.process(right_sample, self.low_pass_alpha);
            block.left_bass_sum_squares += left_bass * left_bass;
            block.right_bass_sum_squares += right_bass * right_bass;
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

pub const MeterReading = struct {
    left_dbfs: f64,
    right_dbfs: f64,
    /// Low-pass energy relative to full-band energy, expressed in decibels.
    bass_db: f64,
};

pub const Rgb = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const Meter = struct {
    displayed: StereoLevels = .{
        .left_dbfs = minimum_dbfs,
        .right_dbfs = minimum_dbfs,
    },
    displayed_bass_db: f64 = minimum_bass_db,
    has_bass_measurement: bool = false,

    const decay_db_per_second = 30.0;
    const bass_smoothing_seconds = 0.15;

    pub fn update(self: *Meter, queue: *SampleQueue, elapsed_seconds: f64) MeterReading {
        var sums = BlockLevels{
            .left_sum_squares = 0,
            .right_sum_squares = 0,
            .left_bass_sum_squares = 0,
            .right_bass_sum_squares = 0,
            .sample_count = 0,
        };
        while (queue.pop()) |block| {
            sums.left_sum_squares += block.left_sum_squares;
            sums.right_sum_squares += block.right_sum_squares;
            sums.left_bass_sum_squares += block.left_bass_sum_squares;
            sums.right_bass_sum_squares += block.right_bass_sum_squares;
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

        const total_energy = sums.left_sum_squares + sums.right_sum_squares;
        const combined_dbfs = if (sums.sample_count == 0)
            minimum_dbfs
        else
            sumSquaresToDbfs(total_energy / 2.0, sums.sample_count);
        const measured_bass_db = if (combined_dbfs <= minimum_dbfs)
            minimum_bass_db
        else
            energyRatioToDb(
                sums.left_bass_sum_squares + sums.right_bass_sum_squares,
                total_energy,
            );
        if (!self.has_bass_measurement) {
            self.displayed_bass_db = measured_bass_db;
            self.has_bass_measurement = true;
        } else {
            const smoothing = 1.0 - @exp(-elapsed_seconds / bass_smoothing_seconds);
            self.displayed_bass_db += smoothing * (measured_bass_db - self.displayed_bass_db);
        }

        return .{
            .left_dbfs = self.displayed.left_dbfs,
            .right_dbfs = self.displayed.right_dbfs,
            .bass_db = self.displayed_bass_db,
        };
    }
};

pub fn segmentsForDbfs(dbfs: f64) usize {
    if (dbfs <= minimum_dbfs) return 0;
    if (dbfs >= 0) return bar_cell_count;
    return @intFromFloat(@ceil((dbfs - minimum_dbfs) / 5.0));
}

pub fn writePlainFrame(writer: *std.Io.Writer, reading: MeterReading) !void {
    const color = colorForBass(reading.bass_db);
    const bass_percent = bassPercent(reading.bass_db);
    try writer.print("L {d:.1} dBFS ", .{reading.left_dbfs});
    try writeBar(writer, reading.left_dbfs, color, false);
    try writer.print(
        " bass {d:.1}% ({d:.1} dB rel) rgb({d},{d},{d})",
        .{ bass_percent, reading.bass_db, color.red, color.green, color.blue },
    );
    try writer.print("\nR {d:.1} dBFS ", .{reading.right_dbfs});
    try writeBar(writer, reading.right_dbfs, color, false);
    try writer.print(
        " bass {d:.1}% ({d:.1} dB rel) rgb({d},{d},{d})",
        .{ bass_percent, reading.bass_db, color.red, color.green, color.blue },
    );
    try writer.writeByte('\n');
}

pub fn writeAnsiFrame(writer: *std.Io.Writer, reading: MeterReading, first_frame: bool) !void {
    const color = colorForBass(reading.bass_db);
    if (!first_frame) try writer.writeAll("\x1b[1A\r");
    try writer.writeAll("\x1b[2K\rL ");
    try writeBar(writer, reading.left_dbfs, color, true);
    try writer.writeAll("\n\x1b[2K\rR ");
    try writeBar(writer, reading.right_dbfs, color, true);
}

pub fn feedTestAudio(queue: *SampleQueue, frame_index: usize) void {
    const frame_count = 2400;
    const target_dbfs = [_]StereoLevels{
        .{ .left_dbfs = -6, .right_dbfs = -18 },
        .{ .left_dbfs = -18, .right_dbfs = -6 },
        .{ .left_dbfs = -12, .right_dbfs = -12 },
        .{ .left_dbfs = minimum_dbfs, .right_dbfs = minimum_dbfs },
    };
    const frequencies_hz = [_]f64{ 80, 2000, 200, 80 };
    const target = target_dbfs[frame_index % target_dbfs.len];
    const left_peak = dbfsToSinePeak(target.left_dbfs);
    const right_peak = dbfsToSinePeak(target.right_dbfs);
    const frequency_hz = frequencies_hz[frame_index % frequencies_hz.len];

    var samples: [frame_count * 2]f32 = undefined;
    for (0..frame_count) |frame| {
        // Every selected frequency completes an exact number of periods in a block.
        const phase = 2.0 * std.math.pi * frequency_hz *
            @as(f64, @floatFromInt(frame)) / default_sample_rate_hz;
        samples[frame * 2] = @floatCast(@sin(phase) * left_peak);
        samples[frame * 2 + 1] = @floatCast(@sin(phase) * right_peak);
    }
    queue.pushStrided(samples[0..].ptr, samples[1..].ptr, frame_count, 2);
}

export fn kbvu_audio_configure(context: ?*anyopaque, sample_rate_hz: f64) callconv(.c) void {
    const queue: *SampleQueue = @ptrCast(@alignCast(context orelse return));
    queue.configureSampleRate(sample_rate_hz);
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

fn lowPassAlpha(sample_rate_hz: f64) f64 {
    return 1.0 - @exp(-2.0 * std.math.pi * bass_cutoff_hz / sample_rate_hz);
}

fn energyRatioToDb(filtered_energy: f64, total_energy: f64) f64 {
    const ratio = std.math.clamp(filtered_energy / total_energy, 0.000001, 1.0);
    return 10.0 * std.math.log10(ratio);
}

fn bassPercent(bass_db: f64) f64 {
    return 100.0 * std.math.pow(f64, 10.0, bass_db / 10.0);
}

fn applyBallistics(displayed: f64, measured: f64, decay: f64) f64 {
    if (measured >= displayed) return measured;
    return @max(measured, displayed - decay);
}

fn dbfsToSinePeak(dbfs: f64) f64 {
    if (dbfs <= minimum_dbfs) return 0;
    return std.math.pow(f64, 10.0, dbfs / 20.0) * std.math.sqrt2;
}

pub fn colorForBass(bass_db: f64) Rgb {
    const cyan = Rgb{ .red = 51, .green = 199, .blue = 255 };
    const yellow = Rgb{ .red = 255, .green = 210, .blue = 63 };
    const red = Rgb{ .red = 255, .green = 0, .blue = 0 };
    if (bass_db <= -20.0) return cyan;
    if (bass_db < -10.0) return interpolateColor(cyan, yellow, (bass_db + 20.0) / 10.0);
    if (bass_db < -4.0) return interpolateColor(yellow, red, (bass_db + 10.0) / 6.0);
    return red;
}

fn interpolateColor(start: Rgb, end: Rgb, amount: f64) Rgb {
    return .{
        .red = interpolateByte(start.red, end.red, amount),
        .green = interpolateByte(start.green, end.green, amount),
        .blue = interpolateByte(start.blue, end.blue, amount),
    };
}

fn interpolateByte(start: u8, end: u8, amount: f64) u8 {
    const start_float: f64 = @floatFromInt(start);
    const end_float: f64 = @floatFromInt(end);
    return @intFromFloat(@round(start_float + amount * (end_float - start_float)));
}

fn writeBar(writer: *std.Io.Writer, dbfs: f64, color: Rgb, ansi: bool) !void {
    const filled = segmentsForDbfs(dbfs);
    if (filled != 0) {
        if (ansi) try writer.print(
            "\x1b[38;2;{d};{d};{d}m",
            .{ color.red, color.green, color.blue },
        );
        for (0..filled) |_| try writer.writeAll("▪");
    }
    if (filled != bar_cell_count) {
        if (ansi) try writer.writeAll("\x1b[2;37m");
        for (filled..bar_cell_count) |_| try writer.writeAll("▫");
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
    try std.testing.expect(levels.bass_db > -3.0);
}

test "bass measurement distinguishes low and high frequencies without changing RMS" {
    const test_sample_rate_hz = 44_100.0;
    const frame_count = 4410;
    const peak = dbfsToSinePeak(-12.0);
    var samples: [frame_count * 2]f32 = undefined;

    var low_queue = SampleQueue.init();
    low_queue.configureSampleRate(test_sample_rate_hz);
    for (0..frame_count) |frame| {
        const phase = 2.0 * std.math.pi * 80.0 *
            @as(f64, @floatFromInt(frame)) / test_sample_rate_hz;
        const sample: f32 = @floatCast(@sin(phase) * peak);
        samples[frame * 2] = sample;
        samples[frame * 2 + 1] = sample;
    }
    low_queue.pushStrided(samples[0..].ptr, samples[1..].ptr, frame_count, 2);
    var low_meter = Meter{};
    const low = low_meter.update(&low_queue, display_interval_seconds);

    var high_queue = SampleQueue.init();
    high_queue.configureSampleRate(test_sample_rate_hz);
    for (0..frame_count) |frame| {
        const phase = 2.0 * std.math.pi * 2000.0 *
            @as(f64, @floatFromInt(frame)) / test_sample_rate_hz;
        const sample: f32 = @floatCast(@sin(phase) * peak);
        samples[frame * 2] = sample;
        samples[frame * 2 + 1] = sample;
    }
    high_queue.pushStrided(samples[0..].ptr, samples[1..].ptr, frame_count, 2);
    var high_meter = Meter{};
    const high = high_meter.update(&high_queue, display_interval_seconds);

    try std.testing.expectApproxEqAbs(-12.0, low.left_dbfs, 0.001);
    try std.testing.expectApproxEqAbs(low.left_dbfs, high.left_dbfs, 0.001);
    try std.testing.expect(low.bass_db > -3.0);
    try std.testing.expect(high.bass_db < -30.0);
}

test "bass color falls toward neutral when audio stops" {
    var queue = SampleQueue.init();
    var meter = Meter{};
    feedTestAudio(&queue, 0);
    const playing = meter.update(&queue, display_interval_seconds);
    const silent = meter.update(&queue, display_interval_seconds);

    try std.testing.expect(silent.bass_db < playing.bass_db);
    try std.testing.expect(silent.bass_db > minimum_bass_db);
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

test "bass color runs from cyan through yellow to red" {
    try std.testing.expectEqual(Rgb{ .red = 51, .green = 199, .blue = 255 }, colorForBass(-20));
    try std.testing.expectEqual(Rgb{ .red = 153, .green = 205, .blue = 159 }, colorForBass(-15));
    try std.testing.expectEqual(Rgb{ .red = 255, .green = 210, .blue = 63 }, colorForBass(-10));
    try std.testing.expectEqual(Rgb{ .red = 255, .green = 0, .blue = 0 }, colorForBass(-4));
}

test "plain renderer is deterministic and contains ten cells per channel" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writePlainFrame(&writer, .{ .left_dbfs = -6, .right_dbfs = -18, .bass_db = -3 });

    try std.testing.expectEqualStrings(
        "L -6.0 dBFS ▪▪▪▪▪▪▪▪▪▫ bass 50.1% (-3.0 dB rel) rgb(255,0,0)\n" ++
            "R -18.0 dBFS ▪▪▪▪▪▪▪▫▫▫ bass 50.1% (-3.0 dB rel) rgb(255,0,0)\n",
        writer.buffered(),
    );
}

test "ANSI renderer uses exactly two terminal lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeAnsiFrame(&writer, .{ .left_dbfs = -6, .right_dbfs = -18, .bass_db = -3 }, true);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "\n"));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b[2K\rL "));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\n\x1b[2K\rR ") != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, writer.buffered(), "\x1b[38;2;255;0;0m"),
    );
}
