const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cb_mod = b.createModule(.{
        .root_source_file = b.path("../../lib/platform/macos/src/cb.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("cb", cb_mod);

    const exe = b.addExecutable(.{
        .name = "macos_ble_bench",
        .root_module = root_mod,
    });

    exe.addCSourceFile(.{
        .file = b.path("../../lib/platform/macos/src/cb_helper.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.addIncludePath(b.path("../../lib/platform/macos/src"));
    exe.linkFramework("CoreBluetooth");
    exe.linkFramework("Foundation");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run macOS BLE benchmark");
    run_step.dependOn(&run_cmd.step);
}
