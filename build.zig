const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 2, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const sdk_path = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
        @panic("a macOS SDK is required");
    const framework_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{
        sdk_path,
        "System/Library/Frameworks",
    }) };
    const library_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) };
    const include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) };

    const keyboard_module = b.createModule(.{
        .root_source_file = b.path("src/keyboard_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    keyboard_module.addSystemFrameworkPath(framework_path);
    keyboard_module.addLibraryPath(library_path);
    keyboard_module.linkFramework("CoreFoundation", .{});
    keyboard_module.linkFramework("IOKit", .{});
    keyboard_module.link_libc = true;

    const keyboard_executable = b.addExecutable(.{
        .name = "kbvu-keyboard-demo",
        .root_module = keyboard_module,
    });
    b.installArtifact(keyboard_executable);

    const flash_module = b.createModule(.{
        .root_source_file = b.path("src/firmware_flash.zig"),
        .target = target,
        .optimize = optimize,
    });
    flash_module.addSystemFrameworkPath(framework_path);
    flash_module.addLibraryPath(library_path);
    flash_module.linkFramework("CoreFoundation", .{});
    flash_module.linkFramework("IOKit", .{});
    flash_module.link_libc = true;
    const flash_executable = b.addExecutable(.{
        .name = "kbvu-firmware-flash",
        .root_module = flash_module,
    });
    b.installArtifact(flash_executable);

    const run_keyboard = b.addRunArtifact(keyboard_executable);
    run_keyboard.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_keyboard.addArgs(args);
    const run_keyboard_step = b.step("run-keyboard-demo", "Run the Air75 V3 side-light demo");
    run_keyboard_step.dependOn(&run_keyboard.step);

    const vu_module = b.createModule(.{
        .root_source_file = b.path("src/vu_meter.zig"),
        .target = target,
        .optimize = optimize,
    });
    vu_module.addSystemFrameworkPath(framework_path);
    vu_module.addLibraryPath(library_path);
    vu_module.addSystemIncludePath(include_path);
    vu_module.addCSourceFile(.{
        .file = b.path("src/audio_capture.m"),
        .flags = &.{"-fobjc-arc"},
    });
    vu_module.addCSourceFile(.{
        .file = b.path("src/menu_bar.m"),
        .flags = &.{"-fobjc-arc"},
    });
    vu_module.linkFramework("AppKit", .{});
    vu_module.linkFramework("Carbon", .{});
    vu_module.linkFramework("CoreAudio", .{});
    vu_module.linkFramework("CoreFoundation", .{});
    vu_module.linkFramework("Foundation", .{});
    vu_module.linkFramework("IOKit", .{});
    vu_module.linkFramework("ServiceManagement", .{});
    vu_module.link_libc = true;

    const vu_executable = b.addExecutable(.{
        .name = "kbvu-vu",
        .root_module = vu_module,
    });
    b.installArtifact(vu_executable);

    const app_binary = b.addInstallFile(
        vu_executable.getEmittedBin(),
        "kbvu.app/Contents/MacOS/kbvu-vu",
    );
    const app_plist = b.addInstallFile(
        b.path("resources/Info.plist"),
        "kbvu.app/Contents/Info.plist",
    );
    const sign_app = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        b.getInstallPath(.prefix, "kbvu.app"),
    });
    sign_app.step.dependOn(&app_binary.step);
    sign_app.step.dependOn(&app_plist.step);
    b.getInstallStep().dependOn(&sign_app.step);

    const live_launcher = b.addInstallFile(
        b.path("tools/run_vu.sh"),
        "bin/kbvu-vu-live",
    );
    b.getInstallStep().dependOn(&live_launcher.step);

    const keyboard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keyboard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    keyboard_tests.root_module.addSystemFrameworkPath(framework_path);
    keyboard_tests.root_module.addLibraryPath(library_path);
    keyboard_tests.root_module.linkFramework("CoreFoundation", .{});
    keyboard_tests.root_module.linkFramework("IOKit", .{});
    keyboard_tests.root_module.link_libc = true;

    const updater_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/updater.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    updater_tests.root_module.addSystemFrameworkPath(framework_path);
    updater_tests.root_module.addLibraryPath(library_path);
    updater_tests.root_module.linkFramework("CoreFoundation", .{});
    updater_tests.root_module.linkFramework("IOKit", .{});
    updater_tests.root_module.link_libc = true;

    const meter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/meter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const keyboard_lights_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keyboard_lights.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    keyboard_lights_tests.root_module.addSystemFrameworkPath(framework_path);
    keyboard_lights_tests.root_module.addLibraryPath(library_path);
    keyboard_lights_tests.root_module.linkFramework("CoreFoundation", .{});
    keyboard_lights_tests.root_module.linkFramework("IOKit", .{});
    keyboard_lights_tests.root_module.link_libc = true;

    const run_keyboard_tests = b.addRunArtifact(keyboard_tests);
    const run_updater_tests = b.addRunArtifact(updater_tests);
    const run_meter_tests = b.addRunArtifact(meter_tests);
    const run_keyboard_lights_tests = b.addRunArtifact(keyboard_lights_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_keyboard_tests.step);
    test_step.dependOn(&run_updater_tests.step);
    test_step.dependOn(&run_meter_tests.step);
    test_step.dependOn(&run_keyboard_lights_tests.step);
}
