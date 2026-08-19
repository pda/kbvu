const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/keyboard_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.linkFramework("CoreFoundation", .{});
    module.linkFramework("IOKit", .{});
    module.link_libc = true;

    const executable = b.addExecutable(.{
        .name = "kbvu-keyboard-demo",
        .root_module = module,
    });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run-keyboard-demo", "Run the Air75 V3 side-light demo");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keyboard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkFramework("CoreFoundation", .{});
    tests.root_module.linkFramework("IOKit", .{});
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
