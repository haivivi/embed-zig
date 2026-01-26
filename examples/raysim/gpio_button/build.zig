const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Debug log file path option (pass to app -> raysim)
    const log_file = b.option([]const u8, "log_file", "Debug log file path (e.g. /tmp/raysim.log)") orelse "";

    // Get gpio_button app dependency with sim_raylib board
    // This internally creates the raysim dependency with log_file option
    const app_dep = b.dependency("gpio_button_app", .{
        .target = target,
        .optimize = optimize,
        .board = .sim_raylib,
        .log_file = log_file,
    });

    // Get raysim from app's internal dependency (same instance)
    const raysim_dep = app_dep.builder.dependency("raysim", .{
        .target = target,
        .optimize = optimize,
        .log_file = log_file,
    });

    // Get raylib from raysim's dependency
    const raylib_dep = raysim_dep.builder.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "gpio_button_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add imports - use raysim from app's dependency to avoid duplication
    exe.root_module.addImport("raysim", raysim_dep.module("raysim"));
    exe.root_module.addImport("app", app_dep.module("app"));

    // Link raylib
    exe.linkLibrary(raylib_dep.artifact("raylib"));

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the simulator");
    run_step.dependOn(&run_cmd.step);
}
