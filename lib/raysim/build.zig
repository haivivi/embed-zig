const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Debug log file path option (empty = disabled)
    const log_file = b.option([]const u8, "log_file", "Debug log file path (e.g. /tmp/raysim.log)") orelse "";

    // Get raylib dependency
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options for raysim
    const options = b.addOptions();
    options.addOption([]const u8, "log_file", log_file);

    // Create raysim module
    const raysim_module = b.addModule("raysim", .{
        .root_source_file = b.path("src/raysim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add build options and raylib imports
    raysim_module.addOptions("build_options", options);
    raysim_module.addImport("raylib", raylib_dep.module("raylib"));
    raysim_module.addImport("raygui", raylib_dep.module("raygui"));

    // Also export raylib modules for consumers
    _ = b.addModule("raylib", .{
        .root_source_file = raylib_dep.module("raylib").root_source_file,
        .target = target,
        .optimize = optimize,
    });

    // Tests (test sim_state separately to avoid comptime issues)
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "log_file", "");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/sim_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", test_options);

    const sim_state_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_sim_state_tests = b.addRunArtifact(sim_state_tests);
    const test_step = b.step("test", "Run raysim tests");
    test_step.dependOn(&run_sim_state_tests.step);
}
