const std = @import("std");
const hid = @import("hid.zig");
const keyboard = @import("keyboard.zig");
const updater = @import("updater.zig");

const usage =
    \\Usage: kbvu-firmware-flash <candidate.bin> [--flash-candidate]
    \\
    \\Without --flash-candidate, only validates the exact candidate size and SHA-256.
    \\With --flash-candidate, enters the Air75 V3 updater, writes and verifies the
    \\hash-locked candidate, then confirms that the application re-enumerates.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return printUsageError();
    const should_flash = args.len == 3 and std.mem.eql(u8, args[2], "--flash-candidate");
    if (args.len == 3 and !should_flash) return printUsageError();

    const image = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(updater.candidate_size + 1),
    );
    defer init.gpa.free(image);
    try updater.validateCandidate(image);
    std.debug.print(
        "Candidate validated: {d} bytes, SHA-256 10df67aaf7d4841cd59340d08a9699e7973fe6b5d8c0fc6aefde992ef0129e7d\n",
        .{image.len},
    );
    if (!should_flash) {
        std.debug.print("Validation only; no device was opened.\n", .{});
        return;
    }

    var boot_device = updater.Updater.open() catch blk: {
        std.debug.print("Requesting the application to enter updater PID 19f5:0722...\n", .{});
        {
            var app_device = try keyboard.Keyboard.open();
            defer app_device.close();
            app_device.start();
            app_device.requestEnterIap() catch |err| {
                // A response timeout or write error is expected if USB drops as
                // the command takes effect. Updater enumeration is authoritative.
                std.debug.print("Application disconnected during IAP request ({t}).\n", .{err});
            };
        }
        break :blk try waitForUpdater();
    };
    boot_device.start();

    std.debug.print("Updater found. Erasing, writing, and verifying the candidate...\n", .{});
    boot_device.flash(image, reportProgress) catch |err| {
        boot_device.close();
        return err;
    };
    boot_device.close();

    std.debug.print("Firmware transfer completed; waiting for application PID 19f5:1028...\n", .{});
    const firmware = try waitForApplication();
    std.debug.print("Application is back. Firmware response:", .{});
    for (firmware) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

fn waitForUpdater() !updater.Updater {
    for (0..30) |_| {
        if (updater.Updater.open()) |device| return device else |_| {}
        hid.sleepMilliseconds(200);
    }
    return error.UpdaterDidNotEnumerate;
}

fn waitForApplication() ![8]u8 {
    for (0..50) |_| {
        if (keyboard.Keyboard.open()) |opened| {
            var device = opened;
            defer device.close();
            device.start();
            if (device.firmwareInfo()) |firmware| return firmware else |_| {}
        } else |_| {}
        hid.sleepMilliseconds(200);
    }
    return error.ApplicationDidNotEnumerate;
}

fn reportProgress(phase: updater.Phase, completed: usize, total: usize) void {
    std.debug.print("  {t}: {d}/{d} blocks\n", .{ phase, completed, total });
}

fn printUsageError() error{InvalidArguments} {
    std.debug.print("{s}", .{usage});
    return error.InvalidArguments;
}
