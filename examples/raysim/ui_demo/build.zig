const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get raysim dependency
    const raysim_dep = b.dependency("raysim", .{
        .target = target,
        .optimize = optimize,
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "raysim_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add raysim module
    exe.root_module.addImport("raysim", raysim_dep.module("raysim"));

    // Link raylib (from raysim's dependency)
    const raylib_dep = raysim_dep.builder.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(raylib_dep.artifact("raylib"));

    // Install
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);
}
