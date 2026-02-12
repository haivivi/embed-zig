const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const crypto_dep = b.dependency("crypto", .{
        .target = target,
        .optimize = optimize,
    });
    const zgrnet_dep = b.dependency("net/noise", .{
        .target = target,
        .optimize = optimize,
    });
    const kcp_dep = b.dependency("kcp", .{});

    // zgrnet module with KCP C source compiled in
    const zgrnet_mod = zgrnet_dep.module("net/noise");
    zgrnet_mod.addIncludePath(zgrnet_dep.path("src/kcp"));
    zgrnet_mod.addCSourceFile(.{
        .file = kcp_dep.path("ikcp.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-fno-sanitize=undefined" },
    });
    zgrnet_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "noise_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("crypto", crypto_dep.module("crypto"));
    exe.root_module.addImport("net/noise", zgrnet_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Noise + KCP throughput test");
    run_step.dependOn(&run_cmd.step);
}
