const std = @import("std");
const keyboard = @import("keyboard.zig");

const Color = keyboard.Color;

const usage =
    \\Usage: kbvu-keyboard-demo [--probe] [--hold-ms N]
    \\
    \\Options:
    \\  --probe       Read identity, lighting state, and side-light colors only
    \\  --hold-ms N   Show each demo pattern for N milliseconds (default: 1500)
    \\  -h, --help    Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var probe_only = false;
    var hold_ms: u32 = 1500;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--probe")) {
            probe_only = true;
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            index += 1;
            if (index >= args.len) return printUsageError("--hold-ms requires a value");
            hold_ms = std.fmt.parseInt(u32, args[index], 10) catch
                return printUsageError("invalid --hold-ms value");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else {
            return printUsageError("unknown argument");
        }
    }

    std.debug.print("Opening NuPhy Air75 V3 ANSI 19f5:1028 management interface...\n", .{});
    var device = try keyboard.Keyboard.open();
    defer device.close();
    device.start();

    const firmware = try device.firmwareInfo();
    std.debug.print("Firmware response:", .{});
    for (firmware) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n", .{});

    const light_count = try device.lightCount();
    std.debug.print("Firmware light count: {d}\n", .{light_count});

    const state = try device.readLightingState(0);
    std.debug.print(
        "macOS profile: backlight mode={d}, side mode={d}, side brightness={d}/255\n",
        .{ state[0], state[9], state[10] },
    );

    var original: [keyboard.side_light_count]Color = undefined;
    try device.readColors(keyboard.side_light_first_index, &original);
    printColors("Side-light colors reported by D2 at indices 84..103", &original);
    if (probe_only) {
        std.debug.print(
            "Probe complete; no lighting or persistent configuration was changed.\n",
            .{},
        );
        return;
    }

    std.debug.print(
        "\nFirst testing the supported D6 whole-side-light zone. Original state will be restored on exit.\n",
        .{},
    );
    var state_mutated = false;
    defer if (state_mutated) {
        std.debug.print("Restoring original lighting state...\n", .{});
        device.setLightingStateVerified(0, state) catch |err| {
            std.debug.print("WARNING: lighting state restoration failed: {t}\n", .{err});
        };
    };

    state_mutated = true;
    try showZonePattern(&device, "both bars static red", stateWithSideColor(state, .{ .red = 255, .green = 0, .blue = 0 }), hold_ms);
    try showZonePattern(&device, "both bars static green", stateWithSideColor(state, .{ .red = 0, .green = 255, .blue = 0 }), hold_ms);
    try showZonePattern(&device, "both bars static blue", stateWithSideColor(state, .{ .red = 0, .green = 0, .blue = 255 }), hold_ms);

    const static_state = stateWithSideColor(state, .{ .red = 32, .green = 32, .blue = 32 });
    try showZonePattern(&device, "both bars dim white (individual-write baseline)", static_state, hold_ms);

    var custom_state = static_state;
    custom_state[0] = 21; // Candidate D8 renderer, proven on the Air100 V3.
    custom_state[4] = 0; // Fixed-color mode.
    std.debug.print("Enabling hidden custom-color effect 21 before D8 writes.\n", .{});
    device.setLightingStateVerified(0, custom_state) catch |err| {
        if (err == error.VerificationFailed) {
            std.debug.print(
                "Custom-color effect 21 did not survive D5 readback; no D8 writes were attempted.\n",
                .{},
            );
        }
        return err;
    };

    var key_baseline: [1]Color = undefined;
    try device.readColors(1, &key_baseline);
    var key_mutated = false;
    defer if (key_mutated) {
        std.debug.print("Restoring known key-light index 1...\n", .{});
        device.setColorsVerified(1, &key_baseline) catch |err| {
            std.debug.print("WARNING: key-light restoration failed: {t}\n", .{err});
        };
    };
    const key_probe = [_]Color{.{ .red = 255, .green = 0, .blue = 255 }};
    key_mutated = true;
    try device.setColorsVerified(1, &key_probe);
    try device.setColorsVerified(1, &key_baseline);
    key_mutated = false;
    std.debug.print("D8 control check at known key-light index 1: PASS\n", .{});

    var baseline: [keyboard.side_light_count]Color = undefined;
    try device.readColors(keyboard.side_light_first_index, &baseline);
    printColors("D2 side-light baseline under custom-color effect 21", &baseline);

    std.debug.print(
        "\nNow testing undocumented D8 per-index writes. The firmware must ACK each write and D2 must report the exact new RGB values.\n",
        .{},
    );
    var colors_mutated = false;
    defer if (colors_mutated) {
        std.debug.print("Restoring the pre-test D2 colors...\n", .{});
        device.setColorsVerified(keyboard.side_light_first_index, &baseline) catch |err| {
            std.debug.print("WARNING: D2 color restoration failed: {t}\n", .{err});
        };
    };

    var pattern: [keyboard.side_light_count]Color = undefined;

    colors_mutated = true;
    @memset(pattern[0..10], Color{ .red = 255, .green = 0, .blue = 0 });
    @memset(pattern[10..20], Color{ .red = 0, .green = 0, .blue = 255 });
    showIndexedPattern(&device, "indices 84..93 red; 94..103 blue", &pattern, hold_ms) catch |err| {
        if (err == error.VerificationFailed) {
            std.debug.print(
                "\nD8 SIDE-LIGHT ROUTE FAILED: the known key-light probe passed, but D2 did not report the requested colors at side-light indices 84..103.\n",
                .{},
            );
        }
        return err;
    };

    @memset(&pattern, Color.black);
    @memset(pattern[0..10], Color{ .red = 0, .green = 255, .blue = 0 });
    try showIndexedPattern(&device, "indices 84..93 full; 94..103 empty", &pattern, hold_ms);

    @memset(&pattern, Color.black);
    @memset(pattern[10..20], Color{ .red = 0, .green = 255, .blue = 255 });
    try showIndexedPattern(&device, "indices 84..93 empty; 94..103 full", &pattern, hold_ms);

    @memset(&pattern, Color.black);
    @memset(pattern[0..3], Color{ .red = 255, .green = 128, .blue = 0 });
    @memset(pattern[10..17], Color{ .red = 160, .green = 0, .blue = 255 });
    try showIndexedPattern(&device, "candidate bars at 3/10 and 7/10", &pattern, hold_ms);

    for (&pattern, 0..) |*color, light_index| {
        color.* = if (light_index % 2 == 0)
            Color{ .red = 255, .green = 255, .blue = 255 }
        else
            Color.black;
    }
    try showIndexedPattern(&device, "alternating side-light indices", &pattern, hold_ms);

    std.debug.print("Demo sequence completed with exact D2 readback after every pattern.\n", .{});
}

fn showZonePattern(
    device: *keyboard.Keyboard,
    description: []const u8,
    state: keyboard.LightingState,
    hold_ms: u32,
) !void {
    std.debug.print("Zone pattern: {s}\n", .{description});
    try device.setLightingStateVerified(0, state);
    keyboard.sleepMilliseconds(hold_ms);
}

fn stateWithSideColor(original: keyboard.LightingState, color: Color) keyboard.LightingState {
    var state = original;
    state[9] = 2; // Static side-light mode.
    state[12] = 0;
    state[13] = 0;
    state[14] = color.red;
    state[15] = color.green;
    state[16] = color.blue;
    return state;
}

fn showIndexedPattern(
    device: *keyboard.Keyboard,
    description: []const u8,
    colors: []const Color,
    hold_ms: u32,
) !void {
    std.debug.print("Indexed pattern: {s}\n", .{description});
    try device.setColors(keyboard.side_light_first_index, colors);
    std.debug.print(
        "Observe the bars now for {d} ms.\n",
        .{hold_ms},
    );
    keyboard.sleepMilliseconds(hold_ms);
    try device.verifyColors(keyboard.side_light_first_index, colors);
}

fn printColors(label: []const u8, colors: []const Color) void {
    std.debug.print("{s}:\n", .{label});
    for (colors, 0..) |color, index| {
        std.debug.print(
            "  {d}: #{x:0>2}{x:0>2}{x:0>2}{s}",
            .{ index + keyboard.side_light_first_index, color.red, color.green, color.blue, if (index == 9) "\n" else "" },
        );
    }
    std.debug.print("\n", .{});
}

fn printUsageError(message: []const u8) error{InvalidArguments} {
    std.debug.print("error: {s}\n\n{s}", .{ message, usage });
    return error.InvalidArguments;
}
