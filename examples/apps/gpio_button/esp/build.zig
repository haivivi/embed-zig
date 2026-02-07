const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    korvo2_v3,
    esp32s3_devkit,
    lichuang_szp,
    lichuang_gocool,
    sim_raylib,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option
    const board = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    // Debug log file path (for simulator)
    const log_file = b.option([]const u8, "log_file", "Debug log file path (simulator only)") orelse "";

    // Get dependencies
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });

    // Board selection as build option
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // App module
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Common dependencies
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addOptions("build_options", board_options);

    // Platform-specific dependencies
    if (board == .sim_raylib) {
        // Simulator uses raysim drivers
        const raysim_dep = b.dependency("raysim", .{
            .target = target,
            .optimize = optimize,
            .log_file = log_file,
        });
        app_module.addImport("raysim", raysim_dep.module("raysim"));
    } else {
        // ESP boards need ESP and drivers
        const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
        const drivers_dep = b.dependency("drivers", .{ .target = target, .optimize = optimize });
        app_module.addImport("esp", esp_dep.module("esp"));
        app_module.addImport("drivers", drivers_dep.module("drivers"));
    }
}
