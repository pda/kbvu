const std = @import("std");
const keyboard_lights = @import("keyboard_lights.zig");
const meter = @import("meter.zig");

const Capture = opaque {};

const MenuSnapshot = extern struct {
    frames_sent: u64,
    frames_suppressed: u64,
    output_reports: u64,
    input_reports: u64,
    hid_busy_nanoseconds: u64,
    usb_link_speed_bps: u64,
    reply_latency_average_ms: f64,
    reply_latency_median_ms: f64,
    reply_latency_p99_ms: f64,
    reply_latency_samples: u16,
    usb_vendor_id: u16,
    usb_product_id: u16,
    hid_report_size: u8,
    left_segments: u8,
    right_segments: u8,
    red: u8,
    green: u8,
    blue: u8,
};

comptime {
    if (@sizeOf(MenuSnapshot) != 88) @compileError("unexpected menu snapshot layout");
}

extern fn kbvu_capture_start(
    context: *anyopaque,
    out_capture: *?*Capture,
    error_message: [*]u8,
    error_capacity: usize,
) callconv(.c) c_int;
extern fn kbvu_capture_stop(capture: *Capture) callconv(.c) void;
extern fn kbvu_is_app_bundle() callconv(.c) c_int;
extern fn kbvu_menubar_start() callconv(.c) c_int;
extern fn kbvu_menubar_pump() callconv(.c) void;
extern fn kbvu_menubar_show_error(message: [*:0]const u8) callconv(.c) void;
extern fn kbvu_menubar_set_keyboard_connected(connected: c_int) callconv(.c) void;
extern fn kbvu_menubar_set_tick_context(context: ?*anyopaque) callconv(.c) void;
extern fn kbvu_menubar_stop() callconv(.c) void;

const Source = enum {
    system,
    test_audio,
};

const OutputMode = enum {
    none,
    plain,
    ansi,
};

const Options = struct {
    source: Source = .system,
    output: OutputMode = .none,
    keyboard: bool = false,
    menubar: bool = false,
    frame_count: ?usize = null,
    launched_as_app: bool = false,
};

const MenuTrackingContext = struct {
    queue: *meter.SampleQueue,
    levels: *meter.Meter,
    lights: *?keyboard_lights.Connection,
    keyboard_status: keyboard_lights.Status = .waiting,
    menubar: bool,

    fn renderKeyboard(self: *MenuTrackingContext, reading: meter.MeterReading) void {
        const status = if (self.lights.*) |*connection|
            connection.render(reading)
        else
            return;
        if (status == self.keyboard_status) return;

        self.keyboard_status = status;
        if (self.menubar) {
            kbvu_menubar_set_keyboard_connected(if (status == .connected) 1 else 0);
        }
    }
};

const usage =
    \\Usage: kbvu-vu [--source system|test] [--ansi|--plain] [--keyboard] [--frames N]
    \\
    \\Measure the Mac's stereo system output. Terminal output is disabled by
    \\default. Bar length is volume; the shared cyan-to-red colour shows
    \\low-frequency energy. Press Ctrl-C to exit.
    \\
    \\Options:
    \\  --source system  Capture the global system-output mix (default)
    \\  --source test    Use deterministic stereo test tones; no permission needed
    \\  --ansi           Show the compact live ANSI meter in the terminal
    \\  --plain          Print numeric dBFS snapshots without ANSI cursor movement
    \\  --keyboard       Render stereo level and bass colour on the Air75 side LEDs
    \\  --frames N       Exit after N display frames (useful for automated tests)
    \\  -h, --help       Show this help
    \\
;

var keep_running = std.atomic.Value(bool).init(true);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = try parseOptions(args);
    if (args.len == 1 and kbvu_is_app_bundle() != 0) {
        options.keyboard = true;
        options.menubar = true;
        options.launched_as_app = true;
    }
    if (!options.keyboard and options.output == .none) {
        return printUsageError("select --keyboard, --ansi, or --plain");
    }
    if (options.source == .system and !options.launched_as_app) {
        std.debug.print(
            "system capture must be launched as the signed app so macOS can grant it audio permission; run `zig build`, then `open zig-out/kbvu.app` or use `./zig-out/bin/kbvu-vu-live --ansi`\n",
            .{},
        );
        return error.UseAppLauncher;
    }

    keep_running.store(true, .monotonic);
    if (options.menubar) {
        if (kbvu_menubar_start() != 0) return error.MenuBarStartFailed;
    }
    defer if (options.menubar) kbvu_menubar_stop();

    var queue = meter.SampleQueue.init();
    var capture: ?*Capture = null;
    if (options.source == .system) {
        var error_buffer: [256]u8 = undefined;
        const status = kbvu_capture_start(
            &queue,
            &capture,
            &error_buffer,
            error_buffer.len,
        );
        if (status != 0) {
            const message = std.mem.sliceTo(&error_buffer, 0);
            std.debug.print(
                "audio capture error: {s}\nEnable System Settings → Privacy & Security → System Audio Recording Only for kbvu-vu, then retry.\n",
                .{message},
            );
            if (options.menubar) kbvu_menubar_show_error(
                "System audio capture failed. Enable Keyboard VU in System Settings → Privacy & Security → System Audio Recording Only, then reopen it.",
            );
            return error.AudioCaptureFailed;
        }
    }
    defer if (capture) |active_capture| kbvu_capture_stop(active_capture);

    var lights: ?keyboard_lights.Connection = if (options.keyboard) .{} else null;
    defer if (lights) |*connection| connection.close();
    if (options.menubar and options.keyboard) kbvu_menubar_set_keyboard_connected(0);

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_action);
    defer std.posix.sigaction(.INT, &old_action, null);
    var old_term_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, &action, &old_term_action);
    defer std.posix.sigaction(.TERM, &old_term_action, null);

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer if (options.output != .none) stdout.flush() catch {};

    defer if (options.output == .ansi) {
        stdout.writeAll("\x1b[0m\n") catch {};
        stdout.flush() catch {};
    };

    var levels = meter.Meter{};
    var menu_tracking_context = MenuTrackingContext{
        .queue = &queue,
        .levels = &levels,
        .lights = &lights,
        .menubar = options.menubar,
    };
    if (options.menubar) kbvu_menubar_set_tick_context(&menu_tracking_context);
    defer if (options.menubar) kbvu_menubar_set_tick_context(null);

    const frame_interval: std.Io.Clock.Duration = .{
        .raw = .fromNanoseconds(
            @intFromFloat(meter.display_interval_seconds * std.time.ns_per_s),
        ),
        .clock = .awake,
    };
    var next_frame = std.Io.Clock.Timestamp.now(init.io, .awake);
    if (options.source == .system) {
        next_frame = next_frame.addDuration(frame_interval);
    }

    var frame_index: usize = 0;
    while (keep_running.load(.monotonic) and
        (options.frame_count == null or frame_index < options.frame_count.?))
    {
        if (options.menubar) {
            kbvu_menubar_pump();
            if (!keep_running.load(.monotonic)) break;
        }
        try next_frame.wait(init.io);
        const frame_started = std.Io.Clock.Timestamp.now(init.io, .awake);
        next_frame = next_frame.addDuration(frame_interval);
        if (next_frame.compare(.lt, frame_started)) {
            next_frame = frame_started.addDuration(frame_interval);
        }

        if (options.source == .test_audio) {
            meter.feedTestAudio(&queue, frame_index);
        }

        const current = levels.update(&queue, meter.display_interval_seconds);
        menu_tracking_context.renderKeyboard(current);
        switch (options.output) {
            .none => {},
            .plain => try meter.writePlainFrame(stdout, current),
            .ansi => try meter.writeAnsiFrame(stdout, current, frame_index == 0),
        }
        if (options.output != .none) try stdout.flush();
        frame_index += 1;
    }

    const dropped = queue.dropped_blocks.load(.monotonic);
    if (dropped != 0) {
        std.debug.print("warning: dropped {d} audio blocks because the display fell behind\n", .{dropped});
    }
}

fn parseOptions(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--source")) {
            index += 1;
            if (index >= args.len) return printUsageError("--source requires a value");
            if (std.mem.eql(u8, args[index], "system")) {
                options.source = .system;
            } else if (std.mem.eql(u8, args[index], "test")) {
                options.source = .test_audio;
            } else {
                return printUsageError("--source must be system or test");
            }
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            if (options.output != .none) return printUsageError("--ansi and --plain cannot be combined");
            options.output = .ansi;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            if (options.output != .none) return printUsageError("--ansi and --plain cannot be combined");
            options.output = .plain;
        } else if (std.mem.eql(u8, arg, "--keyboard")) {
            options.keyboard = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) return printUsageError("--frames requires a value");
            options.frame_count = std.fmt.parseInt(usize, args[index], 10) catch
                return printUsageError("invalid --frames value");
            if (options.frame_count.? == 0) return printUsageError("--frames must be greater than zero");
        } else if (std.mem.eql(u8, arg, "--launched-as-app")) {
            options.launched_as_app = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            return printUsageError("unknown argument");
        }
    }
    return options;
}

fn handleInterrupt(_: std.posix.SIG) callconv(.c) void {
    kbvu_request_stop();
}

export fn kbvu_request_stop() callconv(.c) void {
    keep_running.store(false, .monotonic);
}

export fn kbvu_display_interval_seconds() callconv(.c) f64 {
    return meter.display_interval_seconds;
}

export fn kbvu_menu_tracking_tick(
    raw_context: *anyopaque,
    snapshot: *MenuSnapshot,
) callconv(.c) c_int {
    if (!keep_running.load(.monotonic)) return 1;
    const context: *MenuTrackingContext = @ptrCast(@alignCast(raw_context));
    const current = context.levels.update(
        context.queue,
        meter.display_interval_seconds,
    );
    context.renderKeyboard(current);
    const color = meter.colorForBass(current.bass_db);
    const stats = if (context.lights.*) |*connection|
        connection.stats()
    else
        keyboard_lights.Stats{};
    snapshot.* = .{
        .frames_sent = stats.frames_sent,
        .frames_suppressed = stats.frames_suppressed,
        .output_reports = stats.output_reports,
        .input_reports = stats.input_reports,
        .hid_busy_nanoseconds = stats.hid_busy_nanoseconds,
        .usb_link_speed_bps = stats.usb_link_speed_bps,
        .reply_latency_average_ms = stats.reply_latency_average_ms,
        .reply_latency_median_ms = stats.reply_latency_median_ms,
        .reply_latency_p99_ms = stats.reply_latency_p99_ms,
        .reply_latency_samples = stats.reply_latency_samples,
        .usb_vendor_id = stats.usb_vendor_id,
        .usb_product_id = stats.usb_product_id,
        .hid_report_size = stats.hid_report_size,
        .left_segments = @intCast(meter.segmentsForDbfs(current.left_dbfs)),
        .right_segments = @intCast(meter.segmentsForDbfs(current.right_dbfs)),
        .red = color.red,
        .green = color.green,
        .blue = color.blue,
    };
    return 0;
}

fn printUsageError(message: []const u8) error{InvalidArguments} {
    std.debug.print("error: {s}\n\n{s}", .{ message, usage });
    return error.InvalidArguments;
}
