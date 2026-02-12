const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });
    const tls_dep = b.dependency("net/tls", .{
        .target = target,
        .optimize = optimize,
    });
    const crypto_dep = b.dependency("crypto", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tls_speed_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("std_impl", std_impl_dep.module("std_impl"));
    exe.root_module.addImport("net/tls", tls_dep.module("net/tls"));
    exe.root_module.addImport("crypto", crypto_dep.module("crypto"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Pass command-line args
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the TLS speed test");
    run_step.dependOn(&run_cmd.step);
}
